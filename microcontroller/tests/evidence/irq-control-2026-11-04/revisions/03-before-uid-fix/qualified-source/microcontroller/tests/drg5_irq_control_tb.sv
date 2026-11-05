/* compare machine interrupt boundaries, WFI and encoded handler work independently. */
module drg5_irq_control_tb #(parameter bit C_ENABLED = 0);
  import drg5_control_pkg::*;
  localparam int CAPACITY = 512;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
  logic [4:0] hold_i = 0;
  logic in_valid_i = 0, in_ready_o;
  packet_t in_packet_i = '0;
  logic flush_valid_i = 0, flush_ready_o, flush_aborted_o;
  logic [31:0] flush_pc_i = 0;
  logic redirect_valid_o;
  logic [31:0] redirect_pc_o;
  logic d_req_valid_o, d_req_ready_i, d_req_write_o;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o;
  logic [1:0] d_req_size_o;
  logic [3:0] d_req_wstrb_o;
  logic d_rsp_valid_i, d_rsp_ready_o;
  logic [31:0] d_rsp_tag_i, d_rsp_rdata_i;
  logic [1:0] d_rsp_status_i;
  logic mem_launch_o, mem_busy_o, fatal_o;
  fatal_record_t fatal_record_o;
  logic [4:0] stage_valid_o, kill_valid_o;
  token_t stage_token_o [0:4];
  logic [3:0] transfer_o;
  logic [63:0] kill_uid_o [0:4];
  trace_t trace_o;
  logic unused_detail;
  assign unused_detail = ^fatal_record_o;
  logic [4:0] inspect_reg_i = 0;
  logic [31:0] inspect_value_o;
  logic inspect_defined_o;
  logic [31:0] mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o;
  logic [31:0] mie_o, mip_o, mcountinhibit_o;
  logic [63:0] mcycle_o, minstret_o;
  logic [31:0] mip_levels_i, manual_levels = 0;
  logic fetch_busy_i = 0, irq_valid_o, idle_o, entry_pending_o;
  logic [31:0] irq_pc_o, irq_cause_o;

  /* keep the persistent platform clocked independently of CPU issue and reset. */
  logic platform_command, platform_error, block_ready = 0;
  logic [30:0] event_set = 0;
  logic [31:0] platform_data, platform_levels, platform_pending, platform_enable, platform_count;
  logic [63:0] platform_time, platform_compare;
  logic platform_msip, platform_overflow, platform_stop;
  assign platform_command = d_req_valid_o && d_req_ready_i && d_req_addr_o[31:12] == 20'h40001;
  assign mip_levels_i = manual_levels | platform_levels;
  drg5_irq_platform platform (
    .clk_i(clk_i), .system_reset_i(cold_reset_i), .command_i(platform_command),
    .addr_i(d_req_addr_o), .write_i(d_req_write_o), .wdata_i(d_req_wdata_o),
    .size_i(d_req_size_o), .wstrb_i(d_req_wstrb_o), .event_set_i(event_set),
    .block_ready_i(block_ready), .error_o(platform_error), .rdata_o(platform_data),
    .mip_levels_o(platform_levels), .mtime_o(platform_time), .mtimecmp_o(platform_compare),
    .msip_o(platform_msip), .ext_pending_o(platform_pending), .ext_enable_o(platform_enable),
    .block_count_o(platform_count), .overflow_o(platform_overflow), .stop_o(platform_stop)
  );

  /* enable the machine event path without advertising M or a debug subsystem. */
  drg5_control #(.DIAGNOSTIC(0), .FORWARDING(1), .C_ENABLED(C_ENABLED),
      .IRQ_ENABLED(1), .TIMER_ENABLED(1), .D_MAX_WAIT_CYCLES(128)) dut (.*);

  packet_t original [0:CAPACITY-1];
  bit live [0:CAPACITY-1], admitted [0:CAPACITY-1], issued [0:CAPACITY-1], completed [0:CAPACITY-1];
  logic [31:0] loaded [0:CAPACITY-1];
  logic [1:0] completion_status [0:CAPACITY-1];
  logic [31:0] regs_ref [0:31], ram [0:63];
  bit defined_ref [0:31];
  logic [31:0] status_ref = 'h1800, enable_ref = 0, vector_ref = 0, scratch_ref = 0;
  logic [31:0] epc_ref = 0, cause_ref = 0, tval_ref = 0, inhibit_ref = 5;
  logic [63:0] cycles_ref = 0, retired_ref = 0;
  logic [31:0] arch_pc = 0, issue_pc = 0;
  logic [63:0] next_uid = 0, next_order = 0;
  bit owner = 0, accepted = 0, response_sent = 0, allow_fatal = 0;
  int owner_uid = 0, owner_age = 0, response_age = 0, owner_start = 0, max_service = 0;
  int ack_edge = 0, ack_complete_edge = 0, max_ack = 0, max_return = 0;
  int accept_delay = 0, response_delay = 1, owner_accept_delay = 0, owner_response_delay = 1;
  logic [1:0] response_status = 0, owner_status = 0;
  logic [31:0] owner_addr = 0, owner_data = 0, owner_tag = 0, owner_reply = 0;
  bit owner_write = 0;
  logic [63:0] time_ref = 0, acquisition_clocks = 0;
  logic [31:0] block_ref = 0, enable_platform_ref = 0;
  logic [63:0] compare_ref = '1;
  bit msip_ref = 0;
  int effects = 0, reads = 0, writes = 0, replies = 0, offers = 0;
  int cases = 0, edges = 0, checks = 0, retired = 0, traps = 0, interrupts = 0, killed = 0;
  int admissions = 0, sleeps = 0, wakes = 0, saves = 0, max_entry = 0, max_handler = 0, max_saved = 0;
  bit accepted_input = 0, mutation_applied = 0;
  bit last_idle = 0, flush_pending = 0;
  logic [31:0] flush_target = 0;
  int seed = 1, random_state = 1;

  /* reject a mismatch prior observed state can replace an independent expectation. */
  function automatic void check(input bit condition, input string message);
    checks++;
    /* include both instruction and physical service context in every failure. */
    if (!condition) $fatal(1, "seed=%0d case=%0d edge=%0d pc=%08x owner=%0d accepted=%0d age=%0d response=%0d: %s",
        seed, cases, edges, arch_pc, owner, accepted, owner_age, response_age, message);
  endfunction

  /* use a replayable generator independent of simulator initialization. */
  function automatic logic [31:0] random_word();
    random_state = random_state * 32'd1664525 + 32'd1013904223;
    return 32'(random_state);
  endfunction

  /* the supported machine interrupt order is external, software, then timer. */
  function automatic logic [31:0] irq_cause(input logic [31:0] unused_pending);
    /* no unsupported pending bit can choose a machine cause. */
    if (unused_pending[11]) return 32'h8000000b;
    if (unused_pending[3]) return 32'h80000003;
    if (unused_pending[7]) return 32'h80000007;
    return 0;
  endfunction

  /* read the independently maintained pre-edge CSR state. */
  function automatic logic [31:0] csr_read(input logic [11:0] address);
    /* this encoded corpus names only these resources and one deliberate absent address. */
    case (address)
      'h300: return status_ref;
      'h304: return enable_ref;
      'h305: return vector_ref;
      'h320: return inhibit_ref;
      'h340: return scratch_ref;
      'h341: return epc_ref;
      'h342: return cause_ref;
      'h343: return tval_ref;
      'h344: return (manual_levels & 'h888) | (block_ref != 0 && enable_platform_ref[0] ? 'h800 : 0) |
          (msip_ref ? 8 : 0) | (time_ref >= compare_ref ? 'h80 : 0);
      'hb00: return cycles_ref[31:0];
      'hb02: return retired_ref[31:0];
      default: return 0;
    endcase
  endfunction

  /* address permissions remain independent of the production CSR preview. */
  function automatic bit csr_known(input logic [11:0] address);
    return address inside {'h300,'h304,'h305,'h320,'h340,'h341,'h342,'h343,'h344,'hb00,'hb02};
  endfunction

  /* form a signed immediate directly from original instruction fields. */
  function automatic logic [31:0] immediate(input logic [31:0] unused_raw, input bit store);
    return store ? {{20{unused_raw[31]}},unused_raw[31:25],unused_raw[11:7]} : {{20{unused_raw[31]}},unused_raw[31:20]};
  endfunction

  /* registered target service separates acceptance delay from response delay. */
  always_comb begin
    d_req_ready_i = owner && !accepted && owner_age >= owner_accept_delay;
    d_rsp_valid_i = owner && accepted && !response_sent && response_age >= owner_response_delay - 1;
    d_rsp_tag_i = owner_tag;
    d_rsp_rdata_i = owner_status == 0 && !owner_write ? owner_reply : 0;
    d_rsp_status_i = owner_status;
  end

  /* one scoreboard instance avoids duplicating a large model through driver task inlining. */
  initial forever begin : scoreboard
    logic [4:0] before_valid;
    logic [3:0] pre_transfer;
    token_t prior [0:4];
    bit input_fire, launch, accept_bus, complete_bus, reset_active, pre_idle, pre_entry, pre_fetch;
    bit pre_owner, pre_completed, flush_fire, platform_fire, pre_platform_error;
    logic [31:0] old_pc, old_pending, old_status, pre_platform_data;
    logic [31:0] raw, value, next_pc, source, old_csr, post_csr, fault_cause, fault_value;
    logic [31:0] expected_addr, expected_data, observed_epc, expected_levels;
    logic [11:0] address;
    logic [4:0] rd, rs1, rs2;
    bit fault, write_reg, csr_instruction, read_csr, write_csr, is_return, is_wfi;
    bit observed_irq, observed_idle;
    logic [31:0] observed_cause;
    logic [63:0] observed_cycle;
    int id, count, new_admissions;
    logic [63:0] old_cycle, old_retired, old_platform_time;
    @(posedge clk_i);
    before_valid = stage_valid_o; prior = stage_token_o; pre_transfer = transfer_o;
    input_fire = in_valid_i && in_ready_o; launch = mem_launch_o;
    accept_bus = d_req_valid_o && d_req_ready_i;
    complete_bus = d_rsp_valid_i && d_rsp_ready_o;
    reset_active = cold_reset_i || hart_reset_i; pre_idle = idle_o; pre_entry = entry_pending_o;
    pre_fetch = fetch_busy_i; pre_owner = owner; old_pc = arch_pc;
    old_status = status_ref; old_pending = csr_read('h344) & enable_ref & 'h888;
    pre_completed = before_valid[4] && completed[int'(prior[4].uid)];
    flush_fire = flush_valid_i && flush_ready_o;
    platform_fire = platform_command; pre_platform_data = platform_data; pre_platform_error = platform_error;
    accepted_input = input_fire;
    /* the platform retention model never observes its own output as expected pending state. */
    expected_levels = (block_ref != 0 && enable_platform_ref[0] ? 'h800 : 0) |
        (msip_ref ? 8 : 0) | (time_ref >= compare_ref ? 'h80 : 0);
    if (!cold_reset_i) check(platform_levels == expected_levels && platform_count == block_ref &&
        platform_enable == enable_platform_ref && platform_pending == (block_ref != 0 ? 1 : 0),
        "persistent platform event mismatch");
    if (!cold_reset_i) check(platform_time == time_ref && platform_compare == compare_ref && platform_msip == msip_ref &&
        !platform_overflow && !platform_stop, "independent platform clock/state mismatch");
    check(mem_busy_o == owner && d_req_valid_o == (owner && !accepted), "physical IRQ owner mismatch");
    /* an exposed descriptor stays stable even while interrupt entry waits for service. */
    if (owner) check(d_req_addr_o == owner_addr && d_req_wdata_o == owner_data &&
        d_req_tag_o == owner_tag && d_req_write_o == owner_write && d_req_size_o == 2 &&
        d_req_wstrb_o == (owner_write ? 15 : 0), "IRQ request changed while owned");
    /* selected entry or WFI cannot consume a fresh front-end offer. */
    if (pre_entry || pre_idle) check(!input_fire && !launch, "IRQ selection launched new work");
    old_cycle = cycles_ref; old_retired = retired_ref; old_platform_time = time_ref;
    #1; edges++; acquisition_clocks++;
    observed_irq = irq_valid_o; observed_epc = irq_pc_o; observed_cause = irq_cause_o;
    observed_idle = idle_o; observed_cycle = mcycle_o;
    /* corrupt one real output at the ordinary architectural comparison boundary. */
    if ($test$plusargs("mutate_irq_cause") && observed_irq && !mutation_applied) begin
      observed_cause ^= 4; mutation_applied = 1;
    end
    /* drop one observed event while retaining the real architectural state change. */
    if ($test$plusargs("mutate_irq_lost") && observed_irq && !mutation_applied) begin
      observed_irq = 0; mutation_applied = 1;
    end
    /* alter only the observed cycle count during real idle. */
    if ($test$plusargs("mutate_counter") && pre_idle && !mutation_applied) begin
      observed_cycle--; mutation_applied = 1;
    end
    /* hide one observed wake from the ordinary WFI checker. */
    if ($test$plusargs("mutate_wfi_wake") && pre_idle && old_pending != 0 && !mutation_applied) begin
      observed_idle = 1; mutation_applied = 1;
    end
    /* corrupt event PC only after a real event reaches the ordinary comparator. */
    if ($test$plusargs("mutate_irq_pc") && observed_irq && !mutation_applied) begin
      observed_epc += 4; mutation_applied = 1;
    end
    /* all killed identities must have existed prior this edge. */
    for (int stage = 0; stage < 5; stage++) begin
      /* reset and redirects are the only owners of cancellation. */
      if (kill_valid_o[stage]) begin
        id = int'(kill_uid_o[stage]);
        check(before_valid[stage] && id < CAPACITY && live[id] && prior[stage].uid == kill_uid_o[stage],
              "IRQ duplicate or ownerless kill");
        /* an interrupt can discard only the prefix that has not started architectural execution. */
        if (!reset_active && pre_entry && !(trace_o.valid && (trace_o.trap || redirect_valid_o)) &&
            !flush_pending && !flush_fire)
          check(!admitted[id], "IRQ killed an admitted instruction");
        live[id] = 0; killed++;
      end
    end
    /* reset cancels all architectural effects and preserves platform state on hart-only reset. */
    if (reset_active) begin
      check(!trace_o.valid && !observed_irq, "reset leaked an instruction or interrupt");
      status_ref = 'h1800; enable_ref = 0; vector_ref = 0; scratch_ref = 0;
      epc_ref = 0; cause_ref = 0; tval_ref = 0; inhibit_ref = 5;
      cycles_ref = 0; retired_ref = 0; arch_pc = 0; flush_pending = 0;
      /* x0 alone has architectural reset definedness. */
      for (int regno = 0; regno < 32; regno++) begin regs_ref[regno] = 0; defined_ref[regno] = regno == 0; end
      /* cold isolation also destroys testbench physical target obligations. */
      if (cold_reset_i) begin next_uid = 0; next_order = 0; owner = 0; accepted = 0; response_sent = 0; end
    end
    /* nonreset edges count independently of issue, memory or WFI idle. */
    else begin
      /* old inhibit state governs the edge prior any explicit CSR write. */
      if (!inhibit_ref[0]) cycles_ref++;
      /* interrupt entry is a separate architectural event and cannot retire a fictitious token. */
      if (observed_irq) begin
        check(!trace_o.valid && !pre_fetch && !pre_owner && old_status[3] && old_pending != 0,
              "IRQ entry violated eligibility or ownership");
        /* every admitted older attempt must have completed prior interrupt state changes. */
        for (int uid = 0; uid < CAPACITY; uid++) check(!live[uid] || !admitted[uid], "IRQ passed admitted work");
        check(observed_epc == old_pc && observed_cause == irq_cause(old_pending), "independent IRQ PC/cause mismatch");
        check(redirect_valid_o && redirect_pc_o == vector_ref, "IRQ vector mismatch");
        status_ref = 'h1800 | ((old_status & 8) << 4); epc_ref = old_pc;
        cause_ref = irq_cause(old_pending); tval_ref = 0; arch_pc = vector_ref; interrupts++;
      end
      /* normal terminal semantics are derived from the original instruction and reference GPRs. */
      if (trace_o.valid) begin
        id = int'(trace_o.uid); raw = original[id].raw;
        check(id < CAPACITY && live[id] && admitted[id] && trace_o.order == next_order &&
            trace_o.packet.pc == original[id].pc && trace_o.packet.raw == raw && original[id].pc == arch_pc,
            "lost, duplicate or reordered IRQ instruction");
        live[id] = 0; next_order++;
        rd = raw[11:7]; rs1 = raw[19:15]; rs2 = raw[24:20];
        value = 0; next_pc = arch_pc + 4; fault = original[id].fault;
        fault_cause = original[id].cause; fault_value = original[id].mtval;
        write_reg = 0; csr_instruction = 0; is_return = 0; is_wfi = 0;
        read_csr = 0; write_csr = 0; address = raw[31:20]; old_csr = 0; post_csr = 0;
        /* an earlier fetch fault suppresses all instruction-specific effects. */
        if (!fault) begin
          /* keep the executable corpus deliberately small and independently specified. */
          case (raw[6:0])
            /* LUI initializes arbitrary handler data and addresses. */
            'h37: begin value = {raw[31:12],12'b0}; write_reg = rd != 0; end
            /* ADDI executes modulo XLEN and can consume forwarded operands. */
            'h13: begin
              check(raw[14:12] == 0, "unsupported fixture arithmetic");
              value = regs_ref[rs1] + immediate(raw, 0); write_reg = rd != 0;
            end
            /* word accesses preserve independent memory completion and physical effects. */
            'h03, 'h23: begin
              check(raw[14:12] == 2 && pre_completed, "memory retired prior registered completion");
              expected_addr = regs_ref[rs1] + immediate(raw, raw[6:0] == 'h23);
              check(trace_o.packet.mem_addr == expected_addr, "IRQ memory address mismatch");
              /* a guaranteed no-effect rejection becomes the owning instruction's precise fault. */
              if (completion_status[id] != 0) begin
                fault = 1; fault_cause = raw[6:0] == 'h03 ? 5 : 7; fault_value = expected_addr;
              end
              /* successful load values come from the captured independent target response. */
              else if (raw[6:0] == 'h03) begin value = loaded[id]; write_reg = rd != 0; end
            end
            /* SYSTEM encodings include only exact base exceptions, return, idle and CSR forms. */
            'h73: begin
              /* the six CSR forms derive writes from encoded source selection. */
              if (raw[14:12] inside {1,2,3,5,6,7}) begin
                csr_instruction = 1; read_csr = raw[13:12] != 1 || rd != 0;
                write_csr = raw[13:12] == 1 || rs1 != 0;
                source = raw[14] ? {27'b0,rs1} : regs_ref[rs1];
                old_csr = csr_read(address); post_csr = old_csr;
                /* unsupported addresses fault prior a normal access event. */
                if (!csr_known(address)) begin fault = 1; fault_cause = 2; fault_value = 0; end
                /* legal forms read pre-edge counter values prior this edge's increment. */
                else begin
                  /* explicit counter reads use pre-edge independent values. */
                  if (address == 'hb00) old_csr = old_cycle[31:0];
                  if (address == 'hb02) old_csr = old_retired[31:0];
                  /* writes are computed from the same pre-edge source read. */
                  case (raw[13:12])
                    1: post_csr = source;
                    2: post_csr = old_csr | source;
                    3: post_csr = old_csr & ~source;
                    default: post_csr = old_csr;
                  endcase
                  /* WARL masks match the declared profile without reading DUT previews. */
                  case (address)
                    'h300: post_csr = (post_csr & 'h88) | 'h1800;
                    'h304: post_csr &= 'h888;
                    'h305: post_csr &= 'hfffffffc;
                    'h320: post_csr &= 5;
                    'h341: post_csr &= C_ENABLED ? 'hfffffffe : 'hfffffffc;
                    'h344: post_csr = old_csr;
                    default: begin end
                  endcase
                  value = read_csr ? old_csr : 0; write_reg = rd != 0;
                end
              end
              /* return does not advance the saved continuation or acknowledge a source. */
              else if (raw == 'h30200073) begin is_return = 1; next_pc = epc_ref; end
              /* WFI is a successful retirement with its ordinary sequential continuation. */
              else if (raw == 'h10500073) is_wfi = 1;
              /* exact environment instructions trap without retirement. */
              else if (raw == 'h00000073 || raw == 'h00100073) begin
                fault = 1; fault_cause = raw == 'h00000073 ? 11 : 3;
                fault_value = raw == 'h00100073 ? arch_pc : 0;
              end
              /* reserved SYSTEM encodings are ordinary illegal instructions. */
              else begin fault = 1; fault_cause = 2; fault_value = 0; end
            end
            /* all other deliberate fixture encodings are unsupported and must trap. */
            default: begin fault = 1; fault_cause = 2; fault_value = 0; end
          endcase
        end
        /* compare faults and register updates prior changing expected architectural state. */
        check(trace_o.trap == fault && trace_o.packet.cause == (fault ? fault_cause : 0) &&
            trace_o.packet.mtval == (fault ? fault_value : 0), "IRQ precise exception mismatch");
        check(trace_o.rd_write == (!fault && write_reg) &&
            (!trace_o.rd_write || (trace_o.rd == rd && trace_o.value == value)), "IRQ register result mismatch");
        check(trace_o.csr_read == (!fault && csr_instruction && read_csr) &&
            trace_o.csr_write == (!fault && csr_instruction && write_csr) &&
            trace_o.csr_old == (!fault && csr_instruction && read_csr ? old_csr : 0) &&
            trace_o.csr_new == (!fault && csr_instruction && write_csr ? post_csr : 0), "IRQ CSR trace mismatch");
        /* a synchronous fault has priority over any simultaneously pending interrupt. */
        if (fault) begin
          check(!observed_irq, "IRQ overtook older synchronous fault");
          status_ref = 'h1800 | ((old_status & 8) << 4); epc_ref = arch_pc;
          cause_ref = fault_cause; tval_ref = fault_value; next_pc = vector_ref; traps++;
        end
        /* successful instructions update only their declared destination and resource. */
        else begin
          retired++;
          if (!inhibit_ref[2]) retired_ref++;
          /* x0 is never written even when its operand value participates in execution. */
          if (write_reg) begin regs_ref[rd] = value; defined_ref[rd] = 1; end
          /* normal return restores the one-level machine interrupt stack. */
          if (is_return) status_ref = 'h1880 | ((old_status & 'h80) >> 4);
          /* explicit CSR changes take effect exactly at their successful terminal edge. */
          else if (csr_instruction && write_csr) begin
            /* immutable pending levels are never acknowledged through mip. */
            case (address)
              'h300: status_ref = post_csr;
              'h304: enable_ref = post_csr;
              'h305: vector_ref = post_csr;
              'h320: inhibit_ref = post_csr;
              'h340: scratch_ref = post_csr;
              'h341: epc_ref = post_csr;
              'h342: cause_ref = post_csr;
              'h343: tval_ref = post_csr;
              'hb00: cycles_ref = {old_cycle[63:32],post_csr};
              'hb02: retired_ref = {old_retired[63:32],post_csr};
              default: begin end
            endcase
          end
          /* local pending state prevents WFI from becoming asleep. */
          if (is_wfi) check(idle_o == (old_pending == 0), "WFI entry ignored local pending state");
        end
        check(trace_o.next_pc == next_pc, "IRQ terminal continuation mismatch");
        arch_pc = next_pc;
      end
      /* an external flush changes the next unexecuted PC without a retirement event. */
      if (flush_fire) begin flush_pending = 1; flush_target = flush_pc_i; end
      /* consume only the redirect owned by the pending external flush. */
      if (redirect_valid_o && !trace_o.valid && !observed_irq) begin
        check(flush_pending && redirect_pc_o == flush_target, "unexpected noninstruction redirect");
        arch_pc = flush_target; flush_pending = 0;
      end
      if (flush_aborted_o) flush_pending = 0;
    end
    /* physical acceptance is checked separately from architectural disposition. */
    if (!cold_reset_i) begin
      /* the target records each accepted side effect once, even across hart reset. */
      if (accept_bus) begin
        check(owner && !accepted, "duplicate IRQ target acceptance");
        accepted = 1; response_age = 0; owner_reply = 0;
        /* only successful operations may change the device or local stack. */
        if (owner_status == 0) begin
          effects++;
          /* the persistent platform receives the same single accepted command. */
          if (platform_fire) begin
            check(!pre_platform_error, "platform rejected supported IRQ fixture command");
            owner_reply = pre_platform_data;
            if (owner_write && owner_addr == 'h40001020) ack_edge = edges;
          end
          /* ordinary RAM is independently stored outside the CPU. */
          else if (owner_addr[31:16] == 'h2000) begin
            check(owner_addr[15:8] == 0, "fixture stack address out of bounds");
            /* stores preserve an independently checked firmware register value. */
            if (owner_write) begin ram[owner_addr[7:2]] = owner_data; saves++; end
            else owner_reply = ram[owner_addr[7:2]];
          end
          /* ticket MMIO makes duplicate reads as visible as duplicate stores. */
          else if (owner_write) writes++;
          /* each read consumes exactly one independently counted ticket. */
          else begin
            owner_reply = 32'(reads); reads++;
            /* inject a duplicate physical read effect without changing retirement data. */
            if ($test$plusargs("mutate_duplicate_read") && !mutation_applied) begin
              reads++; mutation_applied = 1;
            end
          end
        end
      end
      /* a reply completes its one owner, without allowing same-edge retirement. */
      if (complete_bus) begin
        check(owner && accepted && owner_uid >= 0 && owner_uid < CAPACITY, "ownerless IRQ response");
        /* healthy replies must satisfy the configured inclusive service deadline. */
        if (!allow_fatal) begin
          check(edges - owner_start == owner_accept_delay + 1 + owner_response_delay && edges - owner_start <= 128,
                "independent data service deadline mismatch");
          if (edges - owner_start > max_service) max_service = edges - owner_start;
        end
        if (owner_write && owner_addr == 'h40001020) ack_complete_edge = edges;
        completed[owner_uid] = 1; completion_status[owner_uid] = owner_status;
        loaded[owner_uid] = owner_reply; owner = fatal_o; accepted = fatal_o; response_sent = 1; replies++;
      end
      /* launch permission is distinct from an ordinary instruction's stage ownership. */
      if (launch) begin
        id = int'(prior[3].uid); raw = original[id].raw;
        check(!pre_owner && before_valid[3] && live[id] && !issued[id] &&
            (raw[6:0] == 'h03 || raw[6:0] == 'h23), "IRQ launched invalid memory attempt");
        rs1 = raw[19:15]; rs2 = raw[24:20];
        expected_addr = regs_ref[rs1] + immediate(raw, raw[6:0] == 'h23);
        expected_data = raw[6:0] == 'h23 ? regs_ref[rs2] : 0;
        check(d_req_addr_o == expected_addr && d_req_wdata_o == expected_data,
              "IRQ memory descriptor differs from instruction intent");
        owner = 1; accepted = 0; response_sent = 0; owner_uid = id; owner_start = edges; issued[id] = 1;
        owner_addr = expected_addr; owner_data = expected_data; owner_write = raw[6:0] == 'h23;
        owner_tag = d_req_tag_o; owner_age = 0; response_age = 0;
        owner_accept_delay = accept_delay; owner_response_delay = response_delay; owner_status = response_status;
        offers++;
      end
      /* service ages advance independently of pipeline holds and retirement. */
      else if (owner) begin
        if (accepted && !accept_bus) response_age++;
        if (!accepted) owner_age++;
      end
    end
    /* the small platform reference covers the exact accepted command subset used here. */
    if (cold_reset_i) begin time_ref = 0; block_ref = 0; enable_platform_ref = 0; compare_ref = '1; msip_ref = 0; end
    /* CPU sleep and hart reset never gate the independent acquisition/timer domain. */
    else begin
      time_ref++;
      /* acknowledge consumes one queued block, while same-edge arrival remains retained. */
      if (platform_fire && owner_write && owner_addr == 'h40001020 && owner_data[0] && block_ref != 0) block_ref--;
      if (block_ready) block_ref++;
      /* apply only the command accepted on this edge to the platform reference. */
      if (platform_fire && owner_write) begin
        /* timer, software and block enables use independent pre-edge command fields. */
        case (owner_addr)
          'h40001000: time_ref = {old_platform_time[63:32],owner_data};
          'h40001004: time_ref = {owner_data,old_platform_time[31:0]};
          'h40001008: compare_ref[31:0] = owner_data;
          'h4000100c: compare_ref[63:32] = owner_data;
          'h40001010: msip_ref = owner_data[0];
          'h40001018: enable_platform_ref = owner_data;
          default: begin end
        endcase
      end
    end
    /* accepted packets receive independent monotonically allocated identities. */
    if (input_fire) begin
      check(next_uid < 64'(CAPACITY), "IRQ fixture UID capacity exceeded");
      id = int'(next_uid); original[id] = in_packet_i; live[id] = 1; admitted[id] = 0;
      issued[id] = 0; completed[id] = 0; completion_status[id] = 0; loaded[id] = 0; next_uid++;
    end
    new_admissions = 0;
    /* the architectural-admission bit must survive every later stage transfer. */
    for (int stage = 0; stage < 5; stage++) begin
      /* a live stage always owns exactly one known, uncancelled input identity. */
      if (stage_valid_o[stage]) begin
        id = int'(stage_token_o[stage].uid);
        check(id < CAPACITY && live[id], "IRQ stage lost its instruction owner");
        /* newly admitted attempts obey a one-per-edge, age-ordered rule. */
        if (stage_token_o[stage].admitted && !admitted[id]) begin
          check(!pre_entry, "IRQ selection admitted younger work");
          for (int older = 0; older < id; older++) check(!live[older] || admitted[older], "IRQ admitted past an older attempt");
          admitted[id] = 1; new_admissions++; admissions++;
        end
        check(stage_token_o[stage].admitted == admitted[id], "IRQ admission state changed while owned");
      end
    end
    check(new_admissions <= 1, "multiple IRQ instruction admissions on one edge");
    /* every surviving input has exactly one stage owner. */
    for (int uid = 0; uid < CAPACITY; uid++) begin
      count = 0;
      for (int stage = 0; stage < 5; stage++)
        if (stage_valid_o[stage] && stage_token_o[stage].uid == 64'(uid)) count++;
      check(count == int'(live[uid]), "IRQ instruction ownership mismatch");
    end
    check(mstatus_o == status_ref && mie_o == enable_ref && mtvec_o == vector_ref &&
        mscratch_o == scratch_ref && mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref &&
        mcountinhibit_o == inhibit_ref, "independent IRQ trap/CSR state mismatch");
    check(observed_cycle == cycles_ref && minstret_o == retired_ref, "independent IRQ counter mismatch");
    check(mip_o == csr_read('h344), "independent IRQ pending mismatch");
    if (!allow_fatal) check(!fatal_o && !fatal_record_o.valid, "unexpected IRQ containment");
    /* containment suppresses all architectural entry and issue while preserving request ownership. */
    if (fatal_o) check(allow_fatal && fatal_record_o.valid && !trace_o.valid && !irq_valid_o &&
        !in_ready_o && !mem_launch_o, "IRQ escaped fatal containment");
    check(inspect_defined_o == defined_ref[inspect_reg_i] &&
        (!inspect_defined_o || inspect_value_o == regs_ref[inspect_reg_i]), "IRQ GPR inspection mismatch");
    check((pre_transfer & ~(before_valid[3:0])) == 0, "IRQ transfer without owner");
    /* waking without global MIE cannot itself create a trap or lose the continuation. */
    if (pre_idle && !reset_active && old_pending != 0) check(!observed_idle, "WFI failed to wake on locally enabled pending");
    if (pre_idle && !reset_active && old_pending == 0) check(observed_idle, "WFI woke for masked or absent event");
    if (!last_idle && idle_o) sleeps++;
    if (last_idle && !idle_o) wakes++;
    last_idle = idle_o;
  end

  /* drive only clock edges; the independent scoreboard runs once per edge. */
  task automatic tick();
    clk_i = 0; inspect_reg_i = 5'(edges); #2; clk_i = 1; #2; clk_i = 0;
  endtask

  /* start a case with positively isolated cold reset and a cleared external source. */
  task automatic reset_case();
    cases++; manual_levels = 0; fetch_busy_i = 0; hold_i = 0;
    in_valid_i = 0; flush_valid_i = 0; block_ready = 0; event_set = 0;
    accept_delay = 0; response_delay = 1; response_status = 0; allow_fatal = 0;
    cold_reset_i = 1; hart_reset_i = 0; tick(); cold_reset_i = 0; tick(); tick(); issue_pc = 0;
  endtask

  /* offer one immutable raw32 instruction until the packet input accepts it. */
  task automatic send(input logic [31:0] raw, input bit fault = 0,
      input logic [31:0] cause = 0, input logic [31:0] tval = 0, input op_t operation = OP_MACHINE);
    int timeout;
    in_packet_i = '0; in_packet_i.op = operation; in_packet_i.next_pc = 'hbad00000; in_packet_i.pc = issue_pc;
    in_packet_i.raw = raw; in_packet_i.length = 4; in_packet_i.raw_valid = 15;
    in_packet_i.fault = fault; in_packet_i.cause = cause; in_packet_i.mtval = tval;
    in_valid_i = 1; timeout = 0;
    /* bounded fixtures never wait forever for a blocked instruction input. */
    do begin tick(); timeout++; check(timeout < 512, "IRQ input timeout"); end while (!accepted_input);
    in_valid_i = 0; issue_pc += 4;
  endtask

  /* wait for accepted instructions and their physical effects to finish. */
  task automatic drain();
    int timeout;
    timeout = 0;
    /* idle is allowed once WFI has already retired. */
    while (stage_valid_o != 0 || mem_busy_o) begin tick(); timeout++; check(timeout < 512, "IRQ drain timeout"); end
  endtask

  /* load a full-width constant using actual RV32I encodings. */
  task automatic constant(input logic [4:0] rd, input logic [31:0] value);
    logic [31:0] upper;
    upper = (value + 'h800) & 'hfffff000;
    send(upper | (32'(rd) << 7) | 'h37);
    send((value << 20) | (32'(rd) << 15) | (32'(rd) << 7) | 'h13);
    drain();
  endtask

  /* update machine state through an encoded CSRRW, never a testbench backdoor. */
  task automatic csr_write(input logic [11:0] address, input logic [31:0] value);
    constant(1, value); send((32'(address) << 20) | (1 << 15) | 'h1073); drain();
  endtask

  /* initialize the declared vector, counter enables and local interrupt masks. */
  task automatic configure(input logic [31:0] enables = 'h888, input bit global_enable = 1);
    csr_write('h305, 'h100);
    csr_write('h320, 0);
    csr_write('h304, enables);
    csr_write('h300, global_enable ? 8 : 0);
  endtask

  /* require a real interrupt event within the measured healthy-platform bound. */
  task automatic await_irq(input int before_count, input int limit = 195);
    int waited;
    waited = 0;
    /* the origin is the first edge after a synchronized source becomes eligible. */
    while (interrupts == before_count) begin tick(); waited++; check(waited <= limit, "IRQ latency bound exceeded"); end
    if (waited > max_entry) max_entry = waited;
    issue_pc = arch_pc;
  endtask

  /* construct a word store without using the production decoder. */
  function automatic logic [31:0] store_word(input int source_reg, input int base_reg, input int offset);
    return ((32'(offset) & 'hfe0) << 20) | (32'(source_reg) << 20) |
        (32'(base_reg) << 15) | 'h2023 | ((32'(offset) & 31) << 7);
  endfunction

  /* wait for a memory offer, leaving acceptance and response scheduling independent. */
  task automatic await_owner();
    int timeout;
    timeout = 0;
    /* bound the wait for the first physical request owner. */
    while (!owner) begin tick(); timeout++; check(timeout < 128, "IRQ memory launch timeout"); end
  endtask

  /* commit one platform register through the CPU data bus. */
  task automatic platform_write(input logic [31:0] address, input logic [31:0] value);
    constant(2, address); constant(3, value); send(store_word(3, 2, 0)); drain();
  endtask

  /* exercise each pending combination and both relevant CSR enable points. */
  task automatic priority_cases();
    int count_irq;
    logic [31:0] mask;
    /* every local-mask and pending combination checks masking and supported cause priority. */
    for (int enabled = 0; enabled < 8; enabled++) begin
      /* each source combination starts with a clean architectural boundary. */
      for (int combination = 0; combination < 8; combination++) begin
        mask = (enabled[0] ? 8 : 0) | (enabled[1] ? 'h80 : 0) | (enabled[2] ? 'h800 : 0);
        reset_case(); configure(mask);
        count_irq = interrupts;
        manual_levels = (combination[0] ? 8 : 0) | (combination[1] ? 'h80 : 0) | (combination[2] ? 'h800 : 0);
        /* only a locally enabled pending source may enter the handler. */
        if ((mask & manual_levels) != 0) begin
          await_irq(count_irq);
          check(cause_ref == irq_cause(mask & manual_levels), "pending combination priority mismatch");
        end
        /* disabled combinations remain pending without creating an event. */
        else begin repeat (4) tick(); check(interrupts == count_irq, "local mask matrix admitted IRQ"); end
      end
    end
    /* unsupported source bits cannot create architectural pending state. */
    reset_case(); configure(); count_irq = interrupts; manual_levels = ~32'h888;
    repeat (8) tick(); check(interrupts == count_irq && !entry_pending_o, "unsupported interrupt enabled");
    /* enabling global MIE takes a retained source at the next boundary. */
    reset_case(); configure('h888, 0); manual_levels = 'h800; count_irq = interrupts;
    repeat (8) tick(); check(interrupts == count_irq, "masked global interrupt entered");
    csr_write('h300, 8); await_irq(count_irq);
    /* enabling a local mask performs the same post-retirement reevaluation. */
    reset_case(); configure(0, 1); manual_levels = 8; count_irq = interrupts;
    repeat (8) tick(); check(interrupts == count_irq, "masked local interrupt entered");
    csr_write('h304, 8); await_irq(count_irq);
    /* MRET immediately reenters on an unacknowledged source without executing its target. */
    count_irq = interrupts; send('h30200073); drain(); await_irq(count_irq);
    check(cause_ref == 'h80000003, "MRET lost retained software interrupt");
    /* an already-admitted CSR may disable either enable while entry drains. */
    for (int disable_kind = 0; disable_kind < 2; disable_kind++) begin
      reset_case(); configure(); constant(1, 0);
      send(disable_kind == 0 ? 'h30009073 : 'h30409073);
      /* stop at the independently visible admission boundary. */
      begin
        int timeout;
        timeout = 0;
        /* observe CSR admission before changing the pending level. */
        while (!(stage_valid_o[4] && stage_token_o[4].admitted)) begin
          tick(); timeout++; check(timeout < 64, "CSR disable admission timeout");
        end
      end
      hold_i[4] = 1; count_irq = interrupts; manual_levels = 'h888; tick(); hold_i[4] = 0;
      drain(); repeat (4) tick();
      check(interrupts == count_irq && !entry_pending_o, "admitted CSR disable did not cancel IRQ");
    end
    /* software writes to mip cannot acknowledge retained platform levels. */
    reset_case(); configure('h888, 0); manual_levels = 'h888;
    csr_write('h344, 0); check(mip_o == 'h888, "mip write cleared pending source");
  endtask

  /* selection drains physical ownership and rechecks live source priority. */
  task automatic drain_cases();
    int count_irq, count_traps, count_reads;
    /* withdrawing a level while an old instruction fetch drains cancels entry. */
    reset_case(); configure(); count_irq = interrupts; fetch_busy_i = 1; manual_levels = 'h80;
    tick(); manual_levels = 0; repeat (3) tick(); fetch_busy_i = 0;
    repeat (4) tick(); check(interrupts == count_irq && !entry_pending_o, "withdrawn interrupt still entered");
    send('h00100293); drain();
    /* the selected cause is recomputed at entry after a higher-priority level arrives. */
    reset_case(); configure(); count_irq = interrupts; fetch_busy_i = 1; manual_levels = 'h80;
    tick(); manual_levels = 'h888; repeat (3) tick(); fetch_busy_i = 0; await_irq(count_irq);
    check(cause_ref == 'h8000000b, "draining interrupt retained obsolete priority");
    /* exercise both preacceptance and accepted-response interrupt onset. */
    for (int phase = 0; phase < 2; phase++) begin
      reset_case(); configure(); constant(2, 'h40000000);
      accept_delay = 7; response_delay = 11; count_irq = interrupts; count_reads = reads;
      send('h00012003); await_owner();
      /* distinguish a stalled offer from an accepted request awaiting response. */
      if (phase != 0) begin while (!accepted) tick(); end
      manual_levels = 'h800; await_irq(count_irq);
      check(reads == count_reads + 1 && !owner, "load x0 effect missing or repeated during IRQ drain");
    end
    /* the older no-effect response fault wins even with a pending interrupt. */
    reset_case(); configure(); constant(2, 'h40000000);
    accept_delay = 4; response_delay = 8; response_status = 1;
    count_irq = interrupts; count_traps = traps; count_reads = reads;
    send('h00012283); await_owner(); manual_levels = 'h888; drain();
    repeat (4) tick(); check(traps == count_traps + 1 && interrupts == count_irq && reads == count_reads &&
        cause_ref == 5 && tval_ref == 'h40000000, "older response fault lost priority");
    /* an unadmitted illegal instruction can be discarded without a synchronous trap. */
    reset_case(); configure(); hold_i[2] = 1; send('hffffffff); count_irq = interrupts;
    manual_levels = 'h800; await_irq(count_irq); hold_i = 0;
    /* an admitted carried fault must still prepare its serial W stage during drain. */
    reset_case(); configure(); hold_i[3] = 1; send('h00000073, 1, 1, 'h5550, OP_CSR);
    /* hold the already-admitted fault until an interrupt is selected. */
    begin
      int timeout;
      timeout = 0;
      /* the fault must own an admitted M attempt before IRQ selection. */
      while (!(stage_valid_o[3] && stage_token_o[3].admitted)) begin
        tick(); timeout++; check(timeout < 64, "fault admission timeout");
      end
    end
    count_traps = traps; count_irq = interrupts; manual_levels = 'h800; tick(); hold_i = 0; drain();
    check(traps == count_traps + 1 && interrupts == count_irq && cause_ref == 1,
        "admitted carried fault failed to drain prior to IRQ");
    /* hart reset kills the instruction while an accepted request and pending level survive. */
    reset_case(); configure(); constant(2, 'h40000000); response_delay = 12;
    count_irq = interrupts; count_reads = reads; send('h00012003); await_owner();
    /* wait for the external device effect before removing architectural ownership. */
    while (!accepted) tick();
    manual_levels = 'h800; hart_reset_i = 1; tick(); hart_reset_i = 0;
    drain(); tick(); issue_pc = 0;
    check(interrupts == count_irq && reads == count_reads + 1, "hart reset replayed IRQ data or entered early");
    configure(); await_irq(count_irq);
    /* an external flush establishes the saved boundary before asynchronous entry. */
    reset_case(); configure(); count_irq = interrupts;
    flush_valid_i = 1; flush_pc_i = 'h440; manual_levels = 'h800; tick(); flush_valid_i = 0;
    await_irq(count_irq); check(epc_ref == 'h440, "IRQ ignored external flush continuation");
  endtask

  /* WFI retires once while timer and acquisition clocks continue independently. */
  task automatic wfi_cases();
    int count_irq;
    logic [63:0] old_count, old_clock, old_acquisition;
    logic [31:0] continuation;
    /* a masked source leaves idle intact, then a local enable wakes despite global MIE=0. */
    reset_case(); configure(8, 0); send('h10500073); drain();
    check(idle_o, "WFI did not enter idle"); old_count = retired_ref; old_clock = cycles_ref;
    old_acquisition = acquisition_clocks; manual_levels = 'h800; count_irq = interrupts;
    repeat (12) tick();
    check(idle_o && retired_ref == old_count && cycles_ref == old_clock + 12 &&
        acquisition_clocks == old_acquisition + 12, "WFI stopped clocks or retired repeatedly");
    manual_levels = 8; tick(); check(!idle_o && interrupts == count_irq, "MIE=0 WFI wake created trap");
    send('h00700293); drain();
    /* a locally pending source prevents sleeping even with global interrupts masked. */
    reset_case(); configure(8, 0); manual_levels = 8; send('h10500073); drain();
    check(!idle_o, "WFI slept with locally enabled pending source");
    /* enabled interrupts wake at the instruction after WFI. */
    reset_case(); configure(); send('h10500073); drain(); old_count = retired_ref;
    count_irq = interrupts; continuation = issue_pc; manual_levels = 'h80; await_irq(count_irq);
    check(epc_ref == continuation && retired_ref == old_count, "WFI wake lost sequential continuation");
    /* the diagnostic WFI packet cannot substitute an arbitrary continuation. */
    reset_case(); configure(8, 0); send('h10500073, 0, 0, 0, OP_WFI); drain();
    continuation = issue_pc; manual_levels = 8; tick();
    check(!idle_o && arch_pc == continuation, "diagnostic WFI used poisoned continuation");
    /* hart reset wakes idle without resetting the independent timer domain. */
    reset_case(); configure(8, 0); send('h10500073); drain(); old_clock = platform_time;
    hart_reset_i = 1; tick(); hart_reset_i = 0; tick(); tick(); issue_pc = 0;
    check(!idle_o && platform_time == old_clock + 3, "hart reset gated platform time");
  endtask

  /* generate all three machine sources with actual accepted peripheral commands. */
  task automatic platform_cases();
    int count_irq;
    logic [63:0] old_time;
    /* a software level stays asserted through handler entry until a CPU store clears it. */
    reset_case(); configure(); count_irq = interrupts; platform_write('h40001010, 1);
    await_irq(count_irq); check(cause_ref == 'h80000003 && platform_msip, "physical software IRQ missing");
    platform_write('h40001010, 0); check(!platform_msip, "software IRQ clear missing");
    /* a compare in the past raises timer pending, then the safe high-half write clears it. */
    reset_case(); configure(); count_irq = interrupts;
    platform_write('h40001008, 0); platform_write('h4000100c, 0);
    await_irq(count_irq); check(cause_ref == 'h80000007, "physical timer IRQ missing");
    platform_write('h4000100c, 'hffffffff); check(!platform_levels[7], "timer compare failed to clear pending");
    /* queue block notifications while masked and keep acquisition active during WFI. */
    reset_case(); configure('h800, 0); platform_write('h40001018, 1);
    block_ready = 1; tick(); tick(); block_ready = 0;
    check(platform_count == 2 && platform_levels[11], "masked block notifications lost");
    count_irq = interrupts; csr_write('h300, 8); await_irq(count_irq);
    platform_write('h40001020, 1); check(platform_count == 1 && platform_levels[11], "block ACK erased another event");
    old_time = platform_time; hart_reset_i = 1; tick(); hart_reset_i = 0; tick(); tick(); issue_pc = 0;
    check(platform_count == 1 && platform_time == old_time + 3, "hart reset lost peripheral event");
    configure(); await_irq(interrupts); platform_write('h40001020, 1);
    check(platform_count == 0 && !platform_levels[11], "last block ACK failed");
  endtask

  /* measure full source-to-handler work using raw stores, ACK, loads and MRET. */
  task automatic latency_cases();
    int count_irq, origin, entry_edge, handler_edge, save_start, start_saves, wait_cycles;
    int chosen_accept, chosen_response, x_delay, saved_edge;
    int save_regs [0:15];
    logic [31:0] saved_values [0:15];
    logic [31:0] unused_choice;
    save_regs = '{1,5,6,7,10,11,12,13,14,15,16,17,28,29,30,31};
    /* include endpoint splits and replayable service/onset schedules. */
    for (int scenario = 0; scenario < 20; scenario++) begin
      reset_case(); configure(); platform_write('h40001018, 1);
      constant(2, 'h20000000); constant(3, 'h40000000);
      /* initialize the ABI caller-clobbered save set before the interrupt. */
      for (int index = 0; index < 16; index++) begin
        constant(5'(save_regs[index]), 'h12340000 + 32'(save_regs[index]));
        saved_values[index] = regs_ref[save_regs[index]];
      end
      unused_choice = random_word();
      chosen_accept = scenario == 0 ? 126 : scenario == 1 ? 0 : scenario == 2 ? 63 : int'(unused_choice[7:1]);
      if (chosen_accept > 126) chosen_accept = 126;
      chosen_response = 127 - chosen_accept;
      accept_delay = chosen_accept; response_delay = chosen_response;
      send('h0001a003); await_owner(); send('h00100913);
      /* stop at the independently visible admission boundary. */
      begin
        int timeout;
        timeout = 0;
        /* model long execution only after the arithmetic attempt is admitted. */
        while (!(stage_valid_o[2] && stage_token_o[2].admitted)) begin
          tick(); timeout++; check(timeout < 64, "latency arithmetic admission timeout");
        end
      end
      x_delay = scenario == 0 ? 36 : scenario == 1 ? 8 : int'(unused_choice[10:8]);
      hold_i[2] = 1; count_irq = interrupts; fetch_busy_i = 1;
      block_ready = 1; tick(); block_ready = 0; origin = edges;
      /* this origin is the edge at which the retained platform level becomes visible. */
      repeat (4) tick(); fetch_busy_i = 0;
      /* endpoint cases serialize the hold after memory for a conservative occupancy test. */
      if (scenario < 2) begin while (owner) tick(); end
      repeat (x_delay) tick(); hold_i[2] = 0; await_irq(count_irq);
      entry_edge = edges;
      check(entry_edge - origin <= (scenario == 0 ? 195 : 151), "full IRQ entry latency exceeded");
      if (entry_edge - origin > max_entry) max_entry = entry_edge - origin;
      /* vector delivery is an explicit adapter delay, not an instruction RAM measurement. */
      repeat (16) tick(); issue_pc = arch_pc; accept_delay = 0; response_delay = 1;
      start_saves = saves; save_start = edges; send(store_word(save_regs[0], 2, 0));
      wait_cycles = 0;
      /* timestamp the actual first handler token in D. */
      while (!(stage_valid_o[1] && stage_token_o[1].p.pc == 'h100)) begin
        tick(); wait_cycles++; check(wait_cycles < 16, "handler D arrival timeout");
      end
      handler_edge = edges; check(handler_edge - origin <= 224, "full handler D latency exceeded");
      if (handler_edge - origin > max_handler) max_handler = handler_edge - origin;
      /* sixteen actual decoded stores save caller-clobbered GPRs in a 64-byte reserved area. */
      for (int index = 1; index < 16; index++) send(store_word(save_regs[index], 2, index*4));
      drain(); saved_edge = edges;
      for (int index = 0; index < 16; index++) check(ram[index] == saved_values[index], "ISR register save mismatch");
      check(saves == start_saves + 16, "ISR save count mismatch");
      if (edges - origin > max_saved) max_saved = edges - origin;
      /* the accepted ACK consumes exactly one block after the complete software save. */
      constant(5, 'h40001020); constant(6, 1); send(store_word(6, 5, 0)); drain();
      check(platform_count == 0 && ack_edge > saved_edge && ack_complete_edge - handler_edge <= 640,
          "ISR block ACK order or service budget mismatch");
      if (ack_complete_edge - handler_edge > max_ack) max_ack = ack_complete_edge - handler_edge;
      /* restore the original caller state with real loads before returning to the saved PC. */
      for (int index = 0; index < 16; index++)
        send((32'(index*4) << 20) | (2 << 15) | 'h2003 | (32'(save_regs[index]) << 7));
      drain();
      for (int index = 0; index < 16; index++) check(regs_ref[save_regs[index]] == saved_values[index], "ISR restore mismatch");
      send('h30200073); drain(); issue_pc = arch_pc;
      check(edges - handler_edge <= 800 && interrupts == count_irq + 1, "ISR return budget or duplicate IRQ mismatch");
      if (edges - handler_edge > max_return) max_return = edges - handler_edge;
      $display("LATENCY scenario=%0d accept=%0d response=%0d x_hold=%0d synthetic_future_divider=%0d fetch_drain=4 vector_delivery=16 source_to_entry=%0d source_to_D=%0d source_to_saved=%0d D_to_ACK_effect=%0d D_to_ACK_complete=%0d D_to_MRET=%0d save_work=%0d",
          scenario, chosen_accept, chosen_response, x_delay, scenario == 0, entry_edge-origin, handler_edge-origin,
          saved_edge-origin, ack_edge-handler_edge, ack_complete_edge-handler_edge, edges-handler_edge, saved_edge-save_start);
    end
  endtask

  /* uncertain outcomes and missed deadlines contain the core instead of fabricating precise traps. */
  task automatic containment_cases();
    int count_irq, count_retired, count_reads, count_offers, waited;
    /* cover an explicit uncertain response and a late response after the watchdog deadline. */
    for (int scenario = 0; scenario < 2; scenario++) begin
      reset_case(); configure(); constant(2, 'h40000000);
      allow_fatal = 1; response_status = scenario == 0 ? 2 : 0;
      response_delay = scenario == 0 ? 4 : 128;
      count_irq = interrupts; count_retired = retired; count_reads = reads; count_offers = offers;
      send('h00012003); await_owner(); manual_levels = 'h800; waited = 0;
      /* healthy IRQ bounds are deliberately inapplicable once service becomes uncertain. */
      while (!fatal_o) begin tick(); waited++; check(waited <= 130, "missing IRQ containment deadline"); end
      check(fatal_record_o.reason == (scenario == 0 ? 2 : 3) && fatal_record_o.owned &&
          fatal_record_o.accepted && fatal_record_o.responded == (scenario == 0) &&
          edges - owner_start == (scenario == 0 ? 5 : 128), "IRQ containment evidence mismatch");
      repeat (12) tick();
      check(response_sent && owner && fatal_o && interrupts == count_irq && retired == count_retired &&
          offers == count_offers + 1 && reads == count_reads + (scenario == 0 ? 0 : 1),
          "IRQ containment replayed or retired an uncertain operation");
    end
    reset_case();
  endtask

  /* initialize all ledgers before the first reset edge. */
  initial begin
    /* unused identities and RAM words cannot accidentally satisfy a scoreboard comparison. */
    for (int uid = 0; uid < CAPACITY; uid++) begin
      original[uid] = '0; live[uid] = 0; admitted[uid] = 0; issued[uid] = 0;
      completed[uid] = 0; loaded[uid] = 0; completion_status[uid] = 0;
    end
    for (int word = 0; word < 64; word++) ram[word] = 0;
    /* initialize reference storage while retaining only x0 as architecturally defined. */
    for (int regno = 0; regno < 32; regno++) begin regs_ref[regno] = 0; defined_ref[regno] = regno == 0; end
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    random_state = seed;
    priority_cases(); drain_cases(); wfi_cases(); platform_cases(); latency_cases(); containment_cases();
    check(!($test$plusargs("mutate_irq_pc") || $test$plusargs("mutate_irq_cause") ||
        $test$plusargs("mutate_irq_lost") || $test$plusargs("mutate_counter") ||
        $test$plusargs("mutate_wfi_wake") || $test$plusargs("mutate_duplicate_read")) || mutation_applied,
          "IRQ negative control never activated");
    $display("PASS irq-control C=%0d seed=%0d cases=%0d edges=%0d checks=%0d retired=%0d traps=%0d interrupts=%0d admissions=%0d kills=%0d offers=%0d replies=%0d effects=%0d sleeps=%0d wakes=%0d saves=%0d entry_max=%0d handler_max=%0d saved_max=%0d service_max=%0d ack_max=%0d return_max=%0d",
        C_ENABLED, seed, cases, edges, checks, retired, traps, interrupts, admissions, killed,
        offers, replies, effects, sleeps, wakes, saves, max_entry, max_handler, max_saved, max_service, max_ack, max_return);
    $finish;
  end
endmodule

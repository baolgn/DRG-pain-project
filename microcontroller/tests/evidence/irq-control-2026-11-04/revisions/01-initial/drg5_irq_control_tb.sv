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
      .IRQ_ENABLED(1), .D_MAX_WAIT_CYCLES(128)) dut (.*);

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
  bit owner = 0, accepted = 0;
  int owner_uid = 0, owner_age = 0, response_age = 0;
  int accept_delay = 0, response_delay = 1, owner_accept_delay = 0, owner_response_delay = 1;
  logic [1:0] response_status = 0, owner_status = 0;
  logic [31:0] owner_addr = 0, owner_data = 0, owner_tag = 0, owner_reply = 0;
  bit owner_write = 0;
  logic [63:0] time_ref = 0, acquisition_clocks = 0;
  logic [31:0] block_ref = 0, enable_platform_ref = 0;
  int effects = 0, reads = 0, writes = 0, replies = 0, offers = 0;
  int cases = 0, edges = 0, checks = 0, retired = 0, traps = 0, interrupts = 0, killed = 0;
  int admissions = 0, sleeps = 0, wakes = 0, saves = 0, max_entry = 0, max_handler = 0, max_saved = 0;
  bit accepted_input = 0, mutation_applied = 0;
  bit last_idle = 0, flush_pending = 0;
  logic [31:0] flush_target = 0;
  int seed = 1, random_state = 1;

  /* reject a mismatch before observed state can replace an independent expectation. */
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
  function automatic logic [31:0] irq_cause(input logic [31:0] pending);
    /* no unsupported pending bit can choose a machine cause. */
    if (pending[11]) return 32'h8000000b;
    if (pending[3]) return 32'h80000003;
    if (pending[7]) return 32'h80000007;
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
      'h344: return manual_levels | (block_ref != 0 && enable_platform_ref[0] ? 'h800 : 0);
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
  function automatic logic [31:0] immediate(input logic [31:0] raw, input bit store);
    return store ? {{20{raw[31]}},raw[31:25],raw[11:7]} : {{20{raw[31]}},raw[31:20]};
  endfunction

  /* registered target service separates acceptance delay from response delay. */
  always_comb begin
    d_req_ready_i = owner && !accepted && owner_age >= owner_accept_delay;
    d_rsp_valid_i = owner && accepted && response_age >= owner_response_delay - 1;
    d_rsp_tag_i = owner_tag;
    d_rsp_rdata_i = owner_status == 0 && !owner_write ? owner_reply : 0;
    d_rsp_status_i = owner_status;
  end

  /* one scoreboard instance avoids duplicating a large model through driver task inlining. */
  always @(posedge clk_i) begin : scoreboard
    logic [4:0] before_valid;
    token_t before [0:4];
    bit input_fire, launch, accept_bus, complete_bus, reset_active, pre_idle, pre_entry, pre_fetch;
    bit pre_owner, pre_completed, flush_fire, platform_fire;
    logic [31:0] old_pc, old_pending, old_status, pre_platform_data;
    logic [31:0] raw, value, next_pc, source, old_csr, post_csr, fault_cause, fault_value;
    logic [31:0] expected_addr, expected_data, observed_epc, expected_levels;
    logic [11:0] address;
    logic [4:0] rd, rs1, rs2;
    bit fault, write_reg, csr_instruction, read_csr, write_csr, is_return, is_wfi;
    bit observed_irq;
    int id, count, new_admissions;
    logic [63:0] old_cycle, old_retired;
    before_valid = stage_valid_o; before = stage_token_o;
    input_fire = in_valid_i && in_ready_o; launch = mem_launch_o;
    accept_bus = d_req_valid_o && d_req_ready_i;
    complete_bus = d_rsp_valid_i && d_rsp_ready_o;
    reset_active = cold_reset_i || hart_reset_i; pre_idle = idle_o; pre_entry = entry_pending_o;
    pre_fetch = fetch_busy_i; pre_owner = owner; old_pc = arch_pc;
    old_status = status_ref; old_pending = csr_read('h344) & enable_ref & 'h888;
    pre_completed = before_valid[4] && completed[int'(before[4].uid)];
    flush_fire = flush_valid_i && flush_ready_o;
    platform_fire = platform_command; pre_platform_data = platform_data;
    accepted_input = input_fire;
    /* the platform retention model never observes its own output as expected pending state. */
    expected_levels = block_ref != 0 && enable_platform_ref[0] ? 'h800 : 0;
    check(platform_levels == expected_levels && platform_count == block_ref &&
        platform_enable == enable_platform_ref && platform_pending == (block_ref != 0 ? 1 : 0),
        "persistent platform event mismatch");
    check(platform_time == time_ref && platform_compare == '1 && !platform_msip &&
        !platform_overflow && !platform_stop, "independent platform clock/state mismatch");
    check(mem_busy_o == owner && d_req_valid_o == (owner && !accepted), "physical IRQ owner mismatch");
    /* an exposed descriptor stays stable even while interrupt entry waits for service. */
    if (owner) check(d_req_addr_o == owner_addr && d_req_wdata_o == owner_data &&
        d_req_tag_o == owner_tag && d_req_write_o == owner_write && d_req_size_o == 2 &&
        d_req_wstrb_o == (owner_write ? 15 : 0), "IRQ request changed while owned");
    /* selected entry or WFI cannot consume a fresh front-end offer. */
    if (pre_entry || pre_idle) check(!input_fire && !launch, "IRQ selection launched new work");
    old_cycle = cycles_ref; old_retired = retired_ref;
    #1; edges++; acquisition_clocks++;
    observed_irq = irq_valid_o; observed_epc = irq_pc_o;
    /* corrupt event PC only after a real event reaches the ordinary comparator. */
    if ($test$plusargs("mutate_irq_pc") && observed_irq && !mutation_applied) begin
      observed_epc += 4; mutation_applied = 1;
    end
    /* all killed identities must have existed before this edge. */
    for (int stage = 0; stage < 5; stage++) begin
      /* reset and redirects are the only owners of cancellation. */
      if (kill_valid_o[stage]) begin
        id = int'(kill_uid_o[stage]);
        check(before_valid[stage] && id < CAPACITY && live[id] && before[stage].uid == kill_uid_o[stage],
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
      if (cold_reset_i) begin next_uid = 0; next_order = 0; owner = 0; accepted = 0; end
    end
    /* nonreset edges count independently of issue, memory or WFI idle. */
    else begin
      /* old inhibit state governs the edge before any explicit CSR write. */
      if (!inhibit_ref[0]) cycles_ref++;
      if (!inhibit_ref[2] && trace_o.valid && !trace_o.trap) retired_ref++;
      /* interrupt entry is a separate architectural event and cannot retire a fictitious token. */
      if (observed_irq) begin
        check(!trace_o.valid && !pre_fetch && !pre_owner && old_status[3] && old_pending != 0,
              "IRQ entry violated eligibility or ownership");
        /* every admitted older attempt must have completed before interrupt state changes. */
        for (int uid = 0; uid < CAPACITY; uid++) check(!live[uid] || !admitted[uid], "IRQ passed admitted work");
        check(observed_epc == old_pc && irq_cause_o == irq_cause(old_pending), "independent IRQ PC/cause mismatch");
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
              check(raw[14:12] == 2 && pre_completed, "memory retired before registered completion");
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
                /* unsupported addresses fault before a normal access event. */
                if (!csr_known(address)) begin fault = 1; fault_cause = 2; fault_value = 0; end
                /* legal forms read pre-edge counter values before this edge's increment. */
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
        /* compare faults and register updates before changing expected architectural state. */
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
            check(!platform_error, "platform rejected supported IRQ fixture command");
            owner_reply = pre_platform_data;
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
          else begin owner_reply = 32'(reads); reads++; end
        end
      end
      /* a reply completes its one owner, without allowing same-edge retirement. */
      if (complete_bus) begin
        check(owner && accepted, "ownerless IRQ response");
        completed[owner_uid] = 1; completion_status[owner_uid] = owner_status;
        loaded[owner_uid] = owner_reply; owner = 0; accepted = 0; replies++;
      end
      /* launch permission is distinct from an ordinary instruction's stage ownership. */
      if (launch) begin
        id = int'(before[3].uid); raw = original[id].raw;
        check(!pre_owner && before_valid[3] && live[id] && !issued[id] &&
            (raw[6:0] == 'h03 || raw[6:0] == 'h23), "IRQ launched invalid memory attempt");
        rs1 = raw[19:15]; rs2 = raw[24:20];
        expected_addr = regs_ref[rs1] + immediate(raw, raw[6:0] == 'h23);
        expected_data = raw[6:0] == 'h23 ? regs_ref[rs2] : 0;
        check(d_req_addr_o == expected_addr && d_req_wdata_o == expected_data,
              "IRQ memory descriptor differs from instruction intent");
        owner = 1; accepted = 0; owner_uid = id; issued[id] = 1;
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
    if (cold_reset_i) begin time_ref = 0; block_ref = 0; enable_platform_ref = 0; end
    /* CPU sleep and hart reset never gate the independent acquisition/timer domain. */
    else begin
      time_ref++;
      /* acknowledge consumes one queued block, while same-edge arrival remains retained. */
      if (platform_fire && owner_write && owner_addr == 'h40001020 && owner_data[0] && block_ref != 0) block_ref--;
      if (block_ready) block_ref++;
      if (platform_fire && owner_write && owner_addr == 'h40001018) enable_platform_ref = owner_data;
    end
    /* accepted packets receive independent monotonically allocated identities. */
    if (input_fire) begin
      check(next_uid < CAPACITY, "IRQ fixture UID capacity exceeded");
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
    /* ordinary observation mutations calibrate the architectural state checks. */
    if ($test$plusargs("mutate_counter") && pre_idle && !mutation_applied) begin
      cycles_ref--; mutation_applied = 1;
    end
    check(mstatus_o == status_ref && mie_o == enable_ref && mtvec_o == vector_ref &&
        mscratch_o == scratch_ref && mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref &&
        mcountinhibit_o == inhibit_ref, "independent IRQ trap/CSR state mismatch");
    check(mcycle_o == cycles_ref && minstret_o == retired_ref, "independent IRQ counter mismatch");
    /* waking without global MIE cannot itself create a trap or lose the continuation. */
    if (pre_idle && !reset_active && old_pending != 0) check(!idle_o, "WFI failed to wake on locally enabled pending");
    if (pre_idle && !reset_active && old_pending == 0) check(idle_o, "WFI woke for masked or absent event");
    if (!last_idle && idle_o) sleeps++;
    if (last_idle && !idle_o) wakes++;
    last_idle = idle_o;
  end

  /* drive only clock edges; the independent scoreboard runs once per edge. */
  task automatic tick();
    clk_i = 0; #2; clk_i = 1; #2; clk_i = 0;
  endtask

  /* start a case with positively isolated cold reset and a cleared external source. */
  task automatic reset_case();
    cases++; manual_levels = 0; fetch_busy_i = 0; hold_i = 0;
    in_valid_i = 0; flush_valid_i = 0; block_ready = 0; event_set = 0;
    accept_delay = 0; response_delay = 1; response_status = 0;
    cold_reset_i = 1; hart_reset_i = 0; tick(); cold_reset_i = 0; tick(); tick(); issue_pc = 0;
  endtask

  /* offer one immutable raw32 instruction until the packet input accepts it. */
  task automatic send(input logic [31:0] raw, input bit fault = 0,
      input logic [31:0] cause = 0, input logic [31:0] tval = 0);
    int timeout;
    in_packet_i = '0; in_packet_i.op = OP_MACHINE; in_packet_i.pc = issue_pc;
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

  /* initialize all ledgers before the first reset edge. */
  initial begin
    /* unused identities and RAM words cannot accidentally satisfy a scoreboard comparison. */
    for (int uid = 0; uid < CAPACITY; uid++) begin
      original[uid] = '0; live[uid] = 0; admitted[uid] = 0; issued[uid] = 0;
      completed[uid] = 0; loaded[uid] = 0; completion_status[uid] = 0;
    end
    for (int word = 0; word < 64; word++) ram[word] = 0;
    for (int regno = 0; regno < 32; regno++) begin regs_ref[regno] = 0; defined_ref[regno] = regno == 0; end
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    random_state = seed;
    reset_case(); configure(); manual_levels = 'h800; await_irq(interrupts);
    check(interrupts > 0 && cause_ref == 'h8000000b, "initial external IRQ missing");
    check(!$test$plusargs("mutate_irq_pc") && !$test$plusargs("mutate_counter") || mutation_applied,
          "IRQ negative control never activated");
    $display("PASS irq-control C=%0d seed=%0d cases=%0d edges=%0d checks=%0d retired=%0d traps=%0d interrupts=%0d admissions=%0d kills=%0d offers=%0d replies=%0d effects=%0d sleeps=%0d wakes=%0d saves=%0d entry_max=%0d handler_max=%0d saved_max=%0d",
        C_ENABLED, seed, cases, edges, checks, retired, traps, interrupts, admissions, killed,
        offers, replies, effects, sleeps, wakes, saves, max_entry, max_handler, max_saved);
    $finish;
  end
endmodule

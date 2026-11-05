/* compare raw RV32M retirement, job ownership, dependencies and interrupt service. */
module drg5_muldiv_control_tb #(parameter bit M_ENABLED = 1, DIAGNOSTIC = 0, FORWARDING = 1);
  localparam bit C_ENABLED = 0;
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

  /* qualify exact M enablement separately from occupancy and forwarding choices. */
  drg5_control #(.DIAGNOSTIC(DIAGNOSTIC), .FORWARDING(FORWARDING), .M_ENABLED(M_ENABLED), .C_ENABLED(C_ENABLED),
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


  bit job_owned = 0;
  int job_uid = 0, job_start = 0;
  logic [2:0] job_op = 0;
  logic [31:0] job_expected = 0;
  logic [31:0] arithmetic_expected [0:CAPACITY-1];
  int starts = 0, finishes = 0, discarded = 0, cancelled = 0, arithmetic_retired = 0;
  int mul_latency = 0, div_latency = 0, held_results = 0, dependent_edges = 0;
  int mask_alu = 0, mask_branch = 0, mask_address = 0, mask_store = 0;
  logic [7:0] op_coverage = 0;

  /* use independent wide mathematical operations, guarding undefined host division cases. */
  function automatic logic [31:0] reference_m(input logic [2:0] operation,
      input logic [31:0] lhs, rhs);
    logic signed [63:0] a_signed, b_signed, unused_signed_product;
    logic [63:0] ununused_signed_product;
    a_signed = {{32{lhs[31]}},lhs};
    b_signed = operation == 2 ? $signed({32'b0,rhs}) : $signed({{32{rhs[31]}},rhs});
    unused_signed_product = a_signed * b_signed;
    ununused_signed_product = {32'b0,lhs} * {32'b0,rhs};
    /* funct3 selects the ISA result, independently of the restoring implementation. */
    case (operation)
      0: return ununused_signed_product[31:0];
      1,2: return unused_signed_product[63:32];
      3: return ununused_signed_product[63:32];
      4: return rhs == 0 ? 32'hffffffff : lhs == 32'h80000000 && rhs == 32'hffffffff ? lhs : 32'($signed(lhs) / $signed(rhs));
      5: return rhs == 0 ? 32'hffffffff : lhs / rhs;
      6: return rhs == 0 ? lhs : lhs == 32'h80000000 && rhs == 32'hffffffff ? 32'b0 : 32'($signed(lhs) % $signed(rhs));
      7: return rhs == 0 ? lhs : lhs % rhs;
      default: return 0;
    endcase
  endfunction

  /* encode one exact M operation without consulting the implementation decoder. */
  function automatic logic [31:0] m_word(input int operation, rd, rs1, rs2);
    return 32'h02000033 | (32'(operation) << 12) | (32'(rd) << 7) |
        (32'(rs1) << 15) | (32'(rs2) << 20);
  endfunction

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
      'h301: return M_ENABLED ? 32'h40001100 : 32'h40000100;
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
    return address inside {'h301,'h300,'h304,'h305,'h320,'h340,'h341,'h342,'h343,'h344,'hb00,'hb02};
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
    bit pre_start, pre_md_valid;
    logic [31:0] observed_md_result;
    logic [63:0] observed_md_uid;
    bit pre_owner, pre_completed, flush_fire, platform_fire, pre_platform_error, external_redirect;
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
    pre_start = dut.md_start; pre_md_valid = dut.md_valid;
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
    /* the job ledger survives hart reset and architectural cancellation. */
    if (cold_reset_i) begin
      if (job_owned) cancelled++;
      job_owned = 0;
    end else begin
      /* consumption releases the prior manager owner before any later job is allowed. */
      if (pre_md_valid) begin
        check(job_owned && !pre_start, "M response has no unique owner");
        if (!live[job_uid] || hart_reset_i || kill_valid_o[2]) discarded++;
        job_owned = 0; finishes++;
      end
      /* starts capture the immutable architectural identity and operation exactly once. */
      if (pre_start) begin
        check(!job_owned && before_valid[2] && !pre_entry, "M start violated ownership or IRQ veto");
        job_owned = 1; job_uid = int'(prior[2].uid); job_start = edges;
        job_op = original[job_uid].raw[14:12];
        job_expected = reference_m(job_op,prior[2].p.rs1_value,prior[2].p.rs2_value);
        arithmetic_expected[job_uid] = job_expected; starts++;
        check(M_ENABLED && original[job_uid].op == OP_MACHINE && original[job_uid].raw[31:25] == 1 &&
              original[job_uid].raw[6:0] == 'h33, "M started for rejected encoding");
      end
      observed_md_result = dut.md_result; observed_md_uid = dut.md_uid;
      /* detector calibration changes the observed job identity, never the reference ledger. */
      if ($test$plusargs("mutate_job_uid") && dut.md_valid && !mutation_applied) begin
        observed_md_uid++; mutation_applied = 1;
      end
      check(dut.md_busy == job_owned, "M busy ownership mismatch");
      /* completion latency is measured from the accepted start edge, including final selection. */
      if (dut.md_valid) begin
        check(job_owned && observed_md_uid == 64'(job_uid), "M completion UID mismatch");
        check(observed_md_result == job_expected, "M unit result differs from independent reference");
        check(edges - job_start == (job_op[2] ? 33 : 2), "M fixed result latency mismatch");
        if (job_op[2]) div_latency = edges - job_start;
        else mul_latency = edges - job_start;
      end
    end
    observed_irq = irq_valid_o; observed_epc = irq_pc_o; observed_cause = irq_cause_o;
    observed_idle = idle_o; observed_cycle = mcycle_o; external_redirect = 0;
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
    /* all killed identities must have existed before this edge. */
    for (int stage = 0; stage < 5; stage++) begin
      /* reset and redirects are the only owners of cancellation. */
      if (kill_valid_o[stage]) begin
        id = int'(kill_uid_o[stage]);
        check(before_valid[stage] && id < CAPACITY && live[id] && prior[stage].uid == kill_uid_o[stage],
              "IRQ duplicate or ownerless kill");
        /* IRQ entry may discard only the unadmitted suffix. */
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
      /* old inhibit state governs the edge before any explicit CSR write. */
      if (!inhibit_ref[0]) cycles_ref++;
      /* interrupt entry is a separate architectural event and cannot retire a fictitious token. */
      if (observed_irq) begin
        check(!job_owned, "IRQ passed an outstanding arithmetic job");
        check(!trace_o.valid && !pre_fetch && !pre_owner && old_status[3] && old_pending != 0,
              "IRQ entry violated eligibility or ownership");
        /* every admitted older attempt must have completed before interrupt state changes. */
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
            /* only the selected machine profile accepts exact M encodings. */
            'h33: begin
              if (M_ENABLED && original[id].op == OP_MACHINE && raw[31:25] == 1) begin
                value = reference_m(raw[14:12],regs_ref[rs1],regs_ref[rs2]); write_reg = rd != 0;
                arithmetic_retired++; op_coverage[raw[14:12]] = 1;
                /* corrupt one retirement value at its ordinary architectural comparator. */
                if ($test$plusargs("mutate_m_result") && !mutation_applied) begin
                  value ^= 1; mutation_applied = 1;
                end
              end else begin fault = 1; fault_cause = 2; fault_value = 0; end
            end
            /* conditional control reads independently retired source values. */
            'h63: begin
              if (raw[14:12] != 0) begin fault = 1; fault_cause = 2; fault_value = 0; end
              else if (regs_ref[rs1] == regs_ref[rs2])
                next_pc = arch_pc + {{19{raw[31]}},raw[31],raw[7],raw[30:25],raw[11:8],1'b0};
            end
            /* JAL derives both link and signed target directly from the original instruction. */
            'h6f: begin
              value = arch_pc + 4; write_reg = rd != 0;
              next_pc = arch_pc + {{11{raw[31]}},raw[31],raw[19:12],raw[20],raw[30:21],1'b0};
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
                    'h301: post_csr = old_csr;
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
      /* a completed external flush supersedes a successful protected retirement boundary. */
      if (flush_fire) begin flush_pending = 1; flush_target = flush_pc_i; end
      /* consume only the redirect owned by the pending external flush. */
      if (redirect_valid_o && !observed_irq && !(trace_o.valid && trace_o.trap) &&
          (flush_pending || !trace_o.valid)) begin
        check(flush_pending && redirect_pc_o == flush_target, "unexpected noninstruction redirect");
        arch_pc = flush_target; flush_pending = 0; external_redirect = 1;
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
    /* a saved result remains attached to its instruction under every pipeline hold. */
    if (stage_valid_o[2] && stage_token_o[2].md_done) begin
      check(stage_token_o[2].p.result == arithmetic_expected[int'(stage_token_o[2].uid)], "M saved result changed");
      if (hold_i[2] || stage_valid_o[3]) held_results++;
    end
    /* newest unfinished X producers must block each consumer class in D. */
    if (before_valid[2] && before_valid[1] && prior[2].md_decoded && !prior[2].md_done &&
        prior[2].p.rd != 0 && (prior[1].p.raw[19:15] == prior[2].p.rd || prior[1].p.raw[24:20] == prior[2].p.rd)) begin
      check(!pre_transfer[1], "M dependency forwarded an older value"); dependent_edges++;
      case (prior[1].p.raw[6:0])
        'h13: mask_alu++;
        'h63: mask_branch++;
        'h03: mask_address++;
        'h23: mask_store++;
        default: begin end
      endcase
    end
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
    /* only a validated external-flush completion can wake idle without local pending state. */
    if (pre_idle && !reset_active && old_pending == 0 && !external_redirect)
      check(observed_idle, "WFI woke for masked or absent event");
    /* calibrate a missing flush wake at the ordinary independently validated redirect boundary. */
    if ($test$plusargs("mutate_wfi_flush_wake") && pre_idle && external_redirect && !mutation_applied) begin
      observed_idle = 1; mutation_applied = 1;
    end
    if (pre_idle && !reset_active && external_redirect)
      check(!observed_idle, "WFI failed to wake on completed external flush");
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
    while (stage_valid_o != 0 || mem_busy_o || dut.md_busy) begin tick(); timeout++; check(timeout < 512, "IRQ drain timeout"); end
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

  /* wait for a real accepted arithmetic job, not just a fetched M instruction. */
  task automatic await_job();
    int waited;
    waited = 0;
    /* unavailable unit ownership has a bounded arithmetic completion. */
    while (!job_owned) begin tick(); waited++; check(waited < 128, "M start timeout"); end
  endtask

  /* cover every instruction with boundary operands, x0 and independently randomized values. */
  task automatic arithmetic_cases();
    logic [31:0] boundary [0:11];
    logic [31:0] lhs, rhs;
    int before_starts;
    boundary = '{0,1,2,3,32'h7fffffff,32'h80000000,32'hffffffff,32'hfffffffd,
                 32'h00010000,32'hffff0001,32'h80000001,32'h55555555};
    /* every operation includes negative, zero, overflow and mixed-sign high-product cases. */
    for (int operation = 0; operation < 8; operation++) begin
      for (int vector = 0; vector < (M_ENABLED ? 20 : 1); vector++) begin
        reset_case();
        lhs = vector < 12 ? boundary[vector] : random_word();
        rhs = vector < 12 ? boundary[(vector+6)%12] : random_word();
        /* explicit divide specials remain present regardless of random seed. */
        if (vector == 0) begin lhs = 'h80000000; rhs = 'hffffffff; end
        if (vector == 1) begin lhs = 'hfffffffd; rhs = 0; end
        if (vector == 2) begin lhs = 'hfffffff9; rhs = 3; end
        if (vector == 3) begin lhs = 7; rhs = 'hfffffffd; end
        constant(2,lhs); constant(3,rhs); before_starts = starts;
        send(m_word(operation,5,2,3)); drain();
        check(starts == before_starts + int'(M_ENABLED), "M enablement changed job count");
        /* a destination of x0 still executes a single owned job. */
        if (M_ENABLED && vector == 0) begin send(m_word(operation,0,2,0)); drain(); end
      end
    end
    /* the base-only entry never inherits the M-enabled machine entry's legality. */
    reset_case(); constant(2,12); constant(3,3); before_starts = starts;
    send(m_word(0,5,2,3),0,0,0,OP_BASE); drain();
    check(cause_ref == 2 && starts == before_starts, "OP_BASE accepted M instruction");
    /* near-miss funct7 and RV64 word encodings must not start arithmetic. */
    reset_case(); send('h042182b3); drain(); check(cause_ref == 2, "reserved funct7 did not trap");
    reset_case(); send('h022182bb); drain(); check(cause_ref == 2, "RV64 M word instruction did not trap");
    /* misa must describe the selected build, independently of packet-interface restrictions. */
    reset_case(); send('h301022f3); drain();
    check(regs_ref[5] == (M_ENABLED ? 32'h40001100 : 32'h40000100), "M misa identity mismatch");
  endtask

  /* block ALU, branch, address and store consumers behind the newest unfinished producer. */
  task automatic dependency_cases();
    int count_reads;
    /* an older value with the same destination must never bypass an unfinished divide. */
    reset_case(); constant(2,100); constant(3,3); constant(5,99);
    send(m_word(4,5,2,3)); send('h00128313); drain();
    check(regs_ref[6] == 34, "M ALU dependency selected stale value");
    /* a dependent untaken branch keeps the known sequential instruction stream. */
    reset_case(); constant(2,100); constant(3,3); constant(5,0);
    send(m_word(4,5,2,3)); send('h00028463); send('h00100393); drain();
    check(regs_ref[7] == 1, "M branch dependency selected stale value");
    /* multiplication creates a permitted RAM address from two ordinary GPR operands. */
    reset_case(); constant(2,'h10000000); constant(3,2); constant(5,'h40000000);
    ram[0] = 'h1234abcd; count_reads = reads;
    send(m_word(0,5,2,3)); send('h0002a303); drain();
    check(regs_ref[6] == 'h1234abcd && reads == count_reads, "M address dependency caused wrong device access");
    /* store data uses the same newest-producer rule independently of its base address. */
    reset_case(); constant(2,100); constant(3,3); constant(5,99); constant(8,'h20000000);
    send(m_word(6,5,2,3)); send(store_word(5,8,0)); drain();
    check(ram[0] == 1, "M store dependency selected stale value");
    /* a younger M instruction captures the first M result before either source can change. */
    reset_case(); constant(2,100); constant(3,3);
    send(m_word(4,5,2,3)); send(m_word(0,6,5,3)); drain();
    check(regs_ref[6] == 99, "M-to-M dependency failed");
  endtask

  /* unit completion must survive X holds and later M/W backpressure without reissue. */
  task automatic backpressure_cases();
    int before_starts, before_retired;
    /* exact result retention is checked every edge in the independent job ledger. */
    for (int operation = 0; operation < 8; operation++) begin
      reset_case(); constant(2,'h80000001); constant(3,3);
      before_starts = starts; before_retired = arithmetic_retired;
      send(m_word(operation,5,2,3)); await_job(); hold_i[2] = 1;
      repeat (40) tick(); check(stage_token_o[2].md_done, "M result absent under X hold");
      hold_i[3] = 1; hold_i[2] = 0; tick(); repeat (5) tick();
      hold_i[4] = 1; hold_i[3] = 0; tick(); repeat (5) tick(); hold_i = 0; drain();
      check(starts == before_starts + 1 && arithmetic_retired == before_retired + 1,
            "M backpressure duplicated start or retirement");
    end
  endtask

  /* orphan jobs finish once and cannot deliver into a replacement instruction. */
  task automatic cancellation_cases();
    int before_retired, before_discard, before_starts, waited;
    logic [31:0] target;
    /* reset and explicit flush each cancel every phase of a real division. */
    for (int reset_kind = 0; reset_kind < 2; reset_kind++) begin
      for (int phase = 0; phase <= 33; phase++) begin
        reset_case(); constant(2,100); constant(3,3);
        send(m_word(4,5,2,3)); await_job(); hold_i[2] = 1;
        repeat (phase) tick(); before_retired = arithmetic_retired; before_discard = discarded;
        /* a hart reset clears tokens but leaves the manager job clocked and owned. */
        if (reset_kind == 0) begin hart_reset_i = 1; tick(); hart_reset_i = 0; target = 0; end
        /* an external flush cancels the token without resetting the independent job. */
        else begin target = 'h440; flush_pc_i = target; flush_valid_i = 1; tick(); flush_valid_i = 0; end
        hold_i = 0; drain(); repeat (2) tick(); issue_pc = target;
        check(arithmetic_retired == before_retired && discarded == before_discard + 1,
            "killed M job retired or was not discarded");
        /* fresh sources and a different UID expose stale-result reuse immediately. */
        constant(2,21); constant(3,4); before_starts = starts;
        send(m_word(6,6,2,3)); drain();
        check(regs_ref[6] == 1 && starts == before_starts + 1, "obsolete M result reached replacement");
      end
    end
    /* an older accepted access error must kill its younger issued division. */
    if (!DIAGNOSTIC) begin
      reset_case(); constant(2,100); constant(3,3); constant(8,'h40000000);
      response_status = 1; response_delay = 8; send('h00042003); await_owner();
      before_retired = arithmetic_retired; before_discard = discarded;
      send(m_word(4,5,2,3)); await_job(); drain();
      check(cause_ref == 5 && arithmetic_retired == before_retired && discarded == before_discard + 1,
            "older fault failed to discard M job");
      /* a held older jump cancels an already-issued younger division at its own retirement. */
      reset_case(); constant(2,100); constant(3,3); hold_i[4] = 1;
      target = issue_pc + 64; send('h0400006f);
      waited = 0;
      while (!stage_valid_o[4]) begin tick(); waited++; check(waited < 32,"jump W timeout"); end
      before_retired = arithmetic_retired; before_discard = discarded;
      send(m_word(4,5,2,3)); await_job(); repeat (3) tick(); hold_i[4] = 0; drain();
      check(arch_pc == target && arithmetic_retired == before_retired && discarded == before_discard + 1,
            "older jump failed to discard M job");
    end
  endtask

  /* every divide iteration is a legal interrupt observation point with bounded drainage. */
  task automatic interrupt_cases();
    int count_irq, before_retired, origin, entry;
    /* no iteration or final-result handoff may abandon the admitted instruction. */
    for (int phase = 0; phase <= 34; phase++) begin
      reset_case(); configure(); constant(2,'h80000001); constant(3,3);
      before_retired = arithmetic_retired; send(m_word(4,5,2,3)); await_job();
      repeat (phase) tick(); origin = edges; count_irq = interrupts; manual_levels = 'h800;
      await_irq(count_irq); entry = edges - origin;
      check(arithmetic_retired == before_retired + 1 && !job_owned && entry <= 40,
            "IRQ abandoned divide or exceeded arithmetic drain bound");
    end
    /* an IRQ selected before X admission prevents a speculative arithmetic start. */
    reset_case(); configure(); constant(2,100); constant(3,3);
    before_retired = starts; hold_i[2] = 1; send(m_word(4,5,2,3)); count_irq = interrupts;
    manual_levels = 'h800; await_irq(count_irq); hold_i = 0;
    check(starts == before_retired, "IRQ started an unadmitted divide");
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
      send('h0001a003); await_owner(); send(m_word(4,17,28,29));
      /* stop at the independently visible admission boundary. */
      begin
        int timeout;
        timeout = 0;
        /* measure a real admitted divide while the old data request remains owned. */
        while (!(stage_valid_o[2] && stage_token_o[2].admitted)) begin
          tick(); timeout++; check(timeout < 64, "latency arithmetic admission timeout");
        end
      end
      x_delay = scenario < 2 ? 8 : int'(unused_choice[10:8]);
      hold_i[2] = 1; count_irq = interrupts; fetch_busy_i = 1;
      block_ready = 1; tick(); block_ready = 0; origin = edges;
      /* this origin is the edge at which the retained platform level becomes visible. */
      repeat (4) tick(); fetch_busy_i = 0;
      /* endpoint cases serialize the hold after memory for a conservative occupancy test. */
      if (scenario < 2) begin while (owner) tick(); end
      repeat (x_delay) tick(); hold_i[2] = 0; await_irq(count_irq);
      entry_edge = edges;
      /* the saved context includes the divide result that retired before IRQ entry. */
      for (int index = 0; index < 16; index++) saved_values[index] = regs_ref[save_regs[index]];
      check(entry_edge - origin <= 195, "full IRQ entry latency exceeded");
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
      $display("M_LATENCY scenario=%0d accept=%0d response=%0d x_hold=%0d actual_divide=%0d fetch_drain=4 vector_delivery=16 source_to_entry=%0d source_to_D=%0d source_to_saved=%0d D_to_ACK_effect=%0d D_to_ACK_complete=%0d D_to_MRET=%0d save_work=%0d",
          scenario, chosen_accept, chosen_response, x_delay, 1, entry_edge-origin, handler_edge-origin,
          saved_edge-origin, ack_edge-handler_edge, ack_complete_edge-handler_edge, edges-handler_edge, saved_edge-save_start);
    end
  endtask

  /* initialize every independent owner before the first qualified reset. */
  initial begin
    /* cold reset may reuse identities only after the fixture has isolated all old traffic. */
    for (int uid = 0; uid < CAPACITY; uid++) begin
      original[uid] = '0; live[uid] = 0; admitted[uid] = 0; issued[uid] = 0;
      completed[uid] = 0; loaded[uid] = 0; completion_status[uid] = 0; arithmetic_expected[uid] = 0;
    end
    /* RAM contents are fixture state; GPR reset definedness remains x0 only. */
    for (int word = 0; word < 64; word++) ram[word] = 0;
    for (int regno = 0; regno < 32; regno++) begin regs_ref[regno] = 0; defined_ref[regno] = regno == 0; end
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    random_state = seed; arithmetic_cases();
    /* disabled profiles test rejection and identity without expecting arithmetic execution. */
    if (M_ENABLED) begin
      dependency_cases(); backpressure_cases(); cancellation_cases(); interrupt_cases();
      if (!DIAGNOSTIC) latency_cases();
      check(op_coverage == 255 && mul_latency == 2 && div_latency == 33 && held_results > 0,
            "M arithmetic coverage missing");
      if (!DIAGNOSTIC) check(mask_alu > 0 && mask_branch > 0 && mask_address > 0 && mask_store > 0,
                            "M dependency class coverage missing");
    end
    check(!job_owned && starts == finishes + cancelled, "M job conservation failed");
    check(!($test$plusargs("mutate_m_result") || $test$plusargs("mutate_job_uid") ||
        $test$plusargs("mutate_irq_pc") || $test$plusargs("mutate_duplicate_read")) || mutation_applied,
          "M negative control never activated");
    $display("PASS muldiv-control M=%0d diagnostic=%0d forwarding=%0d seed=%0d cases=%0d edges=%0d checks=%0d retired=%0d traps=%0d interrupts=%0d kills=%0d starts=%0d finishes=%0d discarded=%0d cancelled=%0d arithmetic=%0d ops=%0h held=%0d dependent=%0d alu=%0d branch=%0d address=%0d store=%0d mul_latency=%0d div_latency=%0d offers=%0d replies=%0d effects=%0d sleeps=%0d wakes=%0d saves=%0d entry_max=%0d handler_max=%0d saved_max=%0d service_max=%0d ack_max=%0d return_max=%0d admissions=%0d",
        M_ENABLED, DIAGNOSTIC, FORWARDING, seed, cases, edges, checks, retired, traps, interrupts, killed,
        starts, finishes, discarded, cancelled, arithmetic_retired, op_coverage, held_results,
        dependent_edges, mask_alu, mask_branch, mask_address, mask_store, mul_latency, div_latency,
        offers, replies, effects, sleeps, wakes, saves, max_entry, max_handler, max_saved,
        max_service, max_ack, max_return, admissions);
    $finish;
  end
endmodule

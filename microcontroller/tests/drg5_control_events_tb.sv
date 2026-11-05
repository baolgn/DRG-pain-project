/* verify control-flow disposition under flush, reset and serialized return events. */
module drg5_control_events_tb #(parameter bit C_ENABLED = 0);
  import drg5_control_pkg::*;
  /* disconnected debug outputs retain named endpoints in legacy configurations. */
  logic unused_debug_halted, unused_debug_resumeack, unused_debug_reg_ready;
  logic [31:0] unused_debug_dpc, unused_debug_dcsr, unused_debug_reg_rdata;
  logic [2:0] unused_debug_reg_error;
  /* preserve the explicitly IRQ-disabled compatibility profile. */
  logic unused_entry_pending, unused_idle, unused_irq_valid;
  logic [31:0] unused_irq_pc, unused_irq_cause;
  /* all stimulus and ownership records are bounded independently of DUT counters. */
  localparam integer CAPACITY = 128;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
  logic [4:0] hold_i = 0;
  logic in_valid_i = 0, in_ready_o;
  packet_t in_packet_i = '0;
  logic flush_valid_i = 0, flush_ready_o, flush_aborted_o;
  logic [31:0] flush_pc_i = 0;
  logic redirect_valid_o;
  logic [31:0] redirect_pc_o;
  logic d_req_valid_o, d_req_ready_i = 0, d_req_write_o;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o;
  logic [1:0] d_req_size_o;
  logic [3:0] d_req_wstrb_o;
  logic d_rsp_valid_i = 0, d_rsp_ready_o;
  logic [31:0] d_rsp_tag_i = 0, d_rsp_rdata_i = 0;
  logic [1:0] d_rsp_status_i = 0;
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
  /* this compatibility fixture leaves new interrupt levels disconnected. */
  logic [31:0] unused_mie, unused_mip, unused_mcountinhibit;
  logic [63:0] unused_mcycle, unused_minstret;

  /* expected packets come from explicit stimulus intent rather than observed decode. */
  typedef struct packed {
    packet_t p;
    logic redirects;
  } expected_t;
  expected_t offered_expectation;
  expected_t expected [0:CAPACITY-1];
  packet_t original [0:CAPACITY-1];
  bit live [0:CAPACITY-1], issued [0:CAPACITY-1], completed [0:CAPACITY-1];
  bit failed [0:CAPACITY-1];
  bit prepared [0:CAPACITY-1];
  bit csr_destination [0:31];
  logic [31:0] load_value [0:CAPACITY-1];
  logic [31:0] regs_ref [0:31];
  bit defined_ref [0:31];
  logic [31:0] arch_pc = 0, status_ref = 'h1800, vector_ref = 0, epc_ref = 0;
  logic [31:0] cause_ref = 0, tval_ref = 0;
  logic [63:0] next_uid = 0, next_order = 0;
  bit recovery_ref = 1, flush_pending = 0;
  logic [31:0] flush_target = 0;
  bit owner = 0, owner_accepted = 0, respond = 0, orphan = 0;
  logic [6:0] owner_uid = 0;
  logic [31:0] owner_addr = 0, owner_tag = 0, last_tag = 0;
  logic [31:0] planned_value = 'h12345678;
  logic [1:0] planned_status = 0;
  int unsigned cycles = 0, cases = 0, checks = 0, terminals = 0, traps = 0;
  int unsigned killed = 0, flushes = 0, flush_redirects = 0, aborts = 0, resets = 0;
  int unsigned launches = 0, responses = 0, dual_captures = 0;
  int unsigned normal_w_cases = 0, fault_w_cases = 0, load_flush_cases = 0;
  int unsigned reset_cases = 0, return_cases = 0, csr_capture_cases = 0;
  bit mutation_applied = 0;

  /* overlapping occupancy is essential to the issued-load and younger-jump cases. */
  drg5_control #(.IRQ_ENABLED(0), .FORWARDING(0), .DIAGNOSTIC(0), .C_ENABLED(C_ENABLED), .TEST_REGIONS(1), .D_MAX_WAIT_CYCLES(256)) dut (
    .debug_haltreq_i(1'b0), .debug_resumereq_i(1'b0), .debug_resethaltreq_i(1'b0),
    .debug_halted_o(unused_debug_halted), .debug_resumeack_o(unused_debug_resumeack), .debug_dpc_o(unused_debug_dpc), .debug_dcsr_o(unused_debug_dcsr), .debug_reg_valid_i(1'b0), .debug_reg_write_i(1'b0),
    .debug_reg_addr_i(16'b0), .debug_reg_wdata_i(32'b0), .debug_reg_ready_o(unused_debug_reg_ready),
    .debug_reg_rdata_o(unused_debug_reg_rdata), .debug_reg_error_o(unused_debug_reg_error),
    .mip_levels_i(32'b0), .fetch_busy_i(1'b0),
    .entry_pending_o(unused_entry_pending), .idle_o(unused_idle), .irq_valid_o(unused_irq_valid),
    .irq_pc_o(unused_irq_pc), .irq_cause_o(unused_irq_cause), .mie_o(unused_mie), .mip_o(unused_mip),
    .mcountinhibit_o(unused_mcountinhibit), .mcycle_o(unused_mcycle),
    .minstret_o(unused_minstret), .*
  );

  /* stop at the first mismatch before another edge can corrupt the ownership ledger. */
  function automatic void check(input bit condition, input string message);
    checks++;
    /* each failure names the exact scenario and independently selected PC. */
    if (!condition) $fatal(1, "case=%0d C=%0d cycle=%0d pc=%08x: %s", cases, C_ENABLED, cycles, arch_pc, message);
  endfunction

  /* ordinary operations are synthetic packet stimulus rather than decoded ISA instructions. */
  function automatic packet_t packet(input logic [31:0] pc, input op_t op = OP_RESULT,
      input logic [4:0] rd = 0, input logic [31:0] value = 0);
    packet_t p;
    p = '0;
    p.pc = pc;
    p.raw = 'h13;
    p.raw_valid = 15;
    p.length = 4;
    p.op = op;
    p.rd = rd;
    p.rd_write = rd != 0;
    p.result = value;
    p.next_pc = pc + 4;
    p.mem_size = 2;
    return p;
  endfunction

  /* produce a true JAL encoding while poisoning annotations that D must replace. */
  function automatic packet_t jal(input logic [31:0] pc, input logic [31:0] offset,
      input logic [4:0] rd = 2);
    packet_t p;
    p = packet(pc, OP_CONTROL, 31, 'hdeadbeef);
    p.raw = ((offset & 'h100000) << 11) | ((offset & 'h7fe) << 20) |
            ((offset & 'h800) << 9) | (offset & 'hff000) | (32'(rd) << 7) | 'h6f;
    p.rs1_used = 1;
    p.rs2_used = 1;
    p.rs1 = 31;
    p.rs2 = 31;
    p.rs1_value = 'hbad0bad0;
    p.rs2_value = 'hbad1bad1;
    p.next_pc = 'hbad2bad2;
    return p;
  endfunction

  /* construct the expected JAL effect from its declared offset, not decoded DUT fields. */
  function automatic expected_t jal_expected(input packet_t p, input logic [31:0] offset,
      input logic [4:0] rd = 2);
    expected_t q;
    q = '0;
    q.p = p;
    q.p.rs1_used = 0;
    q.p.rs2_used = 0;
    q.p.rs1 = 0;
    q.p.rs2 = 0;
    q.p.rs1_value = 0;
    q.p.rs2_value = 0;
    q.p.rd = rd;
    q.p.rd_write = rd != 0;
    q.p.result = p.pc + 4;
    q.p.next_pc = p.pc + offset;
    q.redirects = 1;
    q.p.fault = q.p.next_pc[0] || (!C_ENABLED && q.p.next_pc[1]);
    q.p.cause = 0;
    q.p.mtval = q.p.fault ? q.p.next_pc : 0;
    return q;
  endfunction

  /* this fixture uses BEQ of the same independently supplied register on both ports. */
  function automatic packet_t equal_branch(input logic [31:0] pc, input logic [4:0] source);
    packet_t p;
    p = jal(pc, 8);
    p.raw = (32'(source) << 20) | (32'(source) << 15) | 'h463;
    return p;
  endfunction

  /* equal source operands make the declared BEQ target independently certain. */
  function automatic expected_t branch_expected(input packet_t p, input logic [4:0] source,
      input logic [31:0] value);
    expected_t q;
    q = jal_expected(p, 8, 0);
    q.p.rs1_used = 1;
    q.p.rs2_used = 1;
    q.p.rs1 = source;
    q.p.rs2 = source;
    q.p.rs1_value = value;
    q.p.rs2_value = value;
    q.p.result = 0;
    return q;
  endfunction

  /* CSR inputs remain explicit synthetic operations with real W storage semantics. */
  function automatic packet_t csr_write(input logic [31:0] pc, input logic [11:0] address,
      input logic [31:0] value, input logic read_old = 0, input logic [4:0] rd = 0);
    packet_t p;
    p = packet(pc, OP_CSR, rd);
    p.csr_addr = address;
    p.csr_op = CSR_WRITE;
    p.csr_read = read_old;
    p.csr_write = 1;
    p.csr_source = value;
    return p;
  endfunction

  /* select reference CSR values without reading exposed DUT storage. */
  function automatic logic [31:0] csr_value(input logic [11:0] address);
    /* the fixture deliberately limits its synthetic CSR operation subset. */
    case (address)
      'h300: return status_ref;
      'h305: return vector_ref;
      'h341: return epc_ref;
      /* unsupported fixture addresses are test construction errors. */
      default: begin
        check(0, "fixture used an unmodeled CSR");
        return 0;
      end
    endcase
  endfunction

  /* a completed data response updates only the immutable original load's expectation. */
  function automatic expected_t disposition(input logic [6:0] id);
    expected_t q;
    q = expected[id];
    /* no synthetic early load result is accepted before its planned response. */
    if (q.p.op == OP_LOAD && completed[id]) begin
      q.p.fault = failed[id];
      q.p.cause = failed[id] ? 5 : 0;
      q.p.mtval = failed[id] ? q.p.mem_addr : 0;
      /* access faults preserve the original packet's result field. */
      if (!failed[id]) q.p.result = load_value[id];
    end
    return q;
  endfunction

  /* compare and commit one independently eligible architectural terminal. */
  task automatic terminal(input trace_t actual, input packet_t p);
    logic [6:0] id;
    logic [31:0] old_csr, new_csr, write_value, continuation;
    logic do_write;
    packet_t expected_packet;
    id = 7'(actual.uid);
    check(actual.valid && actual.uid < 64'(CAPACITY) && live[id], "terminal lacked an independently accepted owner");
    check(actual.uid == next_terminal_uid() && actual.order == next_order, "terminal bypassed, duplicated or lost an owner");
    check(p.pc == arch_pc && original[id].pc == arch_pc, "architectural instruction sequence diverged");
    expected_packet = p;
    expected_packet.cause = p.fault ? p.cause : 0;
    expected_packet.mtval = p.fault ? p.mtval : 0;
    check(actual.packet == expected_packet && actual.trap == p.fault,
          "terminal packet or fault differed from independent intent");
    old_csr = p.op == OP_CSR ? csr_value(p.csr_addr) : 0;
    new_csr = p.csr_source;
    /* the tested WARL masks are defined independently of DUT readback. */
    if (p.csr_addr == 'h300) new_csr = 'h1800 | (new_csr & 'h88);
    /* mtvec remains word aligned in both active configurations. */
    if (p.csr_addr == 'h305) new_csr &= 32'hfffffffc;
    /* mepc reflects IALIGN, preserving bit one only when C is enabled. */
    if (p.csr_addr == 'h341) new_csr &= C_ENABLED ? 32'hfffffffe : 32'hfffffffc;
    write_value = p.op == OP_CSR ? (p.csr_read ? old_csr : 0) : p.result;
    do_write = !p.fault && p.rd_write && p.rd != 0 &&
               p.op inside {OP_RESULT, OP_LOAD, OP_CSR, OP_CONTROL};
    check(actual.rd_write == do_write && actual.rd == (do_write ? p.rd : 0) &&
          actual.value == (do_write ? write_value : 0), "unexpected architectural GPR effect");
    check(actual.csr_read == (!p.fault && p.op == OP_CSR && p.csr_read) &&
          actual.csr_write == (!p.fault && p.op == OP_CSR && p.csr_write),
          "unexpected architectural CSR effect");
    check(actual.csr_old == (!p.fault && p.op == OP_CSR && p.csr_read ? old_csr : 0) &&
          actual.csr_new == (!p.fault && p.op == OP_CSR && p.csr_write ? new_csr : 0), "CSR old/new trace value mismatch");
    continuation = p.op == OP_MRET ? epc_ref : p.next_pc;
    check(actual.next_pc == (p.fault ? vector_ref : continuation), "wrong terminal continuation");
    /* trap disposition changes only trap state and consumes its original instruction. */
    if (p.fault) begin
      epc_ref = p.pc & (C_ENABLED ? 32'hfffffffe : 32'hfffffffc);
      cause_ref = p.cause;
      tval_ref = p.mtval;
      status_ref = 'h1800 | (status_ref[3] ? 'h80 : 0);
      arch_pc = vector_ref;
      traps++;
    end
    /* all normal register and CSR effects happen on this one checked W edge. */
    else begin
      arch_pc = continuation;
      /* x0 cannot become a stored link or CSR destination. */
      if (do_write) begin
        regs_ref[p.rd] = write_value;
        defined_ref[p.rd] = 1;
      end
      /* explicit synthetic CSR writes update the independent bank atomically. */
      if (actual.csr_write) begin
        /* the fixture covers all CSR fields it can write. */
        case (p.csr_addr)
          'h300: status_ref = new_csr;
          'h305: vector_ref = new_csr;
          'h341: epc_ref = new_csr;
          default: check(0, "unmodeled CSR update");
        endcase
      end
      /* MRET restores the independently stored previous interrupt enable. */
      if (p.op == OP_MRET) status_ref = 'h1880 | (status_ref[7] ? 8 : 0);
    end
    live[id] = 0;
    terminals++;
    next_order++;
  endtask

  /* the oldest surviving accepted UID is independent of pipeline stage placement. */
  function automatic logic [63:0] next_terminal_uid();
    /* holes represent independently justified squash or reset dispositions. */
    for (int id = 0; id < CAPACITY; id++) begin
      /* a live older owner cannot be skipped even if it has no architectural write. */
      if (live[id]) return 64'(id);
    end
    return '1;
  endfunction

  /* one edge predicts all control events before sampling registered DUT witnesses. */
  task automatic tick();
    logic [4:0] before_valid, wanted_kill, observed_kill, barriers;
    token_t before_token [0:4];
    logic [3:0] before_transfer;
    logic reset_active, accepted_input, flush_accept, active_flush, protect_m, protect_w;
    logic w_done, wanted_redirect, wanted_abort, observed_abort, flush_complete, launch_expected;
    logic accept_request, accept_response, owner_before, ready_expected;
    logic [31:0] redirect_target, active_target;
    expected_t w;
    packet_t x_packet;
    trace_t observed_trace;
    logic [6:0] w_id, m_id;
    int count;
    clk_i = 0;
    d_rsp_valid_i = owner && owner_accepted && respond;
    d_rsp_tag_i = owner_tag;
    d_rsp_rdata_i = planned_status == 0 ? planned_value : 0;
    d_rsp_status_i = planned_status;
    #2;
    reset_active = cold_reset_i || hart_reset_i;
    before_valid = stage_valid_o;
    before_token = stage_token_o;
    before_transfer = transfer_o;
    owner_before = owner;
    barriers = 0;
    /* immutable input operation classes determine the added serialization contract. */
    for (int stage = 0; stage < 5; stage++) begin
      barriers[stage] = before_valid[stage] && original[7'(before_token[stage].uid)].op inside {OP_CSR, OP_MRET};
      /* even the terminal edge excludes younger input and stage departures. */
      if (barriers[stage]) begin
        check(!in_ready_o, "serialized event admitted younger input");
        /* older requests may drain while younger slots remain owned and stationary. */
        for (int younger = 0; younger < stage && younger < 4; younger++)
          check(!before_transfer[younger], "event transfer crossed a serial barrier");
      end
    end
    ready_expected = !flush_pending && !reset_active && !recovery_ref;
    check(flush_ready_o == ready_expected, "flush readiness disagreed with independent ownership");
    flush_accept = flush_valid_i && ready_expected;
    active_flush = flush_pending || flush_accept;
    active_target = flush_pending ? flush_target : flush_pc_i;
    w_id = 7'(before_token[4].uid);
    m_id = 7'(before_token[3].uid);
    w = disposition(w_id);
    protect_m = before_valid[3] && issued[m_id];
    protect_w = before_valid[4] && (issued[w_id] || w.p.fault);
    w_done = before_valid[4] && !hold_i[4] && !reset_active && (!active_flush || protect_w) &&
        (!barriers[4] || (prepared[w_id] && !owner_before));
    wanted_kill = 0;
    /* reset revokes instruction ownership while a physical data owner remains separately live. */
    if (reset_active) wanted_kill = before_valid;
    /* precise W control wins over any requested external flush. */
    else if (w_done && (w.p.fault || w.redirects)) wanted_kill = before_valid & 5'b01111;
    /* a flush preserves the issued token until its W disposition, even after bus response. */
    else if (active_flush) begin
      wanted_kill = before_valid;
      wanted_kill[3] = before_valid[3] && !protect_m;
      wanted_kill[4] = before_valid[4] && !protect_w;
    end
    flush_complete = !reset_active && active_flush && !protect_m &&
                     (!protect_w || w_done) && !owner_before;
    wanted_redirect = flush_complete || (w_done && (w.p.fault || w.redirects));
    redirect_target = active_target;
    /* a trap or normal return/control terminal supplies its own independently known target. */
    if (w_done && (w.p.fault || w.redirects)) redirect_target = w.p.fault ? vector_ref :
        (w.p.op == OP_MRET ? epc_ref : w.p.next_pc);
    wanted_abort = reset_active ? flush_pending : (w_done && w.p.fault && active_flush);
    launch_expected = before_valid[3] && !hold_i[3] && !wanted_kill[3] && !active_flush && !barriers[4] &&
        !reset_active && !expected[m_id].p.fault && !issued[m_id] &&
        expected[m_id].p.op == OP_LOAD && !owner_before && !recovery_ref &&
        (!before_valid[4] || (w_done && !w.p.fault && !w.redirects));
    check(mem_launch_o == launch_expected, "unexpected or missing first-valid memory grant");
    check(mem_busy_o == owner && d_req_valid_o == (owner && !owner_accepted),
          "physical request owner disappeared or appeared without permission");
    /* first-valid request ownership makes the complete external descriptor immutable. */
    if (owner) check(d_req_tag_o == owner_tag && d_req_addr_o == owner_addr &&
        d_req_wdata_o == 0 && !d_req_write_o && d_req_size_o == 2 && d_req_wstrb_o == 0,
        "owned request descriptor changed");
    accepted_input = in_valid_i && in_ready_o;
    accept_request = d_req_valid_o && d_req_ready_i;
    accept_response = d_rsp_valid_i && d_rsp_ready_o;
    /* the barrier now requires both CSR-derived operands to be captured after its commit. */
    if (before_valid[1] && before_transfer[1] && expected[7'(before_token[1].uid)].p.rs1_used &&
        expected[7'(before_token[1].uid)].p.rs2_used &&
        expected[7'(before_token[1].uid)].p.rs1 == expected[7'(before_token[1].uid)].p.rs2 &&
        csr_destination[expected[7'(before_token[1].uid)].p.rs1]) dual_captures++;
    /* preparation is granted only by an unheld W edge with the old manager already free. */
    if (before_valid[4] && barriers[4] && !prepared[w_id] && !hold_i[4] &&
        !wanted_kill[4] && !reset_active && !owner_before) prepared[w_id] = 1;
    clk_i = 1;
    #2;
    cycles++;
    observed_kill = kill_valid_o;
    /* a hidden extra killed instruction must fail the exact independently justified mask. */
    if ($test$plusargs("mutate_kill") && !mutation_applied && !reset_active && before_valid[4] && hold_i[4] &&
        !active_flush) begin
      observed_kill[4] = !observed_kill[4];
      mutation_applied = 1;
    end
    check(!fatal_o && fatal_record_o == '0 && observed_kill == wanted_kill, "unjustified or missing event squash");
    check(trace_o.valid == w_done, "unexpected or missing event terminal");
    check(redirect_valid_o == wanted_redirect && (!wanted_redirect || redirect_pc_o == redirect_target),
          "incorrect event redirect arbitration");
    observed_abort = flush_aborted_o;
    /* a missing flush-abort pulse cannot hide behind a correct trap redirect. */
    if ($test$plusargs("mutate_abort") && !mutation_applied && wanted_abort) begin
      mutation_applied = 1;
      observed_abort = !observed_abort;
    end
    check(observed_abort == wanted_abort, "missing or spurious flush abort");
    /* consume only independently justified instruction kills. */
    for (int stage = 0; stage < 5; stage++) begin
      /* every reported kill must name the exact pre-edge stage owner. */
      if (wanted_kill[stage]) begin
        check(kill_uid_o[stage] == before_token[stage].uid &&
              live[7'(kill_uid_o[stage])], "kill changed or repeated an accepted identity");
        live[7'(kill_uid_o[stage])] = 0;
        killed++;
      end
    end
    /* physical target acceptance has no authority to grant architectural retirement. */
    if (accept_request) begin
      check(owner && !owner_accepted, "duplicate or ownerless target acceptance");
      owner_accepted = 1;
    end
    /* response completion releases the physical owner but preserves its issued-token bit. */
    if (accept_response) begin
      check(owner && owner_accepted, "target response lacked an accepted request");
      /* a reset-edge or earlier orphan response must not recreate an instruction result. */
      if (!reset_active && !orphan) begin
        completed[owner_uid] = 1;
        failed[owner_uid] = planned_status == 1;
        load_value[owner_uid] = planned_value;
      end
      owner = 0;
      owner_accepted = 0;
      orphan = 0;
      responses++;
    end
    /* apply reset to architectural state while preserving hart-reset identity counters. */
    if (reset_active) begin
      check(!cold_reset_i || !owner_before, "fixture attempted to fence an unresolved owner");
      recovery_ref = 1;
      flush_pending = 0;
      status_ref = 'h1800;
      vector_ref = 0;
      epc_ref = 0;
      cause_ref = 0;
      tval_ref = 0;
      arch_pc = 0;
      /* only the architecturally hardwired zero register has a defined reset value. */
      for (int reg_index = 0; reg_index < 32; reg_index++) begin
        defined_ref[reg_index] = reg_index == 0;
        regs_ref[reg_index] = 0;
        csr_destination[reg_index] = 0;
      end
      /* cold reset restarts observation identities; hart reset never does. */
      if (cold_reset_i) begin
        next_uid = 0;
        next_order = 0;
        last_tag = 0;
      end
      /* a surviving request remains owed even after its instruction was reset-aborted. */
      if (hart_reset_i && owner) orphan = 1;
      resets++;
    end
    /* normal clocking resolves pending control events in their independent order. */
    else begin
      /* recovery lasts through at least the edge observing no physical obligation. */
      if (recovery_ref && !owner_before) recovery_ref = 0;
      /* accept one external flush descriptor before any later fault can supersede it. */
      if (flush_accept) begin
        flush_pending = 1;
        flush_target = flush_pc_i;
        flushes++;
      end
      /* terminal comparison commits state before an independent external flush changes PC. */
      if (w_done) begin
        observed_trace = trace_o;
        /* a corrupt MRET return target must be rejected independently of its redirect witness. */
        if ($test$plusargs("mutate_return") && !mutation_applied && w.p.op == OP_MRET) begin
          observed_trace.next_pc ^= 2;
          mutation_applied = 1;
        end
        terminal(observed_trace, w.p);
        /* mark the independent final register producer only after successful disposition. */
        if (!w.p.fault && w.p.rd_write && w.p.rd != 0 &&
            w.p.op inside {OP_RESULT, OP_LOAD, OP_CSR, OP_CONTROL})
          csr_destination[w.p.rd] = w.p.op == OP_CSR;
      end
      /* a surviving external flush can complete on the successful protected load's W edge. */
      if (flush_complete && !(w_done && (w.p.fault || w.redirects))) begin
        arch_pc = active_target;
        flush_redirects++;
      end
      /* neither a completed nor an aborted flush may reappear on a later edge. */
      if (flush_complete || wanted_abort) flush_pending = 0;
      /* allocate exact independent identities only for accepted external packets. */
      if (accepted_input) begin
        check(next_uid < 64'(CAPACITY), "input owner ledger exhausted");
        original[7'(next_uid)] = in_packet_i;
        expected[7'(next_uid)] = offered_expectation;
        live[7'(next_uid)] = 1;
        prepared[7'(next_uid)] = 0;
        issued[7'(next_uid)] = 0;
        completed[7'(next_uid)] = 0;
        failed[7'(next_uid)] = 0;
        load_value[7'(next_uid)] = 0;
        next_uid++;
      end
    end
    aborts += int'(wanted_abort);
    /* reserve the first-valid physical owner only for the independently permitted load. */
    if (launch_expected) begin
      check(!owner, "new memory grant overlapped an existing owner");
      owner = 1;
      owner_accepted = 0;
      owner_uid = m_id;
      owner_addr = original[m_id].mem_addr;
      last_tag++;
      owner_tag = last_tag;
      issued[m_id] = 1;
      launches++;
    end
    check(mem_busy_o == owner && d_req_valid_o == (owner && !owner_accepted),
          "first-valid external request did not match independent grant");
    /* every live input has one physical pipeline slot, even when it has no visible effect. */
    for (int id = 0; id < CAPACITY; id++) begin
      count = 0;
      /* multiplicity prevents one duplicate from concealing a different lost instruction. */
      for (int stage = 0; stage < 5; stage++) begin
        count += int'(stage_valid_o[stage] && stage_token_o[stage].uid == 64'(id));
      end
      check(count == int'(live[id]), "accepted event instruction lost or duplicated");
    end
    /* preparation remains attached to its independently tracked instruction identity. */
    for (int stage = 0; stage < 5; stage++) begin
      if (stage_valid_o[stage]) check(stage_token_o[stage].serial_ready == prepared[7'(stage_token_o[stage].uid)],
          "event serial preparation disagreed with independent ledger");
    end
    /* all movement witnesses must preserve the unique accepted source owner. */
    for (int stage = 0; stage < 4; stage++) begin
      /* a transfer installs its old source in exactly the next stage. */
      if (before_transfer[stage]) check(before_valid[stage] && stage_valid_o[stage+1] &&
          stage_token_o[stage+1].uid == before_token[stage].uid, "event transfer changed identity");
    end
    /* D captures real RF operands before X; supplied poison cannot become source authority. */
    if (before_transfer[1] && stage_valid_o[2] && stage_token_o[2].p.op == OP_CONTROL) begin
      x_packet = expected[7'(stage_token_o[2].uid)].p;
      x_packet.result = 0;
      x_packet.next_pc = 0;
      /* a taken-target alignment failure belongs to X, not D capture. */
      if (x_packet.fault && x_packet.cause == 0) begin
        x_packet.fault = 0;
        x_packet.mtval = 0;
      end
      check(stage_token_o[2].p == x_packet, "control D capture ignored independent operand intent");
    end
    /* a protected held W fault must remain bit-for-bit stable until it can trap. */
    if (before_valid[4] && hold_i[4] && !wanted_kill[4]) check(stage_valid_o[4] &&
        stage_token_o[4] == before_token[4], "held protected W token changed");
    check(mstatus_o == status_ref && mtvec_o == vector_ref && mscratch_o == 0 &&
          mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref,
          "event CSR state differs from independent committed bank");
    /* inspect the full GPR bank to detect speculative or killed link writes. */
    for (int reg_index = 0; reg_index < 32; reg_index++) begin
      inspect_reg_i = 5'(reg_index);
      #1;
      check(inspect_defined_o == defined_ref[reg_index], "early or killed GPR definedness change");
      /* reset leaves nonzero stored bits unspecified until a real commit defines them. */
      if (defined_ref[reg_index]) check(inspect_value_o == regs_ref[reg_index], "event GPR storage mismatch");
    end
    clk_i = 0;
  endtask

  /* start a scenario only after every old instruction and physical obligation is resolved. */
  task automatic begin_case();
    check(!owner && stage_valid_o == 0 && !flush_pending, "new case abandoned an owner or flush");
    in_valid_i = 0;
    flush_valid_i = 0;
    hold_i = 0;
    respond = 0;
    d_req_ready_i = 0;
    planned_status = 0;
    cold_reset_i = 1;
    tick();
    cold_reset_i = 0;
    tick();
    arch_pc = 'h100;
    cases++;
  endtask

  /* hold one packet and its independently constructed intent until input acceptance. */
  task automatic send(input packet_t p, input expected_t q);
    logic [63:0] initial_uid;
    integer clocks;
    initial_uid = next_uid;
    in_packet_i = p;
    offered_expectation = q;
    in_valid_i = 1;
    clocks = 0;
    /* bounded input readiness is required while this fixture has not held an older stage. */
    while (next_uid == initial_uid && clocks < 50) begin
      tick();
      clocks++;
    end
    in_valid_i = 0;
    check(next_uid == initial_uid + 1, "event packet input acceptance did not progress");
  endtask

  /* ordinary precomputed operations retain their original complete packet as expectation. */
  task automatic send_plain(input packet_t p);
    expected_t q;
    q.p = p;
    q.redirects = p.op == OP_MRET;
    send(p, q);
  endtask

  /* wait for a named stage only to place an event, never to determine expected effects. */
  task automatic reach(input logic [2:0] stage, input logic [31:0] pc);
    integer clocks;
    clocks = 0;
    /* a missing or duplicated instruction must also violate this independent finite bound. */
    while (!(stage_valid_o[stage] && stage_token_o[stage].p.pc == pc) && clocks < 50) begin
      tick();
      clocks++;
    end
    check(clocks < 50, "target instruction did not reach requested event boundary");
  endtask

  /* consume every normal terminal and completed external flush without using reset as cleanup. */
  task automatic drain();
    integer clocks;
    clocks = 0;
    /* response permission and holds are explicitly controlled by each scenario. */
    while ((stage_valid_o != 0 || owner || flush_pending) && clocks < 80) begin
      tick();
      clocks++;
    end
    check(clocks < 80 && !owner && !flush_pending && stage_valid_o == 0, "event drainage bound expired");
    /* two quiet edges reject repeated redirect, terminal, abort or request activity. */
    repeat (2) tick();
  endtask

  /* accept one explicit flush request and retain its target through all protected work. */
  task automatic request_flush(input logic [31:0] target = 'h300);
    int unsigned before_count;
    before_count = flushes;
    flush_pc_i = target;
    flush_valid_i = 1;
    tick();
    flush_valid_i = 0;
    check(flushes == before_count + 1, "directed external flush was not accepted");
  endtask

  /* run explicit races with positive coverage assertions in both alignment configurations. */
  initial begin : regression
    packet_t p;
    expected_t q;
    int unsigned before_terminals, before_kills, before_aborts, before_redirects, before_captures;
    logic [31:0] masked_return;
    /* initialize only reference ledgers, not architectural nonzero GPR definedness. */
    for (int id = 0; id < CAPACITY; id++) begin
      original[id] = '0;
      expected[id] = '0;
      live[id] = 0;
      issued[id] = 0;
      completed[id] = 0;
      failed[id] = 0;
      load_value[id] = 0;
    end
    /* establish qualified reset before observing any potentially unspecified power-up slot bits. */
    cold_reset_i = 1;
    clk_i = 0;
    #2;
    clk_i = 1;
    #2;
    clk_i = 0;
    cold_reset_i = 0;
    cycles++;
    resets++;
    /* a held normal JAL and held taken branch are both reversible before W retirement. */
    for (int branch = 0; branch < 2; branch++) begin
      begin_case();
      hold_i[4] = 1;
      p = branch != 0 ? equal_branch('h100, 0) : jal('h100, 8);
      q = branch != 0 ? branch_expected(p, 0, 0) : jal_expected(p, 8);
      send(p, q);
      reach(4, 'h100);
      tick();
      before_terminals = terminals;
      before_kills = killed;
      before_redirects = flush_redirects;
      request_flush();
      hold_i[4] = 0;
      drain();
      check(terminals == before_terminals && killed == before_kills + 1 &&
            flush_redirects == before_redirects + 1 && !defined_ref[2] && arch_pc == 'h300,
            "held normal control was not cleanly squashed by flush");
      send_plain(packet('h300, OP_RESULT, 3, 'h33));
      drain();
      normal_w_cases++;
    end
    /* a held ordered W fault survives a newly accepted flush until its trap can win. */
    begin_case();
    send_plain(csr_write('h100, 'h305, 'h403));
    drain();
    hold_i[4] = 1;
    p = jal('h104, 2);
    q = jal_expected(p, 2);
    /* C permits every even target, so use a real illegal branch encoding in that configuration. */
    if (C_ENABLED) begin
      p.raw = 'h00002063;
      q.p = p;
      q.p.rs1_used = 0;
      q.p.rs2_used = 0;
      q.p.rs1 = 0;
      q.p.rs2 = 0;
      q.p.rs1_value = 0;
      q.p.rs2_value = 0;
      q.p.rd = 0;
      q.p.rd_write = 0;
      q.p.result = 0;
      q.p.next_pc = 0;
      q.p.fault = 1;
      q.p.cause = 2;
      q.p.mtval = 0;
      q.redirects = 0;
    end
    send(p, q);
    reach(4, 'h104);
    before_terminals = terminals;
    before_aborts = aborts;
    before_kills = killed;
    request_flush();
    check(flush_pending && stage_valid_o[4] && terminals == before_terminals,
          "held W fault did not preserve an accepted pending flush");
    /* repeated held clocks must preserve the fault without prematurely aborting the flush. */
    repeat (3) tick();
    hold_i[4] = 0;
    drain();
    check(terminals == before_terminals + 1 && aborts == before_aborts + 1 &&
          killed == before_kills && arch_pc == 'h400 && !defined_ref[2],
          "faulting W did not defeat its pending external flush");
    send_plain(packet('h400, OP_RESULT, 3, 'h44));
    drain();
    fault_w_cases++;
    /* flush must preserve a first-valid or accepted load while killing the younger X jump. */
    for (int accepted_phase = 0; accepted_phase < 2; accepted_phase++) begin
      /* both a normal data response and an access rejection require precise W disposition. */
      for (int fail = 0; fail < 2; fail++) begin
        begin_case();
        send_plain(csr_write('h100, 'h305, 'h400));
        drain();
        p = packet('h104, OP_LOAD, 1);
        p.mem_addr = 'h20000000;
        send_plain(p);
        p = jal('h108, 8);
        send(p, jal_expected(p, 8));
        reach(2, 'h108);
        tick();
        check(owner && !owner_accepted && stage_valid_o[3] && stage_token_o[3].p.pc == 'h104,
              "directed flush failed to overlap younger X with the first load offer");
        /* the accepted variant advances the same immutable owner before flush. */
        if (accepted_phase != 0) begin
          d_req_ready_i = 1;
          tick();
          check(owner_accepted, "load did not reach accepted flush phase");
        end
        before_terminals = terminals;
        before_kills = killed;
        before_aborts = aborts;
        before_redirects = flush_redirects;
        request_flush();
        check(owner && issued[owner_uid] && flush_pending && killed == before_kills + 1,
              "flush discarded the data obligation or preserved its younger jump");
        /* even an unaccepted first-valid offer must survive while the consumer stalls. */
        repeat (2) tick();
        d_req_ready_i = 1;
        planned_status = 2'(fail);
        respond = 1;
        drain();
        check(terminals == before_terminals + 1 && !defined_ref[2] &&
              (fail != 0 ? (aborts == before_aborts + 1 && arch_pc == 'h400 && !defined_ref[1]) :
               (flush_redirects == before_redirects + 1 && arch_pc == 'h300 &&
                regs_ref[1] == planned_value && aborts == before_aborts)),
              "issued-load flush disposition or younger jump suppression failed");
        send_plain(packet(arch_pc, OP_RESULT, 3, 'h55));
        drain();
        load_flush_cases++;
      end
    end
    /* hart reset cancels a held normal jump without reusing observation identities. */
    begin_case();
    hold_i[4] = 1;
    p = jal('h100, 8);
    send(p, jal_expected(p, 8));
    reach(4, 'h100);
    before_terminals = terminals;
    before_kills = killed;
    hart_reset_i = 1;
    tick();
    hart_reset_i = 0;
    hold_i[4] = 0;
    tick();
    drain();
    check(terminals == before_terminals && killed == before_kills + 1 &&
          next_uid == 1 && next_order == 0 && !defined_ref[2] && arch_pc == 0,
          "held jump reset leaked a write or reset an observation counter");
    send_plain(packet(0, OP_RESULT, 3, 'h66));
    drain();
    reset_cases++;
    /* mepc write/readback and MRET use the same independently selected IALIGN mask. */
    begin_case();
    masked_return = C_ENABLED ? 'h202 : 'h200;
    send_plain(csr_write('h100, 'h300, 'h80));
    send_plain(csr_write('h104, 'h341, 'h203, 1, 8));
    p = packet('h108, OP_CSR, 9);
    p.csr_addr = 'h341;
    p.csr_op = CSR_READ;
    p.csr_read = 1;
    send_plain(p);
    send_plain(packet('h10c, OP_MRET));
    drain();
    check(regs_ref[8] == 0 && regs_ref[9] == masked_return && arch_pc == masked_return &&
          status_ref == 'h1888, "masked mepc write/readback or MRET state failed");
    p = jal(masked_return, 8, 5);
    send(p, jal_expected(p, 8, 5));
    drain();
    check(regs_ref[5] == masked_return + 4 && arch_pc == masked_return + 8,
          "control instruction did not execute from the masked return PC");
    return_cases++;
    /* both equal source ports consume the same committed CSR value after the barrier, including read suppression. */
    for (int suppressed = 0; suppressed < 2; suppressed++) begin
      begin_case();
      send_plain(csr_write('h100, 'h305, 'h800));
      drain();
      before_captures = dual_captures;
      send_plain(csr_write('h104, 'h305, 'h804, suppressed == 0, 1));
      p = equal_branch('h108, 1);
      send(p, branch_expected(p, 1, suppressed != 0 ? 0 : 'h800));
      drain();
      check(dual_captures == before_captures + 1 && arch_pc == 'h110 &&
            regs_ref[1] == (suppressed != 0 ? 0 : 'h800), "dual-source committed CSR capture was not exercised correctly");
      csr_capture_cases++;
    end
    check(normal_w_cases == 2 && fault_w_cases == 1 && load_flush_cases == 4 &&
          reset_cases == 1 && return_cases == 1 && csr_capture_cases == 2 &&
          launches == 4 && responses == launches && !owner && !flush_pending && stage_valid_o == 0,
          "required event coverage or final ownership drainage is incomplete");
    $display("PASS control-events C=%0d cases=%0d cycles=%0d checks=%0d terminals=%0d traps=%0d kills=%0d flushes=%0d flush_redirects=%0d aborts=%0d resets=%0d loads=%0d responses=%0d normal_W=%0d fault_W=%0d load_flush=%0d held_reset=%0d mepc_MRET=%0d dual_CSR_capture=%0d",
             C_ENABLED, cases, cycles, checks, terminals, traps, killed, flushes, flush_redirects,
             aborts, resets, launches, responses, normal_w_cases, fault_w_cases, load_flush_cases,
             reset_cases, return_cases, csr_capture_cases);
    $finish;
  end
endmodule

/* check the packet control prototype without claiming ISA conformance. */
module drg5_control_tb #(
  parameter bit DIAGNOSTIC = 1'b1
);
  import drg5_control_pkg::*;
  /* disconnected debug outputs retain named endpoints in legacy configurations. */
  logic unused_debug_halted, unused_debug_resumeack, unused_debug_reg_ready;
  logic [31:0] unused_debug_dpc, unused_debug_dcsr, unused_debug_reg_rdata;
  logic [2:0] unused_debug_reg_error;
  /* preserve the explicitly IRQ-disabled compatibility profile. */
  logic unused_entry_pending, unused_idle, unused_irq_valid;
  logic [31:0] unused_irq_pc, unused_irq_cause;
  localparam int CAPACITY = 512;
  logic clk_i = 0;
  logic cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
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
  packet_t expected [0:CAPACITY-1];
  packet_t expected_stage [0:CAPACITY-1];
  bit live [0:CAPACITY-1];
  bit response_seen [0:CAPACITY-1];
  bit response_error [0:CAPACITY-1];
  bit memory_issued [0:CAPACITY-1];
  bit prepared [0:CAPACITY-1];
  logic [31:0] response_value [0:CAPACITY-1];
  logic [31:0] expected_regs [0:31];
  bit expected_defined [0:31];
  logic [31:0] status_ref, vector_ref, scratch_ref, epc_ref, cause_ref, tval_ref;
  int unsigned next_uid = 0, next_order = 0, cycles = 0;
  int unsigned retirements = 0, traps = 0, kills = 0, launches = 0;
  int unsigned acceptances = 0, completions = 0, accepted_inputs = 0;
  int unsigned coverage_stalls [0:4];
  int unsigned max_occupancy = 0;
  bit bus_owned = 0, bus_accepted = 0, bus_orphan = 0;
  bit fatal_ref = 0, flush_pending = 0;
  bit recovery_ref = 1;
  logic [8:0] bus_uid = 0;
  bit mutation_applied = 0;
  logic [31:0] bus_tag = 0, last_tag = 0, pending_flush_pc = 0;
  packet_t bus_packet;
  logic [31:0] planned_read = 32'h80ff7f01;
  logic [1:0] planned_status = 0;

  drg5_control #(.IRQ_ENABLED(0), .FORWARDING(0), .DIAGNOSTIC(DIAGNOSTIC), .TEST_REGIONS(1), .D_MAX_WAIT_CYCLES(256)) dut (
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

  /* stop at the first mismatch with a replayable logical cycle. */
  task automatic check(input bit condition, input string message);
    /* report failures instead of continuing with a corrupted scoreboard. */
    if (!condition) begin
      $fatal(1, "cycle %0d diagnostic=%0d: %s", cycles, DIAGNOSTIC, message);
    end
  endtask

  /* create known stimulus independently of every DUT observation. */
  function automatic packet_t packet(input logic [31:0] pc,
                                      input op_t op = OP_RESULT,
                                      input logic [4:0] rd = 0,
                                      input logic [31:0] value = 0);
    packet_t p;
    p = '0;
    p.pc = pc;
    p.raw = 32'h00000013;
    p.raw_valid = 4'hf;
    p.length = 4;
    p.op = op;
    p.rd = rd;
    p.rd_write = rd != 0;
    p.result = value;
    p.next_pc = pc + 4;
    p.mem_size = 2;
    return p;
  endfunction

  /* calculate byte enables from the expected request rather than the bus. */
  function automatic logic [3:0] expected_lanes(input logic [1:0] size,
                                              input logic [1:0] offset);
    int unsigned width_bytes;
    width_bytes = 1 << size;
    return 4'(((1 << width_bytes) - 1) << offset);
  endfunction

  /* canonical responses contain only requested successful load lanes. */
  function automatic logic [31:0] canonical_response(input logic [31:0] value,
      input logic [1:0] status, input op_t op, input logic [1:0] size, offset);
    logic [31:0] result;
    logic [3:0] lanes;
    result = 0;
    lanes = expected_lanes(size, offset);
    /* stores and every error status have a zero payload. */
    if (status == 0 && op == OP_LOAD) begin
      /* preserve original lane positions without reading any unrequested byte. */
      for (int lane = 0; lane < 4; lane++) begin
        /* the target supplies only bytes owned by this request. */
        if (lanes[lane]) result[8*lane +: 8] = value[8*lane +: 8];
      end
    end
    return result;
  endfunction

  /* read the independent implemented CSR subset. */
  function automatic logic [31:0] csr_read_ref(input logic [11:0] address);
    /* keep model selection independent of the DUT mux. */
    case (address)
      'h300: return status_ref;
      'h305: return vector_ref;
      'h340: return scratch_ref;
      'h341: return epc_ref;
      'h342: return cause_ref;
      'h343: return tval_ref;
      default: return 0;
    endcase
  endfunction

  /* apply a validated expected CSR write only on its terminal edge. */
  task automatic csr_write_ref(input logic [11:0] address,
                               input logic [31:0] value);
    /* update the expected bank without reading architectural DUT outputs. */
    case (address)
      'h300: status_ref = value;
      'h305: vector_ref = value;
      'h340: scratch_ref = value;
      'h341: epc_ref = value;
      'h342: cause_ref = value;
      'h343: tval_ref = value;
      default: check(0, "reference attempted unknown CSR write");
    endcase
  endtask

  /* predict one terminal attempt from its original accepted stimulus. */
  task automatic terminal(input trace_t actual);
    packet_t p;
    packet_t expected_trace_packet;
    int unsigned id;
    bit fault, csr_known, misaligned, writes_rd, reads_csr, writes_csr;
    logic [31:0] fault_cause, fault_value, value, target, old_csr, new_csr;
    id = int'(actual.uid);
    check(actual.valid, "terminal checker received an invalid record");
    check(actual.uid < 64'(CAPACITY) && live[id], "terminal has no live input owner");
    /* an older surviving packet may never be bypassed by this terminal. */
    for (int i = 0; i < id; i++) begin
      check(!live[i], "terminal bypassed an older live instruction");
    end
    p = expected[id];
    fault = p.fault;
    fault_cause = p.cause;
    fault_value = p.mtval;
    value = p.result;
    target = p.next_pc;
    old_csr = csr_read_ref(p.csr_addr);
    new_csr = old_csr;
    csr_known = p.csr_addr inside {'h300, 'h305, 'h340, 'h341, 'h342, 'h343};
    misaligned = (p.mem_size == 1 && p.mem_addr[0]) ||
                 (p.mem_size == 2 && p.mem_addr[1:0] != 0);
    /* earlier supplied faults dominate all subsequent operation checks. */
    if (!fault) begin
      /* malformed packets are illegal before their memory operation. */
      if (p.length != 4 || p.raw_valid != 15 || p.op > OP_REDIRECT ||
          (p.op == OP_CSR && !csr_known)) begin
        fault = 1;
        fault_cause = 2;
        fault_value = 0;
      end
      /* model memory alignment and the externally planned response. */
      else if (p.op == OP_LOAD || p.op == OP_STORE) begin
        /* local failures require no response or target effect. */
        if (misaligned || p.mem_size == 3) begin
          fault = 1;
          fault_cause = p.op == OP_LOAD ? (misaligned ? 4 : 5) : (misaligned ? 6 : 7);
          fault_value = p.mem_addr;
        end
        /* normal memory instructions cannot terminate before their response. */
        else begin
          check(response_seen[id], "memory terminal preceded its response");
          fault = response_error[id];
          fault_cause = p.op == OP_LOAD ? 5 : 7;
          fault_value = p.mem_addr;
          value = response_value[id];
        end
      end
      /* system operations have explicit trap or redirect expectations. */
      else if (p.op == OP_ECALL || p.op == OP_EBREAK) begin
        fault = 1;
        fault_cause = p.op == OP_ECALL ? 11 : 3;
        fault_value = p.op == OP_ECALL ? 0 : p.pc;
      end
      /* check branch alignment independently of the retired target. */
      else if (p.op == OP_REDIRECT && p.next_pc[1:0] != 0) begin
        fault = 1;
        fault_cause = 0;
        fault_value = p.next_pc;
      end
    end
    /* compute the CSR operation from pre-edge expected state. */
    if (p.op == OP_CSR) begin
      value = p.csr_read ? old_csr : 0;
      /* the command operand is stimulus, not a DUT-computed value. */
      case (p.csr_op)
        CSR_WRITE: new_csr = p.csr_source;
        CSR_SET: new_csr = old_csr | p.csr_source;
        CSR_CLEAR: new_csr = old_csr & ~p.csr_source;
        default: new_csr = old_csr;
      endcase
      /* legalize the prototype's writable trap-state fields. */
      if (p.csr_addr == 'h300) begin
        new_csr = 'h1800 | (new_csr & 'h88);
      end
      /* this skeleton has fixed four-byte instruction alignment. */
      if (p.csr_addr == 'h305 || p.csr_addr == 'h341) begin
        new_csr &= 32'hfffffffc;
      end
      /* unsupported software cause encodings preserve the previous legal value. */
      if (p.csr_addr == 'h342 && !(new_csr <= 7 || new_csr == 11 ||
          new_csr inside {32'h80000003, 32'h80000007, 32'h8000000b})) new_csr = old_csr;
    end
    /* MRET reads the independently maintained return address. */
    if (p.op == OP_MRET) begin
      target = epc_ref;
    end
    writes_rd = !fault && p.rd_write && p.rd != 0 && p.op != OP_STORE && p.op != OP_MRET;
    reads_csr = !fault && p.op == OP_CSR && p.csr_read;
    writes_csr = !fault && p.op == OP_CSR && p.csr_write;
    check(actual.order == 64'(next_order), "terminal order skipped or repeated");
    expected_trace_packet = p;
    expected_trace_packet.fault = fault;
    expected_trace_packet.cause = fault ? fault_cause : 0;
    expected_trace_packet.mtval = fault ? fault_value : 0;
    /* only a completed load replaces the supplied diagnostic result field. */
    if (p.op == OP_LOAD && response_seen[id] && !response_error[id]) begin
      expected_trace_packet.result = response_value[id];
    end
    check(actual.packet == expected_trace_packet, "terminal changed packet fields");
    check(actual.trap == fault && actual.packet.fault == fault, "wrong terminal kind");
    check(actual.rd_write == writes_rd && actual.rd == (writes_rd ? p.rd : 0) &&
          actual.value == (writes_rd ? value : 0), "wrong GPR commit trace");
    check(actual.csr_read == reads_csr && actual.csr_write == writes_csr, "wrong CSR commit enable");
    /* trace read suppression is independent of the explicit write result. */
    check(actual.csr_old == (reads_csr ? old_csr : 0) &&
          actual.csr_new == (writes_csr ? new_csr : 0), "wrong CSR trace values");
    /* a precise fault commits only trap state. */
    if (fault) begin
      check(actual.packet.cause == fault_cause && actual.packet.mtval == fault_value,
            "wrong precise exception metadata");
      check(actual.next_pc == vector_ref && redirect_valid_o && redirect_pc_o == vector_ref,
            "wrong trap redirect");
      epc_ref = p.pc & 32'hfffffffc;
      cause_ref = fault_cause;
      tval_ref = fault_value;
      status_ref = 'h1800 | ((status_ref & 8) != 0 ? 'h80 : 0);
      flush_pending = 0;
      traps++;
    end
    /* normal results update architectural state only here. */
    else begin
      check(actual.next_pc == target, "wrong normal continuation");
      check(actual.packet.cause == 0 && actual.packet.mtval == 0, "normal trace retained fault data");
      /* x0 and suppressed destinations have no architectural write. */
      if (writes_rd) begin
        expected_regs[p.rd] = value;
        expected_defined[p.rd] = 1;
      end
      /* explicit CSR state changes share this same retirement. */
      if (writes_csr) begin
        csr_write_ref(p.csr_addr, new_csr);
      end
      /* return updates only the specified interrupt stack fields. */
      if (p.op == OP_MRET) begin
        status_ref = 'h1880 | ((status_ref & 'h80) != 0 ? 8 : 0);
      end
      /* supplied branch and return targets redirect at W. */
      if (p.op == OP_MRET || p.op == OP_REDIRECT) begin
        check(redirect_valid_o && redirect_pc_o == target, "missing branch or return redirect");
      end
      retirements++;
    end
    live[id] = 0;
    next_order++;
  endtask

  /* reset only architecturally defined expected state. */
  task automatic reset_reference;
    /* undefined reset registers are deliberately not compared as zeros. */
    for (int i = 0; i < 32; i++) begin
      expected_defined[i] = i == 0;
      expected_regs[i] = 0;
    end
    status_ref = 'h1800;
    vector_ref = 0;
    scratch_ref = 0;
    epc_ref = 0;
    cause_ref = 0;
    tval_ref = 0;
    flush_pending = 0;
  endtask

  /* sample handshakes before the edge and check storage after settling. */
  task automatic tick;
    logic [4:0] before_valid;
    token_t before_token [0:4];
    bit input_accept, request_accept, response_accept, launched, flush_accept;
    bit bad_response;
    logic [3:0] before_transfer;
    logic [4:0] expected_kill, observed_kill, barriers;
    bit expected_w_fault, expected_w_done, expected_w_redirect;
    bit bus_was_owned, expected_launch, m_eligible, m_bad_encoding, m_bad_alignment;
    bit expected_abort, observed_request;
    logic [8:0] w_id, m_id;
    trace_t observed_trace;
    int unsigned stage_count, owner_count, occurrences, id;
    bit predecessor_found, expected_transfer;
    logic [31:0] loaded;
    clk_i = 0;
    #2;
    before_valid = stage_valid_o;
    before_token = stage_token_o;
    before_transfer = transfer_o;
    input_accept = in_valid_i && in_ready_o;
    request_accept = d_req_valid_o && d_req_ready_i;
    response_accept = d_rsp_valid_i && d_rsp_ready_o;
    launched = mem_launch_o;
    flush_accept = flush_valid_i && flush_ready_o;
    bus_was_owned = bus_owned;
    barriers = 0;
    /* original operation classes define barriers without trusting token readiness. */
    for (int stage = 0; stage < 5; stage++) begin
      barriers[stage] = before_valid[stage] && expected[9'(before_token[stage].uid)].op inside {OP_CSR, OP_MRET};
      /* a live barrier blocks every younger transfer through its terminal edge. */
      if (barriers[stage]) begin
        check(!in_ready_o, "serialized operation admitted younger input");
        /* the older instruction may drain while its younger slots remain blocked. */
        for (int younger = 0; younger < stage && younger < 4; younger++)
          check(!before_transfer[younger], "younger transfer crossed a serialized operation");
      end
    end
    bad_response = response_accept &&
        (!bus_owned || (!bus_accepted && !request_accept) || d_rsp_tag_i != bus_tag ||
         d_rsp_status_i[1]);
    /* an owned offer retains all externally visible descriptor fields. */
    if (bus_owned && !bus_accepted && !cold_reset_i) begin
      check(bus_packet == expected[bus_uid], "retained bus intent changed across a stall or reset");
      check(d_req_valid_o && d_req_addr_o == bus_packet.mem_addr &&
            d_req_write_o == (bus_packet.op == OP_STORE) &&
            d_req_size_o == bus_packet.mem_size && d_req_tag_o == bus_tag &&
            d_req_wdata_o == bus_packet.mem_wdata &&
            d_req_wstrb_o == (bus_packet.op == OP_STORE ?
              expected_lanes(bus_packet.mem_size, bus_packet.mem_addr[1:0]) : 0),
            "owned request changed or disappeared");
    end
    /* every physical acceptance must belong to one previously offered command. */
    if (request_accept) begin
      check(bus_owned && !bus_accepted, "duplicate or ownerless physical acceptance");
      bus_accepted = 1;
      acceptances++;
    end
    /* model response data from the test's plan rather than DUT trace values. */
    if (response_accept && !bad_response && !fatal_ref) begin
      check(d_rsp_status_i == planned_status && d_rsp_rdata_i == canonical_response(planned_read, planned_status,
            bus_packet.op, bus_packet.mem_size, bus_packet.mem_addr[1:0]),
            "test driver violated the planned response");
      /* a hart reset leaves the bus obligation but removes its instruction. */
      if (!hart_reset_i && !bus_orphan && live[bus_uid]) begin
        response_seen[bus_uid] = 1;
        response_error[bus_uid] = planned_status == 1;
        loaded = planned_read >> (8 * bus_packet.mem_addr[1:0]);
        /* independent sign extension follows the original packet size. */
        if (bus_packet.mem_size == 0) begin
          loaded = bus_packet.mem_signed ? 32'(signed'(loaded[7:0])) : {24'b0, loaded[7:0]};
        end
        /* halfword lanes have the same independent extension rule. */
        else if (bus_packet.mem_size == 1) begin
          loaded = bus_packet.mem_signed ? 32'(signed'(loaded[15:0])) : {16'b0, loaded[15:0]};
        end
        response_value[bus_uid] = bus_packet.op == OP_LOAD ? loaded : bus_packet.result;
        /* the live packet receives only independently predicted completion fields. */
        if (planned_status == 1) begin
          expected_stage[bus_uid].fault = 1;
          expected_stage[bus_uid].cause = bus_packet.op == OP_LOAD ? 5 : 7;
          expected_stage[bus_uid].mtval = bus_packet.mem_addr;
        end
        /* a successful load replaces its provisional diagnostic value. */
        else if (bus_packet.op == OP_LOAD) begin
          expected_stage[bus_uid].result = loaded;
        end
      end
      bus_owned = 0;
      bus_accepted = 0;
      bus_orphan = 0;
      completions++;
    end
    /* fatal response classification must suppress same-edge architectural work. */
    if (bad_response) begin
      fatal_ref = 1;
      /* recovery retains the owner until the explicit isolated cold reset. */
    end
    w_id = 9'(before_token[4].uid);
    expected_w_fault = before_valid[4] &&
        (expected_stage[w_id].fault || expected[w_id].length != 4 ||
         expected[w_id].raw_valid != 15 || expected[w_id].op > OP_REDIRECT ||
         (expected[w_id].op == OP_CSR && !(expected[w_id].csr_addr inside
          {'h300, 'h305, 'h340, 'h341, 'h342, 'h343})) ||
         expected[w_id].op == OP_ECALL || expected[w_id].op == OP_EBREAK ||
         (expected[w_id].op == OP_REDIRECT && expected[w_id].next_pc[1:0] != 0));
    expected_w_redirect = before_valid[4] &&
        (expected[w_id].op == OP_REDIRECT || expected[w_id].op == OP_MRET);
    expected_w_done = before_valid[4] && !hold_i[4] && !cold_reset_i &&
        !hart_reset_i && !fatal_ref &&
        (!barriers[4] || (prepared[w_id] && !bus_was_owned)) &&
        (!(flush_pending || flush_accept) || memory_issued[w_id] || expected_w_fault);
    expected_kill = 0;
    /* architectural reset is the only unconditional all-stage abort. */
    if (cold_reset_i || hart_reset_i) begin
      expected_kill = before_valid;
    end
    /* a fatal event freezes instruction owners until qualified reset. */
    else if (!fatal_ref) begin
      /* independently predicted W control events kill every younger owner. */
      if (expected_w_done && (expected_w_fault || expected_w_redirect)) begin
        expected_kill = before_valid & 5'b01111;
      end
      /* external flush cannot abandon issued memory or an ordered W fault. */
      else if (flush_pending || flush_accept) begin
        expected_kill = before_valid;
        expected_kill[3] = before_valid[3] && !memory_issued[int'(before_token[3].uid)];
        expected_kill[4] = before_valid[4] && !memory_issued[w_id] && !expected_w_fault;
      end
    end
    expected_abort = (cold_reset_i || hart_reset_i) ? flush_pending :
        (expected_w_done && expected_w_fault && (flush_pending || flush_accept));
    m_id = 9'(before_token[3].uid);
    m_bad_encoding = expected[m_id].length != 4 || expected[m_id].raw_valid != 15;
    m_bad_alignment = (expected[m_id].mem_size == 1 && expected[m_id].mem_addr[0]) ||
        (expected[m_id].mem_size == 2 && expected[m_id].mem_addr[1:0] != 0);
    m_eligible = before_valid[3] && !hold_i[3] && !expected_kill[3] && !barriers[4] &&
        !cold_reset_i && !hart_reset_i && !fatal_ref && !(flush_pending || flush_accept) &&
        !expected_stage[m_id].fault && !memory_issued[m_id] &&
        (expected[m_id].op == OP_LOAD || expected[m_id].op == OP_STORE) &&
        (!before_valid[4] || (expected_w_done && !expected_w_fault && !expected_w_redirect));
    expected_launch = m_eligible && !m_bad_encoding && !m_bad_alignment &&
        expected[m_id].mem_size != 3 && !bus_was_owned && !recovery_ref;
    check(launched == expected_launch, "memory launch witness violated independent grant");
    /* local faults change only their current M packet and never launch an offer. */
    if (m_eligible && (m_bad_encoding || m_bad_alignment || expected[m_id].mem_size == 3)) begin
      expected_stage[m_id].fault = 1;
      expected_stage[m_id].cause = m_bad_encoding ? 2 :
          (expected[m_id].op == OP_LOAD ? (m_bad_alignment ? 4 : 5) : (m_bad_alignment ? 6 : 7));
      expected_stage[m_id].mtval = m_bad_encoding ? 0 : expected[m_id].mem_addr;
    end
    /* preparation is a separate eligible W edge with no surviving bus obligation. */
    if (before_valid[4] && barriers[4] && !prepared[w_id] && !hold_i[4] &&
        !expected_kill[4] && !cold_reset_i && !hart_reset_i && !fatal_ref && !bus_was_owned)
      prepared[w_id] = 1;
    clk_i = 1;
    #2;
    cycles++;
    observed_kill = kill_valid_o;
    /* this negative control fabricates a plausible but unauthorized NOP kill. */
    if ($test$plusargs("mutate_kill") && !mutation_applied && before_valid[0] &&
        expected_kill == 0 && !cold_reset_i && !hart_reset_i) begin
      observed_kill[0] = 1;
      mutation_applied = 1;
    end
    check(observed_kill == expected_kill, "unjustified or missing instruction kill");
    check(trace_o.valid == expected_w_done, "terminal did not match eligible W disposition");
    check(flush_aborted_o == expected_abort, "missing or spurious flush abort");
    /* consume explicit killed identities, never infer kills from UID gaps. */
    for (int i = 0; i < 5; i++) begin
      /* a kill must name the pre-edge owner of that exact slot. */
      if (kill_valid_o[i]) begin
        id = int'(kill_uid_o[i]);
        check(before_valid[i] && before_token[i].uid == kill_uid_o[i] &&
              id < CAPACITY && live[id], "kill did not name a live slot owner");
        live[id] = 0;
        kills++;
      end
    end
    /* reset suppresses disposition while preserving any surviving manager. */
    if (cold_reset_i || hart_reset_i) begin
      check(!trace_o.valid && !redirect_valid_o, "reset allowed a terminal or redirect");
      reset_reference();
      recovery_ref = 1;
      /* a cold reset starts a new isolated observation epoch. */
      if (cold_reset_i) begin
        next_uid = 0;
        next_order = 0;
        last_tag = 0;
        bus_owned = 0;
        bus_accepted = 0;
        bus_orphan = 0;
        fatal_ref = 0;
      end
      /* hart reset retains its previous transaction intent. */
      else if (bus_owned) begin
        bus_orphan = 1;
      end
    end
    /* non-reset state can retire once and accept one independent input. */
    else begin
      /* recovery releases only after a pre-edge empty, healthy manager. */
      if (recovery_ref && !bus_was_owned && !fatal_ref) begin
        recovery_ref = 0;
      end
      /* a newly accepted flush is independently tracked until its redirect. */
      if (flush_accept) begin
        flush_pending = 1;
        pending_flush_pc = flush_pc_i;
      end
      /* terminal prediction consumes only original input state. */
      if (trace_o.valid) begin
        check(!fatal_ref, "fatal response allowed retirement");
        observed_trace = trace_o;
        /* a plausible corrupted result must fail the architectural comparator. */
        if ($test$plusargs("mutate_result") && !mutation_applied && trace_o.rd_write) begin
          observed_trace.value ^= 1;
          mutation_applied = 1;
        end
        terminal(observed_trace);
      end
      /* assign identities from the observed input count, not DUT trace IDs. */
      if (input_accept) begin
        check(next_uid < CAPACITY, "test exhausted its fixed input ledger");
        expected[next_uid] = in_packet_i;
        expected_stage[next_uid] = in_packet_i;
        live[next_uid] = 1;
        response_seen[next_uid] = 0;
        response_error[next_uid] = 0;
        response_value[next_uid] = 0;
        memory_issued[next_uid] = 0;
        prepared[next_uid] = 0;
        next_uid++;
        accepted_inputs++;
      end
      /* a launch must name the independently oldest live memory instruction. */
      if (expected_launch) begin
        id = int'(before_token[3].uid);
        check(!bus_owned && live[id] && !flush_accept && !fatal_ref,
              "unpermitted or duplicate memory launch");
        /* older successful retirement may make this same edge eligible. */
        for (int j = 0; j < id; j++) begin
          check(!live[j], "memory launch preceded older retirement");
        end
        bus_packet = expected[id];
        check(bus_packet.op == OP_LOAD || bus_packet.op == OP_STORE,
              "non-memory packet launched a request");
        check(!bus_packet.fault && bus_packet.length == 4 && bus_packet.raw_valid == 15,
              "faulting packet launched a request");
        bus_uid = 9'(id);
        memory_issued[id] = 1;
        last_tag++;
        bus_tag = last_tag;
        bus_owned = 1;
        bus_accepted = 0;
        bus_orphan = 0;
        launches++;
      end
      /* an ordinary flush must finish only after its protected work drains. */
      if (redirect_valid_o && !(trace_o.valid &&
          (trace_o.trap || trace_o.packet.op == OP_REDIRECT || trace_o.packet.op == OP_MRET))) begin
        check(flush_pending && redirect_pc_o == pending_flush_pc && !bus_owned,
              "unexpected or early flush redirect");
        /* a captured response does not end its protected instruction lifetime. */
        for (int j = 0; j < CAPACITY; j++) begin
          check(!(live[j] && memory_issued[j]), "flush redirected before protected W disposition");
        end
        flush_pending = 0;
      end
    end
    check(fatal_o == fatal_ref, "wrong sticky fatal state");
    check(fatal_record_o.valid == fatal_o && (fatal_o || fatal_record_o == '0),
          "fatal snapshot validity disagreed with containment");
    check(mem_busy_o == bus_owned, "manager busy does not match retained ownership");
    observed_request = d_req_valid_o;
    /* this negative control exposes an ownerless first-valid while ready is low. */
    if ($test$plusargs("mutate_orphan_offer") && !mutation_applied && !bus_owned &&
        !cold_reset_i && !hart_reset_i) begin
      observed_request = 1;
      mutation_applied = 1;
    end
    check(observed_request == (bus_owned && !bus_accepted), "ownerless or missing request valid");
    stage_count = 0;
    owner_count = 0;
    /* compare physical live slots against the independent allocation ledger. */
    for (int i = 0; i < 5; i++) begin
      /* a live slot preserves input identity and advances at most one stage. */
      if (stage_valid_o[i]) begin
        id = int'(stage_token_o[i].uid);
        check(id < CAPACITY && live[id], "physical slot lacks a live expected owner");
        check(stage_token_o[i].p == expected_stage[id], "stage corrupted packet fields");
        check(stage_token_o[i].mem_issued == memory_issued[id], "stage forged memory protection");
        check(stage_token_o[i].mem_done == response_seen[id], "stage forged memory completion");
        check(stage_token_o[i].serial_ready == prepared[id], "stage forged serial preparation");
        stage_count++;
        predecessor_found = 0;
        /* compare every old owner against this new slot position. */
        for (int j = 0; j < 5; j++) begin
          /* matching identities may hold or cross exactly one boundary. */
          if (before_valid[j] && before_token[j].uid == stage_token_o[i].uid) begin
            predecessor_found = 1;
            check(i == j || i == j + 1, "token skipped a stage or moved backward");
            /* every actual movement has a matching boundary transfer witness. */
            if (i != j) begin
              check(j < 4 && before_transfer[j], "stage moved without a transfer witness");
            end
            /* a documented stage hold prevents that token's transfer. */
            if (hold_i[j]) begin
              check(i == j, "held stage transferred its token");
              coverage_stalls[j]++;
            end
          end
        end
        /* only a newly accepted input may appear without a pre-edge owner. */
        if (!predecessor_found) begin
          check(input_accept && i == 0 && stage_token_o[i].uid == 64'(next_uid - 1),
                "new instruction bypassed F or lacked an input acceptance");
        end
      end
    end
    /* transfer witnesses must describe exactly the observed one-stage movements. */
    for (int i = 0; i < 4; i++) begin
      expected_transfer = before_valid[i] && stage_valid_o[i + 1] &&
          before_token[i].uid == stage_token_o[i + 1].uid;
      check(before_transfer[i] == expected_transfer, "missing or spurious stage transfer");
    end
    /* conservation catches a vanished NOP even when final registers agree. */
    for (int i = 0; i < CAPACITY; i++) begin
      owner_count += int'(live[i]);
      occurrences = 0;
      /* exact multiplicity also catches one duplication paired with one loss. */
      for (int j = 0; j < 5; j++) begin
        occurrences += int'(stage_valid_o[j] && stage_token_o[j].uid == 64'(i));
      end
      check(occurrences == int'(live[i]), "instruction identity lost or duplicated");
    end
    check(owner_count == stage_count, "token conservation failed");
    /* retain evidence that overlap mode actually filled every stage. */
    if (stage_count > max_occupancy) begin
      max_occupancy = stage_count;
    end
    check(!DIAGNOSTIC || stage_count <= 1, "diagnostic mode overlapped instructions");
    check(mstatus_o == status_ref && mtvec_o == vector_ref && mscratch_o == scratch_ref &&
          mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref,
          "architectural CSR storage changed outside expected W disposition");
    /* inspect every register so an early or hidden write cannot escape trace checking. */
    for (int i = 0; i < 32; i++) begin
      inspect_reg_i = 5'(i);
      #1;
      check(inspect_defined_o == expected_defined[i], "unexpected GPR definedness change");
      /* undefined reset values are intentionally unconstrained. */
      if (expected_defined[i]) begin
        check(inspect_value_o == expected_regs[i], "architectural GPR storage mismatch");
      end
    end
    clk_i = 0;
  endtask

  /* wait for input backpressure without changing an offered packet. */
  task automatic submit(input packet_t p);
    int unsigned old_count;
    old_count = accepted_inputs;
    in_packet_i = p;
    in_valid_i = 1;
    /* every submitted packet has a finite acceptance watchdog. */
    for (int i = 0; i < 100; i++) begin
      tick();
      /* stop after the observed input handshake, not a guessed stage delay. */
      if (accepted_inputs != old_count) begin
        in_valid_i = 0;
        return;
      end
    end
    check(0, "input acceptance timed out");
  endtask

  /* wait for a selected stage while preserving all independent checks. */
  task automatic reach(input logic [2:0] index);
    /* stage arrival has a bounded diagnostic watchdog. */
    for (int i = 0; i < 80; i++) begin
      /* inspect arrival before accidentally allowing another transfer. */
      if (stage_valid_o[index]) begin
        return;
      end
      tick();
    end
    check(0, "stage arrival timed out");
  endtask

  /* finish only after every instruction and physical request has been accounted. */
  task automatic drain;
    /* no progress timeout is treated as a successful program ending. */
    for (int i = 0; i < 150; i++) begin
      tick();
      /* all independently observed owners must actually be gone. */
      if (stage_valid_o == 0 && !bus_owned && !flush_pending) begin
        return;
      end
    end
    check(0, "drain timed out");
  endtask

  /* reset the isolated fixture while keeping cumulative coverage statistics. */
  task automatic cold_reset;
    in_valid_i = 0;
    flush_valid_i = 0;
    d_req_ready_i = 0;
    d_rsp_valid_i = 0;
    hold_i = 0;
    hart_reset_i = 0;
    cold_reset_i = 1;
    tick();
    tick();
    cold_reset_i = 0;
    tick();
    tick();
  endtask

  /* present a fixed planned response after independently chosen bus delays. */
  task automatic service(input int acceptance_delay, input int response_delay,
                          input logic [31:0] value, input logic [1:0] status = 0);
    planned_read = value;
    planned_status = status;
    /* wait for a real registered offer with a finite watchdog. */
    for (int i = 0; i < 100 && !d_req_valid_o; i++) begin
      tick();
    end
    check(d_req_valid_o, "data request never appeared");
    /* hold ready low without changing the saved request descriptor. */
    repeat (acceptance_delay) begin
      tick();
    end
    d_req_ready_i = 1;
    /* zero delay exercises acceptance and response on the same edge. */
    if (response_delay == 0) begin
      d_rsp_valid_i = 1;
      d_rsp_tag_i = bus_tag;
      d_rsp_rdata_i = canonical_response(value, status, bus_packet.op, bus_packet.mem_size, bus_packet.mem_addr[1:0]);
      d_rsp_status_i = status;
    end
    tick();
    d_req_ready_i = 0;
    /* delayed response keeps the accepted request manager occupied. */
    if (response_delay != 0) begin
      /* leave the target response pending for the selected interval. */
      repeat (response_delay - 1) begin
        tick();
      end
      d_rsp_valid_i = 1;
      d_rsp_tag_i = bus_tag;
      d_rsp_rdata_i = canonical_response(value, status, bus_packet.op, bus_packet.mem_size, bus_packet.mem_addr[1:0]);
      d_rsp_status_i = status;
      tick();
    end
    d_rsp_valid_i = 0;
    d_rsp_status_i = 0;
    d_rsp_rdata_i = 0;
    planned_status = 0;
  endtask

  /* stop any unbounded test-driver wait without reporting a false pass. */
  initial begin : watchdog
    #2000000;
    $fatal(1, "global regression watchdog expired");
  end

  /* exercise directed collisions and a reproducible varied-stall stream. */
  initial begin : regression
    packet_t p;
    int unsigned launch_before, trap_before;
    reset_reference();
    cold_reset();
    /* independently stop each pipeline boundary and check exact W write timing. */
    for (int stage = 0; stage < 5; stage++) begin
      p = packet(32'h100 + 32'(stage * 4), OP_RESULT, 5'(stage + 1), 32'h1000 + 32'(stage));
      hold_i[stage] = 1;
      submit(p);
      reach(3'(stage));
      /* preserve the selected stage throughout three sampled stalls. */
      repeat (3) begin
        tick();
      end
      hold_i = 0;
      drain();
    end
    p = packet('h120, OP_RESULT, 0, 'hdeadbeef);
    p.rd_write = 1;
    submit(p);
    drain();
    /* reset at each stage must suppress every same-edge normal write. */
    for (int stage = 0; stage < 5; stage++) begin
      p = packet('h180 + 32'(stage * 4), OP_RESULT, 22, 'hcafef00d);
      hold_i[stage] = 1;
      submit(p);
      reach(3'(stage));
      hold_i = 0;
      hart_reset_i = 1;
      tick();
      hart_reset_i = 0;
      drain();
    end
    /* kill reversible work at every stage before a normal architectural write. */
    for (int stage = 0; stage < 5; stage++) begin
      p = packet(32'h200 + 32'(stage * 4), OP_RESULT, 10, 'hbad00000 + 32'(stage));
      hold_i[stage] = 1;
      submit(p);
      reach(3'(stage));
      flush_pc_i = 'h800 + 32'(stage * 4);
      flush_valid_i = 1;
      tick();
      flush_valid_i = 0;
      hold_i = 0;
      drain();
    end
    /* write a CSR and its old-value destination on one unheld W edge. */
    p = packet('h300, OP_CSR, 11);
    p.csr_addr = 'h340;
    p.csr_op = CSR_WRITE;
    p.csr_source = 'h12345678;
    p.csr_read = 1;
    p.csr_write = 1;
    hold_i[4] = 1;
    submit(p);
    reach(4);
    /* withhold W permission and check that neither CSR nor GPR changes. */
    repeat (4) begin
      tick();
    end
    hold_i = 0;
    drain();
    p.pc = 'h304;
    p.csr_op = CSR_CLEAR;
    p.csr_source = 'h00340000;
    submit(p);
    drain();
    p.pc = 'h308;
    p.csr_op = CSR_SET;
    p.csr_source = 'h80000000;
    submit(p);
    drain();
    p.pc = 'h30c;
    p.csr_write = 0;
    p.csr_op = CSR_READ;
    submit(p);
    drain();
    /* configure an independent trap vector and exercise trap priority. */
    p = packet('h310, OP_CSR);
    p.csr_addr = 'h305;
    p.csr_write = 1;
    p.csr_op = CSR_WRITE;
    p.csr_source = 'h443;
    submit(p);
    drain();
    p = packet('h314, OP_CSR, 12, 'hffffffff);
    p.csr_addr = 'h340;
    p.csr_write = 1;
    p.csr_op = CSR_WRITE;
    p.csr_source = 'hffffffff;
    p.fault = 1;
    p.cause = 2;
    p.mtval = 'h55;
    hold_i[4] = 1;
    submit(p);
    reach(4);
    trap_before = traps;
    flush_valid_i = 1;
    flush_pc_i = 'h880;
    tick();
    flush_valid_i = 0;
    check(traps == trap_before, "held W fault trapped before release");
    /* retain the fault and pending flush while W remains held. */
    repeat (2) begin
      tick();
    end
    hold_i = 0;
    tick();
    check(traps == trap_before, "serialized W fault skipped its preparation edge");
    tick();
    check(traps == trap_before + 1, "flush suppressed an ordered W fault");
    drain();
    /* verify illegal CSR, system traps and aligned/misaligned branches. */
    p = packet('h318, OP_CSR, 13);
    p.csr_addr = 'h777;
    submit(p);
    drain();
    submit(packet('h31c, OP_ECALL));
    drain();
    submit(packet('h320, OP_EBREAK));
    drain();
    p = packet('h324, OP_REDIRECT, 14, 'h328);
    p.next_pc = 'h900;
    submit(p);
    drain();
    p.pc = 'h328;
    p.next_pc = 'h902;
    submit(p);
    drain();
    submit(packet('h32c, OP_MRET));
    drain();
    /* cover the full independent acceptance/response grid and byte lanes. */
    for (int a = 0; a < 2; a++) begin
      /* response delay does not share a draw or gate with acceptance delay. */
      for (int r = 0; r < 3; r++) begin
        p = packet('h400 + 32'(a * 12 + r * 4), OP_LOAD, 15);
        p.mem_addr = 'h20000000 + 32'(r);
        p.mem_size = 0;
        p.mem_signed = 1;
        submit(p);
        service(a, r, 'h80ff7f01);
        drain();
      end
    end
    p = packet('h440, OP_LOAD, 16);
    p.mem_addr = 'h20000002;
    p.mem_size = 1;
    p.mem_signed = 1;
    submit(p);
    service(2, 4, 'h80ff0000);
    drain();
    p = packet('h444, OP_STORE);
    p.mem_addr = 'h20000001;
    p.mem_size = 0;
    p.mem_wdata = 'h00005a00;
    submit(p);
    service(3, 2, 0);
    drain();
    /* an x0 load still owns and completes a real physical request. */
    p = packet('h448, OP_LOAD, 0);
    p.rd_write = 1;
    p.mem_addr = 'h40000000;
    submit(p);
    service(1, 2, 'habcdef01);
    drain();
    /* local alignment and encoding failures must never launch a data request. */
    launch_before = launches;
    p = packet('h44c, OP_LOAD, 17);
    p.mem_addr = 'h20000001;
    submit(p);
    drain();
    p.pc = 'h450;
    p.mem_addr = 'h20000000;
    p.length = 2;
    submit(p);
    drain();
    check(launches == launch_before, "local fault launched a transaction");
    /* a same-edge external flush vetoes a memory attempt before first valid. */
    p = packet('h480, OP_STORE);
    p.mem_addr = 'h20000000;
    p.mem_wdata = 'h12345678;
    hold_i[3] = 1;
    submit(p);
    reach(3);
    hold_i = 0;
    flush_valid_i = 1;
    flush_pc_i = 'h980;
    tick();
    flush_valid_i = 0;
    drain();
    check(launches == launch_before, "flush lost the before-launch arbitration");
    /* a target rejection faults once without changing its destination. */
    p = packet('h454, OP_LOAD, 18);
    p.mem_addr = 'h50001000;
    submit(p);
    service(2, 2, 0, 1);
    drain();
    /* flush after first valid preserves the owned request and its retirement. */
    p = packet('h458, OP_LOAD, 19);
    p.mem_addr = 'h20000000;
    submit(p);
    /* stop at the first registered offer before any physical acceptance. */
    while (!d_req_valid_o) begin
      tick();
    end
    flush_pc_i = 'h990;
    flush_valid_i = 1;
    tick();
    flush_valid_i = 0;
    service(2, 3, 'h76543210);
    drain();
    /* a protected failing memory operation chooses its trap over pending flush. */
    p.pc = 'h45c;
    submit(p);
    /* wait for the nonwithdrawable offer before requesting the flush. */
    while (!d_req_valid_o) begin
      tick();
    end
    flush_valid_i = 1;
    tick();
    flush_valid_i = 0;
    service(1, 1, 0, 1);
    drain();
    /* hart reset aborts the token but retains the unaccepted bus descriptor. */
    p = packet('h460, OP_LOAD, 20);
    p.mem_addr = 'h20000000;
    submit(p);
    /* reset only after the manager owns an unaccepted offer. */
    while (!d_req_valid_o) begin
      tick();
    end
    /* this negative control requires the DUT to reject unsafe cold reset. */
    if ($test$plusargs("negative_cold_live")) begin
      isolated_i = 0;
      cold_reset_i = 1;
      tick();
      check(0, "live-offer isolation guard did not fire");
    end
    hart_reset_i = 1;
    tick();
    hart_reset_i = 0;
    service(2, 2, 'hfeedface);
    drain();
    /* reset must preserve acceptance accounting with delayed or immediate completion. */
    for (int immediate = 0; immediate < 2; immediate++) begin
      p.pc = 'h464 + 32'(immediate * 4);
      submit(p);
      /* establish first valid before colliding acceptance with hart reset. */
      while (!d_req_valid_o) begin
        tick();
      end
      planned_read = 'haabbccdd;
      planned_status = 0;
      d_req_ready_i = 1;
      d_rsp_valid_i = immediate != 0;
      d_rsp_tag_i = bus_tag;
      d_rsp_rdata_i = canonical_response(planned_read, planned_status, bus_packet.op, bus_packet.mem_size, bus_packet.mem_addr[1:0]);
      hart_reset_i = 1;
      tick();
      hart_reset_i = 0;
      d_req_ready_i = 0;
      d_rsp_valid_i = 0;
      /* a delayed response drains the accepted orphan after reset. */
      if (immediate == 0) begin
        tick();
        d_rsp_valid_i = 1;
        tick();
        d_rsp_valid_i = 0;
      end
      drain();
    end
    /* reset at the response edge accounts the bus without architectural delivery. */
    submit(p);
    /* capture the offer before accepting it on the next edge. */
    while (!d_req_valid_o) begin
      tick();
    end
    d_req_ready_i = 1;
    tick();
    d_req_ready_i = 0;
    planned_read = 'h11223344;
    planned_status = 0;
    d_rsp_valid_i = 1;
    d_rsp_tag_i = bus_tag;
    d_rsp_rdata_i = canonical_response(planned_read, planned_status, bus_packet.op, bus_packet.mem_size, bus_packet.mem_addr[1:0]);
    hart_reset_i = 1;
    tick();
    hart_reset_i = 0;
    d_rsp_valid_i = 0;
    drain();
    /* a reset during accepted response wait must not deliver to a replacement token. */
    submit(p);
    /* capture the offer before entering the accepted response wait. */
    while (!d_req_valid_o) begin
      tick();
    end
    d_req_ready_i = 1;
    tick();
    d_req_ready_i = 0;
    hart_reset_i = 1;
    tick();
    hart_reset_i = 0;
    /* retain the orphan through additional response latency. */
    repeat (2) begin
      tick();
    end
    planned_read = 'h55667788;
    d_rsp_valid_i = 1;
    d_rsp_tag_i = bus_tag;
    d_rsp_rdata_i = canonical_response(planned_read, planned_status, bus_packet.op, bus_packet.mem_size, bus_packet.mem_addr[1:0]);
    tick();
    d_rsp_valid_i = 0;
    drain();
    /* exercise overlapping occupancy when diagnostic serialization is disabled. */
    for (int n = 0; n < 40; n++) begin
      p = packet('h1000 + 32'(n * 4), OP_RESULT, 5'(1 + n % 30), 32'h55000000 + 32'(n));
      submit(p);
    end
    drain();
    /* overlap mode must prevent a younger M effect behind an older W fault. */
    if (!DIAGNOSTIC) begin
      hold_i[4] = 1;
      submit(packet('h1800, OP_ECALL));
      reach(4);
      p = packet('h1804, OP_STORE);
      p.mem_addr = 'h40000004;
      p.mem_wdata = 'hbadc0ffe;
      submit(p);
      reach(3);
      launch_before = launches;
      trap_before = traps;
      hold_i = 0;
      tick();
      check(launches == launch_before && traps == trap_before + 1,
            "younger memory escaped an older W fault");
      drain();
    end
    /* a matching uncertain response cannot create a normal terminal. */
    p = packet('h2000, OP_LOAD, 21);
    p.mem_addr = 'h50002000;
    submit(p);
    service(1, 2, 0, 2);
    /* verify that uncertainty preserves the frozen owner over time. */
    repeat (3) begin
      tick();
    end
    check(fatal_o && stage_valid_o != 0, "uncertainty failed to freeze its instruction");
    cold_reset();
    /* a bad tag followed by a matching reply still retains the fatal owner. */
    p = packet('h2100, OP_LOAD, 23);
    p.mem_addr = 'h20000000;
    submit(p);
    /* wait for the surviving owner before injecting a wrong-tag response. */
    while (!d_req_valid_o) begin
      tick();
    end
    d_req_ready_i = 1;
    tick();
    d_req_ready_i = 0;
    d_rsp_valid_i = 1;
    d_rsp_tag_i = bus_tag + 1;
    d_rsp_rdata_i = 0;
    tick();
    d_rsp_tag_i = bus_tag;
    tick();
    d_rsp_valid_i = 0;
    check(fatal_o && mem_busy_o, "late matching response released a fatal owner");
    hart_reset_i = 1;
    tick();
    hart_reset_i = 0;
    tick();
    check(fatal_o && mem_busy_o, "hart reset released a fatal owner");
    cold_reset();
    /* reject a response for an unknown owner without delivering it elsewhere. */
    d_rsp_valid_i = 1;
    d_rsp_tag_i = 'hbad;
    d_rsp_rdata_i = 0;
    tick();
    d_rsp_valid_i = 0;
    check(fatal_o, "unknown response did not cause containment");
    /* fatal state requires isolation even when the manager has no live request. */
    if ($test$plusargs("negative_cold_fatal_free")) begin
      isolated_i = 0;
      cold_reset_i = 1;
      tick();
      check(0, "empty-manager isolation guard did not fire");
    end
    cold_reset();
    drain();
    /* require each independently stalled boundary to have been exercised. */
    for (int i = 0; i < 5; i++) begin
      check(coverage_stalls[i] != 0, "missing stage-stall coverage");
    end
    check(accepted_inputs > 60 && retirements > 40 && traps >= 8 && launches >= 12,
          "directed regression did not exercise its required paths");
    check(DIAGNOSTIC ? max_occupancy == 1 : max_occupancy == 5,
          "requested occupancy mode was not actually exercised");
    $display("PASS diagnostic=%0d cycles=%0d inputs=%0d retirements=%0d traps=%0d kills=%0d launches=%0d accepts=%0d completions=%0d",
             DIAGNOSTIC, cycles, accepted_inputs, retirements, traps, kills, launches, acceptances, completions);
    $finish;
  end
endmodule

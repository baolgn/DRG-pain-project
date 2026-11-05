/* verify real control-flow execution through the packet pipeline. */
module drg5_control_flow_tb #(
  parameter bit C_ENABLED = 0,
  parameter bit DIAGNOSTIC = 0
);
  import drg5_control_pkg::*;
  /* disconnected debug outputs retain named endpoints in legacy configurations. */
  logic unused_debug_halted, unused_debug_resumeack, unused_debug_reg_ready;
  logic [31:0] unused_debug_dpc, unused_debug_dcsr, unused_debug_reg_rdata;
  logic [2:0] unused_debug_reg_error;
  /* preserve the explicitly IRQ-disabled compatibility profile. */
  logic unused_entry_pending, unused_idle, unused_irq_valid;
  logic [31:0] unused_irq_pc, unused_irq_cause;
  /* bound independent input identities and program storage for every directed run. */
  localparam integer CAPACITY = 512;
  localparam integer PROGRAM_PARCELS = 8192;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
  logic [4:0] hold_i = 0;
  logic in_valid_i, in_ready_o;
  packet_t in_packet_i;
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

  /* the program map and architectural state are independent of retirement outputs. */
  packet_t program_packet [0:PROGRAM_PARCELS-1];
  bit program_valid [0:PROGRAM_PARCELS-1];
  packet_t original [0:CAPACITY-1];
  bit live [0:CAPACITY-1];
  bit prepared [0:CAPACITY-1];
  logic [31:0] regs_ref [0:31];
  bit defined_ref [0:31];
  logic [31:0] arch_pc = 0, feed_pc = 0, vector_ref = 0, epc_ref = 0;
  logic [31:0] cause_ref = 0, tval_ref = 0;
  bit feeding = 0, integration = 0, integration_fault_seen = 0;
  int unsigned next_uid = 0, next_order = 0, cycles = 0, cases = 0;
  int unsigned retirements = 0, traps = 0, redirects = 0, kills = 0;
  int unsigned hazard_stalls = 0, bypasses = 0, nearest_stalls = 0;
  int unsigned held_x = 0, held_w = 0, branch_transfers = 0, x_behind_load = 0;
  logic [31:0] hold_x_pc = '1, hold_w_pc = '1;
  int hold_x_remaining = 0, hold_w_remaining = 0;
  bit owner = 0, accepted = 0;
  bit reset_recovery = 1;
  logic [31:0] owner_addr = 0, owner_tag = 0, last_tag = 0;
  logic [8:0] owner_uid = 0;
  int unsigned owner_since = 0, accepted_cycle = 0;
  int unsigned launches = 0, completions = 0;
  integer response_delay = 0;
  logic [31:0] memory_value = 0;
  logic [1:0] memory_status = 0;
  bit load_completed [0:CAPACITY-1];
  logic [31:0] load_values [0:CAPACITY-1];
  bit load_failed [0:CAPACITY-1];
  bit mutation_applied = 0;

  /* control predictions include operand use and instruction-relative next state. */
  typedef struct packed {
    logic legal, use1, use2, writes, taken, fault;
    logic [4:0] rs1, rs2, rd;
    logic [3:0] kind;
    logic [2:0] cond;
    logic [31:0] a, b, immediate, result, next_pc, cause, mtval;
  } prediction_t;

  /* instantiate the actual five-stage pipeline under both alignment configurations. */
  drg5_control #(.IRQ_ENABLED(0), .FORWARDING(0), .C_ENABLED(C_ENABLED), .DIAGNOSTIC(DIAGNOSTIC), .TEST_REGIONS(1), .D_MAX_WAIT_CYCLES(256)) dut (
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

  /* use the actual fetch manager only in the target-access-fault integration case. */
  logic f_req_valid, f_req_ready, f_rsp_valid, f_rsp_ready;
  logic [31:0] f_req_addr, f_req_tag, f_rsp_tag, f_rsp_data;
  logic [1:0] f_req_mask, f_rsp_mask;
  logic f_valid, f_ready, f_supported, f_fault;
  logic [31:0] f_pc, f_raw, f_cause, f_mtval;
  logic [3:0] f_raw_valid;
  logic [1:0] f_kind, f_generation, f_generation_current;
  logic [2:0] f_bytes, f_fatal_reason;
  logic f_busy, f_discard, f_fatal, f_launch, f_accept, f_complete, f_drop;
  logic f_pending;
  logic [31:0] integration_jump;
  int unsigned instruction_reads = 0, target_faults = 0;

  /* connect the real instruction manager to a distinct registered ROM target. */
  drg5_fetch #(.C_FETCH(C_ENABLED), .GEN_BITS(2), .MAX_WAIT_CYCLES(64),
      .RESET_PC(32'h1000)) fetch (
    .clk_i, .cold_reset_i, .isolated_i, .hart_reset_i,
    .permit_i(integration && feeding),
    .redirect_valid_i(integration && redirect_valid_o), .redirect_pc_i(redirect_pc_o),
    .i_req_valid_o(f_req_valid), .i_req_ready_i(f_req_ready),
    .i_req_addr_o(f_req_addr), .i_req_tag_o(f_req_tag), .i_req_parcels_o(f_req_mask),
    .i_rsp_valid_i(f_rsp_valid), .i_rsp_ready_o(f_rsp_ready), .i_rsp_tag_i(f_rsp_tag),
    .i_rsp_data_i(f_rsp_data), .i_rsp_parcels_i(f_rsp_mask),
    .i_rsp_fault_i(2'b0), .i_rsp_status_i(2'b0),
    .insn_valid_o(f_valid), .insn_ready_i(f_ready), .insn_pc_o(f_pc), .insn_raw_o(f_raw),
    .insn_raw_valid_o(f_raw_valid), .insn_length_kind_o(f_kind),
    .insn_length_supported_o(f_supported), .insn_length_bytes_o(f_bytes),
    .insn_generation_o(f_generation), .insn_fault_o(f_fault),
    .insn_cause_o(f_cause), .insn_mtval_o(f_mtval),
    .busy_o(f_busy), .discard_o(f_discard), .fatal_o(f_fatal), .fatal_reason_o(f_fatal_reason),
    .generation_o(f_generation_current), .launch_o(f_launch), .accept_o(f_accept),
    .complete_o(f_complete), .drop_o(f_drop)
  );

  /* report the exact independent PC and case at the first failure. */
  function automatic void check(input bit condition, input string message);
    /* later comparisons are invalid after the first ledger mismatch. */
    if (!condition) begin
      $fatal(1, "case=%0d cycle=%0d C=%0d diagnostic=%0d pc=%08x: %s",
             cases, cycles, C_ENABLED, DIAGNOSTIC, arch_pc, message);
    end
  endfunction

  /* instructions in this bounded fixture occupy explicitly named halfword addresses. */
  function automatic integer program_index(input logic [31:0] pc);
    check(pc < 2 * PROGRAM_PARCELS && !pc[0], "program address outside fixture");
    return int'(pc / 2);
  endfunction

  /* construct ordinary packets independently of every implementation output. */
  function automatic packet_t packet(input logic [31:0] pc, input op_t op = OP_RESULT,
                                     input logic [4:0] rd = 0, input logic [31:0] result = 0);
    packet_t p;
    p = '0;
    p.pc = pc;
    p.op = op;
    p.raw = 'h13;
    p.raw_valid = 15;
    p.length = 4;
    p.next_pc = pc + 4;
    p.rd = rd;
    p.rd_write = rd != 0;
    p.result = result;
    p.mem_size = 2;
    return p;
  endfunction

  /* encode branch stimulus directly from the architectural displacement bits. */
  function automatic logic [31:0] encode_branch(input logic [2:0] condition,
      input logic [4:0] source1, source2, input logic [31:0] displacement);
    return ((displacement & 'h1000) << 19) | ((displacement & 'h7e0) << 20) |
           (32'(source2) << 20) | (32'(source1) << 15) | (32'(condition) << 12) |
           ((displacement & 'h1e) << 7) | ((displacement & 'h800) >> 4) | 'h63;
  endfunction

  /* J-format generation is separate from the per-bit decoding reference below. */
  function automatic logic [31:0] encode_jal(input logic [4:0] destination,
                                            input logic [31:0] displacement);
    return ((displacement & 'h100000) << 11) | ((displacement & 'h7fe) << 20) |
           ((displacement & 'h800) << 9) | (displacement & 'hff000) |
           (32'(destination) << 7) | 'h6f;
  endfunction

  /* JALR retains a signed byte displacement and clears its target bit later. */
  function automatic logic [31:0] encode_jalr(input logic [4:0] destination,
      input logic [4:0] source, input logic [11:0] displacement);
    return (32'(displacement) << 20) | (32'(source) << 15) | (32'(destination) << 7) | 'h67;
  endfunction

  /* supplied control annotations are poisoned to prove real decode and RF use. */
  function automatic packet_t control(input logic [31:0] pc, input logic [31:0] word);
    packet_t p;
    p = packet(pc, OP_CONTROL, 31, 'hbad0bad0);
    p.raw = word;
    p.rs1_used = 1;
    p.rs2_used = 1;
    p.rs1 = 31;
    p.rs2 = 31;
    p.rs1_value = 'hdeadbeef;
    p.rs2_value = 'hcafef00d;
    p.next_pc = 'hbad0bad0;
    return p;
  endfunction

  /* decode offsets bit by bit rather than importing DUT immediate or branch logic. */
  function automatic logic [31:0] immediate_ref(input logic [31:0] word,
                                              input logic [3:0] kind);
    logic [31:0] value;
    integer source;
    value = 0;
    /* bit zero is fixed for B/J offsets and all upper bits repeat the sign. */
    for (int bit_number = 0; bit_number < 32; bit_number++) begin
      source = -1;
      /* select the architectural format independently of opcode-case RTL. */
      case (kind)
        5: source = bit_number == 0 ? -1 : bit_number < 11 ? bit_number + 20 :
                    bit_number == 11 ? 20 : bit_number < 20 ? bit_number : 31;
        6: source = bit_number < 12 ? bit_number + 20 : 31;
        7: source = bit_number == 0 ? -1 : bit_number < 5 ? bit_number + 7 :
                    bit_number < 11 ? bit_number + 20 : bit_number == 11 ? 7 : 31;
        default: source = -1;
      endcase
      /* fixed-zero positions never read an instruction bit. */
      if (source >= 0) value[bit_number] = word[source];
    end
    return value;
  endfunction

  /* a widened signed difference avoids sharing the DUT sign-selection predicate. */
  function automatic bit less_signed_ref(input logic [31:0] a, b);
    logic signed [32:0] difference;
    logic [31:0] unused_difference_magnitude;
    difference = $signed({a[31], a}) - $signed({b[31], b});
    /* the exact subtraction sign alone determines this comparison. */
    unused_difference_magnitude = difference[31:0];
    return difference[32];
  endfunction

  /* predict only from original accepted stimulus and the independent committed bank. */
  function automatic prediction_t predict(input packet_t p, input logic [8:0] id);
    prediction_t q;
    logic [31:0] word, target;
    bit width_ok;
    logic [157:0] unused_supplied_annotations;
    /* original operand annotations and non-read CSR controls are not prediction authority. */
    unused_supplied_annotations = {p.rs1_used, p.rs2_used, p.rs1, p.rs2, p.rs1_value,
        p.rs2_value, p.mem_wdata, p.mem_size, p.mem_signed, p.csr_addr, p.csr_op,
        p.csr_write, p.csr_source};
    q = '0;
    q.legal = 1;
    q.next_pc = p.next_pc;
    q.result = p.result;
    q.rd = p.rd;
    q.writes = p.rd_write && p.rd != 0 && p.op != OP_STORE;
    q.fault = p.fault;
    q.cause = p.cause;
    q.mtval = p.mtval;
    /* a completed load's value belongs to the responder plan, not retirement trace. */
    if (p.op == OP_LOAD && !p.fault) begin
      q.result = load_values[id];
      q.fault = load_failed[id];
      q.cause = q.fault ? 5 : 0;
      q.mtval = q.fault ? p.mem_addr : 0;
    end
    /* CSR predictions use an independent mtvec bank for reads and write-only results. */
    if (p.op == OP_CSR) begin
      q.result = p.csr_read ? vector_ref : 0;
    end
    /* an older explicit trap is useful for proving younger branch suppression. */
    if (p.op == OP_ECALL && !p.fault) begin
      q.fault = 1;
      q.cause = 11;
      q.mtval = 0;
    end
    /* raw or trusted expanded control instructions replace every poisoned annotation. */
    if (p.op == OP_CONTROL) begin
      q.result = 0;
      q.next_pc = 0;
      q.rd = 0;
      q.writes = 0;
      word = p.length == 2 ? p.expanded : p.raw;
      width_ok = (p.length == 4 && p.raw_valid == 15 && !p.expanded_valid) ||
                 (C_ENABLED && p.length == 2 && p.raw_valid == 3 && p.expanded_valid &&
                  p.raw[31:16] == 0 && p.raw[1:0] != 3);
      q.kind = (word & 'h7f) == 'h6f ? 5 :
               (word & 'h707f) == 'h67 ? 6 :
               ((word & 'h7f) == 'h63 && word[14:12] inside {0, 1, 4, 5, 6, 7}) ? 7 : 0;
      q.legal = width_ok && q.kind != 0;
      /* fetch faults suppress decode and operand use even with a valid-looking word. */
      if (!p.fault && q.legal) begin
        q.use1 = q.kind != 5;
        q.use2 = q.kind == 7;
        q.rs1 = q.use1 ? word[19:15] : 0;
        q.rs2 = q.use2 ? word[24:20] : 0;
        q.rd = q.kind == 7 ? 0 : word[11:7];
        q.writes = q.rd != 0;
        q.a = q.use1 && q.rs1 != 0 ? regs_ref[q.rs1] : 0;
        q.b = q.use2 && q.rs2 != 0 ? regs_ref[q.rs2] : 0;
        q.cond = q.kind == 7 ? word[14:12] : 0;
        q.immediate = immediate_ref(word, q.kind);
        q.taken = q.kind != 7;
        /* branch conditions are independent of the supplied packet's resolved PC. */
        if (q.kind == 7) begin
          /* signed and unsigned decisions have separate explicit meanings. */
          case (q.cond)
            0: q.taken = q.a == q.b;
            1: q.taken = q.a != q.b;
            4: q.taken = less_signed_ref(q.a, q.b);
            5: q.taken = !less_signed_ref(q.a, q.b);
            6: q.taken = q.a < q.b;
            7: q.taken = q.a >= q.b;
            default: q.taken = 0;
          endcase
        end
        target = q.kind == 6 ? (q.a + q.immediate) & 32'hfffffffe : p.pc + q.immediate;
        q.next_pc = q.taken ? target : p.pc + {29'b0, p.length};
        q.result = q.kind == 7 ? 0 : p.pc + {29'b0, p.length};
        /* an untaken branch never faults on its unused target. */
        if (q.taken && (target[0] || (!C_ENABLED && target[1]))) begin
          q.fault = 1;
          q.cause = 0;
          q.mtval = target;
        end
      end
      /* unsupported control encodings produce a precise illegal instruction. */
      else if (!p.fault) begin
        q.fault = 1;
        q.cause = 2;
        q.mtval = 0;
      end
    end
    return q;
  endfunction

  /* source dependencies are semantic, including x0 exclusion and decoded destinations. */
  function automatic logic [4:0] destination(input packet_t p);
    logic [31:0] word;
    logic [350:0] unused_non_destination_fields;
    /* dependency intent does not depend on operand values or later execution results. */
    unused_non_destination_fields = {p.pc, p.rs1_used, p.rs2_used, p.rs1, p.rs2,
        p.rs1_value, p.rs2_value, p.result, p.next_pc, p.mem_addr, p.mem_wdata,
        p.mem_size, p.mem_signed, p.csr_addr, p.csr_op, p.csr_read, p.csr_write,
        p.csr_source, p.cause, p.mtval};
    word = p.length == 2 ? p.expanded : p.raw;
    /* branches have no destination even if their input annotations say otherwise. */
    if (p.op == OP_CONTROL) return
        !p.fault && ((p.length == 4 && p.raw_valid == 15 && !p.expanded_valid) ||
        (C_ENABLED && p.length == 2 && p.raw_valid == 3 && p.expanded_valid &&
         p.raw[31:16] == 0 && p.raw[1:0] != 3)) &&
        ((word & 'h7f) == 'h6f || (word & 'h707f) == 'h67) ? word[11:7] : 0;
    return p.rd_write && p.op inside {OP_RESULT, OP_LOAD, OP_CSR, OP_REDIRECT} ? p.rd : 0;
  endfunction

  /* build the producer stream from a program map or the actual fetch adapter. */
  always_comb begin
    in_valid_i = 0;
    in_packet_i = '0;
    f_ready = integration && feeding && in_ready_o;
    /* the adapter preserves fetch faults and original bytes as their own later token. */
    if (integration) begin
      in_valid_i = feeding && f_valid;
      in_packet_i.pc = f_pc;
      in_packet_i.raw = f_raw;
      in_packet_i.raw_valid = f_raw_valid;
      in_packet_i.length = f_bytes;
      in_packet_i.op = !f_fault && ((f_raw & 'h7f) inside {'h63, 'h67, 'h6f}) ? OP_CONTROL : OP_RESULT;
      in_packet_i.next_pc = f_pc + {29'b0, f_bytes};
      in_packet_i.fault = f_fault;
      in_packet_i.cause = f_cause;
      in_packet_i.mtval = f_mtval;
    end
    /* direct packets remain a prototype fixture, not a general instruction decoder. */
    else if (feeding && feed_pc < 2 * PROGRAM_PARCELS && !feed_pc[0]) begin
      in_valid_i = program_valid[int'(feed_pc / 2)];
      in_packet_i = program_packet[int'(feed_pc / 2)];
    end
  end

  /* a registered instruction target returns safe ROM bytes one edge after acceptance. */
  assign f_req_ready = !f_pending;
  assign f_rsp_valid = f_pending;
  /* capture read data on the target clock and retain its response until consumed. */
  always_ff @(posedge clk_i) begin
    /* positive isolation fences both the manager and this target. */
    if (cold_reset_i) begin
      f_pending <= 0;
      f_rsp_tag <= 0;
      f_rsp_mask <= 0;
      f_rsp_data <= 0;
    end
    /* registered read capture is independent of pipeline backpressure. */
    else begin
      /* no wide or speculative instruction read may reach the denied target. */
      if (f_req_valid && f_req_ready) begin
        check(f_req_addr >= 'h1000 && f_req_addr < 'h2000, "fetch integration read a forbidden target");
        f_pending <= 1;
        f_rsp_tag <= f_req_tag;
        f_rsp_mask <= f_req_mask;
        f_rsp_data <= 0;
        /* each requested parcel gets its byte-positioned original encoding. */
        for (int parcel = 0; parcel < 2; parcel++) begin
          /* no unrequested parcel contributes response data. */
          if (f_req_mask[parcel]) begin
            f_rsp_data[16*parcel +: 16] <= f_req_addr == 'h1000 ?
                integration_jump[16*parcel +: 16] : (parcel == 0 ? 16'h0013 : 16'b0);
          end
        end
      end
      /* one response ends its own accepted transaction exactly once. */
      if (f_rsp_valid && f_rsp_ready) f_pending <= 0;
    end
  end

  /* compare terminal identity, operands, result, trap state and independent next PC. */
  task automatic terminal(input trace_t actual, input prediction_t q);
    packet_t p, expected_packet;
    int unsigned id;
    logic [31:0] next_arch;
    logic [40:0] unused_terminal_decode;
    /* decode-stage checks consume these fields before terminal architectural comparison. */
    unused_terminal_decode = {q.legal, q.taken, q.kind, q.cond, q.immediate};
    check(actual.valid, "terminal comparator received an invalid trace");
    id = int'(actual.uid);
    check(id < CAPACITY && live[id], "terminal lacked an accepted input owner");
    p = original[id];
    check(p.pc == arch_pc && actual.packet.pc == arch_pc, "architectural control-flow sequence diverged");
    check(actual.order == 64'(next_order), "terminal order skipped or duplicated");
    /* surviving older inputs must retire or be explicitly killed first. */
    for (int older = 0; older < int'(id); older++) begin
      check(!live[older], "terminal bypassed an older input");
    end
    check(actual.packet.raw == p.raw && actual.packet.raw_valid == p.raw_valid &&
          actual.packet.length == p.length && actual.packet.expanded_valid == p.expanded_valid &&
          actual.packet.expanded == p.expanded, "control packet lost original instruction identity");
    check(actual.trap == q.fault && actual.packet.fault == q.fault,
          "wrong control terminal disposition");
    check(actual.rd_write == (q.writes && !q.fault) &&
          actual.rd == (q.writes && !q.fault ? q.rd : 0) &&
          actual.value == (q.writes && !q.fault ? q.result : 0), "wrong architectural control result");
    /* successful loads require their independently recorded external completion. */
    if (p.op == OP_LOAD && !p.fault) check(load_completed[id], "load retired before external completion");
    check(actual.csr_read == (!q.fault && p.op == OP_CSR && p.csr_read) &&
          actual.csr_write == (!q.fault && p.op == OP_CSR && p.csr_write), "wrong CSR write disposition");
    /* reads expose old state independently of writes, including read-only accesses. */
    check(actual.csr_old == (!q.fault && p.op == OP_CSR && p.csr_read ? vector_ref : 0) &&
          actual.csr_new == (!q.fault && p.op == OP_CSR && p.csr_write ?
            (p.csr_source & 32'hfffffffc) : 0), "wrong CSR retirement values");
    /* source values must be the real captured bank values, including W bypass. */
    if (p.op == OP_CONTROL) begin
      check(actual.packet.rs1_used == q.use1 && actual.packet.rs2_used == q.use2 &&
            actual.packet.rs1 == q.rs1 && actual.packet.rs2 == q.rs2 &&
            actual.packet.rs1_value == q.a && actual.packet.rs2_value == q.b,
            "control operands did not come from the independent register bank");
      check(actual.packet.rd == q.rd && actual.packet.rd_write == q.writes,
            "control destination intent was not decoded");
      check(actual.packet.result == q.result && actual.packet.next_pc == q.next_pc,
            "control packet has wrong X result or continuation");
    end
    expected_packet = p;
    /* original annotations are immutable except explicitly specified control decode fields. */
    if (p.op == OP_CONTROL) begin
      expected_packet.rs1_used = q.use1;
      expected_packet.rs2_used = q.use2;
      expected_packet.rs1 = q.rs1;
      expected_packet.rs2 = q.rs2;
      expected_packet.rs1_value = q.a;
      expected_packet.rs2_value = q.b;
      expected_packet.rd = q.rd;
      expected_packet.rd_write = q.writes;
      expected_packet.result = q.result;
      expected_packet.next_pc = q.next_pc;
    end
    /* only successful load capture replaces the supplied result field. */
    if (p.op == OP_LOAD && !q.fault) expected_packet.result = q.result;
    expected_packet.fault = q.fault;
    expected_packet.cause = q.fault ? q.cause : 0;
    expected_packet.mtval = q.fault ? q.mtval : 0;
    check(actual.packet == expected_packet, "terminal packet changed immutable or predicted metadata");
    next_arch = q.fault ? vector_ref : q.next_pc;
    check(actual.next_pc == next_arch, "wrong committed next PC");
    /* precise traps commit only trap state, never a jump link. */
    if (q.fault) begin
      check(actual.packet.cause == q.cause && actual.packet.mtval == q.mtval,
            "wrong control-flow trap metadata");
      epc_ref = p.pc & (C_ENABLED ? 32'hfffffffe : 32'hfffffffc);
      cause_ref = q.cause;
      tval_ref = q.mtval;
      traps++;
      /* this end-to-end fault belongs to the target token after the jump retired. */
      if (integration && p.pc == 'h3000) begin
        check(q.cause == 1 && q.mtval == 'h3000 && regs_ref[1] == 'h1004,
              "target fetch fault erased or misattributed the successful jump");
        integration_fault_seen = 1;
        feeding = 0;
        target_faults++;
      end
    end
    /* normal W retirement is the only permitted architectural GPR write. */
    else begin
      retirements++;
      /* write suppression is checked against independently decoded intent. */
      if (q.writes) begin
        regs_ref[q.rd] = q.result;
        defined_ref[q.rd] = 1;
      end
      /* the fixture's only CSR update configures its real trap target. */
      if (p.op == OP_CSR && p.csr_write) vector_ref = p.csr_source & 32'hfffffffc;
    end
    arch_pc = next_arch;
    live[id] = 0;
    next_order++;
  endtask

  /* sample inputs once, then apply the independent architectural model at W. */
  task automatic tick();
    logic [4:0] before_valid, expected_kill, barriers;
    token_t before_token [0:4];
    logic [3:0] before_transfer;
    packet_t accepted_packet;
    prediction_t w, d, x;
    logic [238:0] unused_dependency_prediction;
    logic [135:0] unused_capture_prediction;
    bit input_accept, w_done, expected_redirect, request_accept, response_accept, launch_before;
    bit hazard, owner_before;
    logic [4:0] rd;
    logic [31:0] observed_redirect;
    int unsigned matching_writers, count, id;
    trace_t observed_trace;
    clk_i = 0;
    hold_i = 0;
    /* independent bounded stalls test that X computes and W redirects once. */
    if (stage_valid_o[2] && stage_token_o[2].p.pc == hold_x_pc && hold_x_remaining > 0) begin
      hold_i[2] = 1;
      hold_x_remaining--;
      held_x++;
    end
    /* a held W jump may neither write its link nor publish its redirect. */
    if (stage_valid_o[4] && stage_token_o[4].p.pc == hold_w_pc && hold_w_remaining > 0) begin
      hold_i[4] = 1;
      hold_w_remaining--;
      held_w++;
    end
    d_req_ready_i = owner && !accepted;
    d_rsp_valid_i = owner && accepted && cycles - accepted_cycle >= 32'(response_delay);
    d_rsp_tag_i = owner_tag;
    d_rsp_rdata_i = memory_status == 0 ? memory_value : 0;
    d_rsp_status_i = memory_status;
    #2;
    /* sample combinational readiness before its handshake changes ownership. */
    check(flush_ready_o == (!cold_reset_i && !hart_reset_i && !reset_recovery),
          "idle external flush interface became unavailable");
    before_valid = stage_valid_o;
    before_token = stage_token_o;
    before_transfer = transfer_o;
    owner_before = owner;
    barriers = 0;
    /* serialization derives from accepted stimulus rather than the DUT preparation bit. */
    for (int stage = 0; stage < 5; stage++) begin
      barriers[stage] = before_valid[stage] && original[int'(before_token[stage].uid)].op inside {OP_CSR, OP_MRET};
      /* a serial operation excludes younger transfers and all new packet admission. */
      if (barriers[stage]) begin
        check(!in_ready_o, "serial operation admitted younger control input");
        /* the barrier remains active through its disposition edge. */
        for (int younger = 0; younger < stage && younger < 4; younger++)
          check(!before_transfer[younger], "control transfer crossed serial barrier");
      end
    end
    /* this overlap bin proves the younger independent jump really occupied X during a load wait. */
    if (before_valid[2] && before_valid[3] && before_token[2].p.op == OP_CONTROL &&
        before_token[3].p.op == OP_LOAD && owner) x_behind_load++;
    input_accept = in_valid_i && in_ready_o;
    accepted_packet = in_packet_i;
    request_accept = d_req_valid_o && d_req_ready_i;
    response_accept = d_rsp_valid_i && d_rsp_ready_o;
    launch_before = mem_launch_o;
    w = '0;
    /* independent current architectural state predicts the oldest possible terminal. */
    if (before_valid[4]) w = predict(original[int'(before_token[4].uid)], 9'(before_token[4].uid));
    w_done = before_valid[4] && !hold_i[4] && !cold_reset_i && !hart_reset_i &&
        (!barriers[4] || (prepared[int'(before_token[4].uid)] && !owner_before));
    expected_redirect = w_done && (w.fault ||
        (original[int'(before_token[4].uid)].op == OP_CONTROL && w.taken));
    expected_kill = (cold_reset_i || hart_reset_i) ? before_valid :
                    (expected_redirect ? before_valid & 5'b01111 : 0);
    /* decode dependency intent from original input, never from normalized DUT fields. */
    hazard = 0;
    matching_writers = 0;
    d = '0;
    /* only real control packets consume the decoded register dependency path. */
    if (before_valid[1] && original[int'(before_token[1].uid)].op == OP_CONTROL) begin
      d = predict(original[int'(before_token[1].uid)], 9'(before_token[1].uid));
      /* malformed and already-faulting controls do not consume ordinary operands. */
      if (d.legal && !original[int'(before_token[1].uid)].fault) begin
        /* X/M producers interlock, while a matching successful W write can bypass. */
        for (int stage = 2; stage < 5; stage++) begin
          rd = destination(original[int'(before_token[stage].uid)]);
          /* zero destinations never create dependencies. */
          if (before_valid[stage] && rd != 0 &&
              ((d.use1 && d.rs1 == rd) || (d.use2 && d.rs2 == rd))) begin
            matching_writers++;
            /* a nearer producer dominates an older retiring value. */
            if (stage != 4 || !(w_done && !w.fault && w.writes)) hazard = 1;
          end
        end
      end
    end
    /* dependency checks deliberately ignore results and operands until the capture edge. */
    unused_dependency_prediction = {d.writes, d.taken, d.fault, d.rd, d.kind, d.cond,
        d.a, d.b, d.immediate, d.result, d.next_pc, d.cause, d.mtval};
    /* a hazard must inhibit the actual D-to-X transfer even if an old value exists. */
    if (hazard && !expected_kill[1] && !cold_reset_i && !hart_reset_i) begin
      check(!before_transfer[1], "control bypassed an unresolved older writer");
      hazard_stalls++;
      /* this bin covers a nearer producer hiding a farther matching producer. */
      if (matching_writers > 1) nearest_stalls++;
    end
    /* count actual same-edge retirement bypass opportunities that were exercised. */
    if (before_transfer[1] && before_valid[1] && w_done && !w.fault && w.writes &&
        ((d.use1 && d.rs1 == w.rd) || (d.use2 && d.rs2 == w.rd))) bypasses++;
    /* every offered data request must preserve its independent owner and descriptor. */
    if (owner && !accepted && !cold_reset_i) begin
      check(d_req_valid_o && d_req_addr_o == owner_addr && d_req_tag_o == owner_tag &&
            !d_req_write_o && d_req_size_o == 2 && d_req_wstrb_o == 0,
            "owned load request changed or disappeared");
    end
    check(!d_req_valid_o || d_req_addr_o != 'h40000000, "wrong-path MMIO offer escaped control flow");
    /* acceptance and response belong to the original load, not to any branch result. */
    if (request_accept) begin
      check(owner && !accepted, "duplicate data acceptance");
      accepted = 1;
      accepted_cycle = cycles;
    end
    /* an independent response plan supplies a load value or precise access fault. */
    if (response_accept) begin
      check(owner && accepted && d_rsp_tag_i == owner_tag, "ownerless data completion");
      load_completed[owner_uid] = 1;
      load_values[owner_uid] = memory_value;
      load_failed[owner_uid] = memory_status == 1;
      owner = 0;
      accepted = 0;
      completions++;
    end
    /* one earlier unheld W edge prepares each serialized instruction. */
    if (before_valid[4] && barriers[4] && !prepared[int'(before_token[4].uid)] &&
        !hold_i[4] && !expected_kill[4] && !cold_reset_i && !hart_reset_i && !owner_before)
      prepared[int'(before_token[4].uid)] = 1;
    clk_i = 1;
    #2;
    cycles++;
    check(!fatal_o && fatal_record_o == '0 && !flush_aborted_o, "unexpected pipeline containment or flush abort");
    check(kill_valid_o == expected_kill, "unjustified or missing control-flow squash");
    check(trace_o.valid == w_done, "W eligibility and terminal count disagreed");
    check(redirect_valid_o == expected_redirect, "missing or repeated control-flow redirect");
    /* consume only independently justified kill identities. */
    for (int stage = 0; stage < 5; stage++) begin
      /* a killed token must be exactly the pre-edge owner of that stage. */
      if (kill_valid_o[stage]) begin
        id = int'(kill_uid_o[stage]);
        check(before_valid[stage] && before_token[stage].uid == kill_uid_o[stage] && live[id],
              "squash did not name the expected live stage owner");
        live[id] = 0;
        kills++;
      end
    end
    /* architectural reset clears definedness, never promises values for nonzero GPRs. */
    if (cold_reset_i || hart_reset_i) begin
      next_uid = 0;
      next_order = 0;
      vector_ref = 0;
      epc_ref = 0;
      cause_ref = 0;
      tval_ref = 0;
      last_tag = 0;
      /* x0 alone has an architecturally defined reset value. */
      for (int reg_index = 0; reg_index < 32; reg_index++) begin
        defined_ref[reg_index] = reg_index == 0;
        regs_ref[reg_index] = 0;
      end
    end
    /* terminal prediction updates the independent bank before checking any new X token. */
    else begin
      /* only a current W record can consume the next expected architectural instruction. */
      if (trace_o.valid) begin
        observed_trace = trace_o;
        /* a corrupted jump link must be caught independently of final register inspection. */
        if ($test$plusargs("mutate_link") && !mutation_applied &&
            original[int'(trace_o.uid)].op == OP_CONTROL && trace_o.rd_write) begin
          observed_trace.value ^= 1;
          mutation_applied = 1;
        end
        /* an operand observation corruption must fail the independently sourced bank check. */
        if ($test$plusargs("mutate_source") && !mutation_applied &&
            original[int'(trace_o.uid)].op == OP_CONTROL && trace_o.packet.rs1_used &&
            !trace_o.trap) begin
          observed_trace.packet.rs1_value ^= 1;
          mutation_applied = 1;
        end
        terminal(observed_trace, w);
      end
      /* redirect addresses are checked before the producer follows the actual hardware signal. */
      if (redirect_valid_o) begin
        observed_redirect = redirect_pc_o;
        /* detector qualification corrupts only the observed redirect, never reference state. */
        if ($test$plusargs("mutate_target") && !mutation_applied) begin
          observed_redirect ^= 4;
          mutation_applied = 1;
        end
        check(observed_redirect == arch_pc, "redirect target disagreed with independent architectural PC");
        feed_pc = redirect_pc_o;
        redirects++;
      end
      /* accepted inputs receive monotonic independent identities before internal mutation. */
      if (input_accept) begin
        check(next_uid < CAPACITY, "accepted-input ledger exhausted");
        original[next_uid] = accepted_packet;
        live[next_uid] = 1;
        prepared[next_uid] = 0;
        load_completed[next_uid] = 0;
        load_values[next_uid] = 0;
        load_failed[next_uid] = 0;
        next_uid++;
        /* input acceptance advances only the speculative producer, not architectural PC. */
        if (!integration) feed_pc = accepted_packet.pc + {29'b0, accepted_packet.length};
      end
    end
    /* first valid is an irrevocable request and must name the oldest surviving load. */
    if (!owner && d_req_valid_o) begin
      id = int'(before_token[3].uid);
      check(launch_before && before_valid[3] && live[id] && original[id].op == OP_LOAD &&
            !expected_redirect, "unpermitted data-side-effect grant");
      /* no older unresolved control instruction may be bypassed by a memory launch. */
      for (int older = 0; older < int'(id); older++) begin
        check(!live[older], "memory launched before an older control instruction retired");
      end
      check(d_req_addr_o == original[id].mem_addr && d_req_wdata_o == original[id].mem_wdata &&
            d_req_tag_o == last_tag + 1, "load request differs from independent intent");
      owner = 1;
      accepted = 0;
      owner_uid = 9'(id);
      owner_addr = original[id].mem_addr;
      owner_tag = d_req_tag_o;
      last_tag++;
      owner_since = cycles;
      launches++;
    end
    check(mem_busy_o == owner && d_req_valid_o == (owner && !accepted),
          "load owner vanished or replayed its request");
    /* every accepted identity has exactly one live physical slot or a disposition. */
    for (int ledger = 0; ledger < CAPACITY; ledger++) begin
      count = 0;
      /* exact multiplicity prevents a duplicate from hiding another lost instruction. */
      for (int stage = 0; stage < 5; stage++) begin
        count += int'(stage_valid_o[stage] && stage_token_o[stage].uid == 64'(ledger));
      end
      check(count == int'(live[ledger]), "control instruction identity lost or duplicated");
    end
    /* every live preparation bit must have its independently recorded earlier edge. */
    for (int stage = 0; stage < 5; stage++) begin
      if (stage_valid_o[stage]) check(stage_token_o[stage].serial_ready == prepared[int'(stage_token_o[stage].uid)],
          "control serial preparation disagreed with independent ledger");
    end
    /* every advertised transfer must install precisely its previous stage owner. */
    for (int stage = 0; stage < 4; stage++) begin
      /* reset and redirect suppress all younger transfers rather than relabeling them. */
      if (before_transfer[stage]) check(before_valid[stage] && stage_valid_o[stage+1] &&
          stage_token_o[stage+1].uid == before_token[stage].uid,
          "pipeline transfer witness did not preserve its owner");
    end
    x = '0;
    /* inspect newly captured X operands after independent W retirement and bypass. */
    if (before_transfer[1] && stage_valid_o[2] && stage_token_o[2].p.op == OP_CONTROL) begin
      id = int'(stage_token_o[2].uid);
      x = predict(original[id], 9'(id));
      check((!x.use1 || defined_ref[x.rs1]) && (!x.use2 || defined_ref[x.rs2]),
            "test consumed an unspecified reset register value");
      check(stage_token_o[2].p.rs1_used == x.use1 && stage_token_o[2].p.rs2_used == x.use2 &&
            stage_token_o[2].p.rs1 == x.rs1 && stage_token_o[2].p.rs2 == x.rs2 &&
            stage_token_o[2].p.rs1_value == x.a && stage_token_o[2].p.rs2_value == x.b,
            "D-to-X used stale, poisoned or undefined-source annotations");
      check(stage_token_o[2].cf_kind == (x.legal && !original[id].fault ? x.kind : 0) &&
            stage_token_o[2].cf_cond == x.cond && stage_token_o[2].cf_imm == x.immediate &&
            !stage_token_o[2].cf_taken, "D-to-X control metadata mismatch");
    end
    /* X entry has not executed, so its final result and target are checked at W. */
    unused_capture_prediction = {x.writes, x.taken, x.fault, x.rd,
        x.result, x.next_pc, x.cause, x.mtval};
    /* a held X token must not recompute from a later register-bank value. */
    if (hold_i[2] && before_valid[2] && !expected_kill[2]) begin
      check(stage_valid_o[2] && stage_token_o[2] == before_token[2], "held X control token changed");
    end
    /* a held W token cannot publish a second link, redirect or modified packet. */
    if (hold_i[4] && before_valid[4] && !expected_kill[4]) begin
      check(stage_valid_o[4] && stage_token_o[4] == before_token[4], "held W control token changed");
    end
    /* each X-to-M control movement corresponds to one actual execution opportunity. */
    if (before_transfer[2] && before_token[2].p.op == OP_CONTROL) branch_transfers++;
    check(mstatus_o == 'h1800 && mtvec_o == vector_ref && mscratch_o == 0 &&
          mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref,
          "architectural trap state diverged");
    /* every register is observed so hidden early link writes cannot escape the trace check. */
    for (int reg_index = 0; reg_index < 32; reg_index++) begin
      inspect_reg_i = 5'(reg_index);
      #1;
      check(inspect_defined_o == defined_ref[reg_index], "GPR definedness changed before expected W commit");
      /* unspecified reset contents are never treated as architectural zero. */
      if (defined_ref[reg_index]) check(inspect_value_o == regs_ref[reg_index], "architectural GPR value mismatch");
    end
    /* fetch protocol observations are checked without making them the retirement oracle. */
    if (integration) begin
      check(!f_fatal && f_fatal_reason == 0, "fetch integration contained unexpectedly");
      check(f_accept == (f_req_valid && f_req_ready) && (!f_complete || f_rsp_valid),
            "fetch integration protocol witnesses disagreed");
      check(!f_drop || f_complete, "fetch discard lacked a matching reply");
      check(!f_discard || f_busy || !f_req_valid, "fetch discarded a newly offered live stream");
      check(!f_launch || feeding, "fetch launched after integration stopped");
      /* any delivered generation must be the currently selected fetch stream. */
      if (f_valid) begin
        check(f_generation == f_generation_current, "stale fetch generation reached adapter");
        check(f_fault || (f_kind == 2 && f_supported && f_bytes == 4),
              "integration fixture produced unexpected instruction framing");
      end
      instruction_reads += int'(f_accept);
    end
    check(!owner || cycles - owner_since < 100, "load response liveness bound expired");
    /* this fixture resets only with an empty manager, then spends one edge in recovery. */
    reset_recovery = cold_reset_i || hart_reset_i;
    clk_i = 0;
  endtask

  /* replace only the test program while retaining cumulative evidence counters. */
  task automatic begin_case(input logic [31:0] pc = 'h100);
    feeding = 0;
    integration = 0;
    integration_fault_seen = 0;
    hold_x_remaining = 0;
    hold_w_remaining = 0;
    hold_x_pc = '1;
    hold_w_pc = '1;
    response_delay = 0;
    memory_status = 0;
    memory_value = 0;
    check(!owner, "new case attempted to abandon a data request");
    /* each case starts with no stale program or accepted token identities. */
    for (int index = 0; index < PROGRAM_PARCELS; index++) program_valid[index] = 0;
    cold_reset_i = 1;
    tick();
    cold_reset_i = 0;
    tick();
    arch_pc = pc;
    feed_pc = pc;
    cases++;
  endtask

  /* publish immutable program packets before any simulated execution. */
  task automatic put(input packet_t p);
    program_packet[program_index(p.pc)] = p;
    program_valid[program_index(p.pc)] = 1;
  endtask

  /* bounded termination checks detect missing instructions even if they write no state. */
  task automatic run_program();
    integer clocks;
    feeding = 1;
    clocks = 0;
    /* run until the producer and every surviving pipeline or data owner are empty. */
    while ((program_valid[program_index(feed_pc)] || stage_valid_o != 0 || owner) && clocks < 500) begin
      tick();
      clocks++;
    end
    feeding = 0;
    check(clocks < 500 && !owner && stage_valid_o == 0 &&
          !program_valid[program_index(arch_pc)], "bounded architectural program did not complete");
  endtask

  /* every branch condition gets both outcomes and independent signed/unsigned edges. */
  initial begin : regression
    packet_t p;
    logic [2:0] condition;
    logic [31:0] a, b;
    integer clocks;
    int unsigned load_overlap_start;
    integration_jump = encode_jal(1, 'h2000);
    /* initialization does not define architectural x1 through x31. */
    for (int id = 0; id < CAPACITY; id++) begin
      live[id] = 0;
      original[id] = '0;
      load_completed[id] = 0;
      load_values[id] = 0;
      load_failed[id] = 0;
    end
    /* establish reset state before the checker reads any pre-edge DUT storage. */
    cold_reset_i = 1;
    #2;
    clk_i = 1;
    #2;
    clk_i = 0;
    /* map the six legal funct3 values independently of any decoder output. */
    for (int choice = 0; choice < 6; choice++) begin
      condition = choice < 2 ? 3'(choice) : 3'(choice + 2);
      /* each case uses its own independent architectural sequence. */
      for (int take = 0; take < 2; take++) begin
        begin_case();
        a = 'h80000000;
        b = 'h7fffffff;
        /* equality conditions receive exact equal and unequal edge values. */
        if (condition < 2) b = ((condition == 0) == (take != 0)) ? a : a + 1;
        /* reverse signed edges to obtain both outcomes without overflow arithmetic. */
        else if ((condition == 4 && take == 0) || (condition == 5 && take != 0)) begin
          a = 'h7fffffff;
          b = 'h80000000;
        end
        /* unsigned high-bit order deliberately differs from signed interpretation. */
        else if (condition >= 6) begin
          a = ((condition == 6) == (take != 0)) ? 1 : 'hffffffff;
          b = ((condition == 6) == (take != 0)) ? 'hffffffff : 1;
        end
        put(packet('h100, OP_RESULT, 1, a));
        put(packet('h104, OP_RESULT, 2, b));
        put(control('h108, encode_branch(condition, 1, 2, 12)));
        put(packet('h10c, OP_RESULT, 3, 'h1111));
        put(control('h110, encode_jal(0, 8)));
        put(packet('h114, OP_RESULT, 3, 'h2222));
        put(packet('h118, OP_RESULT, 4, 'h3333));
        hold_x_pc = 'h108;
        hold_x_remaining = 3;
        hold_w_pc = 'h108;
        hold_w_remaining = 3;
        run_program();
        check(regs_ref[3] == (take != 0 ? 'h2222 : 'h1111), "branch fixture did not exercise requested outcome");
      end
    end
    /* a nearer older writer must hide the farther writer, then bypass at W. */
    begin_case();
    put(packet('h100, OP_RESULT, 1, 0));
    put(packet('h104, OP_RESULT, 1, 1));
    put(control('h108, encode_branch(1, 1, 0, 8)));
    p = packet('h10c, OP_STORE);
    p.mem_addr = 'h40000000;
    p.mem_wdata = 'hbadc0ffe;
    put(p);
    put(packet('h110, OP_RESULT, 5, 'h55));
    run_program();
    /* write-only CSR packets still produce a real zero GPR result for dependent branches. */
    begin_case();
    put(packet('h100, OP_RESULT, 1, 'hffffffff));
    p = packet('h104, OP_CSR, 1);
    p.csr_addr = 'h305;
    p.csr_op = CSR_WRITE;
    p.csr_write = 1;
    p.csr_read = 0;
    p.csr_source = 'h800;
    put(p);
    put(control('h108, encode_branch(0, 1, 0, 8)));
    p = packet('h10c, OP_STORE);
    p.mem_addr = 'h40000000;
    put(p);
    put(packet('h110, OP_RESULT, 12, 'hcc));
    run_program();
    /* ordinary CSR reads publish their independently maintained old value before the consumer. */
    begin_case();
    p = packet('h100, OP_CSR);
    p.csr_addr = 'h305;
    p.csr_op = CSR_WRITE;
    p.csr_write = 1;
    p.csr_source = 'h800;
    put(p);
    p = packet('h104, OP_CSR, 1);
    p.csr_addr = 'h305;
    p.csr_op = CSR_READ;
    p.csr_read = 1;
    put(p);
    put(control('h108, encode_branch(1, 1, 0, 8)));
    p = packet('h10c, OP_STORE);
    p.mem_addr = 'h40000000;
    put(p);
    put(packet('h110, OP_RESULT, 13, 'hdd));
    run_program();
    /* JALR must capture an old source before writing a link to the same register. */
    begin_case();
    put(packet('h100, OP_RESULT, 1, 'h111));
    put(control('h104, encode_jalr(1, 1, 0)));
    put(packet('h108, OP_STORE));
    put(packet('h110, OP_RESULT, 6, 'h66));
    hold_w_pc = 'h104;
    hold_w_remaining = 5;
    run_program();
    check(regs_ref[1] == 'h108, "JALR rd=rs1 used its new link as the target source");
    /* x0 is a real JALR source and never a writing link destination. */
    begin_case();
    put(control('h100, encode_jalr(0, 0, 'h110)));
    put(packet('h110, OP_RESULT, 14, 'hee));
    run_program();
    /* bit zero is cleared before testing the remaining target alignment bit. */
    begin_case();
    put(packet('h100, OP_RESULT, 1, 'h113));
    put(control('h104, encode_jalr(2, 1, 0)));
    put(packet('h112, OP_RESULT, 14, 'he1));
    run_program();
    check(C_ENABLED ? regs_ref[2] == 'h108 : !defined_ref[2],
          "JALR alignment did not follow low-bit clearing");
    /* alignment checks use the taken target after JALR bit-zero clearing. */
    begin_case();
    put(control('h100, encode_jal(1, 2)));
    put(packet('h102, OP_RESULT, 7, 'h77));
    run_program();
    check(C_ENABLED ? regs_ref[1] == 'h104 : !defined_ref[1], "misaligned jump wrote or lost a link");
    /* an untaken target with bit one set must not raise an alignment fault. */
    begin_case();
    put(control('h100, encode_branch(1, 0, 0, 2)));
    put(packet('h104, OP_RESULT, 8, 'h88));
    run_program();
    /* trusted C.JAL expansion preserves its original two-byte link and raw bits. */
    begin_case();
    p = control('h100, encode_jal(1, 6));
    p.raw = 'h2019;
    p.raw_valid = 3;
    p.length = 2;
    p.expanded_valid = 1;
    p.expanded = encode_jal(1, 6);
    put(p);
    put(packet('h106, OP_RESULT, 9, 'h99));
    run_program();
    check(C_ENABLED ? regs_ref[1] == 'h102 : !defined_ref[1], "trusted C link did not use original length");
    /* trusted C.JALR keeps its captured old source while retiring a two-byte link. */
    begin_case();
    put(packet('h100, OP_RESULT, 1, 'h111));
    p = control('h104, encode_jalr(1, 1, 0));
    p.raw = 'h9082;
    p.raw_valid = 3;
    p.length = 2;
    p.expanded_valid = 1;
    p.expanded = encode_jalr(1, 1, 0);
    put(p);
    put(packet('h110, OP_RESULT, 9, 'h91));
    run_program();
    check(regs_ref[1] == (C_ENABLED ? 'h106 : 'h111), "trusted C.JALR used wrong source or link length");
    /* the same branch PC executes twice with a backward displacement and different outcomes. */
    begin_case();
    put(packet('h100, OP_RESULT, 1, 0));
    put(control('h104, encode_jal(0, 12)));
    put(packet('h108, OP_RESULT, 1, 1));
    put(control('h10c, encode_jal(0, 4)));
    put(control('h110, encode_branch(0, 1, 0, -32'd8)));
    put(packet('h114, OP_RESULT, 15, 'hf1));
    run_program();
    check(regs_ref[1] == 1 && regs_ref[15] == 'hf1, "backward branch loop did not exit independently");
    /* illegal OP_CONTROL instructions cannot become pre-resolved diagnostic redirects. */
    begin_case();
    put(control('h100, 'h00000013));
    run_program();
    /* malformed control metadata is rejected independently of valid-looking instruction bits. */
    for (int variant = 0; variant < 8; variant++) begin
      begin_case('h102);
      p = control('h102, encode_jal(1, 8));
      /* each variant violates one width or control encoding requirement. */
      case (variant)
        0: p.length = 0;
        1: p.raw_valid = 7;
        2: p.expanded_valid = 1;
        3: p.raw = encode_branch(2, 0, 0, 8);
        /* a short original requires an explicit expanded instruction. */
        4: begin
          p.length = 2;
          p.raw_valid = 3;
          p.raw = 'h9082;
        end
        /* short original instructions cannot carry upper raw bytes. */
        5: begin
          p.length = 2;
          p.raw_valid = 3;
          p.expanded_valid = 1;
          p.expanded = encode_jal(1, 8);
          p.raw = 'h10009082;
        end
        /* a trusted short original must have a compressed-length prefix. */
        6: begin
          p.length = 2;
          p.raw_valid = 3;
          p.expanded_valid = 1;
          p.expanded = encode_jal(1, 8);
          p.raw = 'h9083;
        end
        /* a supplied fetch fault wins over a valid control encoding. */
        default: begin
          p.fault = 1;
          p.cause = 1;
          p.mtval = 'h104;
        end
      endcase
      put(p);
      run_program();
      check(!defined_ref[1] && cause_ref == (variant == 7 ? 1 : 2) &&
            epc_ref == (C_ENABLED ? 'h102 : 'h100), "malformed control or incoming fault priority failed");
    end
    /* a delayed load either supplies the real branch operand or traps first. */
    for (int fail = 0; fail < 2; fail++) begin
      begin_case();
      p = packet('h100, OP_CSR);
      p.csr_addr = 'h305;
      p.csr_op = CSR_WRITE;
      p.csr_write = 1;
      p.csr_source = 'h800;
      put(p);
      p = packet('h104, OP_LOAD, 1);
      p.mem_addr = 'h20000000;
      put(p);
      put(control('h108, encode_branch(4, 1, 0, 8)));
      p = packet('h10c, OP_STORE);
      p.mem_addr = 'h40000000;
      put(p);
      put(packet('h110, OP_RESULT, 10, 'haa));
      put(packet('h800, OP_RESULT, 11, 'hbb));
      response_delay = 7;
      memory_value = 'h80000000;
      memory_status = 2'(fail);
      run_program();
      check(fail != 0 ? (!defined_ref[1] && regs_ref[11] == 'hbb) : regs_ref[10] == 'haa,
            "older delayed load did not control branch disposition");
    end
    /* an independent jump can occupy X while an older load owns the data interface. */
    for (int fail = 0; fail < 2; fail++) begin
      begin_case();
      load_overlap_start = x_behind_load;
      p = packet('h100, OP_CSR);
      p.csr_addr = 'h305;
      p.csr_op = CSR_WRITE;
      p.csr_write = 1;
      p.csr_source = 'h800;
      put(p);
      p = packet('h104, OP_LOAD, 1);
      p.mem_addr = 'h20000000;
      put(p);
      put(control('h108, encode_jal(2, 8)));
      p = packet('h10c, OP_STORE);
      p.mem_addr = 'h40000000;
      put(p);
      put(packet('h110, OP_RESULT, 10, 'haa));
      put(packet('h800, OP_RESULT, 11, 'hbb));
      response_delay = 7;
      memory_value = 'h12345678;
      memory_status = 2'(fail);
      run_program();
      check(DIAGNOSTIC || x_behind_load > load_overlap_start,
            "independent jump never occupied X behind its older pending load");
      check(fail != 0 ? (!defined_ref[2] && regs_ref[11] == 'hbb) :
            (regs_ref[2] == 'h10c && regs_ref[10] == 'haa),
            "older load fault lost priority over an independent younger jump");
    end
    /* real fetch must report the denied target after a successful JAL and link commit. */
    begin_case('h1000);
    integration = 1;
    feeding = 1;
    clocks = 0;
    /* the adapter stops only after the independently checked target trap. */
    while ((!integration_fault_seen || stage_valid_o != 0 || f_busy) && clocks < 200) begin
      tick();
      clocks++;
    end
    check(integration_fault_seen && clocks < 200 && !owner && !f_busy,
          "fetch-to-control target access-fault scenario did not finish");
    integration = 0;
    feeding = 0;
    check(held_x != 0 && held_w != 0 && branch_transfers >= 20 && target_faults == 1,
          "control-flow coverage was incomplete");
    check(DIAGNOSTIC || (hazard_stalls != 0 && bypasses != 0 && nearest_stalls != 0 && x_behind_load != 0),
          "pipeline dependency or retirement-bypass coverage was incomplete");
    check(launches == completions, "control-flow test left a data owner unresolved");
    $display("PASS control-flow C=%0d diagnostic=%0d cases=%0d cycles=%0d retirements=%0d traps=%0d redirects=%0d kills=%0d hazards=%0d bypasses=%0d nearest=%0d X_hold=%0d W_hold=%0d loads=%0d target_faults=%0d I_reads=%0d X_behind_load=%0d",
             C_ENABLED, DIAGNOSTIC, cases, cycles, retirements, traps, redirects, kills,
             hazard_stalls, bypasses, nearest_stalls, held_x, held_w, launches, target_faults, instruction_reads, x_behind_load);
    $finish;
  end
endmodule

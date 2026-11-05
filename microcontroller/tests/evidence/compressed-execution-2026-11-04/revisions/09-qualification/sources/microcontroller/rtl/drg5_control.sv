`include "drg5_datapath_defs.svh"

/* execute checked base instructions; commit only the oldest W token. */
module drg5_control #(
  parameter bit DIAGNOSTIC = 1'b1,
  parameter bit FORWARDING = 1'b1,
  parameter bit C_ENABLED = 1'b0,
  parameter bit TEST_REGIONS = 1'b0,
  parameter bit IRAM_WRITE = 1'b0,
  parameter bit TIMER_ENABLED = 1'b0,
  parameter bit IRQ_ENABLED = 1'b0,
  parameter bit M_ENABLED = 1'b0,
  parameter logic [31:0] RESET_PC = 32'b0,
  parameter integer D_MAX_WAIT_CYCLES = 128
) (
  input logic clk_i,
  input logic cold_reset_i, isolated_i, hart_reset_i,
  input logic [31:0] mip_levels_i,
  input logic fetch_busy_i,
  output logic entry_pending_o, idle_o,
  output logic irq_valid_o,
  output logic [31:0] irq_pc_o, irq_cause_o,
  input logic [4:0] hold_i,
  input logic in_valid_i,
  output logic in_ready_o,
  input drg5_control_pkg::packet_t in_packet_i,
  input logic flush_valid_i,
  output logic flush_ready_o,
  input logic [31:0] flush_pc_i,
  output logic flush_aborted_o,
  output logic redirect_valid_o,
  output logic [31:0] redirect_pc_o,
  output logic d_req_valid_o,
  input logic d_req_ready_i,
  output logic [31:0] d_req_addr_o, d_req_wdata_o,
  output logic d_req_write_o,
  output logic [1:0] d_req_size_o,
  output logic [3:0] d_req_wstrb_o,
  output logic [31:0] d_req_tag_o,
  input logic d_rsp_valid_i,
  output logic d_rsp_ready_o,
  input logic [31:0] d_rsp_tag_i, d_rsp_rdata_i,
  input logic [1:0] d_rsp_status_i,
  output logic mem_launch_o, mem_busy_o, fatal_o,
  output drg5_control_pkg::fatal_record_t fatal_record_o,
  output logic [4:0] stage_valid_o,
  output drg5_control_pkg::token_t stage_token_o [0:4],
  output logic [3:0] transfer_o,
  output logic [4:0] kill_valid_o,
  output logic [63:0] kill_uid_o [0:4],
  output drg5_control_pkg::trace_t trace_o,
  input logic [4:0] inspect_reg_i,
  output logic [31:0] inspect_value_o,
  output logic inspect_defined_o,
  output logic [31:0] mstatus_o, mtvec_o, mscratch_o,
  output logic [31:0] mepc_o, mcause_o, mtval_o,
  output logic [31:0] mie_o, mip_o, mcountinhibit_o,
  output logic [63:0] mcycle_o, minstret_o
);
  import drg5_control_pkg::*;
  localparam int F = 0, D = 1, X = 2, M = 3, W = 4;
  localparam int D_AGE_BITS = D_MAX_WAIT_CYCLES < 2 ? 1 : $clog2(D_MAX_WAIT_CYCLES + 1);
  /* retain unsafe completed transactions until isolation. */
  typedef enum logic [1:0] {BUS_FREE, BUS_OFFER, BUS_WAIT, BUS_RECOVER} bus_state_t;
  token_t slot_q [0:4], slot_d [0:4];
  logic [4:0] valid_q, valid_d, kill;
  logic [31:0] regs_q [0:31];
  logic [31:0] defined_q;
  logic [63:0] uid_q, order_q;
  logic recovery_q, flush_q;
  logic [31:0] flush_pc_q;
  bus_state_t bus_q;
  token_t owner_q;
  logic [31:0] tag_q;
  logic orphan_q;
  logic fatal_q, fatal_now, bus_timeout, bad_payload, uid_exhausted;
  logic [D_AGE_BITS-1:0] bus_age_q;
  logic [31:0] owner_lane_mask;
  logic [3:0] owner_byte_mask;
  logic flush_accept, flush_active, flush_finish, protect_m, protect_w;
  logic w_done, w_fault, w_redirect, csr_legal;
  logic [31:0] w_cause, w_tval, w_value, w_next;
  logic [31:0] csr_old, csr_new, csr_read_value;
  logic bus_accept, bus_complete, bus_bad, bus_deliver;
  logic launch, tag_exhausted, mem_local_fault, unused_mem_misaligned, mem_allowed;
  logic [31:0] mem_cause, load_value;
  logic [31:0] d_word, d_immediate, d_rs1_value, d_rs2_value;
  logic [3:0] d_kind;
  logic [2:0] d_imm_kind, d_cond;
  logic [4:0] d_rs1, d_rs2, d_rd;
  logic d_legal, d_rs1_used, d_rs2_used, d_rd_write, d_imm_valid;
  logic d_control_ok, d_memory_ok, d_base_ok, d_execute_ok, d_hazard, w_gpr_write;
  logic d_machine_ok, d_system_csr, d_system_mret, d_system_wfi, d_muldiv;
  logic d_short_ok, d_c_legal, unused_c_hint;
  logic [1:0] unused_c_class;
  logic [31:0] d_expanded;
  logic md_start, md_busy, md_valid;
  logic [31:0] md_result;
  logic [63:0] md_uid;
  logic d_operand_rs1_used, d_operand_rs2_used;
  logic [4:0] d_operand_rs1, d_operand_rs2;
  logic [3:0] d_alu_op;
  logic d_a_pc, d_b_imm, d_load_signed;
  logic [1:0] d_mem_size;
  logic x_cf_valid, x_cf_taken, x_cf_misaligned;
  logic [31:0] x_cf_target, x_cf_next, x_cf_link;
  logic [57:0] unused_owner_control;
  logic x_mem_allowed, unused_x_misaligned;
  logic [31:0] x_mem_addr, x_mem_cause, x_mem_wdata;
  logic [31:0] unused_x_load, unused_m_wdata, unused_m_load;
  logic [31:0] unused_owner_cause, unused_owner_wdata;
  logic [3:0] unused_x_strobe, unused_m_strobe, unused_owner_strobe;
  logic unused_owner_allowed, unused_owner_misaligned;
  logic [31:0] x_alu_a, x_alu_b, x_alu_value;
  logic x_alu_valid, unused_x_eq, unused_x_lt, unused_x_ltu;
  logic [2:0] producer_valid, producer_write, producer_ready;
  logic [14:0] producer_rd;
  logic [95:0] producer_value;
  logic [1:0] unused_rs1_select, unused_rs2_select;
  logic unused_rs1_match, unused_rs2_match;
  logic [4:0] barrier, barrier_older;
  logic [4:0] admitted, older_unadmitted;
  logic irq_drain_q, idle_q, irq_select, irq_wait, irq_safe, irq_enter, wfi_sleep;
  logic post_mie_global, admit_x, admit_m_fault;
  logic [31:0] post_mie, local_pending, irq_cause, boundary_pc_q;

  /* a deadline is inclusive and must contain at least one sampling edge. */
  initial begin
    assert (D_MAX_WAIT_CYCLES >= 1) else $fatal(1, "invalid data deadline");
  end

  /* validate original bytes independently of the optional decoded C micro-op. */
  function automatic logic control_width_ok(input logic [2:0] length,
      input logic [3:0] raw_valid, input logic expanded_valid, short_original);
    return (length == 4 && raw_valid == 4'hf && !expanded_valid) ||
           (C_ENABLED && length == 2 && raw_valid == 4'h3 && expanded_valid && short_original);
  endfunction

  /* only internally decoded short instructions may use ordinary execution paths. */
  function automatic logic execution_width_ok(input logic [2:0] length,
      input logic [3:0] raw_valid, input logic decoded_short);
    return (length == 4 && raw_valid == 4'hf) ||
        (C_ENABLED && decoded_short && length == 2 && raw_valid == 4'h3);
  endfunction

  /* only operation classes with an actual GPR destination create dependencies. */
  function automatic logic writer(input op_t op, input logic rd_write, input logic [4:0] rd);
    return rd_write && rd != 0 &&
        (op == OP_RESULT || op == OP_LOAD || op == OP_CSR || op == OP_REDIRECT || op == OP_CONTROL);
  endfunction

  /* recognize base barriers before D normalization without trusting supplied execution fields. */
  function automatic logic serializing(input logic base_serial, input op_t op,
      input logic fault, input logic [2:0] length, input logic [3:0] raw_valid,
      input logic expanded_valid, input logic [31:0] raw);
    return base_serial || op == OP_FENCE || op == OP_CSR || op == OP_MRET ||
        (IRQ_ENABLED && op == OP_WFI) ||
        (C_ENABLED && op == OP_MACHINE && !fault && length == 2 && raw_valid == 3 &&
         !expanded_valid && raw == 32'h00009002) ||
        ((op == OP_BASE || op == OP_MACHINE) && !fault && length == 4 && raw_valid == 4'hf && !expanded_valid &&
         ((raw[6:0] == 7'h0f && raw[14:12] == 0) ||
          raw == 32'h00000073 || raw == 32'h00100073 ||
          (op == OP_MACHINE && raw[6:0] == 7'h73 &&
           (raw == 32'h30200073 || (IRQ_ENABLED && raw == 32'h10500073) || raw[13:12] != 0))));
  endfunction

  /* memory owners never consume the token's control-flow metadata. */
  assign unused_owner_control = {owner_q.admitted, owner_q.alu_decoded, owner_q.alu_a_pc, owner_q.alu_b_imm,
                                  owner_q.alu_op, owner_q.md_decoded, owner_q.md_issued, owner_q.md_done, owner_q.md_op,
                                  owner_q.base_serial, owner_q.serial_ready,
                                  owner_q.mem_decoded, owner_q.c_decoded, owner_q.cf_kind, owner_q.cf_cond,
                                  owner_q.cf_imm, owner_q.cf_taken};
  /* decode raw C inside the core; trusted expanded control packets remain diagnostic-only. */
  generate
    /* disabled C builds contain no decompressor or short architectural entry. */
    if (C_ENABLED) begin : gen_decompress
      drg5_decompress decompress (
        .instr_i(slot_q[D].p.raw[15:0]), .expanded_o(d_expanded), .legal_o(d_c_legal),
        .hint_o(unused_c_hint), .class_o(unused_c_class)
      );
    /* constants preserve the original non-C configuration. */
    end else begin : gen_no_decompress
      assign d_expanded = 0;
      assign d_c_legal = 0;
      assign unused_c_hint = 0;
      assign unused_c_class = 0;
    end
  endgenerate
  assign d_short_ok = C_ENABLED && slot_q[D].p.op == OP_MACHINE && slot_q[D].p.length == 2 &&
      slot_q[D].p.raw_valid == 3 && !slot_q[D].p.expanded_valid &&
      slot_q[D].p.raw[31:16] == 0 && d_c_legal;
  /* packet annotations never override raw-machine instruction semantics. */
  assign d_word = slot_q[D].p.length == 2 ?
      (slot_q[D].p.op == OP_MACHINE ? d_expanded : slot_q[D].p.expanded) : slot_q[D].p.raw;
  drg5_decoder control_decode (
    .instr_i(d_word), .legal_o(d_legal), .kind_o(d_kind), .alu_op_o(d_alu_op),
    .imm_kind_o(d_imm_kind), .rs1_used_o(d_rs1_used), .rs2_used_o(d_rs2_used),
    .rd_write_o(d_rd_write), .rs1_o(d_rs1), .rs2_o(d_rs2), .rd_o(d_rd),
    .a_pc_o(d_a_pc), .b_imm_o(d_b_imm), .branch_cond_o(d_cond),
    .mem_size_o(d_mem_size), .load_signed_o(d_load_signed)
  );
  /* generate B/J control offsets and signed I/S data or JALR immediates. */
  drg5_immediate control_immediate (
    .instr_i(d_word), .kind_i(d_imm_kind), .value_o(d_immediate), .valid_o(d_imm_valid)
  );
  assign d_control_ok = control_width_ok(slot_q[D].p.length, slot_q[D].p.raw_valid,
      slot_q[D].p.expanded_valid, slot_q[D].p.raw[31:16] == 0 && slot_q[D].p.raw[1:0] != 3) &&
      d_legal && d_imm_valid &&
      (d_kind == `DRG5_KIND_BRANCH || d_kind == `DRG5_KIND_JAL || d_kind == `DRG5_KIND_JALR);
  /* memory execution initially accepts complete original 32-bit instructions only. */
  assign d_memory_ok = slot_q[D].p.length == 4 && slot_q[D].p.raw_valid == 4'hf &&
      !slot_q[D].p.expanded_valid && d_legal && d_imm_valid &&
      (d_kind == `DRG5_KIND_LOAD || d_kind == `DRG5_KIND_STORE);
  /* the complete base entry rejects extensions and short expanded instructions. */
  assign d_base_ok = slot_q[D].p.length == 4 && slot_q[D].p.raw_valid == 4'hf &&
      !slot_q[D].p.expanded_valid && d_legal && d_imm_valid;
  /* only the machine entry admits the six exact CSR funct3 values and exact MRET. */
  assign d_system_csr = slot_q[D].p.op == OP_MACHINE && d_word[6:0] == 7'h73 &&
      d_word[13:12] != 0;
  assign d_system_mret = slot_q[D].p.op == OP_MACHINE && d_word == 32'h30200073;
  assign d_system_wfi = IRQ_ENABLED && slot_q[D].p.op == OP_MACHINE && d_word == 32'h10500073;
  /* M uses every funct3 only under its exact opcode and funct7. */
  assign d_muldiv = M_ENABLED && slot_q[D].p.op == OP_MACHINE &&
      d_word[6:0] == 7'h33 && d_word[31:25] == 7'h01;
  assign d_machine_ok = ((slot_q[D].p.length == 4 && slot_q[D].p.raw_valid == 4'hf &&
      !slot_q[D].p.expanded_valid) || d_short_ok) &&
      ((d_legal && d_imm_valid) || d_system_csr || d_system_mret || d_system_wfi || d_muldiv);
  assign d_execute_ok = (slot_q[D].p.op == OP_CONTROL && d_control_ok) ||
                         (slot_q[D].p.op == OP_MEMORY && d_memory_ok) ||
                         (slot_q[D].p.op == OP_BASE && d_base_ok) ||
                         (slot_q[D].p.op == OP_MACHINE && d_machine_ok);
  /* immediate CSR fields are constants, never GPR dependencies. */
  assign d_operand_rs1_used = d_muldiv || (d_system_csr ? !d_word[14] : d_rs1_used);
  assign d_operand_rs2_used = d_muldiv || (d_system_csr ? 1'b0 : d_rs2_used);
  assign d_operand_rs1 = d_muldiv ? d_word[19:15] : d_system_csr ? (d_word[14] ? 5'b0 : d_word[19:15]) : d_rs1;
  assign d_operand_rs2 = d_muldiv ? d_word[24:20] : d_system_csr ? 5'b0 : d_rs2;
  assign w_gpr_write = w_done && !w_fault &&
      writer(slot_q[W].p.op, slot_q[W].p.rd_write, slot_q[W].p.rd);

  /* supply producer identity independently of readiness so a newer fault cannot expose an old value. */
  always_comb begin
    producer_valid = 0;
    producer_write = 0;
    producer_ready = 0;
    producer_rd = 0;
    producer_value = 0;
    /* packed lanes are ordered newest X, then M, then oldest W. */
    for (int stage = X; stage <= W; stage++) begin
      producer_valid[stage-X] = valid_q[stage];
      producer_write[stage-X] = writer(slot_q[stage].p.op, slot_q[stage].p.rd_write, slot_q[stage].p.rd);
      producer_rd[5*(stage-X) +: 5] = slot_q[stage].p.rd;
      producer_value[32*(stage-X) +: 32] = slot_q[stage].p.result;
    end
    /* X arithmetic and link values are complete; a load has no result yet. */
    if (!slot_q[X].p.fault) begin
      /* malformed diagnostic result packets must wait for their precise fault. */
      if (slot_q[X].p.op == OP_RESULT && execution_width_ok(slot_q[X].p.length, slot_q[X].p.raw_valid, slot_q[X].c_decoded)) begin
        producer_ready[0] = slot_q[X].md_decoded ? slot_q[X].md_done :
                            !slot_q[X].alu_decoded || x_alu_valid;
        producer_value[0 +: 32] = slot_q[X].alu_decoded ? x_alu_value : slot_q[X].p.result;
      end
      /* a misaligned control target cannot supply its suppressed link. */
      if (slot_q[X].p.op == OP_CONTROL) begin
        producer_ready[0] = x_cf_valid && !x_cf_misaligned;
        producer_value[0 +: 32] = x_cf_link;
      end
    end
    /* load results become sources only after a captured successful response. */
    if (!slot_q[M].p.fault) begin
      producer_ready[1] = ((slot_q[M].p.op == OP_RESULT || slot_q[M].p.op == OP_LOAD) &&
                           execution_width_ok(slot_q[M].p.length, slot_q[M].p.raw_valid, slot_q[M].c_decoded) &&
                           (slot_q[M].p.op != OP_LOAD || slot_q[M].mem_done)) ||
                          slot_q[M].p.op == OP_CONTROL;
    end
    /* dynamic CSR previews remain unavailable until their actual successful commit. */
    producer_ready[2] = FORWARDING && slot_q[W].p.op != OP_CSR ? !w_fault : w_gpr_write;
    producer_value[64 +: 32] = w_value;
  end

  /* capture each operand from its nearest matching producer or stall on that producer. */
  drg5_forward #(.FORWARDING(FORWARDING)) operand_forward (
    .rs1_i(d_operand_rs1), .rs2_i(d_operand_rs2),
    .rs1_used_i(valid_q[D] && !slot_q[D].p.fault && d_execute_ok && d_operand_rs1_used),
    .rs2_used_i(valid_q[D] && !slot_q[D].p.fault && d_execute_ok && d_operand_rs2_used),
    .rs1_rf_value_i(regs_q[d_operand_rs1]), .rs2_rf_value_i(regs_q[d_operand_rs2]),
    .producer_valid_i(producer_valid), .producer_write_i(producer_write),
    .producer_ready_i(producer_ready), .producer_rd_i(producer_rd), .producer_value_i(producer_value),
    .rs1_value_o(d_rs1_value), .rs2_value_o(d_rs2_value), .hazard_o(d_hazard),
    .rs1_select_o(unused_rs1_select), .rs2_select_o(unused_rs2_select),
    .rs1_match_o(unused_rs1_match), .rs2_match_o(unused_rs2_match)
  );

  /* barriers hold only younger work and block input through their terminal edge. */
  always_comb begin
    barrier = 0;
    barrier_older = 0;
    /* every stage can identify its own barrier before normalized execution. */
    for (int stage = F; stage <= W; stage++) begin
      barrier[stage] = valid_q[stage] && serializing(slot_q[stage].base_serial, slot_q[stage].p.op,
          slot_q[stage].p.fault, slot_q[stage].p.length, slot_q[stage].p.raw_valid,
          slot_q[stage].p.expanded_valid, slot_q[stage].p.raw);
    end
    /* an instruction never blocks its own progress. */
    for (int stage = F; stage < W; stage++) begin
      /* all higher stages contain older instructions in this in-order pipeline. */
      for (int older = stage + 1; older <= W; older++) begin
        barrier_older[stage] |= barrier[older];
      end
    end
  end

  /* observe post-retirement enables before granting any younger instruction attempt. */
  always_comb begin
    post_mie_global = mstatus_o[3];
    post_mie = mie_o;
    /* ordered synchronous exceptions defeat asynchronous entry on this edge. */
    if (w_done) begin
      /* trap entry clears MIE before a pending interrupt can become eligible. */
      if (w_fault) post_mie_global = 0;
      /* MRET restores MIE before the return target can be admitted. */
      else if (slot_q[W].p.op == OP_MRET) post_mie_global = mstatus_o[7];
      /* legalized CSR writes take effect before younger launch arbitration. */
      else if (slot_q[W].p.op == OP_CSR && slot_q[W].p.csr_write) begin
        /* only these two writable CSRs alter eligibility. */
        if (slot_q[W].p.csr_addr == 12'h300) post_mie_global = csr_new[3];
        /* mip writes are ignored; its live platform levels remain authoritative. */
        if (slot_q[W].p.csr_addr == 12'h304) post_mie = csr_new;
      end
    end
    admitted = 0;
    older_unadmitted = 0;
    /* allocation alone never makes an instruction non-preemptible. */
    for (int stage = F; stage <= W; stage++) begin
      admitted[stage] = valid_q[stage] && slot_q[stage].admitted;
      /* only the oldest unadmitted token may start an attempt. */
      for (int older = stage + 1; older <= W; older++) begin
        older_unadmitted[stage] |= valid_q[older] && !slot_q[older].admitted;
      end
    end
    local_pending = mie_o & mip_o & 32'h888;
    /* priority is external, software, then timer, sampled again at actual entry. */
    if (local_pending[11]) irq_cause = 32'h8000000b;
    else if (local_pending[3]) irq_cause = 32'h80000003;
    else irq_cause = 32'h80000007;
  end
  assign irq_select = IRQ_ENABLED && post_mie_global && |(post_mie & mip_o & 32'h888) &&
                      !recovery_q && !fatal_now && !cold_reset_i && !hart_reset_i;
  assign irq_wait = IRQ_ENABLED && (irq_drain_q || irq_select);
  /* suppress a first fetch offer on the edge that retires a sleeping WFI. */
  assign wfi_sleep = IRQ_ENABLED && w_done && !w_fault && slot_q[W].p.op == OP_WFI && !(|local_pending);
  assign entry_pending_o = IRQ_ENABLED && (irq_wait || idle_q || wfi_sleep);
  assign idle_o = IRQ_ENABLED && idle_q;
  assign irq_safe = !(|admitted) && bus_q == BUS_FREE && !md_busy && !fetch_busy_i &&
                    !flush_active && !recovery_q && !fatal_now && !uid_exhausted && !cold_reset_i && !hart_reset_i;
  assign irq_enter = IRQ_ENABLED && irq_drain_q && irq_safe && mstatus_o[3] && |local_pending;
  /* admitted arithmetic drains even when a later interrupt blocks all new grants. */
  assign admit_x = IRQ_ENABLED && valid_q[X] && !slot_q[X].admitted && !older_unadmitted[X] &&
      !hold_i[X] && !barrier_older[X] && !entry_pending_o && !flush_active &&
      (!slot_q[X].md_decoded || !md_busy) &&
      !fatal_now && !cold_reset_i && !hart_reset_i &&
      !(w_done && (w_fault || w_redirect)) &&
      (slot_q[X].p.fault || (!barrier[X] && slot_q[X].p.op != OP_LOAD && slot_q[X].p.op != OP_STORE));
  /* an already-detected local fault starts at M without exposing a bus request. */
  assign admit_m_fault = IRQ_ENABLED && valid_q[M] && !slot_q[M].admitted && slot_q[M].p.fault &&
      !older_unadmitted[M] && !hold_i[M] && !barrier_older[M] && !entry_pending_o &&
      !flush_active && !fatal_now && !cold_reset_i && !hart_reset_i &&
      !(w_done && (w_fault || w_redirect));

  /* an idle unit accepts one admitted X job; interrupts cannot start a replacement. */
  assign md_start = M_ENABLED && valid_q[X] && slot_q[X].md_decoded &&
      !slot_q[X].md_issued && !slot_q[X].p.fault && !md_busy && !recovery_q &&
      !hold_i[X] && !barrier_older[X] && !flush_active && !fatal_now &&
      !cold_reset_i && !hart_reset_i && !(w_done && (w_fault || w_redirect)) &&
      (!IRQ_ENABLED || admit_x);
  /* a killed job finishes independently; UID matching prevents stale delivery. */
  generate
    if (M_ENABLED) begin : gen_muldiv
      drg5_muldiv arithmetic_unit (
        .clk_i(clk_i), .cold_reset_i(cold_reset_i), .start_i(md_start),
        .op_i(slot_q[X].md_op), .lhs_i(slot_q[X].p.rs1_value), .rhs_i(slot_q[X].p.rs2_value),
        .uid_i(slot_q[X].uid), .ready_i(1'b1), .busy_o(md_busy), .valid_o(md_valid),
        .result_o(md_result), .uid_o(md_uid)
      );
    /* the base configuration contains no arithmetic job manager. */
    end else begin : gen_no_muldiv
      assign md_busy = 0;
      assign md_valid = 0;
      assign md_result = 0;
      assign md_uid = 0;
    end
  endgenerate

  /* ALU operands use the same captured sources as branches, addresses and store data. */
  assign x_alu_a = slot_q[X].alu_a_pc ? slot_q[X].p.pc : slot_q[X].p.rs1_value;
  assign x_alu_b = slot_q[X].alu_b_imm ? slot_q[X].cf_imm : slot_q[X].p.rs2_value;
  drg5_alu execute_alu (
    .a_i(x_alu_a), .b_i(x_alu_b), .op_i(slot_q[X].alu_op),
    .result_o(x_alu_value), .valid_o(x_alu_valid), .eq_o(unused_x_eq),
    .lt_signed_o(unused_x_lt), .lt_unsigned_o(unused_x_ltu)
  );

  /* held X operands produce a stable candidate without publishing a redirect. */
  drg5_branch #(.C_ENABLED(C_ENABLED)) control_branch (
    .pc_i(slot_q[X].p.pc), .rs1_i(slot_q[X].p.rs1_value), .rs2_i(slot_q[X].p.rs2_value),
    .imm_i(slot_q[X].cf_imm), .kind_i(slot_q[X].cf_kind), .cond_i(slot_q[X].cf_cond),
    .length_i(slot_q[X].p.length), .valid_o(x_cf_valid), .taken_o(x_cf_taken),
    .misaligned_o(x_cf_misaligned), .target_o(x_cf_target), .next_pc_o(x_cf_next), .link_o(x_cf_link)
  );

  /* X forms the effective address modulo XLEN and checks it before any bus ownership. */
  assign x_mem_addr = slot_q[X].p.rs1_value + slot_q[X].cf_imm;
  drg5_lsu #(.TEST_REGIONS(TEST_REGIONS), .IRAM_WRITE(IRAM_WRITE),
              .TIMER_ENABLED(TIMER_ENABLED)) execute_memory (
    .addr_i(x_mem_addr), .store_value_i(slot_q[X].p.rs2_value), .rsp_data_i(32'b0),
    .size_i(slot_q[X].p.mem_size), .write_i(slot_q[X].p.op == OP_STORE),
    .signed_i(slot_q[X].p.mem_signed), .allowed_o(x_mem_allowed),
    .misaligned_o(unused_x_misaligned), .cause_o(x_mem_cause), .wdata_o(x_mem_wdata),
    .wstrb_o(unused_x_strobe), .load_value_o(unused_x_load)
  );

  /* M also checks diagnostic memory packets before granting a first-valid request. */
  drg5_lsu #(.TEST_REGIONS(TEST_REGIONS), .IRAM_WRITE(IRAM_WRITE),
              .TIMER_ENABLED(TIMER_ENABLED)) permit_memory (
    .addr_i(slot_q[M].p.mem_addr), .store_value_i(32'b0), .rsp_data_i(32'b0),
    .size_i(slot_q[M].p.mem_size), .write_i(slot_q[M].p.op == OP_STORE),
    .signed_i(slot_q[M].p.mem_signed), .allowed_o(mem_allowed),
    .misaligned_o(unused_mem_misaligned), .cause_o(mem_cause), .wdata_o(unused_m_wdata),
    .wstrb_o(unused_m_strobe), .load_value_o(unused_m_load)
  );

  /* only the immutable response owner selects and extends returned load lanes. */
  drg5_lsu #(.TEST_REGIONS(TEST_REGIONS), .IRAM_WRITE(IRAM_WRITE),
              .TIMER_ENABLED(TIMER_ENABLED)) complete_memory (
    .addr_i(owner_q.p.mem_addr), .store_value_i(32'b0), .rsp_data_i(d_rsp_rdata_i),
    .size_i(owner_q.p.mem_size), .write_i(owner_q.p.op == OP_STORE),
    .signed_i(owner_q.p.mem_signed), .allowed_o(unused_owner_allowed),
    .misaligned_o(unused_owner_misaligned), .cause_o(unused_owner_cause),
    .wdata_o(unused_owner_wdata), .wstrb_o(unused_owner_strobe), .load_value_o(load_value)
  );

  /* form exact requested lanes for strobes, canonical responses and fault evidence. */
  always_comb begin
    /* unsupported widths never own a request. */
    case (owner_q.p.mem_size)
      0: owner_byte_mask = 4'b0001 << owner_q.p.mem_addr[1:0];
      1: owner_byte_mask = 4'b0011 << owner_q.p.mem_addr[1:0];
      2: owner_byte_mask = 4'b1111;
      default: owner_byte_mask = 0;
    endcase
    owner_lane_mask = 0;
    /* expand byte enables without shifting the effective address a second time. */
    for (int lane = 0; lane < 4; lane++) begin
      owner_lane_mask[8*lane +: 8] = {8{owner_byte_mask[lane]}};
    end
    d_req_wstrb_o = d_req_write_o ? owner_byte_mask : 4'b0;
    bad_payload = (d_rsp_status_i != 0 || d_req_write_o) ? d_rsp_rdata_i != 0 :
                  (d_rsp_rdata_i & ~owner_lane_mask) != 0;
  end

  /* expose immutable manager state until acceptance and through response. */
  assign d_req_valid_o = bus_q == BUS_OFFER;
  assign d_req_addr_o = owner_q.p.mem_addr;
  assign d_req_wdata_o = d_req_write_o ? owner_q.p.mem_wdata & owner_lane_mask : 32'b0;
  assign d_req_write_o = owner_q.p.op == OP_STORE;
  assign d_req_size_o = owner_q.p.mem_size;
  assign d_req_tag_o = tag_q;
  assign d_rsp_ready_o = !cold_reset_i;
  assign mem_busy_o = bus_q != BUS_FREE;
  assign mem_launch_o = launch;
  assign stage_valid_o = valid_q;
  assign stage_token_o = slot_q;
  assign inspect_value_o = inspect_reg_i == 0 ? 32'b0 : regs_q[inspect_reg_i];
  assign inspect_defined_o = defined_q[inspect_reg_i];
  assign flush_ready_o = !flush_q && !hart_reset_i && !cold_reset_i &&
                         !recovery_q && !fatal_now;
  assign flush_accept = flush_valid_i && flush_ready_o;
  assign flush_active = flush_q || flush_accept;
  assign protect_m = valid_q[M] && slot_q[M].mem_issued;
  assign protect_w = valid_q[W] && (slot_q[W].mem_issued ||
                                  (w_fault && (!IRQ_ENABLED || slot_q[W].admitted)));
  /* completion replaces the continuation only after every protected memory effect drains. */
  assign flush_finish = flush_active && !protect_m && (!protect_w || w_done) &&
                        bus_q == BUS_FREE && !fatal_now;
  assign bus_accept = d_req_valid_o && d_req_ready_i;
  assign bus_complete = d_rsp_valid_i && d_rsp_ready_o &&
      d_rsp_tag_i == tag_q && (bus_q == BUS_WAIT || bus_accept);
  assign bus_bad = d_rsp_valid_i && d_rsp_ready_o &&
      (!bus_complete || d_rsp_status_i[1] || bad_payload);
  /* the final allowed edge accepts a matching reply; later replies remain recovery-only. */
  assign bus_timeout = (bus_q == BUS_OFFER || bus_q == BUS_WAIT) &&
      !bus_complete && bus_age_q == D_AGE_BITS'(D_MAX_WAIT_CYCLES - 1) && !cold_reset_i;
  /* publish sticky status only after the sampling edge; contain same-edge effects internally. */
  assign fatal_now = fatal_q || bus_bad || bus_timeout;
  assign fatal_o = fatal_q;
  assign uid_exhausted = in_valid_i && uid_q == 64'hffffffffffffffff && valid_q == 0 &&
      bus_q == BUS_FREE && !md_busy && !hart_reset_i && !flush_active && !recovery_q && !entry_pending_o;
  assign bus_deliver = bus_complete && !d_rsp_status_i[1] && !orphan_q &&
      !hart_reset_i && !fatal_now && valid_q[M] &&
      slot_q[M].uid == owner_q.uid;

  /* only an ordered terminal edge may change the shared machine state. */
  drg5_csr #(.C_ENABLED(C_ENABLED),
      .MISA_VALUE(32'h40000100 | (M_ENABLED ? 32'h1000 : 32'b0) | (C_ENABLED ? 32'h4 : 32'b0))) csr_bank (
    .clk_i(clk_i), .reset_i(cold_reset_i || hart_reset_i),
    .access_i(valid_q[W] && slot_q[W].p.op == OP_CSR),
    .addr_i(slot_q[W].p.csr_addr), .op_i(slot_q[W].p.csr_op),
    .source_i(slot_q[W].p.csr_source), .read_i(slot_q[W].p.csr_read),
    .write_i(slot_q[W].p.csr_write),
    .commit_i(w_done && !w_fault && slot_q[W].p.op == OP_CSR),
    .trap_i((w_done && w_fault) || irq_enter),
    .trap_pc_i(irq_enter ? boundary_pc_q : slot_q[W].p.pc),
    .trap_cause_i(irq_enter ? irq_cause : w_cause), .trap_tval_i(irq_enter ? 32'b0 : w_tval),
    .mret_i(w_done && !w_fault && slot_q[W].p.op == OP_MRET),
    .retire_i(w_done && !w_fault), .mip_levels_i(mip_levels_i),
    .debug_mode_i(1'b0), .debug_ebreak_entry_i(1'b0),
    .legal_o(csr_legal), .old_o(csr_old), .read_value_o(csr_read_value), .new_o(csr_new),
    .mstatus_o(mstatus_o), .mtvec_o(mtvec_o), .mscratch_o(mscratch_o),
    .mepc_o(mepc_o), .mcause_o(mcause_o), .mtval_o(mtval_o),
    .mie_o(mie_o), .mip_o(mip_o), .mcountinhibit_o(mcountinhibit_o),
    .mcycle_o(mcycle_o), .minstret_o(minstret_o)
  );

  /* inspect pre-edge machine state; faults suppress every normal effect. */
  always_comb begin
    w_fault = slot_q[W].p.fault;
    w_cause = slot_q[W].p.cause;
    w_tval = slot_q[W].p.mtval;
    w_value = slot_q[W].p.result;
    w_next = slot_q[W].p.next_pc;
    w_redirect = slot_q[W].p.op == OP_REDIRECT ||
                 (slot_q[W].p.op == OP_CONTROL && slot_q[W].cf_taken);
    /* preserve an earlier fault before checking the supplied operation. */
    if (!w_fault) begin
      /* reject incomplete encoding, unsupported operations and CSR addresses. */
      if ((slot_q[W].p.op == OP_CONTROL ?
           !control_width_ok(slot_q[W].p.length, slot_q[W].p.raw_valid, slot_q[W].p.expanded_valid,
                             slot_q[W].p.raw[31:16] == 0 && slot_q[W].p.raw[1:0] != 3) :
           !execution_width_ok(slot_q[W].p.length, slot_q[W].p.raw_valid, slot_q[W].c_decoded)) ||
          (slot_q[W].p.op > OP_FENCE && !(IRQ_ENABLED && slot_q[W].p.op == OP_WFI)) ||
          (slot_q[W].p.op == OP_CSR && !csr_legal)) begin
        w_fault = 1'b1;
        w_cause = 2;
        w_tval = 0;
      /* execute only a well-formed supplied operation. */
      end else begin
        /* form synchronous exceptions and the serialized return target. */
        case (slot_q[W].p.op)
          OP_CSR: w_value = csr_read_value;
          /* prepare the return without changing architectural state. */
          OP_MRET: begin
            w_next = mepc_o;
            w_redirect = 1'b1;
          end
          /* WFI resumes after its own encoding, including diagnostic packets. */
          OP_WFI: w_next = slot_q[W].p.pc + 32'd4;
          /* retain the machine-call exception convention. */
          OP_ECALL: begin
            w_fault = 1'b1;
            w_cause = 11;
            w_tval = 0;
          end
          /* debug routing is absent from this prototype. */
          OP_EBREAK: begin
            w_fault = 1'b1;
            w_cause = 3;
            w_tval = slot_q[W].p.pc;
          end
          /* validate the supplied target before redirecting. */
          OP_REDIRECT: begin
            /* the diagnostic redirect follows the active alignment setting. */
            if (w_next[0] || (!C_ENABLED && w_next[1])) begin
              w_fault = 1'b1;
              w_cause = 0;
              w_tval = w_next;
            end
          end
          /* ordinary result and memory packets need no W operation. */
          default: begin end
        endcase
      end
    end
  end

  /* a held ordered fault stays owned until it can trap, even during flush. */
  assign w_done = valid_q[W] && !hold_i[W] && !cold_reset_i &&
      !hart_reset_i && !fatal_now &&
      (!IRQ_ENABLED || slot_q[W].admitted) &&
      (!barrier[W] || (slot_q[W].serial_ready && bus_q == BUS_FREE)) &&
      (!flush_active || protect_w);

  /* compute stage movement, ordered launch permission and explicit kills. */
  always_comb begin
    valid_d = valid_q;
    slot_d = slot_q;
    kill = 0;
    transfer_o = 0;
    launch = 0;
    tag_exhausted = 0;
    in_ready_o = 0;
    mem_local_fault = !mem_allowed || !execution_width_ok(slot_q[M].p.length, slot_q[M].p.raw_valid, slot_q[M].c_decoded);
    /* a reset aborts instructions while the separate manager survives. */
    if (hart_reset_i || cold_reset_i) begin
      kill = valid_q;
    /* fatal recovery freezes slots until explicit reset-abort. */
    end else if (!fatal_now) begin
      /* a precise W redirect kills all younger tokens before any launch. */
      if (irq_enter) begin
        kill = valid_q;
      /* only unadmitted tokens can remain at an interrupt entry boundary. */
      end else if (w_done && (w_fault || w_redirect)) begin
        kill = valid_q & 5'b01111;
      /* retain irreversible memory work and an ordered W fault. */
      end else if (flush_active) begin
        kill = valid_q;
        kill[M] = valid_q[M] && !protect_m;
        kill[W] = valid_q[W] && !protect_w;
      end
      /* release W only for its single architectural disposition. */
      if (w_done) begin
        valid_d[W] = 0;
      end
      /* admission remains owned by the token even while its destination is stalled. */
      if (admit_x) slot_d[X].admitted = 1;
      /* a fault grant has no request descriptor or device effect. */
      if (admit_m_fault) slot_d[M].admitted = 1;
      /* a started job remains attached until completion or an explicit token kill. */
      if (md_start) slot_d[X].md_issued = 1;
      /* an admitted fault barrier must finish preparation even while IRQ entry drains. */
      if (valid_q[W] && barrier[W] && !slot_q[W].serial_ready && !hold_i[W] &&
          !kill[W] && bus_q == BUS_FREE &&
          (!IRQ_ENABLED || !entry_pending_o || slot_q[W].admitted)) begin
        slot_d[W].serial_ready = 1;
        slot_d[W].admitted = IRQ_ENABLED;
      end
      /* a completed M token moves independently of response capture. */
      if (valid_q[M] && !hold_i[M] && !kill[M] && !barrier_older[M] && !valid_d[W] &&
          (!IRQ_ENABLED || slot_q[M].admitted || admit_m_fault ||
           (!entry_pending_o && !slot_q[M].p.fault && barrier[M])) &&
          (slot_q[M].p.fault ||
           (slot_q[M].p.op != OP_LOAD && slot_q[M].p.op != OP_STORE) ||
           slot_q[M].mem_done)) begin
        slot_d[W] = slot_q[M];
        slot_d[W].admitted = slot_q[M].admitted || admit_m_fault;
        valid_d[W] = 1;
        valid_d[M] = 0;
        transfer_o[M] = 1;
      end
      /* grant effects only when all older work has successfully retired. */
      if (valid_q[M] && !hold_i[M] && !kill[M] && !flush_active && !barrier_older[M] &&
          (!IRQ_ENABLED || (!entry_pending_o && !older_unadmitted[M])) &&
          !slot_q[M].p.fault && !slot_q[M].mem_issued &&
          (slot_q[M].p.op == OP_LOAD || slot_q[M].p.op == OP_STORE) &&
          (!valid_q[W] || (w_done && !w_fault && !w_redirect))) begin
        /* local failures never create a request owner. */
        if (mem_local_fault) begin
          slot_d[M].p.fault = 1;
          slot_d[M].admitted = IRQ_ENABLED;
          /* malformed metadata precedes address and width checks. */
          if (!execution_width_ok(slot_q[M].p.length, slot_q[M].p.raw_valid, slot_q[M].c_decoded)) begin
            slot_d[M].p.cause = 2;
            slot_d[M].p.mtval = 0;
          /* report the first local address or width fault. */
          end else begin
            slot_d[M].p.cause = mem_cause;
            slot_d[M].p.mtval = slot_q[M].p.mem_addr;
          end
        /* an empty manager can reserve one eligible request. */
        end else if (bus_q == BUS_FREE && !recovery_q) begin
          /* exhaustion applies only to an otherwise-permitted new request. */
          if (tag_q == 32'hffffffff) begin
            tag_exhausted = !valid_q[W];
          /* first valid follows this irrevocable reservation. */
          end else begin
            launch = 1;
            slot_d[M].mem_issued = 1;
            slot_d[M].admitted = IRQ_ENABLED;
          end
        end
      end
      /* walk backward so a vacated slot can accept one different token. */
      for (int i = X; i >= F; i--) begin
        /* holds stop transfer, while kills dominate replacement. */
        if (valid_q[i] && !hold_i[i] && !kill[i] && !valid_d[i+1] &&
            !barrier_older[i] &&
            (!IRQ_ENABLED || (!entry_pending_o || slot_q[i].admitted)) &&
            (!IRQ_ENABLED || i != X || slot_q[X].admitted || admit_x ||
             barrier[X] || slot_q[X].p.op == OP_LOAD || slot_q[X].p.op == OP_STORE) &&
            !flush_active && !(w_done && (w_fault || w_redirect)) &&
            !(i == D && d_hazard) &&
            !(i == X && slot_q[X].md_decoded && !slot_q[X].p.fault && !slot_q[X].md_done)) begin
          slot_d[i+1] = slot_q[i];
          /* an X grant follows its token through a same-edge transfer. */
          if (i == X) slot_d[i+1].admitted = slot_q[i].admitted || admit_x;
          valid_d[i+1] = 1;
          valid_d[i] = 0;
          transfer_o[i] = 1;
          /* D captures real sources once for each decoded instruction. */
          if (i == D && (slot_q[D].p.op == OP_CONTROL || slot_q[D].p.op == OP_MEMORY ||
                         slot_q[D].p.op == OP_BASE || slot_q[D].p.op == OP_MACHINE)) begin
            slot_d[X].p.rs1_used = 0;
            slot_d[X].p.rs2_used = 0;
            slot_d[X].p.rs1 = 0;
            slot_d[X].p.rs2 = 0;
            slot_d[X].p.rs1_value = 0;
            slot_d[X].p.rs2_value = 0;
            slot_d[X].p.rd = 0;
            slot_d[X].p.rd_write = 0;
            slot_d[X].p.result = 0;
            slot_d[X].p.next_pc = 0;
            /* raw base instructions never inherit synthetic memory or CSR intent. */
            if (slot_q[D].p.op == OP_BASE || slot_q[D].p.op == OP_MACHINE) begin
              slot_d[X].p.mem_addr = 0;
              slot_d[X].p.mem_wdata = 0;
              slot_d[X].p.mem_size = 0;
              slot_d[X].p.mem_signed = 0;
              slot_d[X].p.csr_addr = 0;
              slot_d[X].p.csr_op = CSR_READ;
              slot_d[X].p.csr_read = 0;
              slot_d[X].p.csr_write = 0;
              slot_d[X].p.csr_source = 0;
            end
            /* an existing fetch fault wins before decode or operand use. */
            if (!slot_q[D].p.fault) begin
              /* unsupported encodings produce a precise illegal-instruction token. */
              if (!d_execute_ok) begin
                slot_d[X].p.fault = 1;
                slot_d[X].p.cause = 2;
                slot_d[X].p.mtval = 0;
              end
              /* capture sources once before any later destination write. */
              else begin
                /* preserve original bytes and length beside the validated expansion. */
                if (d_short_ok) begin
                  slot_d[X].c_decoded = 1;
                  slot_d[X].p.expanded_valid = 1;
                  slot_d[X].p.expanded = d_expanded;
                end
                slot_d[X].p.rs1_used = d_operand_rs1_used;
                slot_d[X].p.rs2_used = d_operand_rs2_used;
                slot_d[X].p.rs1 = d_operand_rs1;
                slot_d[X].p.rs2 = d_operand_rs2;
                slot_d[X].p.rs1_value = d_operand_rs1_used ? d_rs1_value : 32'b0;
                slot_d[X].p.rs2_value = d_operand_rs2_used ? d_rs2_value : 32'b0;
                slot_d[X].p.rd = d_rd;
                slot_d[X].p.rd_write = d_rd_write;
                slot_d[X].cf_imm = d_immediate;
                /* normal base execution starts with no supplied result or fault annotation. */
                if (slot_q[D].p.op == OP_BASE || slot_q[D].p.op == OP_MACHINE) begin
                  slot_d[X].p.next_pc = slot_q[D].p.pc + {29'b0, slot_q[D].p.length};
                  slot_d[X].p.cause = 0;
                  slot_d[X].p.mtval = 0;
                end
                /* M captures both real sources and waits in X for its owned result. */
                if (d_muldiv) begin
                  slot_d[X].p.op = OP_RESULT;
                  slot_d[X].p.rd = d_word[11:7];
                  slot_d[X].p.rd_write = d_word[11:7] != 0;
                  slot_d[X].md_decoded = 1;
                  slot_d[X].md_op = d_word[14:12];
                end
                /* CSR suppression follows encoded indices, never the captured source value. */
                else if (d_system_csr) begin
                  slot_d[X].p.op = OP_CSR;
                  slot_d[X].base_serial = 1;
                  slot_d[X].p.rd = d_word[11:7];
                  slot_d[X].p.rd_write = d_word[11:7] != 0;
                  slot_d[X].p.csr_addr = d_word[31:20];
                  slot_d[X].p.csr_op = csr_op_t'(d_word[13:12]);
                  slot_d[X].p.csr_read = d_word[13:12] != 1 || d_word[11:7] != 0;
                  slot_d[X].p.csr_write = d_word[13:12] == 1 || d_word[19:15] != 0;
                  slot_d[X].p.csr_source = d_word[14] ? {27'b0, d_word[19:15]} : d_rs1_value;
                end
                /* exact MRET consumes no GPR and reads mepc only at retirement. */
                else if (d_system_mret) begin
                  slot_d[X].p.op = OP_MRET;
                  slot_d[X].base_serial = 1;
                end
                /* WFI has no operands and sleeps only after its ordered retirement. */
                else if (d_system_wfi) begin
                  slot_d[X].p.op = OP_WFI;
                  slot_d[X].base_serial = 1;
                end
                /* normalized memory operations retain their original encoded identity. */
                else if (d_kind == `DRG5_KIND_LOAD || d_kind == `DRG5_KIND_STORE) begin
                  slot_d[X].p.op = d_kind == `DRG5_KIND_STORE ? OP_STORE : OP_LOAD;
                  slot_d[X].p.mem_addr = 0;
                  slot_d[X].p.mem_wdata = 0;
                  slot_d[X].p.mem_size = d_mem_size;
                  slot_d[X].p.mem_signed = d_load_signed;
                  slot_d[X].mem_decoded = 1;
                end
                /* control transfers retain decoded comparisons and length-aware links. */
                else if (d_kind == `DRG5_KIND_BRANCH || d_kind == `DRG5_KIND_JAL ||
                         d_kind == `DRG5_KIND_JALR) begin
                  slot_d[X].p.op = OP_CONTROL;
                  slot_d[X].cf_kind = d_kind;
                  slot_d[X].cf_cond = d_cond;
                end
                /* arithmetic instructions execute through the independently checked ALU. */
                else if (d_kind == `DRG5_KIND_REG || d_kind == `DRG5_KIND_IMM ||
                         d_kind == `DRG5_KIND_LUI || d_kind == `DRG5_KIND_AUIPC) begin
                  slot_d[X].p.op = OP_RESULT;
                  slot_d[X].alu_decoded = 1;
                  slot_d[X].alu_op = d_alu_op;
                  slot_d[X].alu_a_pc = d_a_pc;
                  slot_d[X].alu_b_imm = d_b_imm;
                end
                /* base fences and environment instructions act only at ordered W. */
                else begin
                  slot_d[X].base_serial = 1;
                  /* all legal remaining decoder kinds have one precise disposition. */
                  case (d_kind)
                    `DRG5_KIND_FENCE: slot_d[X].p.op = OP_FENCE;
                    `DRG5_KIND_ECALL: slot_d[X].p.op = OP_ECALL;
                    `DRG5_KIND_EBREAK: slot_d[X].p.op = OP_EBREAK;
                    /* a future unsupported kind cannot silently become an ordinary result. */
                    default: begin
                      slot_d[X].p.fault = 1;
                      slot_d[X].p.cause = 2;
                      slot_d[X].p.mtval = 0;
                    end
                  endcase
                end
              end
            end
          end
          /* latch an ALU result only when X transfers its owned instruction. */
          if (i == X && slot_q[X].alu_decoded && !slot_q[X].p.fault) begin
            slot_d[M].p.result = x_alu_value;
            /* decoder and ALU disagreement is contained as an illegal instruction. */
            if (!x_alu_valid) begin
              slot_d[M].p.fault = 1;
              slot_d[M].p.cause = 2;
              slot_d[M].p.mtval = 0;
            end
          end
          /* X records one result; only the older-ordered W disposition may act. */
          if (i == X && slot_q[X].p.op == OP_CONTROL && !slot_q[X].p.fault) begin
            slot_d[M].cf_taken = x_cf_taken;
            slot_d[M].p.next_pc = x_cf_next;
            slot_d[M].p.result = slot_q[X].cf_kind == `DRG5_KIND_BRANCH ? 32'b0 : x_cf_link;
            /* malformed control metadata is an illegal instruction. */
            if (!x_cf_valid) begin
              slot_d[M].p.fault = 1;
              slot_d[M].p.cause = 2;
              slot_d[M].p.mtval = 0;
            end
            /* a taken alignment fault traps on the source instruction, without link commit. */
            else if (x_cf_misaligned) begin
              slot_d[M].p.fault = 1;
              slot_d[M].p.cause = 0;
              slot_d[M].p.mtval = x_cf_target;
            end
          end
          /* X computes address and lanes once; M grants effects only after older success. */
          if (i == X && slot_q[X].mem_decoded && !slot_q[X].p.fault) begin
            slot_d[M].p.mem_addr = x_mem_addr;
            slot_d[M].p.mem_wdata = x_mem_wdata;
            slot_d[M].p.next_pc = slot_q[X].p.pc + {29'b0, slot_q[X].p.length};
            /* local faults have no bus owner, including a load whose destination is x0. */
            if (!x_mem_allowed) begin
              slot_d[M].p.fault = 1;
              slot_d[M].p.cause = x_mem_cause;
              slot_d[M].p.mtval = x_mem_addr;
            end
          end
        end
      end
      in_ready_o = !valid_d[F] && !flush_active && !recovery_q && !(|barrier) &&
          !entry_pending_o && !irq_enter &&
          uid_q != 64'hffffffffffffffff &&
          !(w_done && (w_fault || w_redirect)) &&
          (!DIAGNOSTIC || (valid_q == 0 && bus_q == BUS_FREE && !md_busy));
      /* allocate a fresh identity only for an actual input transfer. */
      if (in_valid_i && in_ready_o) begin
        slot_d[F] = '0;
        slot_d[F].p = in_packet_i;
        slot_d[F].uid = uid_q;
        valid_d[F] = 1;
      end
    end
    /* completion never revives a killed, reset or unrelated X token. */
    if (md_valid && valid_q[X] && slot_q[X].md_issued && slot_q[X].uid == md_uid &&
        !kill[X] && !fatal_now && !cold_reset_i && !hart_reset_i) begin
      slot_d[X].md_done = 1;
      slot_d[X].p.result = md_result;
    end
    /* response delivery updates only its still-owned M token. */
    if (bus_deliver && !kill[M]) begin
      slot_d[M].mem_done = 1;
      /* access errors suppress normal writeback and retain the fault address. */
      if (d_rsp_status_i == 1) begin
        slot_d[M].p.fault = 1;
        slot_d[M].p.cause = owner_q.p.op == OP_LOAD ? 32'd5 : 32'd7;
        slot_d[M].p.mtval = owner_q.p.mem_addr;
      /* stores have no register result to replace. */
      end else if (owner_q.p.op == OP_LOAD) begin
        slot_d[M].p.result = load_value;
      end
    end
    /* zero dead storage so stale fields cannot masquerade as live state. */
    for (int i = F; i <= W; i++) begin
      /* explicit kills also defeat a same-edge incoming replacement. */
      if (kill[i]) begin
        valid_d[i] = 0;
      end
      /* an invalid slot owns no residual packet. */
      if (!valid_d[i]) begin
        slot_d[i] = '0;
      end
    end
  end

  /* retain data obligations across hart reset; cold reset requires isolation. */
  always_ff @(posedge clk_i) begin
    /* only the platform may destroy a live manager at qualified cold reset. */
    if (cold_reset_i) begin
      assert ((!fatal_now && bus_q == BUS_FREE) || isolated_i)
        else $fatal(1, "cold reset without transaction isolation");
      bus_q <= BUS_FREE;
      owner_q <= '0;
      tag_q <= 0;
      orphan_q <= 0;
      bus_age_q <= 0;
      fatal_q <= 0;
      fatal_record_o <= '0;
    /* hart reset leaves this manager clocked and owned. */
    end else begin
      /* retain fatal state until coordinated cold recovery. */
      if (!fatal_q && (bus_bad || bus_timeout || tag_exhausted || uid_exhausted)) begin
        fatal_q <= 1;
        fatal_record_o <= '0;
        fatal_record_o.valid <= 1;
        fatal_record_o.reason <= bus_bad ?
            ((bus_complete && d_rsp_status_i == 2 && !bad_payload) ? 3'd2 : 3'd1) :
            bus_timeout ? 3'd3 : tag_exhausted ? 3'd4 : 3'd5;
        /* the snapshot records exposure and same-edge acceptance/completion, not later drainage. */
        if (bus_q != BUS_FREE) begin
          fatal_record_o.owned <= 1;
          fatal_record_o.accepted <= bus_q != BUS_OFFER || bus_accept;
          fatal_record_o.responded <= bus_complete || owner_q.mem_done;
          fatal_record_o.uid <= owner_q.uid;
          fatal_record_o.pc <= owner_q.p.pc;
          fatal_record_o.addr <= owner_q.p.mem_addr;
          fatal_record_o.wdata <= d_req_wdata_o;
          fatal_record_o.tag <= tag_q;
          fatal_record_o.size <= owner_q.p.mem_size;
          fatal_record_o.wstrb <= d_req_wstrb_o;
          fatal_record_o.write <= owner_q.p.op == OP_STORE;
        end
        /* exhausted tags identify the checked candidate, which never owned a bus request. */
        else if (!bus_bad && !bus_timeout && tag_exhausted) begin
          fatal_record_o.uid <= slot_q[M].uid;
          fatal_record_o.pc <= slot_q[M].p.pc;
          fatal_record_o.addr <= slot_q[M].p.mem_addr;
          fatal_record_o.size <= slot_q[M].p.mem_size;
          fatal_record_o.write <= slot_q[M].p.op == OP_STORE;
        end
        /* exhausted instruction identity records the still-unaccepted producer input. */
        else if (!bus_bad && !bus_timeout && uid_exhausted) begin
          fatal_record_o.uid <= uid_q;
          fatal_record_o.pc <= in_packet_i.pc;
        end
      end
      /* age includes stalled acceptance and saturates without rearming after containment. */
      if ((bus_q == BUS_OFFER || bus_q == BUS_WAIT) && !bus_complete && !fatal_q &&
          bus_age_q != D_AGE_BITS'(D_MAX_WAIT_CYCLES - 1)) begin
        bus_age_q <= bus_age_q + 1'b1;
      end
      /* an architectural reset removes only the instruction reference. */
      if (hart_reset_i && bus_q != BUS_FREE) begin
        orphan_q <= 1;
      end
      /* launch reserves the descriptor before first request-valid appears. */
      if (launch) begin
        bus_q <= BUS_OFFER;
        owner_q <= slot_q[M];
        owner_q.admitted <= IRQ_ENABLED;
        owner_q.mem_issued <= 1;
        owner_q.mem_done <= 0;
        tag_q <= tag_q + 1;
        orphan_q <= 0;
        bus_age_q <= 0;
      end
      /* an accepted request is never presented a second time. */
      if (bus_accept) begin
        bus_q <= BUS_WAIT;
      end
      /* uncertain or already-fatal outcomes retain a recovery owner. */
      if (bus_complete) begin
        bus_q <= fatal_now ? BUS_RECOVER : BUS_FREE;
        owner_q.mem_done <= 1;
        orphan_q <= 0;
      end
    end
  end

  /* commit GPR/CSR/trap state only at W; trace never backpressures execution. */
  always_ff @(posedge clk_i) begin
    valid_q <= valid_d;
    slot_q <= slot_d;
    trace_o <= '0;
    irq_valid_o <= 0;
    irq_pc_o <= 0;
    irq_cause_o <= 0;
    redirect_valid_o <= 0;
    flush_aborted_o <= 0;
    kill_valid_o <= kill;
    /* report each killed identity before its slot is cleared. */
    for (int i = F; i <= W; i++) begin
      kill_uid_o[i] <= kill[i] ? slot_q[i].uid : 64'b0;
    end
    /* reset architectural validity without promising reset GPR values. */
    if (cold_reset_i || hart_reset_i) begin
      defined_q <= 32'b1;
      recovery_q <= 1;
      flush_q <= 0;
      flush_pc_q <= 0;
      irq_drain_q <= 0;
      idle_q <= 0;
      boundary_pc_q <= RESET_PC;
      redirect_pc_o <= 0;
      flush_aborted_o <= flush_q;
      /* hart reset preserves observation identities and request tags. */
      if (cold_reset_i) begin
        uid_q <= 0;
        order_q <= 0;
      end
    /* resume execution only after reset drainage. */
    end else begin
      /* selection stops new attempts; owned requests and admitted work keep progressing. */
      if (irq_select) irq_drain_q <= 1;
      /* a withdrawn source cancels entry only after the admitted prefix is safe. */
      if (irq_drain_q && irq_safe) irq_drain_q <= 0;
      /* local enables wake WFI even when global MIE remains clear. */
      if (idle_q && |local_pending) idle_q <= 0;
      /* leave recovery only after every old data obligation has drained. */
      if (recovery_q && bus_q == BUS_FREE && !md_busy && !fatal_now) begin
        recovery_q <= 0;
      end
      /* input identity allocation is independent of later squashes. */
      if (in_valid_i && in_ready_o) begin
        uid_q <= uid_q + 1;
      end
      /* latch one external flush while irreversible work drains. */
      if (flush_accept) begin
        flush_q <= 1;
        flush_pc_q <= flush_pc_i;
      end
      /* a flush redirects only after its protected instruction terminates. */
      if (flush_finish) begin
        flush_q <= 0;
        redirect_valid_o <= 1;
        redirect_pc_o <= flush_q ? flush_pc_q : flush_pc_i;
        boundary_pc_q <= flush_q ? flush_pc_q : flush_pc_i;
        idle_q <= 0;
      end
      /* exactly one terminal record accompanies each W disposition. */
      if (w_done) begin
        trace_o.valid <= 1;
        trace_o.trap <= w_fault;
        trace_o.uid <= slot_q[W].uid;
        trace_o.order <= order_q;
        trace_o.packet <= slot_q[W].p;
        trace_o.packet.fault <= w_fault;
        trace_o.packet.cause <= w_fault ? w_cause : 32'b0;
        trace_o.packet.mtval <= w_fault ? w_tval : 32'b0;
        trace_o.next_pc <= w_fault ? mtvec_o : w_next;
        order_q <= order_q + 1;
        /* an older fault wins; otherwise a completed flush replaces the retired continuation. */
        boundary_pc_q <= w_fault ? mtvec_o : flush_finish ? (flush_q ? flush_pc_q : flush_pc_i) : w_next;
        /* precise faults suppress both normal CSR and GPR writes. */
        if (w_fault) begin
          redirect_valid_o <= 1;
          redirect_pc_o <= mtvec_o;
          flush_q <= 0;
          flush_aborted_o <= flush_active;
        /* successful retirement applies permitted writes once. */
        end else begin
          /* retiring WFI never gates the core counter, timer, acquisition or DMA clocks. */
          if (IRQ_ENABLED && slot_q[W].p.op == OP_WFI) idle_q <= !(|local_pending);
          /* discard x0 writes while preserving the instruction's effects. */
          if (w_gpr_write) begin
            regs_q[slot_q[W].p.rd] <= w_value;
            defined_q[slot_q[W].p.rd] <= 1;
            trace_o.rd_write <= 1;
            trace_o.rd <= slot_q[W].p.rd;
            trace_o.value <= w_value;
          end
          /* report actual CSR access events, including writes that preserve the stored value. */
          if (slot_q[W].p.op == OP_CSR) begin
            trace_o.csr_read <= slot_q[W].p.csr_read;
            trace_o.csr_write <= slot_q[W].p.csr_write;
            trace_o.csr_old <= slot_q[W].p.csr_read ? csr_old : 32'b0;
            trace_o.csr_new <= slot_q[W].p.csr_write ? csr_new : 32'b0;
          end
          /* resolved branch/return redirects occur at retirement in this prototype. */
          if (w_redirect) begin
            redirect_valid_o <= 1;
            redirect_pc_o <= w_next;
          end
        end
      end
      /* asynchronous trap records carry a boundary PC, not a fictitious instruction UID. */
      if (irq_enter) begin
        irq_valid_o <= 1;
        irq_pc_o <= boundary_pc_q;
        irq_cause_o <= irq_cause;
        boundary_pc_q <= mtvec_o;
        redirect_valid_o <= 1;
        redirect_pc_o <= mtvec_o;
        idle_q <= 0;
      end
    end
  end

  /* assert local ownership invariants independently of the test scoreboard. */
  always_ff @(posedge clk_i) begin
    /* reset-qualified startup establishes all observation state. */
    if (!cold_reset_i && !hart_reset_i && !recovery_q) begin
      assert ($countones(valid_d) + $countones(kill) + int'(w_done) ==
              $countones(valid_q) + int'(in_valid_i && in_ready_o))
        else $fatal(1, "instruction conservation failed");
      assert (bus_q == BUS_FREE || (owner_q.mem_issued &&
              (bus_q == BUS_RECOVER || !owner_q.mem_done)))
        else $fatal(1, "invalid manager ownership");
      assert (!DIAGNOSTIC || $countones(valid_q) <= 1)
        else $fatal(1, "diagnostic occupancy exceeded");
      assert (!(launch && (flush_active || fatal_now || slot_q[M].p.fault)))
        else $fatal(1, "unpermitted memory launch");
      assert (!(w_done && kill[W]))
        else $fatal(1, "killed instruction retired");
      /* IRQ entry excludes dispositions, owned requests and new allocation containment. */
      if (IRQ_ENABLED) begin
        assert (!(irq_enter && (w_done || |admitted || mem_busy_o || md_busy || fetch_busy_i || uid_exhausted)))
          else $fatal(1, "interrupt entered outside a safe boundary");
        assert (!(entry_pending_o && launch))
          else $fatal(1, "data launch after interrupt selection or WFI idle");
        /* an admitted younger attempt cannot cross an unadmitted older token. */
        for (int stage = F; stage <= W; stage++) begin
          assert (!(admitted[stage] && older_unadmitted[stage]))
            else $fatal(1, "instruction admission is not an ordered prefix");
        end
      end
      /* every issued arithmetic instruction either owns a job or holds its completed value. */
      if (valid_q[X] && slot_q[X].md_issued && !slot_q[X].md_done && !fatal_now) begin
        assert (md_busy && md_uid == slot_q[X].uid)
          else $fatal(1, "arithmetic owner lost");
      end
      assert (!(md_start && (kill[X] || entry_pending_o)))
        else $fatal(1, "unpermitted arithmetic start");
      /* stage ownership is unique even with simultaneous replacement. */
      for (int i = F; i <= W; i++) begin
        /* compare only pairs of live slots. */
        for (int j = i + 1; j <= W; j++) begin
          assert (!(valid_q[i] && valid_q[j] && slot_q[i].uid == slot_q[j].uid))
            else $fatal(1, "duplicate instruction owner");
        end
      end
    end
  end

  /* a stalled offer survives hart reset and keeps every bus field stable. */
  assert property (@(posedge clk_i) disable iff (cold_reset_i)
      d_req_valid_o && !d_req_ready_i |=>
      d_req_valid_o && $stable({d_req_addr_o, d_req_wdata_o,
          d_req_write_o, d_req_size_o, d_req_wstrb_o, d_req_tag_o}))
    else $fatal(1, "owned request changed before acceptance");
endmodule

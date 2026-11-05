/* assemble one instruction from two words; C_FETCH enables framing only. */
module drg5_fetch_buffer #(
  parameter bit C_FETCH = 0,
  parameter integer GEN_BITS = 8
) (
  input logic clk_i, reset_i, restart_i,
  input logic [31:0] restart_pc_i,
  input logic [GEN_BITS-1:0] restart_generation_i,
  input logic fill_valid_i,
  input logic [31:0] fill_addr_i,
  input logic [GEN_BITS-1:0] fill_generation_i,
  input logic [1:0] fill_parcels_i,
  input logic [31:0] fill_data_i,
  input logic [1:0] fill_fault_i,
  output logic need_valid_o,
  output logic [31:0] need_addr_o,
  output logic [1:0] need_parcels_o,
  output logic insn_valid_o,
  input logic insn_ready_i,
  output logic [31:0] insn_pc_o, insn_raw_o,
  output logic [3:0] insn_raw_valid_o,
  output logic [1:0] insn_length_kind_o,
  output logic insn_length_supported_o,
  output logic [2:0] insn_length_bytes_o,
  output logic [GEN_BITS-1:0] insn_generation_o,
  output logic insn_fault_o,
  output logic [31:0] insn_cause_o, insn_mtval_o
);
  logic [31:0] pc_q, pc_n, base_q [0:1], base_n [0:1];
  logic [31:0] data_q [0:1], data_n [0:1];
  logic [GEN_BITS-1:0] generation_q, generation_n;
  logic [GEN_BITS-1:0] slot_generation_q [0:1], slot_generation_n [0:1];
  logic [1:0] present_q [0:1], present_n [0:1], fault_q [0:1], fault_n [0:1];
  logic parked_q, parked_n, output_valid_q, output_valid_n;
  logic [31:0] output_pc_q, output_pc_n, output_raw_q, output_raw_n;
  logic [3:0] output_raw_valid_q, output_raw_valid_n;
  logic [1:0] output_kind_q, output_kind_n;
  logic output_supported_q, output_supported_n;
  logic [2:0] output_bytes_q, output_bytes_n;
  logic [GEN_BITS-1:0] output_generation_q, output_generation_n;
  logic output_fault_q, output_fault_n;
  logic [31:0] output_cause_q, output_cause_n, output_mtval_q, output_mtval_n;
  logic [15:0] first_data, second_data;
  logic first_present, second_present, first_fault, second_fault, misaligned;
  logic [1:0] prefix_kind;
  logic [31:0] advanced_pc;

  /* select instruction-relative parcels without changing their word storage. */
  always_comb begin
    first_data = pc_q[1] ? data_q[0][31:16] : data_q[0][15:0];
    first_present = present_q[0][pc_q[1]];
    first_fault = fault_q[0][pc_q[1]];
    second_data = pc_q[1] ? data_q[1][15:0] : data_q[0][31:16];
    second_present = pc_q[1] ? present_q[1][0] : present_q[0][1];
    second_fault = pc_q[1] ? fault_q[1][0] : fault_q[0][1];
    misaligned = pc_q[0] || (!C_FETCH && pc_q[1]);
    prefix_kind = first_data[1:0] != 2'b11 ? 2'd1 :
                  first_data[4:2] != 3'b111 ? 2'd2 : 2'd3;
    advanced_pc = pc_q + {29'b0, output_bytes_q};
  end

  /* request only missing required parcels; the manager owns every offer. */
  always_comb begin
    need_valid_o = 0;
    need_addr_o = 0;
    need_parcels_o = 0;
    /* occupied output and terminal packets prevent younger fetch requests. */
    if (!reset_i && !restart_i && !parked_q && !output_valid_q && !misaligned) begin
      /* non-C candidates require four bytes even when the prefix is short. */
      if (!first_present) begin
        need_valid_o = 1;
        need_addr_o = base_q[0];
        need_parcels_o = C_FETCH ? (pc_q[1] ? 2'b10 : 2'b01) : ~present_q[0];
      end
      /* a known long prefix never requests an optional next-word neighbor. */
      else if (!first_fault && (!C_FETCH || prefix_kind != 1) && !second_present) begin
        need_valid_o = 1;
        need_addr_o = pc_q[1] ? base_q[1] : base_q[0];
        need_parcels_o = pc_q[1] ? 2'b01 : 2'b10;
      end
    end
  end

  /* expose only registered output; reset and restart suppress same-edge transfer. */
  always_comb begin
    insn_valid_o = output_valid_q && !reset_i && !restart_i;
    insn_pc_o = output_pc_q;
    insn_raw_o = output_raw_q;
    insn_raw_valid_o = output_raw_valid_q;
    insn_length_kind_o = output_kind_q;
    insn_length_supported_o = output_supported_q;
    insn_length_bytes_o = output_bytes_q;
    insn_generation_o = output_generation_q;
    insn_fault_o = output_fault_q;
    insn_cause_o = output_cause_q;
    insn_mtval_o = output_mtval_q;
  end

  /* merge validated replies, assemble once and rotate only after transfer. */
  always_comb begin
    pc_n = pc_q;
    generation_n = generation_q;
    parked_n = parked_q;
    output_valid_n = output_valid_q;
    output_pc_n = output_pc_q;
    output_raw_n = output_raw_q;
    output_raw_valid_n = output_raw_valid_q;
    output_kind_n = output_kind_q;
    output_supported_n = output_supported_q;
    output_bytes_n = output_bytes_q;
    output_generation_n = output_generation_q;
    output_fault_n = output_fault_q;
    output_cause_n = output_cause_q;
    output_mtval_n = output_mtval_q;
    /* retain the reserved current and next words until their window advances. */
    for (integer slot = 0; slot < 2; slot = slot + 1) begin
      base_n[slot] = base_q[slot];
      data_n[slot] = data_q[slot];
      slot_generation_n[slot] = slot_generation_q[slot];
      present_n[slot] = present_q[slot];
      fault_n[slot] = fault_q[slot];
      /* ignore stale, misplaced or overlapping fills rather than overwrite data. */
      if (fill_valid_i && fill_generation_i == generation_q &&
          fill_generation_i == slot_generation_q[slot] && fill_addr_i == base_q[slot] &&
          fill_parcels_i != 0 && (fill_parcels_i & present_q[slot]) == 0 &&
          (fill_fault_i & ~fill_parcels_i) == 0) begin
        present_n[slot] = present_q[slot] | fill_parcels_i;
        fault_n[slot] = fault_q[slot] | fill_fault_i;
        /* faulted or unavailable bytes never become invented instruction bits. */
        for (integer parcel = 0; parcel < 2; parcel = parcel + 1) begin
          /* merge only the parcels reserved by the surviving manager. */
          if (fill_parcels_i[parcel]) begin
            data_n[slot][16*parcel +: 16] = fill_fault_i[parcel] ? 16'b0 :
                                                   fill_data_i[16*parcel +: 16];
          end
        end
      end
    end
    /* a completed packet transfers once, leaving its terminal case parked. */
    if (insn_valid_o && insn_ready_i) begin
      output_valid_n = 0;
      /* unknown or unsupported lengths cannot invent a sequential continuation. */
      if (output_fault_q || !output_supported_q) parked_n = 1;
      /* normal sequential advancement keeps any next-word parcels already held. */
      else begin
        pc_n = advanced_pc;
        /* movement across one boundary rotates; no third word is prefetched. */
        if ({advanced_pc[31:2], 2'b00} != base_q[0]) begin
          base_n[0] = base_n[1];
          data_n[0] = data_n[1];
          slot_generation_n[0] = slot_generation_n[1];
          present_n[0] = present_n[1];
          fault_n[0] = fault_n[1];
          base_n[1] = {advanced_pc[31:2], 2'b00} + 32'd4;
          data_n[1] = 0;
          slot_generation_n[1] = generation_q;
          present_n[1] = 0;
          fault_n[1] = 0;
        end
      end
    end
    /* assemble from captured slots on the clock after the last required reply. */
    if (!output_valid_q && !parked_q && (misaligned || first_present)) begin
      output_pc_n = pc_q;
      output_raw_n = 0;
      output_raw_valid_n = 0;
      output_kind_n = 0;
      output_supported_n = 0;
      output_bytes_n = 0;
      output_generation_n = generation_q;
      output_fault_n = 0;
      output_cause_n = 0;
      output_mtval_n = 0;
      /* defensive alignment faults have no instruction bytes or bus request. */
      if (misaligned) begin
        output_valid_n = 1;
        output_fault_n = 1;
        output_mtval_n = pc_q;
      end
      /* the first required fault wins even if a later parcel is also faulted. */
      else if (first_fault) begin
        output_valid_n = 1;
        output_fault_n = 1;
        output_cause_n = 1;
        output_mtval_n = pc_q;
        /* non-C upper bytes are required and retained when already available. */
        if (!C_FETCH && second_present && !second_fault) begin
          output_raw_n[31:16] = second_data;
          output_raw_valid_n = 4'b1100;
        end
      end
      /* successful first bytes establish framing without claiming decode legality. */
      else begin
        output_raw_n[15:0] = first_data;
        output_raw_valid_n = 4'b0011;
        output_kind_n = prefix_kind;
        output_supported_n = prefix_kind == 2 || (C_FETCH && prefix_kind == 1);
        output_bytes_n = prefix_kind == 2 ? 3'd4 :
                         C_FETCH && prefix_kind == 1 ? 3'd2 : 3'd0;
        /* compressed framing ends after one successful required parcel. */
        if (C_FETCH && prefix_kind == 1) output_valid_n = 1;
        /* every other candidate requires a terminal second-parcel result. */
        else if (second_present) begin
          output_valid_n = 1;
          /* a second-parcel access failure outranks unsupported-length decoding. */
          if (second_fault) begin
            output_fault_n = 1;
            output_cause_n = 1;
            output_mtval_n = pc_q + 32'd2;
          end
          /* preserve the full original encoding, including unsupported prefixes. */
          else begin
            output_raw_n[31:16] = second_data;
            output_raw_valid_n = 4'b1111;
          end
        end
      end
    end
    /* reset and redirect kill insertion and transfer, including same-edge replies. */
    if (reset_i || restart_i) begin
      pc_n = restart_pc_i;
      generation_n = restart_generation_i;
      parked_n = 0;
      output_valid_n = 0;
      output_pc_n = 0;
      output_raw_n = 0;
      output_raw_valid_n = 0;
      output_kind_n = 0;
      output_supported_n = 0;
      output_bytes_n = 0;
      output_generation_n = 0;
      output_fault_n = 0;
      output_cause_n = 0;
      output_mtval_n = 0;
      /* establish both bases in the new generation, including address wrap. */
      for (integer slot = 0; slot < 2; slot = slot + 1) begin
        base_n[slot] = {restart_pc_i[31:2], 2'b00} + (slot == 0 ? 32'd0 : 32'd4);
        data_n[slot] = 0;
        slot_generation_n[slot] = restart_generation_i;
        present_n[slot] = 0;
        fault_n[slot] = 0;
      end
    end
  end

  /* retain the sole assembly window and stable instruction output. */
  always_ff @(posedge clk_i) begin
    pc_q <= pc_n;
    generation_q <= generation_n;
    parked_q <= parked_n;
    output_valid_q <= output_valid_n;
    output_pc_q <= output_pc_n;
    output_raw_q <= output_raw_n;
    output_raw_valid_q <= output_raw_valid_n;
    output_kind_q <= output_kind_n;
    output_supported_q <= output_supported_n;
    output_bytes_q <= output_bytes_n;
    output_generation_q <= output_generation_n;
    output_fault_q <= output_fault_n;
    output_cause_q <= output_cause_n;
    output_mtval_q <= output_mtval_n;
    /* word identity, generation and per-parcel outcome move together. */
    for (integer slot = 0; slot < 2; slot = slot + 1) begin
      base_q[slot] <= base_n[slot];
      data_q[slot] <= data_n[slot];
      slot_generation_q[slot] <= slot_generation_n[slot];
      present_q[slot] <= present_n[slot];
      fault_q[slot] <= fault_n[slot];
    end
  end
endmodule

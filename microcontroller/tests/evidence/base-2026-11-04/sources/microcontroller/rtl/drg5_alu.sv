`include "drg5_datapath_defs.svh"

/* compute arithmetic modulo 2^32 and independent comparison predicates. */
module drg5_alu (
  input logic [31:0] a_i, b_i,
  input logic [3:0] op_i,
  output logic [31:0] result_o,
  output logic valid_o, eq_o, lt_signed_o, lt_unsigned_o
);
  logic [1:0] shift_op;
  logic [31:0] shift_result;
  logic shift_valid;

  /* reuse the independently tested combinational shifter. */
  drg5_shifter shift_unit (
    .value_i(a_i), .amount_i(b_i), .op_i(shift_op),
    .value_o(shift_result), .valid_o(shift_valid)
  );

  /* comparisons do not depend on the selected result operation. */
  always_comb begin
    eq_o = a_i == b_i;
    lt_signed_o = $signed(a_i) < $signed(b_i);
    lt_unsigned_o = a_i < b_i;
    shift_op = `DRG5_SHIFT_LEFT;
    /* select a right-shift flavor only for its corresponding operation. */
    case (op_i)
      `DRG5_ALU_SRL: shift_op = `DRG5_SHIFT_RIGHT;
      `DRG5_ALU_SRA: shift_op = `DRG5_SHIFT_ARITH;
      default: shift_op = `DRG5_SHIFT_LEFT;
    endcase
  end

  /* invalid operations produce a benign result and explicit rejection. */
  always_comb begin
    result_o = 0;
    valid_o = 1;
    /* assignment to 32 bits deliberately discards arithmetic carry. */
    case (op_i)
      `DRG5_ALU_ADD: result_o = a_i + b_i;
      `DRG5_ALU_SUB: result_o = a_i - b_i;
      `DRG5_ALU_SLT: result_o = {31'b0, lt_signed_o};
      `DRG5_ALU_SLTU: result_o = {31'b0, lt_unsigned_o};
      `DRG5_ALU_XOR: result_o = a_i ^ b_i;
      `DRG5_ALU_OR: result_o = a_i | b_i;
      `DRG5_ALU_AND: result_o = a_i & b_i;
      `DRG5_ALU_COPY_B: result_o = b_i;
      /* shift legality is checked by the selected unit. */
      `DRG5_ALU_SLL, `DRG5_ALU_SRL, `DRG5_ALU_SRA: begin
        result_o = shift_result;
        valid_o = shift_valid;
      end
      /* comparison outputs remain meaningful even for rejected operations. */
      default: begin
        result_o = 0;
        valid_o = 0;
      end
    endcase
  end
endmodule

`include "drg5_datapath_defs.svh"

/* reconstruct RV32I immediates; branch and jump offsets include bit zero. */
module drg5_immediate (
  input logic [31:0] instr_i,
  input logic [2:0] kind_i,
  output logic [31:0] value_o,
  output logic valid_o
);
  logic [6:0] unused_opcode;

  /* legality belongs to the decoder; opcode bits do not encode immediates. */
  assign unused_opcode = instr_i[6:0];

  /* every selector has a defined result without stored state. */
  always_comb begin
    value_o = 0;
    valid_o = 1;
    /* sign extension uses the instruction sign bit, including SLTIU. */
    case (kind_i)
      `DRG5_IMM_NONE: value_o = 0;
      `DRG5_IMM_I: value_o = {{20{instr_i[31]}}, instr_i[31:20]};
      `DRG5_IMM_S: value_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
      `DRG5_IMM_B: value_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                             instr_i[30:25], instr_i[11:8], 1'b0};
      `DRG5_IMM_U: value_o = {instr_i[31:12], 12'b0};
      `DRG5_IMM_J: value_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                             instr_i[20], instr_i[30:21], 1'b0};
      `DRG5_IMM_SHAMT: value_o = {27'b0, instr_i[24:20]};
      /* invalid selectors cannot leave an old immediate on the output. */
      default: begin
        value_o = 0;
        valid_o = 0;
      end
    endcase
  end
endmodule

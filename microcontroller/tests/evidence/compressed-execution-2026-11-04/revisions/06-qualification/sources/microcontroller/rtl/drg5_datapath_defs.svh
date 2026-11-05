/* share interface codes without requiring a SystemVerilog package frontend. */
`ifndef DRG5_DATAPATH_DEFS_SVH
`define DRG5_DATAPATH_DEFS_SVH

/* select the base integer operations; other values are invalid. */
`define DRG5_ALU_ADD    4'd0
`define DRG5_ALU_SUB    4'd1
`define DRG5_ALU_SLL    4'd2
`define DRG5_ALU_SLT    4'd3
`define DRG5_ALU_SLTU   4'd4
`define DRG5_ALU_XOR    4'd5
`define DRG5_ALU_SRL    4'd6
`define DRG5_ALU_SRA    4'd7
`define DRG5_ALU_OR     4'd8
`define DRG5_ALU_AND    4'd9
`define DRG5_ALU_COPY_B 4'd10

/* select instruction-immediate layouts independently of opcode legality. */
`define DRG5_IMM_NONE  3'd0
`define DRG5_IMM_I     3'd1
`define DRG5_IMM_S     3'd2
`define DRG5_IMM_B     3'd3
`define DRG5_IMM_U     3'd4
`define DRG5_IMM_J     3'd5
`define DRG5_IMM_SHAMT 3'd6

/* classify legal RV32I packets without advertising later extensions. */
`define DRG5_KIND_NONE   4'd0
`define DRG5_KIND_REG    4'd1
`define DRG5_KIND_IMM    4'd2
`define DRG5_KIND_LUI    4'd3
`define DRG5_KIND_AUIPC  4'd4
`define DRG5_KIND_JAL    4'd5
`define DRG5_KIND_JALR   4'd6
`define DRG5_KIND_BRANCH 4'd7
`define DRG5_KIND_LOAD   4'd8
`define DRG5_KIND_STORE  4'd9
`define DRG5_KIND_FENCE  4'd10
`define DRG5_KIND_ECALL  4'd11
`define DRG5_KIND_EBREAK 4'd12

/* mask shift amounts to five bits at the shifter boundary. */
`define DRG5_SHIFT_LEFT  2'd0
`define DRG5_SHIFT_RIGHT 2'd1
`define DRG5_SHIFT_ARITH 2'd2
`endif

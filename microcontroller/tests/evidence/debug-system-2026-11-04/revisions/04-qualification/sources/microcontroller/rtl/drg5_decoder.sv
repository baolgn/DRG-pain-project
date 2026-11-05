`include "drg5_datapath_defs.svh"

/* decode RV32I 2.1 only; legality does not certify a complete CPU. */
module drg5_decoder (
  input logic [31:0] instr_i,
  output logic legal_o,
  output logic [3:0] kind_o, alu_op_o,
  output logic [2:0] imm_kind_o,
  output logic rs1_used_o, rs2_used_o, rd_write_o,
  output logic [4:0] rs1_o, rs2_o, rd_o,
  output logic a_pc_o, b_imm_o,
  output logic [2:0] branch_cond_o,
  output logic [1:0] mem_size_o,
  output logic load_signed_o
);
  logic has_rd;

  /* default every output so rejected instructions request no work. */
  always_comb begin
    legal_o = 0;
    kind_o = `DRG5_KIND_NONE;
    alu_op_o = `DRG5_ALU_ADD;
    imm_kind_o = `DRG5_IMM_NONE;
    rs1_used_o = 0;
    rs2_used_o = 0;
    has_rd = 0;
    rd_write_o = 0;
    rs1_o = 0;
    rs2_o = 0;
    rd_o = 0;
    a_pc_o = 0;
    b_imm_o = 0;
    branch_cond_o = 0;
    mem_size_o = 0;
    load_signed_o = 0;
    /* match complete base opcodes, including the instruction-length bits. */
    case (instr_i[6:0])
      /* LUI writes the upper immediate without reading either source. */
      7'h37: begin
        legal_o = 1;
        kind_o = `DRG5_KIND_LUI;
        alu_op_o = `DRG5_ALU_COPY_B;
        imm_kind_o = `DRG5_IMM_U;
        has_rd = 1;
        b_imm_o = 1;
      end
      /* AUIPC adds its upper immediate to the instruction PC. */
      7'h17: begin
        legal_o = 1;
        kind_o = `DRG5_KIND_AUIPC;
        imm_kind_o = `DRG5_IMM_U;
        has_rd = 1;
        a_pc_o = 1;
        b_imm_o = 1;
      end
      /* JAL uses a PC-relative target; link generation remains separate. */
      7'h6f: begin
        legal_o = 1;
        kind_o = `DRG5_KIND_JAL;
        imm_kind_o = `DRG5_IMM_J;
        has_rd = 1;
        a_pc_o = 1;
        b_imm_o = 1;
      end
      /* JALR requires funct3 zero; clear target bit zero after address addition. */
      7'h67: begin
        legal_o = instr_i[14:12] == 0;
        kind_o = `DRG5_KIND_JALR;
        imm_kind_o = `DRG5_IMM_I;
        rs1_used_o = 1;
        has_rd = 1;
        b_imm_o = 1;
      end
      /* branch operands feed comparison; a separate adder forms PC plus offset. */
      7'h63: begin
        legal_o = instr_i[14:12] == 0 || instr_i[14:12] == 1 || instr_i[14];
        kind_o = `DRG5_KIND_BRANCH;
        alu_op_o = `DRG5_ALU_SUB;
        imm_kind_o = `DRG5_IMM_B;
        rs1_used_o = 1;
        rs2_used_o = 1;
        branch_cond_o = instr_i[14:12];
      end
      /* all legal loads access memory even when their destination is x0. */
      7'h03: begin
        legal_o = instr_i[14:12] == 0 || instr_i[14:12] == 1 ||
                  instr_i[14:12] == 2 || instr_i[14:12] == 4 || instr_i[14:12] == 5;
        kind_o = `DRG5_KIND_LOAD;
        imm_kind_o = `DRG5_IMM_I;
        rs1_used_o = 1;
        has_rd = 1;
        b_imm_o = 1;
        mem_size_o = instr_i[13:12];
        load_signed_o = !instr_i[14];
      end
      /* store rs2 supplies data while rs1 plus immediate supplies its address. */
      7'h23: begin
        legal_o = instr_i[14:12] <= 2;
        kind_o = `DRG5_KIND_STORE;
        imm_kind_o = `DRG5_IMM_S;
        rs1_used_o = 1;
        rs2_used_o = 1;
        b_imm_o = 1;
        mem_size_o = instr_i[13:12];
      end
      /* arithmetic immediates never consume the encoded rs2 field. */
      7'h13: begin
        legal_o = 1;
        kind_o = `DRG5_KIND_IMM;
        imm_kind_o = `DRG5_IMM_I;
        rs1_used_o = 1;
        has_rd = 1;
        b_imm_o = 1;
        /* shift prefixes are exact RV32 encodings, not arbitrary immediates. */
        case (instr_i[14:12])
          0: alu_op_o = `DRG5_ALU_ADD;
          /* SLLI reserves every upper immediate bit. */
          1: begin
            legal_o = instr_i[31:25] == 0;
            alu_op_o = `DRG5_ALU_SLL;
            imm_kind_o = `DRG5_IMM_SHAMT;
          end
          2: alu_op_o = `DRG5_ALU_SLT;
          3: alu_op_o = `DRG5_ALU_SLTU;
          4: alu_op_o = `DRG5_ALU_XOR;
          /* SRLI and SRAI differ only in the permitted upper prefix. */
          5: begin
            legal_o = instr_i[31:25] == 0 || instr_i[31:25] == 7'h20;
            alu_op_o = instr_i[30] ? `DRG5_ALU_SRA : `DRG5_ALU_SRL;
            imm_kind_o = `DRG5_IMM_SHAMT;
          end
          6: alu_op_o = `DRG5_ALU_OR;
          7: alu_op_o = `DRG5_ALU_AND;
          default: legal_o = 0;
        endcase
      end
      /* only SUB and SRA admit funct7=0x20; M encodings remain illegal. */
      7'h33: begin
        legal_o = instr_i[31:25] == 0 ||
                  (instr_i[31:25] == 7'h20 &&
                   (instr_i[14:12] == 0 || instr_i[14:12] == 5));
        kind_o = `DRG5_KIND_REG;
        rs1_used_o = 1;
        rs2_used_o = 1;
        has_rd = 1;
        /* choose the operation after independently checking the prefix. */
        case (instr_i[14:12])
          0: alu_op_o = instr_i[30] ? `DRG5_ALU_SUB : `DRG5_ALU_ADD;
          1: alu_op_o = `DRG5_ALU_SLL;
          2: alu_op_o = `DRG5_ALU_SLT;
          3: alu_op_o = `DRG5_ALU_SLTU;
          4: alu_op_o = `DRG5_ALU_XOR;
          5: alu_op_o = instr_i[30] ? `DRG5_ALU_SRA : `DRG5_ALU_SRL;
          6: alu_op_o = `DRG5_ALU_OR;
          7: alu_op_o = `DRG5_ALU_AND;
          default: legal_o = 0;
        endcase
      end
      /* accept all base FENCE fields; the consumer enforces a full barrier. */
      7'h0f: begin
        legal_o = instr_i[14:12] == 0;
        kind_o = `DRG5_KIND_FENCE;
      end
      /* ECALL and EBREAK are exact encodings, not a permissive SYSTEM group. */
      7'h73: begin
        /* all CSR, privileged and other SYSTEM instructions are unsupported. */
        case (instr_i)
          /* the later execution environment chooses the precise trap action. */
          32'h00000073: begin
            legal_o = 1;
            kind_o = `DRG5_KIND_ECALL;
          end
          /* debug routing is not enabled by recognizing the base EBREAK opcode. */
          32'h00100073: begin
            legal_o = 1;
            kind_o = `DRG5_KIND_EBREAK;
          end
          default: legal_o = 0;
        endcase
      end
      default: legal_o = 0;
    endcase
    /* legality gates every control field, not only architectural writeback. */
    if (!legal_o) begin
      kind_o = `DRG5_KIND_NONE;
      alu_op_o = 0;
      imm_kind_o = 0;
      rs1_used_o = 0;
      rs2_used_o = 0;
      has_rd = 0;
      a_pc_o = 0;
      b_imm_o = 0;
      branch_cond_o = 0;
      mem_size_o = 0;
      load_signed_o = 0;
    end
    /* x0 remains an operand, but never a register dependency or destination. */
    rs1_o = rs1_used_o ? instr_i[19:15] : 5'b0;
    rs2_o = rs2_used_o ? instr_i[24:20] : 5'b0;
    rd_o = has_rd ? instr_i[11:7] : 5'b0;
    rd_write_o = legal_o && has_rd && instr_i[11:7] != 0;
  end
endmodule

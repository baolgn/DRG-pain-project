`include "drg5_datapath_defs.svh"

/* resolve decoded transfers from captured operands and the original length. */
module drg5_branch #(
  parameter bit C_ENABLED = 0
) (
  input logic [31:0] pc_i, rs1_i, rs2_i, imm_i,
  input logic [3:0] kind_i,
  input logic [2:0] cond_i, length_i,
  output logic valid_o, taken_o, misaligned_o,
  output logic [31:0] target_o, next_pc_o, link_o
);
  logic condition_valid, condition_taken, less_signed;

  /* compare signs directly so subtraction overflow cannot reverse a decision. */
  always_comb begin
    less_signed = rs1_i[31] != rs2_i[31] ? rs1_i[31] : rs1_i < rs2_i;
    condition_valid = 1;
    condition_taken = 0;
    /* the active conditional field uses the six RV32I funct3 encodings. */
    case (cond_i)
      3'd0: condition_taken = rs1_i == rs2_i;
      3'd1: condition_taken = rs1_i != rs2_i;
      3'd4: condition_taken = less_signed;
      3'd5: condition_taken = !less_signed;
      3'd6: condition_taken = rs1_i < rs2_i;
      3'd7: condition_taken = rs1_i >= rs2_i;
      default: condition_valid = 0;
    endcase
  end

  /* invalid decoded controls have no target, link, redirect or fault intent. */
  always_comb begin
    valid_o = (length_i == 4 || (C_ENABLED && length_i == 2)) &&
              (kind_i == `DRG5_KIND_JAL || kind_i == `DRG5_KIND_JALR ||
               (kind_i == `DRG5_KIND_BRANCH && condition_valid));
    taken_o = 0;
    misaligned_o = 0;
    target_o = 0;
    next_pc_o = 0;
    link_o = 0;
    /* original length controls the link independently of any expanded encoding. */
    if (valid_o) begin
      link_o = pc_i + {29'b0, length_i};
      taken_o = kind_i != `DRG5_KIND_BRANCH || condition_taken;
      target_o = pc_i + imm_i;
      /* clear JALR bit zero before checking the effective instruction alignment. */
      if (kind_i == `DRG5_KIND_JALR) target_o = (rs1_i + imm_i) & 32'hfffffffe;
      next_pc_o = taken_o ? target_o : link_o;
      misaligned_o = taken_o && (target_o[0] || (!C_ENABLED && target_o[1]));
    end
  end
endmodule

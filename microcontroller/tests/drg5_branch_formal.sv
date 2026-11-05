/* prove the decoded transfer contract for every two-state input combination. */
module drg5_branch_formal #(
  parameter C_ENABLED = 0,
  parameter MUTATE_LINK = 0
) (
  input [31:0] pc_i, rs1_i, rs2_i, imm_i,
  input [3:0] kind_i,
  input [2:0] cond_i, length_i
);
  wire valid_o, taken_o, misaligned_o;
  wire [31:0] target_o, next_pc_o, link_o;
  reg expected_valid, expected_taken, expected_fault, comparison, valid_condition;
  reg [31:0] expected_target, expected_link, expected_next;
  reg signed [32:0] signed_difference;
  reg [32:0] relative_sum, indirect_sum, sequential_sum;

  /* keep the oracle independent of implementation macros and comparator structure. */
  drg5_branch #(.C_ENABLED(C_ENABLED)) dut (.*);

  /* widened signed subtraction cannot overflow for two signed 32-bit operands. */
  always @* begin
    signed_difference = {rs1_i[31], rs1_i} - {rs2_i[31], rs2_i};
    relative_sum = {1'b0, pc_i} + {1'b0, imm_i};
    indirect_sum = {1'b0, rs1_i} + {1'b0, imm_i};
    sequential_sum = {1'b0, pc_i} + {30'b0, length_i};
    valid_condition = cond_i != 2 && cond_i != 3;
    comparison = 0;
    /* numeric conditions are specified separately from the DUT control cases. */
    case (cond_i)
      0: comparison = signed_difference == 0;
      1: comparison = signed_difference != 0;
      4: comparison = signed_difference < 0;
      5: comparison = signed_difference >= 0;
      6: comparison = {1'b0, rs1_i} < {1'b0, rs2_i};
      7: comparison = {1'b0, rs1_i} >= {1'b0, rs2_i};
      default: comparison = 0;
    endcase
    expected_valid = (length_i == 4 || (C_ENABLED && length_i == 2)) &&
                     (kind_i == 5 || kind_i == 6 || (kind_i == 7 && valid_condition));
    expected_taken = 0;
    expected_target = 0;
    expected_link = 0;
    expected_next = 0;
    expected_fault = 0;
    /* all diagnostics remain defined even when a valid taken target is misaligned. */
    if (expected_valid) begin
      expected_taken = kind_i == 7 ? comparison : 1;
      expected_link = sequential_sum[31:0];
      expected_target = kind_i == 6 ? {indirect_sum[31:1], 1'b0} : relative_sum[31:0];
      expected_next = expected_taken ? expected_target : expected_link;
      expected_fault = expected_taken && ((expected_target % (C_ENABLED ? 2 : 4)) != 0);
    end
    /* every output is constrained, including inactive and invalid cases. */
    assert(valid_o == expected_valid);
    assert(taken_o == expected_taken);
    assert(misaligned_o == expected_fault);
    assert(target_o == expected_target);
    assert(next_pc_o == expected_next);
    assert(link_o == (expected_link ^ MUTATE_LINK));
  end
endmodule

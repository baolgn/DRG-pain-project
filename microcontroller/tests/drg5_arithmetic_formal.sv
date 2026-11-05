/* prove arithmetic for every two-state operand and operation selector. */
module drg5_arithmetic_formal #(
  parameter MUTATE_RESULT = 0
) (
  input [31:0] a_i, b_i,
  input [3:0] op_i,
  input [1:0] shift_op_i
);
  wire [31:0] result, shifted;
  wire valid, equal, less_signed, less_unsigned, shift_valid;
  reg [31:0] expected, left_bits, right_bits, arithmetic_bits, expected_shift;
  reg [32:0] wide_sum, wide_difference;
  reg expected_less;
  integer source_bit;

  /* keep reference logic outside both independently instantiated units. */
  drg5_alu alu (
    .a_i(a_i), .b_i(b_i), .op_i(op_i), .result_o(result), .valid_o(valid),
    .eq_o(equal), .lt_signed_o(less_signed), .lt_unsigned_o(less_unsigned)
  );
  drg5_shifter shifter (
    .value_i(a_i), .amount_i(b_i), .op_i(shift_op_i),
    .value_o(shifted), .valid_o(shift_valid)
  );

  /* use bit routing, widened arithmetic and sign separation as the oracle. */
  always @* begin
    left_bits = 0;
    right_bits = 0;
    arithmetic_bits = 0;
    /* select source bits directly instead of using a staged barrel network. */
    for (integer bit_number = 0; bit_number < 32; bit_number = bit_number + 1) begin
      source_bit = bit_number - b_i[4:0];
      /* positions shifted in from below the operand are zero. */
      if (source_bit >= 0) begin
        left_bits[bit_number] = a_i[source_bit];
      end
      source_bit = bit_number + b_i[4:0];
      /* in-range right shifts share their source bit. */
      if (source_bit < 32) begin
        right_bits[bit_number] = a_i[source_bit];
        arithmetic_bits[bit_number] = a_i[source_bit];
      end
      /* arithmetic shifts alone replicate the original sign. */
      else begin
        arithmetic_bits[bit_number] = a_i[31];
      end
    end
    wide_sum = {1'b0, a_i} + {1'b0, b_i};
    wide_difference = {1'b0, a_i} + {1'b0, ~b_i} + 33'd1;
    expected_less = a_i[31] != b_i[31] ? a_i[31] : a_i < b_i;
    expected = 0;
    /* numeric interface codes keep the oracle independent of DUT macros. */
    case (op_i)
      0: expected = wide_sum[31:0];
      1: expected = wide_difference[31:0];
      2: expected = left_bits;
      3: expected = {31'b0, expected_less};
      4: expected = {31'b0, a_i < b_i};
      5: expected = a_i ^ b_i;
      6: expected = right_bits;
      7: expected = arithmetic_bits;
      8: expected = a_i | b_i;
      9: expected = a_i & b_i;
      10: expected = b_i;
      default: expected = 0;
    endcase
    expected_shift = 0;
    /* the standalone shifter has a separate selector and rejection behavior. */
    case (shift_op_i)
      0: expected_shift = left_bits;
      1: expected_shift = right_bits;
      2: expected_shift = arithmetic_bits;
      default: expected_shift = 0;
    endcase
    /* unconstrained inputs cover overflow, all counts and invalid selectors. */
    assert(result == (expected ^ MUTATE_RESULT));
    assert(valid == (op_i <= 10));
    assert(equal == (a_i == b_i));
    assert(less_signed == expected_less);
    assert(less_unsigned == (a_i < b_i));
    assert(shifted == expected_shift);
    assert(shift_valid == (shift_op_i < 3));
  end
endmodule

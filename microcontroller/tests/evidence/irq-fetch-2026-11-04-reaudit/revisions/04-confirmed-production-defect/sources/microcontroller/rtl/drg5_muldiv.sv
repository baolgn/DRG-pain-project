/* own one RV32M job from atomic start through result consumption. */
module drg5_muldiv (
  input logic clk_i, cold_reset_i,
  input logic start_i,
  input logic [2:0] op_i,
  input logic [31:0] lhs_i, rhs_i,
  input logic [63:0] uid_i,
  input logic ready_i,
  output logic busy_o, valid_o,
  output logic [31:0] result_o,
  output logic [63:0] uid_o
);
  typedef enum logic [2:0] {IDLE, MUL_SUM, MUL_END, DIV_ITER, DIV_END, HOLD} state_t;
  state_t state_q;
  logic [2:0] op_q;
  logic [31:0] lhs_q, rhs_q;
  logic [31:0] pp00_q, pp01_q, pp10_q, pp11_q;
  logic [63:0] product_q;
  logic [31:0] quotient_q, remainder_q, divisor_q;
  logic [31:0] corrected_high, signed_quotient, signed_remainder;
  logic [32:0] shifted_remainder;
  logic [31:0] reduced_remainder;
  logic [5:0] iteration_q;
  logic quotient_negative_q, remainder_negative_q, divide_zero_q, overflow_q;
  logic subtract_divisor;

  /* held results retain ownership until one ready edge; starts cannot replace them. */
  assign busy_o = state_q != IDLE;
  assign valid_o = state_q == HOLD;

  /* correct unsigned product high bits without increasing multiplier operand widths. */
  always_comb begin
    corrected_high = product_q[63:32];
    /* both signed-high forms subtract the unsigned rhs for a negative lhs. */
    if ((op_q == 3'b001 || op_q == 3'b010) && lhs_q[31]) begin
      corrected_high = corrected_high - rhs_q;
    end
    /* only signed-by-signed multiplication also corrects a negative rhs. */
    if (op_q == 3'b001 && rhs_q[31]) begin
      corrected_high = corrected_high - lhs_q;
    end
  end

  /* restore one unsigned quotient bit and apply final two's-complement signs. */
  always_comb begin
    shifted_remainder = {remainder_q, quotient_q[31]};
    subtract_divisor = shifted_remainder >= {1'b0, divisor_q};
    reduced_remainder = shifted_remainder[31:0] - divisor_q;
    signed_quotient = quotient_negative_q ? 32'b0 - quotient_q : quotient_q;
    signed_remainder = remainder_negative_q ? 32'b0 - remainder_q : remainder_q;
  end

  /* only cold reset may discard a job; pipeline kills must drain and ignore its uid. */
  always_ff @(posedge clk_i) begin
    /* reset establishes idle ownership and deterministic public outputs. */
    if (cold_reset_i) begin
      state_q <= IDLE;
      op_q <= 0;
      lhs_q <= 0;
      rhs_q <= 0;
      pp00_q <= 0;
      pp01_q <= 0;
      pp10_q <= 0;
      pp11_q <= 0;
      product_q <= 0;
      quotient_q <= 0;
      remainder_q <= 0;
      divisor_q <= 0;
      iteration_q <= 0;
      quotient_negative_q <= 0;
      remainder_negative_q <= 0;
      divide_zero_q <= 0;
      overflow_q <= 0;
      result_o <= 0;
      uid_o <= 0;
    end else begin
      /* each state owns either one arithmetic step or the retained result. */
      case (state_q)
        IDLE: begin
          /* capture every job field once; later input changes have no effect. */
          if (start_i) begin
            op_q <= op_i;
            lhs_q <= lhs_i;
            rhs_q <= rhs_i;
            uid_o <= uid_i;
            /* all four products fit native 18-by-18 FPGA multipliers. */
            if (!op_i[2]) begin
              pp00_q <= lhs_i[15:0] * rhs_i[15:0];
              pp01_q <= lhs_i[15:0] * rhs_i[31:16];
              pp10_q <= lhs_i[31:16] * rhs_i[15:0];
              pp11_q <= lhs_i[31:16] * rhs_i[31:16];
              state_q <= MUL_SUM;
            end else begin
              quotient_q <= !op_i[0] && lhs_i[31] ? 32'b0 - lhs_i : lhs_i;
              divisor_q <= !op_i[0] && rhs_i[31] ? 32'b0 - rhs_i : rhs_i;
              remainder_q <= 0;
              iteration_q <= 0;
              quotient_negative_q <= !op_i[0] && (lhs_i[31] ^ rhs_i[31]);
              remainder_negative_q <= !op_i[0] && lhs_i[31];
              divide_zero_q <= rhs_i == 0;
              overflow_q <= !op_i[0] && lhs_i == 32'h80000000 && rhs_i == 32'hffffffff;
              state_q <= DIV_ITER;
            end
          end
        end
        /* the shifted partial-product sum is the full unsigned 64-bit product. */
        MUL_SUM: begin
          product_q <= {pp11_q, 32'b0} + {16'b0, pp01_q, 16'b0} +
                       {16'b0, pp10_q, 16'b0} + {32'b0, pp00_q};
          state_q <= MUL_END;
        end
        /* multiply result-valid begins two clocks after acceptance. */
        MUL_END: begin
          result_o <= op_q == 0 ? product_q[31:0] : corrected_high;
          state_q <= HOLD;
        end
        /* exactly 32 restoring steps avoid operand-dependent completion timing. */
        DIV_ITER: begin
          quotient_q <= {quotient_q[30:0], subtract_divisor};
          remainder_q <= subtract_divisor ? reduced_remainder : shifted_remainder[31:0];
          iteration_q <= iteration_q + 1'b1;
          /* the final iteration's state is visible to the following finish edge. */
          if (iteration_q == 31) begin
            state_q <= DIV_END;
          end
        end
        /* division result-valid begins 33 clocks after acceptance, including special cases. */
        DIV_END: begin
          result_o <= op_q[1] ? signed_remainder : signed_quotient;
          /* zero and signed overflow return ISA values without arithmetic traps. */
          if (divide_zero_q) begin
            result_o <= op_q[1] ? lhs_q : 32'hffffffff;
          end else if (overflow_q) begin
            result_o <= op_q[1] ? 32'b0 : 32'h80000000;
          end
          state_q <= HOLD;
        end
        /* consumption releases ownership; another start requires a later idle edge. */
        HOLD: begin
          /* ready has no effect before result-valid. */
          if (ready_i) begin
            state_q <= IDLE;
          end
        end
        /* unreachable encoding fails closed instead of accepting another job. */
        default: begin
          state_q <= state_q;
        end
      endcase
    end
  end

  /* caller misuse cannot silently overwrite an owned arithmetic job. */
  assert property (@(posedge clk_i) disable iff (cold_reset_i)
      start_i |-> !busy_o) else $fatal(1, "arithmetic start while busy");

  /* backpressure retains both the value and its instruction identity. */
  assert property (@(posedge clk_i) disable iff (cold_reset_i)
      valid_o && !ready_i |=> valid_o && $stable({result_o, uid_o}))
    else $fatal(1, "arithmetic result changed while held");
endmodule

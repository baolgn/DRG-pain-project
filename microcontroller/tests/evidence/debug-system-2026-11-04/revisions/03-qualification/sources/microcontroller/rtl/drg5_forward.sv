/* choose each source's nearest older producer without bypassing an unavailable match. */
module drg5_forward #(
  parameter bit FORWARDING = 1
) (
  input logic [4:0] rs1_i, rs2_i,
  input logic rs1_used_i, rs2_used_i,
  input logic [31:0] rs1_rf_value_i, rs2_rf_value_i,
  input logic [2:0] producer_valid_i, producer_write_i, producer_ready_i,
  input logic [14:0] producer_rd_i,
  input logic [95:0] producer_value_i,
  output logic [31:0] rs1_value_o, rs2_value_o,
  output logic hazard_o,
  output logic [1:0] rs1_select_o, rs2_select_o,
  output logic rs1_match_o, rs2_match_o
);
  logic available;

  /* packed lanes run from X in the low bits through M to W in the high bits. */
  always_comb begin
    rs1_value_o = rs1_used_i && rs1_i != 0 ? rs1_rf_value_i : 32'b0;
    rs2_value_o = rs2_used_i && rs2_i != 0 ? rs2_rf_value_i : 32'b0;
    rs1_select_o = 0;
    rs2_select_o = 0;
    rs1_match_o = 0;
    rs2_match_o = 0;
    hazard_o = 0;
    available = 0;
    /* the first eligible match owns its source even if an older value is already ready. */
    for (int producer = 0; producer < 3; producer++) begin
      available = producer_ready_i[producer] && (FORWARDING || producer == 2);
      /* invalid slots, nonwriters and x0 destinations cannot produce a dependency. */
      if (producer_valid_i[producer] && producer_write_i[producer] &&
          producer_rd_i[5*producer +: 5] != 0) begin
        /* source one never falls back past a matching but unavailable producer. */
        if (rs1_used_i && rs1_i != 0 && !rs1_match_o &&
            producer_rd_i[5*producer +: 5] == rs1_i) begin
          rs1_match_o = 1;
          rs1_select_o = 2'(producer + 1);
          rs1_value_o = available ? producer_value_i[32*producer +: 32] : 32'b0;
          hazard_o = hazard_o || !available;
        end
        /* source two selects independently, including the same writer as source one. */
        if (rs2_used_i && rs2_i != 0 && !rs2_match_o &&
            producer_rd_i[5*producer +: 5] == rs2_i) begin
          rs2_match_o = 1;
          rs2_select_o = 2'(producer + 1);
          rs2_value_o = available ? producer_value_i[32*producer +: 32] : 32'b0;
          hazard_o = hazard_o || !available;
        end
      end
    end
  end
endmodule

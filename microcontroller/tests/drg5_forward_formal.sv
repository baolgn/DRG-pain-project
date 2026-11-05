/* prove every source and producer identity, eligibility, readiness and value combination. */
module drg5_forward_formal #(
  parameter FORWARDING = 1,
  parameter MUTATE_HAZARD = 0
) (
  input [4:0] rs1_i, rs2_i,
  input rs1_used_i, rs2_used_i,
  input [31:0] rs1_rf_value_i, rs2_rf_value_i,
  input [2:0] producer_valid_i, producer_write_i, producer_ready_i,
  input [14:0] producer_rd_i,
  input [95:0] producer_value_i
);
  wire [31:0] rs1_value_o, rs2_value_o;
  wire hazard_o, rs1_match_o, rs2_match_o;
  wire [1:0] rs1_select_o, rs2_select_o;
  wire [2:0] eligible, available, matches1, matches2, winner1, winner2;
  wire [31:0] value1, value2;
  wire [1:0] select1, select2;
  wire expected_hazard;

  /* keep the implementation separate from the reference's one-hot priority equations. */
  drg5_forward #(.FORWARDING(FORWARDING)) dut (.*);

  /* each raw match is independent of readiness and therefore blocks older matches. */
  assign eligible = producer_valid_i & producer_write_i;
  assign available = producer_ready_i & (FORWARDING ? 3'b111 : 3'b100);
  assign matches1 = {3{rs1_used_i && rs1_i != 0}} & eligible &
                    {producer_rd_i[14:10] == rs1_i, producer_rd_i[9:5] == rs1_i,
                     producer_rd_i[4:0] == rs1_i};
  assign matches2 = {3{rs2_used_i && rs2_i != 0}} & eligible &
                    {producer_rd_i[14:10] == rs2_i, producer_rd_i[9:5] == rs2_i,
                     producer_rd_i[4:0] == rs2_i};
  assign winner1 = matches1 & {!(|matches1[1:0]), !matches1[0], 1'b1};
  assign winner2 = matches2 & {!(|matches2[1:0]), !matches2[0], 1'b1};
  assign select1 = {1'b0, winner1[0]} + {winner1[1], 1'b0} + {2{winner1[2]}};
  assign select2 = {1'b0, winner2[0]} + {winner2[1], 1'b0} + {2{winner2[2]}};

  /* mutually exclusive masked values replace the implementation's procedural search. */
  assign value1 = ({32{rs1_used_i && rs1_i != 0 && matches1 == 0}} & rs1_rf_value_i) |
                  ({32{winner1[0] && available[0]}} & producer_value_i[31:0]) |
                  ({32{winner1[1] && available[1]}} & producer_value_i[63:32]) |
                  ({32{winner1[2] && available[2]}} & producer_value_i[95:64]);
  assign value2 = ({32{rs2_used_i && rs2_i != 0 && matches2 == 0}} & rs2_rf_value_i) |
                  ({32{winner2[0] && available[0]}} & producer_value_i[31:0]) |
                  ({32{winner2[1] && available[1]}} & producer_value_i[63:32]) |
                  ({32{winner2[2] && available[2]}} & producer_value_i[95:64]);
  assign expected_hazard = |((winner1 | winner2) & ~available);

  /* constrain every output without assumptions on external metadata or data values. */
  always @* begin
    assert(rs1_value_o == value1);
    assert(rs2_value_o == value2);
    assert(rs1_select_o == select1);
    assert(rs2_select_o == select2);
    assert(rs1_match_o == (|matches1));
    assert(rs2_match_o == (|matches2));
    assert(hazard_o == (expected_hazard ^ (MUTATE_HAZARD != 0)));
  end
endmodule

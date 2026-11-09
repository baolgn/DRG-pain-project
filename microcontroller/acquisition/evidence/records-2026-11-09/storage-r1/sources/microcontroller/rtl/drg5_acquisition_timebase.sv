/* count acquisition edges independently of CPU execution; the lifetime never wraps. */
module drg5_acquisition_timebase #(
  parameter logic [63:0] RESET_TICK = 64'b0
) (
  input logic clk_i, system_reset_i,
  output logic [63:0] tick_o,
  output logic exhausted_o
);
  /* only an isolated whole-domain reset starts a new timebase lifetime. */
  always_ff @(posedge clk_i) begin
    if (system_reset_i) tick_o <= RESET_TICK;
    else if (!(&tick_o)) tick_o <= tick_o + 1'b1;
  end
  assign exhausted_o = &tick_o;
endmodule

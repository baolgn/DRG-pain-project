/* model reset/lock sequencing only; no analog PLL or clock-frequency claim. */
module drg5_board_pll (
  input logic clk25_i,
  output logic clk_cpu_o, locked_o
);
  logic lock_enabled = 0;
  assign clk_cpu_o = clk25_i;
  assign locked_o = lock_enabled;
endmodule

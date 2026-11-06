/* map the portable smoke core onto the selected ULX3S clock and LED pins. */
module smoke_top (input wire clk25_i, output wire [7:0] led_o);
  wire clk80, locked;
  wire [31:0] count, memory_word;
  wire [35:0] product;
  qualification_pll pll (.clkin(clk25_i), .clkout0(clk80), .locked(locked));
  smoke_core core (.clk_i(clk80), .reset_i(!locked), .count_o(count),
                   .memory_o(memory_word), .product_o(product));
  assign led_o = count[7:0] ^ count[15:8] ^ count[23:16] ^ count[31:24] ^
                 memory_word[7:0] ^ memory_word[15:8] ^ memory_word[23:16] ^ memory_word[31:24] ^
                 product[7:0] ^ product[15:8] ^ product[23:16] ^ product[31:24] ^ {4'b0, product[35:32]};
  /* reserve the user flash-clock primitive in its high-impedance safe state. */
  USRMCLK flash_clock (.USRMCLKI(1'b0), .USRMCLKTS(1'b1));
endmodule

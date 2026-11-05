`timescale 1ns/1ps
/* exercise portable carry, multiplier and synchronous memory behavior. */
module smoke_core (
  input logic clk_i, reset_i,
  output logic [31:0] count_o, memory_o,
  output logic [35:0] product_o
);
  logic [31:0] memory [0:511];
  logic [8:0] address;
  assign address = count_o[8:0];

  /* preserve read-first RAM behavior; unwritten memory is not checked. */
  always_ff @(posedge clk_i) begin
    memory[address] <= count_o;
    memory_o <= memory[address];
    product_o <= count_o[17:0] * count_o[18:1];
    /* reset only the counter so the memory remains eligible for EBR mapping. */
    if (reset_i) begin
      count_o <= 0;
    /* exercise carry propagation and address wrap without clock gating. */
    end else begin
      count_o <= count_o + 1'b1;
    end
  end
endmodule

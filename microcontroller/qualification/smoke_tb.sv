/* compare portable RTL against independent cycle-level arithmetic. */
module smoke_tb;
  timeunit 1ns;
  timeprecision 1ps;
  logic clk, reset;
  logic [31:0] count, memory_word;
  logic [35:0] product;
  smoke_core dut (.clk_i(clk), .reset_i(reset), .count_o(count),
                  .memory_o(memory_word), .product_o(product));

  /* the testbench clock is independent of the physical PLL primitive. */
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  /* emit a waveform and check wraparound memory, multiply and counter results. */
  initial begin
    reset = 1;
    $dumpfile("smoke.vcd");
    $dumpvars(0, smoke_tb);
    repeat (2) @(negedge clk);
    reset = 0;
    /* each observation follows the corresponding active-edge updates. */
    for (int unsigned cycle = 0; cycle < 2048; cycle++) begin
      @(negedge clk);
      assert (count == cycle + 1) else $fatal(1, "counter mismatch");
      assert (product == 36'(cycle) * 36'(cycle >> 1)) else $fatal(1, "multiply mismatch");
      /* earlier writes define memory contents after one complete address sweep. */
      if (cycle >= 512) begin
        assert (memory_word == cycle - 512) else $fatal(1, "read-first RAM mismatch");
      end
    end
    $display("SMOKE_SIM_PASS cycles=2048");
    $finish;
  end
endmodule

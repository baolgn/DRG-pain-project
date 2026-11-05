/* qualify proof, cover and intentional assertion failure with one transition system. */
module formal (input wire clk);
  reg [3:0] count = 0;
  reg past_valid = 0;
  /* advance a wrapping counter under the formal global clock. */
  always @(posedge clk) begin
    past_valid <= 1;
    count <= count + 1'b1;
    /* the transition property must hold after the initial sample. */
    if (past_valid) begin
      assert (count == $past(count) + 4'd1);
    end
    cover (count == 15);
    /* the negative control must produce a counterexample, never a proof. */
`ifdef NEGATIVE
    assert (count == 0);
`endif
  end
endmodule

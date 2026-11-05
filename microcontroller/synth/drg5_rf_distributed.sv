/* compare the distributed RF storage candidate with explicit port semantics. */
module drg5_rf_distributed (
  input logic clk_i, reset_i, write_valid_i,
  input logic [4:0] write_addr_i, read1_addr_i, read2_addr_i,
  input logic [31:0] write_data_i,
  output logic [31:0] read1_data_o, read2_data_o,
  output logic read1_defined_o, read2_defined_o
);
  (* ram_style = "distributed" *) logic [31:0] words [0:31];
  logic [31:0] defined_q;
  logic commit;
  assign commit = write_valid_i && !reset_i && write_addr_i != 0;
  /* reset validity only; stored x1 through x31 have no reset value. */
  always_ff @(posedge clk_i) begin
    /* reset invalidates nonzero registers without clearing their data. */
    if (reset_i) defined_q <= 32'b1;
    /* a committed write defines its destination. */
    else if (commit) defined_q[write_addr_i] <= 1'b1;
    /* commit only nonzero writes outside reset. */
    if (commit) words[write_addr_i] <= write_data_i;
  end
  /* read asynchronously with explicit same-cycle write-through. */
  always_comb begin
    read1_data_o = read1_addr_i == 0 ? 32'b0 :
        commit && read1_addr_i == write_addr_i ? write_data_i : words[read1_addr_i];
    read2_data_o = read2_addr_i == 0 ? 32'b0 :
        commit && read2_addr_i == write_addr_i ? write_data_i : words[read2_addr_i];
    read1_defined_o = read1_addr_i == 0 || (!reset_i &&
        (defined_q[read1_addr_i] || (commit && read1_addr_i == write_addr_i)));
    read2_defined_o = read2_addr_i == 0 || (!reset_i &&
        (defined_q[read2_addr_i] || (commit && read2_addr_i == write_addr_i)));
  end
endmodule

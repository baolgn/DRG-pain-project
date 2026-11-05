/* exercise both read ports and every data bit in an identical route harness. */
module drg5_rf_map #(
  parameter integer CANDIDATE = 0
) (
  input logic clk25_i, serial_i,
  output logic [7:0] led_o
);
  wire clk80, locked;
  logic [48:0] state_q = 49'b1;
  logic [31:0] read1, read2;
  logic defined1, defined2;
  logic [31:0] checksum_q = 0;
  wire reset_core = state_q[0] || !locked;
  wire write_valid = state_q[1];
  wire [4:0] write_addr = state_q[6:2];
  wire [4:0] read1_addr = state_q[11:7];
  wire [4:0] read2_addr = state_q[16:12];
  drg5_rf_pll pll(.clk25_i(clk25_i), .clk80_o(clk80), .locked(locked));
  /* select one candidate without changing its architectural ports. */
  generate
    /* measure the flip-flop candidate. */
    if (CANDIDATE == 0) begin: ff_case
      drg5_rf_ff rf(.clk_i(clk80), .reset_i(reset_core), .write_valid_i(write_valid),
        .write_addr_i(write_addr), .write_data_i(state_q[48:17]),
        .read1_addr_i(read1_addr), .read2_addr_i(read2_addr),
        .read1_data_o(read1), .read2_data_o(read2),
        .read1_defined_o(defined1), .read2_defined_o(defined2));
    end
    /* measure asynchronous distributed RAM. */
    else if (CANDIDATE == 1) begin: distributed_case
      drg5_rf_distributed rf(.clk_i(clk80), .reset_i(reset_core), .write_valid_i(write_valid),
        .write_addr_i(write_addr), .write_data_i(state_q[48:17]),
        .read1_addr_i(read1_addr), .read2_addr_i(read2_addr),
        .read1_data_o(read1), .read2_data_o(read2),
        .read1_defined_o(defined1), .read2_defined_o(defined2));
    end
    /* measure the registered-read EBR alternative. */
    else if (CANDIDATE == 2) begin: bram_case
      drg5_rf_bram rf(.clk_i(clk80), .reset_i(reset_core), .write_valid_i(write_valid),
        .write_addr_i(write_addr), .write_data_i(state_q[48:17]),
        .read1_addr_i(read1_addr), .read2_addr_i(read2_addr),
        .read1_data_o(read1), .read2_data_o(read2),
        .read1_defined_o(defined1), .read2_defined_o(defined2));
    end
    /* verify the actual selected production module. */
    else begin: selected_case
      drg5_regfile rf(.clk_i(clk80), .reset_i(reset_core), .write_valid_i(write_valid),
        .write_addr_i(write_addr), .write_data_i(state_q[48:17]),
        .read1_addr_i(read1_addr), .read2_addr_i(read2_addr),
        .read1_data_o(read1), .read2_data_o(read2),
        .read1_defined_o(defined1), .read2_defined_o(defined2));
    end
  endgenerate
  /* shift arbitrary external bits so address, data and control remain independent. */
  always_ff @(posedge clk80) begin
    /* hold deterministic fixture control until the PLL locks. */
    if (!locked) state_q <= 49'b1;
    /* sample one external stimulus bit per clock. */
    else state_q <= {state_q[47:0], serial_i};
    /* clear only the checksum when fixture reset is requested. */
    if (reset_core) checksum_q <= 0;
    /* fold both defined read results into the observable output. */
    else checksum_q <= {checksum_q[30:0], checksum_q[31]} ^
        (defined1 ? read1 : 32'b0) ^ (defined2 ? {read2[15:0], read2[31:16]} : 32'b0);
  end
  assign led_o = checksum_q[7:0] ^ checksum_q[15:8] ^ checksum_q[23:16] ^ checksum_q[31:24];
endmodule

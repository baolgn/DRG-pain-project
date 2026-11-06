/* read bounded byte streams with the flash's standard mode-zero 03h command. */
module drg5_spi_read #(
  parameter integer HALF_PERIOD = 2
) (
  input logic clk_i, reset_i,
  input logic start_i,
  input logic [23:0] address_i,
  input logic [16:0] length_i,
  input logic miso_i,
  output logic cs_n_o, sck_o, mosi_o,
  output logic byte_valid_o,
  input logic byte_ready_i,
  output logic [7:0] byte_o,
  output logic busy_o, done_o
);
  localparam integer DIV_BITS = HALF_PERIOD < 2 ? 1 : $clog2(HALF_PERIOD);
  typedef enum logic [1:0] {IDLE, COMMAND, RECEIVE, HOLD} state_t;
  state_t state_q;
  logic [31:0] command_q;
  logic [5:0] command_bit_q;
  logic [2:0] data_bit_q;
  logic [7:0] received_q;
  logic [16:0] remaining_q;
  logic [DIV_BITS-1:0] divider_q;

  /* pauses occur only with SCK low; the buffered byte survives arbitrary consumer stalls. */
  assign busy_o = state_q != IDLE;
  assign byte_valid_o = state_q == HOLD;
  assign byte_o = received_q;
  assign mosi_o = state_q == COMMAND ? command_q[31] : 1'b0;

  /* every command owns chip select until all requested bytes have been consumed. */
  always_ff @(posedge clk_i) begin
    done_o <= 0;
    /* a board reset abandons the read-only command and returns the flash to deselected idle. */
    if (reset_i) begin
      state_q <= IDLE;
      command_q <= 0;
      command_bit_q <= 0;
      data_bit_q <= 0;
      received_q <= 0;
      remaining_q <= 0;
      divider_q <= 0;
      cs_n_o <= 1;
      sck_o <= 0;
    /* idle offers begin one fixed-address read; zero length is rejected without clocks. */
    end else if (state_q == IDLE) begin
      /* capture command and count before generating the first rising clock. */
      if (start_i && length_i != 0) begin
        state_q <= COMMAND;
        command_q <= {8'h03, address_i};
        command_bit_q <= 31;
        data_bit_q <= 7;
        received_q <= 0;
        remaining_q <= length_i;
        divider_q <= DIV_BITS'(HALF_PERIOD - 1);
        cs_n_o <= 0;
        sck_o <= 0;
      end
    /* a held byte never generates clocks or advances the flash address. */
    end else if (state_q == HOLD) begin
      /* consume the previous byte before resuming the next complete SPI byte. */
      if (byte_ready_i) begin
        /* final consumption closes the read transaction exactly once. */
        if (remaining_q == 1) begin
          state_q <= IDLE;
          cs_n_o <= 1;
          done_o <= 1;
        /* retain chip select while reading the next sequential byte. */
        end else begin
          state_q <= RECEIVE;
          remaining_q <= remaining_q - 1'b1;
          data_bit_q <= 7;
          received_q <= 0;
          divider_q <= DIV_BITS'(HALF_PERIOD - 1);
        end
      end
    /* half-period expiry advances one physical clock edge. */
    end else if (divider_q == 0) begin
      divider_q <= DIV_BITS'(HALF_PERIOD - 1);
      sck_o <= !sck_o;
      /* mode zero samples flash data only on rising SCK. */
      if (!sck_o) begin
        if (state_q == RECEIVE) received_q[data_bit_q] <= miso_i;
      /* command data changes on falling SCK and remains stable through the next rise. */
      end else if (state_q == COMMAND) begin
        /* the command and 24-bit address precede the first returned data bit. */
        if (command_bit_q == 0) begin
          state_q <= RECEIVE;
          data_bit_q <= 7;
        /* shift remaining command bits toward the serial output. */
        end else begin
          command_q <= {command_q[30:0], 1'b0};
          command_bit_q <= command_bit_q - 1'b1;
        end
      /* a received byte is presented only after its final falling edge. */
      end else if (data_bit_q == 0) begin
        state_q <= HOLD;
      end else data_bit_q <= data_bit_q - 1'b1;
    end else divider_q <= divider_q - 1'b1;
  end

`ifndef SYNTHESIS
  /* integration parameters and producer ownership are checked without altering the protocol. */
  initial begin
    assert (HALF_PERIOD >= 1) else $fatal(1, "SPI half period must be positive");
  end
  /* no caller may issue overlapping commands or hide an empty transfer. */
  always_ff @(posedge clk_i) begin
    if (!reset_i && start_i) assert (!busy_o && length_i != 0) else $fatal(1, "invalid SPI read offer");
  end
`endif
endmodule

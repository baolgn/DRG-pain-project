/* queue diagnostic bytes and serialize 8N1 without stalling CPU memory effects. */
module drg5_uart_tx #(
  parameter integer CLOCK_HZ = 80000000,
  parameter integer BAUD = 115200
) (
  input logic clk_i, reset_i, valid_i,
  input logic [7:0] data_i,
  output logic tx_o, busy_o, overflow_o,
  output logic [6:0] queued_o
);
  localparam integer DIVISOR = (CLOCK_HZ + BAUD / 2) / BAUD;
  localparam integer COUNT_BITS = $clog2(DIVISOR + 1);
  logic [7:0] fifo [0:63];
  logic [5:0] read_q, write_q;
  logic [6:0] count_q;
  logic [9:0] shift_q;
  logic [3:0] bits_q;
  logic [COUNT_BITS-1:0] divider_q;
  logic active_q, push, pop;

  /* a simultaneous dequeue frees one slot even when the FIFO starts full. */
  assign pop = !active_q && count_q != 0;
  assign push = valid_i && (count_q < 64 || pop);
  assign tx_o = active_q ? shift_q[0] : 1'b1;
  assign busy_o = active_q || count_q != 0;
  assign queued_o = count_q;

  /* queued storage needs no reset; pointers determine which bytes are owned. */
  always_ff @(posedge clk_i) begin
    if (!reset_i && push) fifo[write_q] <= data_i;
  end

  /* overflow is sticky until board reset and never silently reports successful output. */
  always_ff @(posedge clk_i) begin
    /* reset discards queued diagnostics and restores an idle serial line. */
    if (reset_i) begin
      read_q <= 0;
      write_q <= 0;
      count_q <= 0;
      shift_q <= '1;
      bits_q <= 0;
      divider_q <= 0;
      active_q <= 0;
      overflow_o <= 0;
    /* preserve byte ownership until its complete stop bit has elapsed. */
    end else begin
      if (valid_i && !push) overflow_o <= 1;
      if (push) write_q <= write_q + 1'b1;
      if (pop) read_q <= read_q + 1'b1;
      case ({push, pop})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
      /* load one start bit, eight least-significant-first data bits and one stop bit. */
      if (pop) begin
        shift_q <= {1'b1, fifo[read_q], 1'b0};
        bits_q <= 10;
        divider_q <= COUNT_BITS'(DIVISOR - 1);
        active_q <= 1;
      /* advance only after a complete bit period. */
      end else if (active_q) begin
        /* each byte retains all ten bit periods, including the final stop bit. */
        if (divider_q == 0) begin
          divider_q <= COUNT_BITS'(DIVISOR - 1);
          shift_q <= {1'b1, shift_q[9:1]};
          bits_q <= bits_q - 1'b1;
          if (bits_q == 1) active_q <= 0;
        end else divider_q <= divider_q - 1'b1;
      end
    end
  end
endmodule

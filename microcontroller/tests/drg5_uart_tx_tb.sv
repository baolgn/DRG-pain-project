/* check UART framing, FIFO ownership, overflow and reset against a byte queue. */
module drg5_uart_tx_tb;
  parameter integer CLOCK_HZ = 80000000;
  localparam integer BAUD = 115200;
  localparam integer DIVISOR = (CLOCK_HZ + BAUD / 2) / BAUD;
  logic clk = 0;
  logic reset = 1;
  logic valid = 0;
  logic [7:0] data = 0;
  logic tx, busy, overflow;
  logic [6:0] queued;
  byte unsigned expected[$];
  byte unsigned current;
  bit receiving = 0;
  integer frame_clock = 0;
  integer completed = 0;
  integer checks = 0;
  integer accepted = 0;
  integer discarded = 0;
  integer cycles = 0;
  bit expected_bit;

  /* observe only public serial and queue-status outputs. */
  drg5_uart_tx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) dut (
    .clk_i(clk), .reset_i(reset), .valid_i(valid), .data_i(data),
    .tx_o(tx), .busy_o(busy), .overflow_o(overflow), .queued_o(queued)
  );

  /* check every serial clock against the queued character's independent 8N1 frame. */
  task automatic tick;
    #1;
    clk = 1;
    #1;
    cycles++;
    if (cycles > 3000000) $fatal(1, "UART progress deadline");
    /* reset invalidates all outstanding diagnostics, including a partial character. */
    if (reset) begin
      discarded += expected.size() + integer'(receiving);
      expected.delete();
      receiving = 0;
      frame_clock = 0;
      if (tx !== 1 || busy !== 0 || queued !== 0 || overflow !== 0)
        $fatal(1, "UART reset outputs");
      checks++;
    /* decode only outside reset. */
    end else begin
      /* the start bit claims exactly one queued expectation. */
      if (!receiving && tx === 0) begin
        if (expected.size() == 0) $fatal(1, "unexpected UART character");
        current = expected.pop_front();
        receiving = 1;
        frame_clock = 0;
      /* a running frame advances exactly once per input clock. */
      end else if (receiving) begin
        frame_clock++;
        /* ten complete bit periods precede frame completion. */
        if (frame_clock == 10 * DIVISOR) begin
          if (tx !== 1) $fatal(1, "UART stop period shortened");
          receiving = 0;
          completed++;
        end
      end
      /* validate all clocks, including boundaries that midpoint decoding could miss. */
      if (receiving) begin
        if (frame_clock < DIVISOR) expected_bit = 0;
        else if (frame_clock >= 9 * DIVISOR) expected_bit = 1;
        else expected_bit = current[(frame_clock / DIVISOR) - 1];
        if (tx !== expected_bit) $fatal(1, "UART bit or period mismatch");
        checks++;
      end
      if (queued > 64) $fatal(1, "UART queue capacity");
    end
    clk = 0;
    #1;
  endtask

  /* callers declare which offered bytes the finite-capacity contract admits. */
  task automatic offer(input byte unsigned value, input bit admit);
    valid = 1;
    data = value;
    /* acceptance expectations are independent of the DUT's internal write pointer. */
    if (admit) begin
      expected.push_back(value);
      accepted++;
    end
    tick();
    valid = 0;
  endtask

  /* drain under the explicit free-running clock assumption. */
  task automatic drain;
    while (busy || receiving || expected.size() != 0) tick();
    repeat (3) tick();
  endtask

  /* cover full capacity, simultaneous refill, overflow, wrap and partial-frame reset. */
  initial begin
    repeat (3) tick();
    reset = 0;
    offer(8'h55, 1);
    while (!receiving) tick();
    /* hold one serializer byte plus all sixty-four FIFO slots. */
    for (integer i = 0; i < 64; i++) offer(8'(i ^ 8'ha6), 1);
    if (queued != 64 || overflow) $fatal(1, "UART full queue setup");
    while (completed != 1) tick();
    if (queued != 64) $fatal(1, "UART full queue lost bytes");
    /* the next edge dequeues and refills a full FIFO without loss. */
    offer(8'he1, 1);
    if (queued != 64 || overflow) $fatal(1, "UART simultaneous full dequeue/refill");
    offer(8'hde, 0);
    if (!overflow || queued != 64) $fatal(1, "UART overflow response");
    drain();
    if (completed != 66 || accepted != 66 || !overflow)
      $fatal(1, "UART exact-once burst or sticky overflow");
    /* idle reset clears the failure latch and both pointer generations. */
    reset = 1;
    tick();
    reset = 0;
    for (integer i = 0; i < 20; i++) offer(8'(255 - i), 1);
    repeat (DIVISOR + 3) tick();
    if (!receiving) $fatal(1, "UART partial-frame reset setup");
    reset = 1;
    tick();
    reset = 0;
    offer(8'h00, 1);
    offer(8'hff, 1);
    offer(8'haa, 1);
    drain();
    if (completed != 69 || discarded != 20 || accepted != completed + discarded || overflow)
      $fatal(1, "UART reset accounting");
    $display("UART pass clock_hz=%0d divisor=%0d accepted=%0d completed=%0d discarded=%0d checks=%0d cycles=%0d",
      CLOCK_HZ, DIVISOR, accepted, completed, discarded, checks, cycles);
    $finish;
  end
endmodule

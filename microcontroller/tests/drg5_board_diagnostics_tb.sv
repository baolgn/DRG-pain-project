/* check the physical wrapper's early stages with a controlled lock model. */
module drg5_board_diagnostics_tb;
  timeunit 1ns;
  timeprecision 1ps;
  logic clk;
  logic reset_btn = 0, event_btn = 0;
  logic [7:0] led0, led1;
  logic uart0, uart1;
  integer checks = 0;
  drg5_ulx3s #(.CLOCK_HZ(25000000), .STAGE(0)) stage0 (
    .clk25_i(clk), .reset_btn_i(reset_btn), .event_btn_i(event_btn),
    .led_o(led0), .uart_tx_o(uart0)
  );
  drg5_ulx3s #(.CLOCK_HZ(25000000), .STAGE(1)) stage1 (
    .clk25_i(clk), .reset_btn_i(reset_btn), .event_btn_i(event_btn),
    .led_o(led1), .uart_tx_o(uart1)
  );

  /* the model uses a 25 MHz clock without a generated physical PLL. */
  always #20 clk = !clk;

  /* observe after the active edge and all nonblocking updates. */
  task automatic tick;
    @(negedge clk);
  endtask

  /* each requirement records a named failure rather than only a process exit. */
  task automatic check(input logic condition, input string reason);
    checks++;
    assert (condition) else $fatal(1, "BOARD_DIAGNOSTIC_CHECK %s", reason);
  endtask

  /* both wrappers share the same external lock event. */
  task automatic set_lock(input logic value);
    stage0.pll.lock_enabled = value;
    stage1.pll.lock_enabled = value;
  endtask

  /* success or fault must finish within 768 diagnostic clocks plus release margin. */
  task automatic await_diagnostic;
    integer elapsed;
    elapsed = 0;
    /* bounded progress rejects a hung RAM state machine. */
    while (!led1[3] && !led1[5] && elapsed < 800) begin
      tick();
      elapsed++;
    end
    check(elapsed < 800, "RAM diagnostic progress");
  endtask

  /* reset, RAM results and deliberate corruption are checked independently of LEDs. */
  initial begin
    clk = 0;
    repeat (3) tick();
    check(led0[7] && led1[7], "unlocked startup reset");
    check(uart0 && uart1, "diagnostic UART idle");
    set_lock(1);
    tick();
    check(led0[7] && led1[7], "first release edge remains reset");
    tick();
    check(!led0[7] && !led1[7], "second release edge clears reset");
    await_diagnostic();
    check(led1[3] && !led1[5], "RAM success LED3");
    check(stage1.diagnostic.state_q == 3, "RAM terminal state");
    /* all words are written with distinct address-dependent values before readback. */
    for (integer index = 0; index < 256; index++) begin
      check(stage1.diagnostic.ram[index] == (32'ha55a0000 | 32'(index)), "RAM pattern");
    end
    check(led0[6:1] == 0, "clock-only stage has no RAM verdict");
    check(stage0.diagnostic.count_q >= 768, "clock-only heartbeat progress");
    event_btn = 1;
    repeat (4) tick();
    event_btn = 0;
    check(led1[3] && !led1[5], "unused event cannot reset diagnostic");

    /* an asynchronous button assertion is visible before the next clock edge. */
    #1 reset_btn = 1;
    #1;
    check(led0[7] && led1[7], "asynchronous button reset assertion");
    repeat (8) tick();
    check(!led1[3] && !led1[5] && stage1.diagnostic.count_q == 0,
          "held reset clears verdict and counter");
    reset_btn = 0;
    tick();
    check(led1[7], "button release first edge");
    tick();
    check(!led1[7], "button release second edge");
    repeat (256) tick();
    check(stage1.diagnostic.state_q == 1, "all RAM writes complete before reads");
    stage1.diagnostic.ram[255] = 0;
    await_diagnostic();
    check(led1[5] && !led1[3], "corrupted last RAM word rejects pass");

    /* loss of lock also asserts immediately and restarts the complete RAM test. */
    #1 set_lock(0);
    #1;
    check(led0[7] && led1[7], "asynchronous lock-loss reset assertion");
    repeat (4) tick();
    check(!led1[3] && !led1[5], "lock loss clears old verdict");
    set_lock(1);
    tick();
    check(led1[7], "lock restoration first edge");
    tick();
    check(!led1[7], "lock restoration second edge");
    await_diagnostic();
    check(led1[3] && !led1[5], "reset rewrites corrupted RAM");
    $display("BOARD_DIAGNOSTICS_PASS checks=%0d", checks);
    $finish;
  end

  /* a stopped test cannot masquerade as a successful finite diagnostic. */
  initial begin
    #200000;
    $fatal(1, "BOARD_DIAGNOSTIC_CHECK test timeout");
  end
endmodule

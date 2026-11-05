/* load validated flash applications without changing the persistent FPGA configuration. */
module drg5_ulx3s_programmable #(
  parameter integer CLOCK_HZ = 25000000,
  parameter integer STAGE = 2,
  parameter ROM_FILE = "rom.hex"
) (
  input logic clk25_i, reset_btn_i, event_btn_i, flash_miso_i,
  output logic [7:0] led_o,
  output logic uart_tx_o, flash_cs_n_o, flash_mosi_o, flash_hold_n_o, flash_wp_n_o
);
  logic clk_cpu, locked, reset_async, reset, flash_sck;
  (* async_reg = "true" *) logic [1:0] reset_release_q = 2'b11;
  (* async_reg = "true" *) logic force_meta_q = 0, force_sync_q = 0;
  logic uart_busy, uart_overflow, output_valid, status_write, fatal, idle, busy;
  logic boot_busy, boot_done, boot_fault, boot_bank, cpu_reset;
  logic [1:0] boot_headers;
  logic [3:0] boot_reason;
  logic [6:0] uart_queued;
  logic [7:0] output_data;
  logic [31:0] status, mepc, mcause, mtval;
  logic [63:0] mcycle, minstret, mtime;
  logic [96:0] irq_event;
  drg5_control_pkg::trace_t trace_record;
  logic unused_observation;

  /* actual clock and analysis profile are generated together by the qualified route driver. */
  drg5_board_pll pll (.clk25_i, .clk_cpu_o(clk_cpu), .locked_o(locked));
  assign reset_async = reset_btn_i || !locked;
  assign reset = reset_release_q[1];
  assign flash_hold_n_o = 1;
  assign flash_wp_n_o = 1;

  /* keep SCK driven until a read abort has deselected flash; reset may terminate a read immediately. */
  USRMCLK flash_clock (.USRMCLKI(flash_sck), .USRMCLKTS(reset || (!boot_busy && flash_cs_n_o)));

  /* a held board reset or PLL loss asserts reset immediately; release waits two working clocks. */
  always_ff @(posedge clk_cpu or posedge reset_async) begin
    if (reset_async) reset_release_q <= 2'b11;
    else reset_release_q <= {reset_release_q[0], 1'b0};
  end

  /* the recovery button synchronizes even while reset is held, before the boot choice is sampled. */
  always_ff @(posedge clk_cpu) begin
    force_meta_q <= event_btn_i;
    force_sync_q <= force_meta_q;
  end

  /* hardware performs read-only SPI validation; ordinary firmware has no flash-programming port. */
  drg5_programmable_system #(.CLOCK_HZ(CLOCK_HZ), .ROM_FILE(ROM_FILE), .ROM_CRC32(32'h7309d786)) system (
    .clk_i(clk_cpu), .reset_i(reset), .force_a_i(force_sync_q), .flash_miso_i,
    .flash_cs_n_o, .flash_sck_o(flash_sck), .flash_mosi_o,
    .boot_busy_o(boot_busy), .boot_done_o(boot_done), .boot_fault_o(boot_fault), .boot_bank_o(boot_bank),
    .boot_headers_o(boot_headers), .boot_reason_o(boot_reason), .cpu_reset_o(cpu_reset),
    .uart_tx_o, .uart_busy_o(uart_busy), .uart_overflow_o(uart_overflow), .uart_queued_o(uart_queued),
    .led_o, .output_valid_o(output_valid), .status_write_o(status_write), .output_data_o(output_data),
    .status_o(status), .fatal_o(fatal), .idle_o(idle), .busy_o(busy), .trace_o(trace_record), .irq_event_o(irq_event),
    .mepc_o(mepc), .mcause_o(mcause), .mtval_o(mtval), .mcycle_o(mcycle), .minstret_o(minstret), .mtime_o(mtime)
  );

`ifndef SYNTHESIS
  /* progressive earlier images use a separate top, never an ambiguous unsupported parameter. */
  initial begin
    assert (STAGE == 2) else $fatal(1, "programmable top supports stage two only");
  end
`endif
  assign unused_observation = ^{STAGE, uart_busy, uart_overflow, uart_queued, output_valid, status_write,
      output_data, status, fatal, idle, busy, trace_record, irq_event, mepc, mcause, mtval,
      mcycle, minstret, mtime, boot_done, boot_fault, boot_bank, boot_headers, boot_reason, cpu_reset};
endmodule

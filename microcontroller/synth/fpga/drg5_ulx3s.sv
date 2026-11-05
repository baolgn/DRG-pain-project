/* qualify clock/reset, synchronous RAM and the local CPU on the exact ULX3S pin map. */
module drg5_ulx3s #(
  parameter integer CLOCK_HZ = 80000000,
  parameter integer STAGE = 2,
  parameter ROM_FILE = "rom.hex",
  parameter IRAM_FILE = "iram.hex"
) (
  input logic clk25_i, reset_btn_i, event_btn_i,
  output logic [7:0] led_o,
  output logic uart_tx_o
);
  logic clk_cpu, locked, reset_async, reset;
  (* async_reg = "true" *) logic [1:0] reset_release_q = 2'b11;
  logic unused_observation;

  /* the generated PLL and timing profile must describe the same physical output frequency. */
  drg5_board_pll pll (.clk25_i, .clk_cpu_o(clk_cpu), .locked_o(locked));
  assign reset_async = reset_btn_i || !locked;
  assign reset = reset_release_q[1];

  /* loss of lock or a held reset button asserts immediately; release takes two fabric edges. */
  always_ff @(posedge clk_cpu or posedge reset_async) begin
    if (reset_async) reset_release_q <= 2'b11;
    else reset_release_q <= {reset_release_q[0], 1'b0};
  end

  /* early stages avoid CPU state while checking the clock, reset and a synchronous RAM port. */
  generate if (STAGE < 2) begin : diagnostic
    logic [31:0] count_q;
    logic [31:0] ram [0:255];
    logic [31:0] data_q;
    logic [7:0] address_q;
    logic [1:0] state_q;
    logic passed_q, failed_q;
    logic [31:0] pattern;
    assign pattern = 32'ha55a0000 | {24'b0, address_q};
    assign uart_tx_o = 1;
    assign led_o = {reset, 1'b0, failed_q, 1'b0, passed_q, 2'b0, count_q[24]};
    assign unused_observation = event_btn_i;

    /* native RAM receives a registered read and a single synchronous write port. */
    always_ff @(posedge clk_cpu) begin
      if (!reset && STAGE == 1 && state_q == 0) ram[address_q] <= pattern;
      if (!reset && STAGE == 1 && state_q == 1) data_q <= ram[address_q];
    end

    /* fill every word, then compare registered reads before declaring diagnostic success. */
    always_ff @(posedge clk_cpu) begin
      /* restart diagnostics without assuming any RAM power-up contents. */
      if (reset) begin
        count_q <= 0;
        address_q <= 0;
        state_q <= 0;
        passed_q <= 0;
        failed_q <= 0;
      /* the heartbeat remains observable after the finite RAM check. */
      end else begin
        count_q <= count_q + 1'b1;
        /* stage zero only verifies reference/PLL/reset and heartbeat behavior. */
        if (STAGE == 1) begin
          case (state_q)
            /* write all addresses before beginning readback. */
            0: begin
              address_q <= address_q + 1'b1;
              if (address_q == 255) state_q <= 1;
            end
            1: state_q <= 2;
            /* synchronous read data belongs to the unchanged address. */
            2: begin
              if (data_q != pattern) failed_q <= 1;
              address_q <= address_q + 1'b1;
              state_q <= address_q == 255 ? 3 : 1;
              if (address_q == 255) passed_q <= !failed_q && data_q == pattern;
            end
            default: state_q <= state_q;
          endcase
        end
      end
    end
  /* the integrated image runs the same compiled program used by the portable board simulation. */
  end else begin : application
    logic uart_busy, uart_overflow, output_valid, status_write, fatal, idle, busy;
    logic [6:0] uart_queued;
    logic [7:0] output_data;
    logic [31:0] status, mepc, mcause, mtval;
    logic [63:0] mcycle, minstret, mtime;
    logic [96:0] irq_event;
    drg5_control_pkg::trace_t trace_record;
    drg5_board_system #(.CLOCK_HZ(CLOCK_HZ), .ROM_FILE(ROM_FILE), .IRAM_FILE(IRAM_FILE)) system (
      .clk_i(clk_cpu), .reset_i(reset), .event_btn_i, .uart_tx_o,
      .uart_busy_o(uart_busy), .uart_overflow_o(uart_overflow), .uart_queued_o(uart_queued),
      .led_o, .output_valid_o(output_valid), .status_write_o(status_write), .output_data_o(output_data),
      .status_o(status), .fatal_o(fatal), .idle_o(idle), .busy_o(busy), .trace_o(trace_record),
      .irq_event_o(irq_event), .mepc_o(mepc), .mcause_o(mcause), .mtval_o(mtval),
      .mcycle_o(mcycle), .minstret_o(minstret), .mtime_o(mtime)
    );
    assign unused_observation = ^{uart_busy, uart_overflow, uart_queued, output_valid, status_write,
        output_data, status, fatal, idle, busy, trace_record, irq_event, mepc, mcause, mtval, mcycle, minstret, mtime};
  end endgenerate
endmodule

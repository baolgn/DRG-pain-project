/* run the local CPU image with physical UART output and retained diagnostic interrupts. */
module drg5_board_system #(
  parameter integer CLOCK_HZ = 80000000,
  parameter ROM_FILE = "rom.hex",
  parameter IRAM_FILE = "iram.hex",
  parameter DRAM_FILE = "",
  parameter bit FORWARDING = 1
) (
  input logic clk_i, reset_i, event_btn_i,
  output logic uart_tx_o, uart_busy_o, uart_overflow_o,
  output logic [6:0] uart_queued_o,
  output logic [7:0] led_o,
  output logic output_valid_o, status_write_o,
  output logic [7:0] output_data_o,
  output logic [31:0] status_o,
  output logic fatal_o, idle_o, busy_o,
  output drg5_control_pkg::trace_t trace_o,
  output logic [96:0] irq_event_o,
  output logic [31:0] mepc_o, mcause_o, mtval_o,
  output logic [63:0] mcycle_o, minstret_o, mtime_o
);
  localparam integer HEARTBEAT = CLOCK_HZ / 2;
  (* async_reg = "true" *) logic event_meta_q, event_sync_q;
  logic event_previous_q, heartbeat_q, diagnostic_sent_q;
  logic [31:0] heartbeat_count_q;
  logic [31:1] events;
  logic [31:0] ext_pending, ext_enable;
  logic unused_observation;
  logic iv, ir, rv, rr, dv, dr, dw, sv, sr;
  logic [31:0] ia, it, rt, rd, da, dd, dt, st, sd;
  logic [1:0] ip, rp, rf, rs, ds, ss;
  logic [3:0] de;
  logic [2:0] fetch_reason;
  drg5_control_pkg::fatal_record_t core_record;

  /* only rising synchronized button edges request source three; contact bounce may coalesce. */
  assign events = {28'b0, event_sync_q && !event_previous_q,
                   output_valid_o && output_data_o == 8'h52 && !diagnostic_sent_q, 1'b0};

  /* source two loops back only the first diagnostic request per reset, independently of UART drain. */
  drg5_soc #(.ROM_FILE(ROM_FILE), .IRAM_FILE(IRAM_FILE), .DRAM_FILE(DRAM_FILE),
      .FORWARDING(FORWARDING)) soc (
    .clk_i, .reset_i, .isolated_i(reset_i), .permit_i(!uart_overflow_o), .hold_i(5'b0),
    .i_accept_delay_i(4'b0), .i_response_delay_i(4'd1),
    .d_accept_delay_i(4'b0), .d_response_delay_i(4'd1), .event_set_i(events), .block_ready_i(1'b0),
    .i_req_valid_o(iv), .i_req_ready_o(ir), .i_req_addr_o(ia), .i_req_tag_o(it), .i_req_parcels_o(ip),
    .i_rsp_valid_o(rv), .i_rsp_ready_o(rr), .i_rsp_tag_o(rt), .i_rsp_data_o(rd),
    .i_rsp_parcels_o(rp), .i_rsp_fault_o(rf), .i_rsp_status_o(rs),
    .d_req_valid_o(dv), .d_req_ready_o(dr), .d_req_addr_o(da), .d_req_wdata_o(dd), .d_req_tag_o(dt),
    .d_req_write_o(dw), .d_req_size_o(ds), .d_req_wstrb_o(de),
    .d_rsp_valid_o(sv), .d_rsp_ready_o(sr), .d_rsp_tag_o(st), .d_rsp_rdata_o(sd), .d_rsp_status_o(ss),
    .status_write_o, .output_valid_o, .status_o, .output_data_o, .fatal_o, .idle_o, .busy_o,
    .fetch_fatal_reason_o(fetch_reason), .core_fatal_record_o(core_record), .irq_event_o, .trace_o,
    .mepc_o, .mcause_o, .mtval_o, .mcycle_o, .minstret_o, .mtime_o,
    .ext_pending_o(ext_pending), .ext_enable_o(ext_enable)
  );

  /* the twenty-byte self-test burst fits without assuming CPU polling or serial service. */
  drg5_uart_tx #(.CLOCK_HZ(CLOCK_HZ)) uart (
    .clk_i, .reset_i, .valid_i(output_valid_o), .data_i(output_data_o),
    .tx_o(uart_tx_o), .busy_o(uart_busy_o), .overflow_o(uart_overflow_o), .queued_o(uart_queued_o)
  );

  /* a fabric heartbeat continues during WFI, CPU stalls and all exception handling. */
  always_ff @(posedge clk_i) begin
    /* the synchronous board reset initializes control only, never ordinary CPU storage. */
    if (reset_i) begin
      event_meta_q <= 0;
      event_sync_q <= 0;
      event_previous_q <= 0;
      heartbeat_count_q <= 0;
      heartbeat_q <= 0;
      diagnostic_sent_q <= 0;
    /* synchronize the external button before forming a fabric-domain event. */
    end else begin
      event_meta_q <= event_btn_i;
      event_sync_q <= event_meta_q;
      event_previous_q <= event_sync_q;
      if (output_valid_o && output_data_o == 8'h52) diagnostic_sent_q <= 1;
      /* toggle at one hertz without gating the CPU or peripheral clocks. */
      if (heartbeat_count_q == HEARTBEAT - 1) begin
        heartbeat_count_q <= 0;
        heartbeat_q <= !heartbeat_q;
      end else heartbeat_count_q <= heartbeat_count_q + 1'b1;
    end
  end

  /* LEDs expose activity, verdict, containment and output congestion. */
  assign led_o = {reset_i, uart_overflow_o, fatal_o, status_o == 3,
                  status_o == 1 && !fatal_o && !uart_overflow_o, uart_busy_o, idle_o, heartbeat_q};
  assign unused_observation = ^{iv, ir, ia, it, ip, rv, rr, rt, rd, rp, rf, rs,
      dv, dr, da, dd, dt, dw, ds, de, sv, sr, st, sd, ss, fetch_reason, core_record, ext_pending, ext_enable};
endmodule

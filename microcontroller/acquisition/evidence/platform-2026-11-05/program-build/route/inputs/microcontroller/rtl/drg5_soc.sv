/* run compiled M-only firmware entirely from initialized local storage. */
module drg5_soc #(
  parameter ROM_FILE = "",
  parameter IRAM_FILE = "",
  parameter DRAM_FILE = "",
  parameter bit C_ENABLED = 1,
  parameter bit M_ENABLED = 1,
  parameter bit DIAGNOSTIC = 0,
  parameter bit FORWARDING = 1
) (
  input logic clk_i, reset_i, isolated_i, permit_i,
  input logic [4:0] hold_i,
  input logic [3:0] i_accept_delay_i, i_response_delay_i,
  input logic [3:0] d_accept_delay_i, d_response_delay_i,
  input logic [31:1] event_set_i,
  input logic block_ready_i,
  output logic i_req_valid_o, i_req_ready_o,
  output logic [31:0] i_req_addr_o, i_req_tag_o,
  output logic [1:0] i_req_parcels_o,
  output logic i_rsp_valid_o, i_rsp_ready_o,
  output logic [31:0] i_rsp_tag_o, i_rsp_data_o,
  output logic [1:0] i_rsp_parcels_o, i_rsp_fault_o, i_rsp_status_o,
  output logic d_req_valid_o, d_req_ready_o,
  output logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o,
  output logic d_req_write_o,
  output logic [1:0] d_req_size_o,
  output logic [3:0] d_req_wstrb_o,
  output logic d_rsp_valid_o, d_rsp_ready_o,
  output logic [31:0] d_rsp_tag_o, d_rsp_rdata_o,
  output logic [1:0] d_rsp_status_o,
  output logic status_write_o, output_valid_o,
  output logic [31:0] status_o,
  output logic [7:0] output_data_o,
  output logic fatal_o, idle_o, busy_o,
  output logic [2:0] fetch_fatal_reason_o,
  output drg5_control_pkg::fatal_record_t core_fatal_record_o,
  output logic [96:0] irq_event_o,
  output drg5_control_pkg::trace_t trace_o,
  output logic [31:0] mepc_o, mcause_o, mtval_o,
  output logic [63:0] mcycle_o, minstret_o, mtime_o,
  output logic [31:0] ext_pending_o, ext_enable_o
);
  import drg5_control_pkg::*;
  logic fetch_busy, fetch_fatal, core_fatal, entry_pending, frontend_valid, frontend_ready;
  logic redirect;
  logic [31:0] redirect_pc, mip_levels;
  packet_t packet;
  logic [4:0] stages, kills;
  token_t stage_tokens [0:4];
  logic [63:0] kill_uids [0:4];
  logic [3:0] transfers;
  logic [1:0] fetch_generation, packet_generation;
  logic fetch_discard, fetch_launch, fetch_accept, fetch_complete, fetch_drop;
  logic [2:0] fetch_reason;
  logic irq_valid, flush_ready, flush_aborted, mem_launch, mem_busy, inspect_defined;
  logic [31:0] irq_pc, irq_cause, inspect_value, mstatus, mtvec, mscratch, mie, mip, inhibit;
  fatal_record_t fatal_record;
  logic fabric_busy;
  logic unused_debug_halted, unused_debug_resumeack, unused_debug_reg_ready;
  logic [31:0] unused_debug_dpc, unused_debug_dcsr, unused_debug_reg_rdata;
  logic [2:0] unused_debug_reg_error;
  logic unused_observation;

  /* local storage and peripherals remain clocked while useful CPU issue is paused. */
  drg5_local_fabric #(.ROM_FILE(ROM_FILE), .IRAM_FILE(IRAM_FILE), .DRAM_FILE(DRAM_FILE)) fabric (
    .clk_i, .reset_i, .isolated_i, .i_accept_delay_i, .i_response_delay_i, .d_accept_delay_i, .d_response_delay_i,
    .i_req_valid_i(i_req_valid_o), .i_req_ready_o, .i_req_addr_i(i_req_addr_o), .i_req_tag_i(i_req_tag_o),
    .i_req_parcels_i(i_req_parcels_o), .i_rsp_valid_o, .i_rsp_ready_i(i_rsp_ready_o),
    .i_rsp_tag_o, .i_rsp_data_o, .i_rsp_parcels_o, .i_rsp_fault_o, .i_rsp_status_o,
    .d_req_valid_i(d_req_valid_o), .d_req_ready_o, .d_req_addr_i(d_req_addr_o), .d_req_wdata_i(d_req_wdata_o),
    .d_req_tag_i(d_req_tag_o), .d_req_write_i(d_req_write_o), .d_req_size_i(d_req_size_o),
    .d_req_wstrb_i(d_req_wstrb_o), .d_rsp_valid_o, .d_rsp_ready_i(d_rsp_ready_o),
    .d_rsp_tag_o, .d_rsp_rdata_o, .d_rsp_status_o, .event_set_i, .block_ready_i,
    .mip_levels_o(mip_levels), .ext_pending_o, .ext_enable_o, .mtime_o,
    .status_write_o, .status_o, .output_valid_o, .output_data_o, .busy_o(fabric_busy)
  );
  assign busy_o = fetch_busy || mem_busy || fabric_busy;
  assign fatal_o = core_fatal || fetch_fatal;
  /* expose sticky failure provenance without changing containment or transaction ownership. */
  assign fetch_fatal_reason_o = fetch_reason;
  assign core_fatal_record_o = fatal_record;
  assign irq_event_o = {irq_valid, irq_pc, irq_cause, mtvec};

  /* execute permissions and obsolete-response ownership remain in the production frontend. */
  drg5_frontend #(.C_ENABLED(C_ENABLED), .GEN_BITS(2), .MAX_WAIT_CYCLES(128)) frontend (
    .clk_i, .cold_reset_i(reset_i), .isolated_i, .hart_reset_i(1'b0),
    .permit_i, .entry_pending_i(entry_pending), .core_fatal_i(core_fatal),
    .redirect_valid_i(redirect), .redirect_pc_i(redirect_pc),
    .i_req_valid_o, .i_req_ready_i(i_req_ready_o), .i_req_addr_o, .i_req_tag_o, .i_req_parcels_o,
    .i_rsp_valid_i(i_rsp_valid_o), .i_rsp_ready_o, .i_rsp_tag_i(i_rsp_tag_o), .i_rsp_data_i(i_rsp_data_o), .i_rsp_parcels_i(i_rsp_parcels_o), .i_rsp_fault_i(i_rsp_fault_o), .i_rsp_status_i(i_rsp_status_o),
    .insn_valid_o(frontend_valid), .insn_ready_i(frontend_ready), .insn_packet_o(packet),
    .busy_o(fetch_busy), .discard_o(fetch_discard), .fatal_o(fetch_fatal), .fatal_reason_o(fetch_reason),
    .generation_o(fetch_generation), .insn_generation_o(packet_generation),
    .launch_o(fetch_launch), .accept_o(fetch_accept), .complete_o(fetch_complete), .drop_o(fetch_drop)
  );

  /* the local prototype executes raw instructions with IRQ, timer and instruction synchronization. */
  drg5_control #(.C_ENABLED(C_ENABLED), .M_ENABLED(M_ENABLED), .IRQ_ENABLED(1), .TIMER_ENABLED(1),
      .ZIFENCEI_ENABLED(1), .IRAM_WRITE(1), .DIAGNOSTIC(DIAGNOSTIC), .FORWARDING(FORWARDING),
      .D_MAX_WAIT_CYCLES(128)) core (
    .clk_i, .cold_reset_i(reset_i), .isolated_i, .hart_reset_i(1'b0), .mip_levels_i(mip_levels),
    .fetch_busy_i(fetch_busy), .entry_pending_o(entry_pending), .idle_o,
    .irq_valid_o(irq_valid), .irq_pc_o(irq_pc), .irq_cause_o(irq_cause), .hold_i,
    .in_valid_i(frontend_valid), .in_ready_o(frontend_ready), .in_packet_i(packet),
    .flush_valid_i(1'b0), .flush_ready_o(flush_ready), .flush_pc_i(32'b0), .flush_aborted_o(flush_aborted),
    .redirect_valid_o(redirect), .redirect_pc_o(redirect_pc),
    .d_req_valid_o, .d_req_ready_i(d_req_ready_o), .d_req_addr_o, .d_req_wdata_o, .d_req_write_o, .d_req_size_o,
    .d_req_wstrb_o, .d_req_tag_o, .d_rsp_valid_i(d_rsp_valid_o), .d_rsp_ready_o, .d_rsp_tag_i(d_rsp_tag_o), .d_rsp_rdata_i(d_rsp_rdata_o),
    .d_rsp_status_i(d_rsp_status_o), .mem_launch_o(mem_launch), .mem_busy_o(mem_busy), .fatal_o(core_fatal),
    .fatal_record_o(fatal_record), .stage_valid_o(stages), .stage_token_o(stage_tokens),
    .transfer_o(transfers), .kill_valid_o(kills), .kill_uid_o(kill_uids), .trace_o,
    .inspect_reg_i(5'b0), .inspect_value_o(inspect_value), .inspect_defined_o(inspect_defined),
    .mstatus_o(mstatus), .mtvec_o(mtvec), .mscratch_o(mscratch), .mepc_o, .mcause_o, .mtval_o,
    .mie_o(mie), .mip_o(mip), .mcountinhibit_o(inhibit), .mcycle_o, .minstret_o,
    .debug_haltreq_i(1'b0), .debug_resumereq_i(1'b0), .debug_resethaltreq_i(1'b0),
    .debug_halted_o(unused_debug_halted), .debug_resumeack_o(unused_debug_resumeack),
    .debug_dpc_o(unused_debug_dpc), .debug_dcsr_o(unused_debug_dcsr),
    .debug_reg_valid_i(1'b0), .debug_reg_write_i(1'b0), .debug_reg_addr_i(16'b0), .debug_reg_wdata_i(32'b0),
    .debug_reg_ready_o(unused_debug_reg_ready), .debug_reg_rdata_o(unused_debug_reg_rdata), .debug_reg_error_o(unused_debug_reg_error)
  );

  /* unused diagnostics remain observational and cannot constrain the architectural test. */
  assign unused_observation = ^{stages, kills, stage_tokens[0], stage_tokens[1], stage_tokens[2],
      stage_tokens[3], stage_tokens[4], kill_uids[0], kill_uids[1], kill_uids[2], kill_uids[3], kill_uids[4],
      transfers, fetch_generation, packet_generation, fetch_discard, fetch_launch, fetch_accept, fetch_complete,
      fetch_drop, fetch_reason, flush_ready, flush_aborted, mem_launch, mem_busy, inspect_value, inspect_defined,
      mstatus, mscratch, mie, mip, inhibit, fatal_record};
endmodule

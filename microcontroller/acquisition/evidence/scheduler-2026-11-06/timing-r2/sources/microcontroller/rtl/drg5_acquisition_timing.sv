/* connect command admission and fixed-grid scheduling through one acquisition timebase. */
module drg5_acquisition_timing #(
  parameter integer CONFIG_CYCLES = 239976000,
  parameter integer CANCEL_CYCLES = 1119,
  parameter integer CLOSE_CYCLES = 799920,
  parameter integer HANDOFF_CYCLES = 80,
  parameter logic [63:0] COUNTER_LIMIT = 64'hffffffffffffffff
) (
  input logic clk_i, system_reset_i, cpu_reset_i, cpu_halt_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic req_write_i,
  input logic [11:0] req_addr_i,
  input logic [31:0] req_wdata_i, req_tag_i,
  input logic [3:0] req_wstrb_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [31:0] rsp_rdata_o, rsp_tag_o,
  output logic rsp_error_o,
  input logic session_verified_i,
  input logic [127:0] session_id_i,
  input logic qualification_valid_i,
  input logic [63:0] qualification_config_id_i,
  input logic [255:0] qualification_digest_i,
  input logic [63:0] qualification_timebase_id_i,
  input logic [31:0] qualification_manifest_length_i,
  input logic physical_ready_i, metadata_archived_i, ownership_clear_i, pins_idle_i,
  input logic [6:0] free_blocks_i,
  input logic emergency_stop_i,
  input logic [31:0] fault_i,
  input logic supervisor_fault_i,
  input logic backend_valid_i, backend_ok_i,
  input logic [1:0] backend_phase_i,
  input logic [63:0] backend_command_id_i,
  output logic service_valid_o, service_cancel_o,
  output logic [1:0] service_phase_o,
  output logic [63:0] service_command_id_o,
  output logic [767:0] service_config_o,
  input logic close_valid_i,
  input logic [63:0] close_epoch_i,
  input logic [1:0] close_result_i,
  output logic close_request_o, terminal_sealed_o,
  output logic [63:0] epoch_o, first_tick_o,
  output logic [63:0] tick_o, arm_commit_epoch_o, arm_commit_first_tick_o,
  output logic arm_commit_o,
  output logic arm_o, run_permit_o, stop_o, isolate_o, irq_o,
  output logic [3:0] state_o,
  input logic capture_idle_i, record_credit_i, storage_available_i,
  input logic [8:0] fifo_occupancy_i,
  output logic scheduler_active_o, pulse_busy_o, convst_o, launch_o,
  output logic [63:0] launch_epoch_o, launch_slot_o, launch_tick_o,
  output logic outcome_valid_o,
  input logic outcome_ready_i,
  output logic outcome_triggered_o,
  output logic [63:0] outcome_epoch_o, outcome_slot_o, outcome_tick_o,
  output logic [31:0] outcome_causes_o,
  output logic end_valid_o,
  input logic end_ack_i,
  input logic [63:0] end_ack_epoch_i,
  output logic [31:0] end_ack_result_o,
  output logic [63:0] end_epoch_o, end_tick_o, end_delivered_o,
  output logic [63:0] scheduled_o, emitted_o, missing_o, delivered_o,
  output logic last_slot_known_o,
  output logic [63:0] last_slot_o, last_tick_o,
  output logic exact_o, loss_valid_o, loss_last_known_o,
  output logic [63:0] loss_first_o, loss_last_o,
  output logic [31:0] end_causes_o,
  output logic scheduler_fault_o, scheduler_isolate_o,
  output logic [31:0] scheduler_sticky_o, scheduler_first_fault_o, scheduler_latest_fault_o,
  output logic [63:0] scheduler_first_fault_tick_o, scheduler_latest_fault_tick_o
);
  logic scheduler_ready, scheduler_accept, control_isolate;
  logic scheduler_quiescent, control_ownership_clear, control_pins_idle;
  logic end_ack_allowed, arm_link_fault_q;
  logic [31:0] scheduler_arm_result, scheduler_ack_result, merged_faults;
  logic [1:0] effective_close_result;

  /* capture closure cannot certify a live pulse or an unretired scheduler notification. */
  assign scheduler_quiescent = !scheduler_active_o && !pulse_busy_o && !outcome_valid_o && capture_idle_i;
  assign control_pins_idle = pins_idle_i && !pulse_busy_o;
  assign control_ownership_clear = ownership_clear_i && scheduler_quiescent &&
    (close_request_o ? end_valid_o && end_epoch_o == epoch_o : !end_valid_o);
  /* a backend archives the full scheduler receipt separately from control's epoch/code receipt. */
  assign end_ack_allowed = terminal_sealed_o && end_epoch_o == epoch_o &&
    !close_request_o && scheduler_quiescent && ownership_clear_i && pins_idle_i;
  assign end_ack_result_o = end_ack_i && !end_ack_allowed ? 32'd7 : scheduler_ack_result;
  assign merged_faults = {fault_i[31:16], 1'b0, fault_i[14:0]} |
    ((arm_link_fault_q || fault_i[15]) ? 32'h80000000 : 32'b0);
  assign isolate_o = control_isolate || scheduler_isolate_o;
  /* a backend cannot downgrade known scheduler uncertainty or hide a malformed result. */
  assign effective_close_result = close_result_i != 3 && !exact_o ? 2'd2 : close_result_i;

  /* a rejected committed binding is a retained protocol fault, never an automatic retry. */
  always_ff @(posedge clk_i) begin
    if (system_reset_i) arm_link_fault_q <= 0;
    else arm_link_fault_q <= arm_commit_o && (!scheduler_accept || scheduler_arm_result != 1);
  end

  /* bus outcomes and fault evidence remain independent of scheduler notification backpressure. */
  drg5_acquisition_control #(
    .CONFIG_CYCLES(CONFIG_CYCLES), .CANCEL_CYCLES(CANCEL_CYCLES),
    .CLOSE_CYCLES(CLOSE_CYCLES), .COUNTER_LIMIT(COUNTER_LIMIT)
  ) control (
    .clk_i, .system_reset_i, .cpu_reset_i, .cpu_halt_i,
    .req_valid_i, .req_ready_o, .req_write_i, .req_addr_i, .req_wdata_i, .req_tag_i, .req_wstrb_i,
    .rsp_valid_o, .rsp_ready_i, .rsp_rdata_o, .rsp_tag_o, .rsp_error_o,
    .session_verified_i, .session_id_i, .qualification_valid_i, .qualification_config_id_i,
    .qualification_digest_i, .qualification_timebase_id_i, .qualification_manifest_length_i,
    .physical_ready_i, .metadata_archived_i, .ownership_clear_i(control_ownership_clear),
    .pins_idle_i(control_pins_idle), .arm_ready_i(scheduler_ready), .free_blocks_i,
    .emergency_stop_i, .fault_i(merged_faults),
    .fault_occurrence_i({scheduler_fault_o, 15'b0}), .supervisor_fault_i,
    .backend_valid_i, .backend_ok_i, .backend_phase_i, .backend_command_id_i,
    .service_valid_o, .service_cancel_o, .service_phase_o, .service_command_id_o, .service_config_o,
    .close_valid_i, .close_epoch_i, .close_result_i(effective_close_result),
    .close_request_o, .terminal_sealed_o, .epoch_o, .first_tick_o,
    .tick_o, .arm_commit_o, .arm_commit_epoch_o, .arm_commit_first_tick_o,
    .arm_o, .run_permit_o, .stop_o, .isolate_o(control_isolate), .irq_o, .state_o
  );

  /* the scheduler sees ARM on acceptance edge A, before the due edge A+1. */
  drg5_acquisition_scheduler #(
    .COUNTER_LIMIT(COUNTER_LIMIT), .HANDOFF_CYCLES(HANDOFF_CYCLES)
  ) scheduler (
    .clk_i, .system_reset_i, .tick_i(tick_o), .timebase_exhausted_i(&tick_o),
    .arm_i(arm_commit_o), .arm_epoch_i(arm_commit_epoch_o), .arm_first_tick_i(arm_commit_first_tick_o),
    .arm_period_i(32'd1600), .arm_ready_o(scheduler_ready), .arm_accept_o(scheduler_accept),
    .arm_result_o(scheduler_arm_result), .stop_i(stop_o), .cpu_reset_i, .cpu_halt_i,
    .qualified_i(physical_ready_i && session_verified_i), .supervisor_fault_i, .isolate_i(control_isolate),
    .capture_idle_i, .record_credit_i, .storage_available_i, .fifo_occupancy_i,
    .active_o(scheduler_active_o), .pulse_busy_o, .convst_o, .launch_o,
    .launch_epoch_o, .launch_slot_o, .launch_tick_o,
    .outcome_valid_o, .outcome_ready_i, .outcome_triggered_o,
    .outcome_epoch_o, .outcome_slot_o, .outcome_tick_o, .outcome_causes_o,
    .end_valid_o, .end_ack_i(end_ack_i && end_ack_allowed), .end_ack_epoch_i,
    .end_ack_result_o(scheduler_ack_result), .end_epoch_o, .end_tick_o, .end_delivered_o,
    .scheduled_o, .emitted_o, .missing_o, .delivered_o, .last_slot_known_o, .last_slot_o, .last_tick_o,
    .exact_o, .loss_valid_o, .loss_last_known_o, .loss_first_o, .loss_last_o, .end_causes_o,
    .fault_o(scheduler_fault_o), .isolate_request_o(scheduler_isolate_o),
    .sticky_causes_o(scheduler_sticky_o), .first_fault_o(scheduler_first_fault_o),
    .latest_fault_o(scheduler_latest_fault_o), .first_fault_tick_o(scheduler_first_fault_tick_o),
    .latest_fault_tick_o(scheduler_latest_fault_tick_o)
  );
endmodule

/* bind scheduler decisions to preallocated complete-record storage in one clock domain. */
module drg5_acquisition_storage #(
  parameter integer DEPTH = 256,
  parameter logic [63:0] COUNTER_LIMIT = 64'hffffffffffffffff
) (
  input logic clk_i, system_reset_i, prepare_i, stop_i,
  input logic arm_i,
  input logic [63:0] arm_epoch_i, arm_first_tick_i,
  input logic scheduler_active_i, scheduler_end_valid_i,
  input logic launch_i,
  input logic [63:0] launch_epoch_i, launch_slot_i, launch_tick_i,
  input logic outcome_valid_i, outcome_triggered_i,
  input logic [63:0] outcome_epoch_i, outcome_slot_i, outcome_tick_i,
  output logic outcome_ready_o,
  output logic arm_ready_o, record_credit_o, capture_idle_o, drained_o,
  output logic [8:0] occupancy_o,
  output logic capture_start_o,
  output logic [63:0] capture_id_o,
  input logic complete_valid_i,
  output logic complete_ready_o,
  input logic [63:0] complete_id_i,
  input logic [383:0] complete_record_i,
  output logic [3:0] complete_result_o,
  input logic cancel_i,
  input logic [63:0] cancel_epoch_i, cancel_slot_i,
  output logic [3:0] cancel_result_o,
  output logic dma_valid_o,
  input logic dma_ready_i,
  output logic [383:0] dma_record_o,
  output logic [63:0] dma_epoch_o, dma_slot_o,
  output logic dma_owned_o, dma_sent_o,
  input logic dma_done_i,
  input logic [63:0] dma_done_epoch_i, dma_done_slot_i,
  output logic [3:0] dma_done_result_o,
  output logic [8:0] reserved_count_o, capture_count_o, missing_count_o,
  output logic [8:0] assembler_count_o, fifo_count_o, dma_count_o,
  output logic [63:0] allocated_o, unused_released_o, retired_o, admitted_o,
  output logic stop_request_o, fault_o,
  output logic [31:0] link_faults_o, record_faults_o
);
  logic reserved, reserve, release_spare, admit, confirm_q, confirm_match, launch_room, missing_offer, missing_ready;
  logic [63:0] reservation_id, confirm_epoch_q, confirm_slot_q, confirm_tick_q;
  logic [63:0] admit_epoch, admit_slot, admit_tick;
  logic [3:0] bind_result, reserve_result, release_result, admit_result;
  logic record_fault, reserve_ready, bound;
  logic [63:0] bound_epoch, bound_first_tick;
  logic [31:0] reasons;
  logic [79:0] missing_tick;

  /* capacity is owned before ARM or a due edge; no completion creates speculative credit. */
  assign record_credit_o = reserved && !confirm_q && !system_reset_i;
  assign arm_ready_o = record_credit_o && occupancy_o == 1 && !confirm_q &&
    !outcome_valid_i && !stop_request_o;
  assign reserve = prepare_i && !stop_i && !scheduler_end_valid_i &&
    !stop_request_o && !reserved && reserve_ready && !arm_i;
  /* a missing decision may arrive after active falls, so reconcile every notification first. */
  assign release_spare = reserved && !scheduler_active_i && !outcome_valid_i &&
    !confirm_q && !launch_i && !arm_i && (scheduler_end_valid_i || !prepare_i);
  assign drained_o = occupancy_o == 0 && !confirm_q && !outcome_valid_i;
  assign stop_request_o = |link_faults_o || |record_faults_o;

  /* launch installs the owner immediately; its later notification only confirms that identity. */
  assign missing_offer = outcome_valid_i && !outcome_triggered_i;
  assign missing_tick = {16'b0, bound_first_tick} + {16'b0, outcome_slot_i} * 80'd1600;
  assign missing_ready = reserved && bound && !arm_i && outcome_epoch_i == bound_epoch &&
    outcome_slot_i == admitted_o && outcome_slot_i != 64'hffffffffffffffff &&
    missing_tick[79:64] == 0 && outcome_tick_i == missing_tick[63:0];
  assign launch_room = !missing_offer &&
    (!confirm_q || (outcome_valid_i && outcome_triggered_i && confirm_match));
  assign admit = missing_offer ? missing_ready : launch_i && launch_room;
  assign admit_epoch = missing_offer ? outcome_epoch_i : launch_epoch_i;
  assign admit_slot = missing_offer ? outcome_slot_i : launch_slot_i;
  assign admit_tick = missing_offer ? outcome_tick_i : launch_tick_i;
  assign capture_start_o = launch_i && launch_room && admit_result == 1 && !system_reset_i;
  assign capture_id_o = reservation_id;
  assign confirm_match = confirm_q && outcome_epoch_i == confirm_epoch_q &&
    outcome_slot_i == confirm_slot_q && outcome_tick_i == confirm_tick_q;
  assign outcome_ready_o = !system_reset_i && outcome_valid_i &&
    (outcome_triggered_i ? confirm_match : missing_ready);

  /* malformed link events retain owners and request an autonomous stop. */
  always_comb begin
    reasons = 0;
    if (arm_i && bind_result != 1) reasons[0] = 1;
    if (launch_i && (!launch_room || admit_result != 1)) reasons[1] = 1;
    if (outcome_valid_i && !outcome_triggered_i && (launch_i || admit_result != 1)) reasons[2] = 1;
    if (outcome_valid_i && outcome_triggered_i && !confirm_match) reasons[3] = 1;
    if (launch_i && confirm_q && !(outcome_valid_i && outcome_triggered_i && confirm_match)) reasons[4] = 1;
    if (release_spare && release_result != 1) reasons[5] = 1;
    if (prepare_i && !reserved && allocated_o >= COUNTER_LIMIT) reasons[6] = 1;
    if (reserve && reserve_result != 1) reasons[7] = 1;
  end

  /* CPU reset is a stop input upstream; only contained system reset erases this link. */
  always_ff @(posedge clk_i) begin
    /* discarded context cannot report a successful acknowledgment during reset. */
    if (system_reset_i) begin
      confirm_q <= 0; confirm_epoch_q <= 0; confirm_slot_q <= 0; confirm_tick_q <= 0;
      link_faults_o <= 0; fault_o <= 0;
    /* confirmations are independent of how quickly a synthetic conversion completes. */
    end else begin
      link_faults_o <= link_faults_o | reasons;
      fault_o <= (|(reasons & ~link_faults_o)) || record_fault;
      if (outcome_valid_i && outcome_triggered_i && outcome_ready_o) confirm_q <= 0;
      /* a new launch can replace only a simultaneously confirmed older identity. */
      if (capture_start_o) begin
        confirm_q <= 1; confirm_epoch_q <= launch_epoch_i;
        confirm_slot_q <= launch_slot_i; confirm_tick_q <= launch_tick_i;
      end
    end
  end

  /* the ordered ledger charges every stage to the same finite physical ring. */
  drg5_acquisition_records #(.DEPTH(DEPTH), .COUNTER_LIMIT(COUNTER_LIMIT)) records (
    .clk_i, .system_reset_i, .inhibit_i(stop_i || stop_request_o),
    .bind_i(arm_i), .bind_epoch_i(arm_epoch_i), .bind_first_tick_i(arm_first_tick_i),
    .bind_result_o(bind_result), .epoch_o(bound_epoch), .first_tick_o(bound_first_tick), .bound_o(bound),
    .reserve_i(reserve), .reserve_ready_o(reserve_ready), .reserve_result_o(reserve_result),
    .reserved_o(reserved), .reservation_id_o(reservation_id),
    .release_i(release_spare), .release_id_i(reservation_id), .release_result_o(release_result),
    .admit_i(admit), .admit_id_i(reservation_id), .admit_epoch_i(admit_epoch),
    .admit_slot_i(admit_slot), .admit_tick_i(admit_tick), .admit_triggered_i(!missing_offer),
    .admit_result_o(admit_result), .complete_valid_i, .complete_ready_o, .complete_id_i,
    .complete_record_i, .complete_result_o, .cancel_i, .cancel_epoch_i, .cancel_slot_i, .cancel_result_o,
    .dma_valid_o, .dma_ready_i, .dma_record_o, .dma_epoch_o, .dma_slot_o, .dma_owned_o, .dma_sent_o,
    .dma_done_i, .dma_done_epoch_i, .dma_done_slot_i, .dma_done_result_o,
    .owned_o(occupancy_o), .reserved_count_o, .capture_count_o, .missing_count_o,
    .assembler_count_o, .fifo_count_o, .dma_count_o, .allocated_o, .unused_released_o,
    .retired_o, .admitted_o, .capture_idle_o, .sticky_faults_o(record_faults_o), .fault_o(record_fault)
  );
endmodule

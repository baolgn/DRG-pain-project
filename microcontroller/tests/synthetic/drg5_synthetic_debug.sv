/* simulation-only copy: enable the bounded test aperture; production region permissions remain unchanged. */
/* compose the CPU, Debug Module and JTAG transport with ordered reset and SBA guards. */
module drg5_synthetic_debug #(
  parameter logic [31:0] JTAG_IDCODE = 32'h00000001,
  parameter integer MAX_WAIT_CYCLES = 128
) (
  input logic clk_i, power_reset_i, isolated_i,
  input logic tck_i, tms_i, tdi_i,
  output logic tdo_o,
  input logic [31:0] mip_levels_i,
  input logic buffer_owned_i,
  output logic acquisition_stop_o, system_reset_o, halted_o, fatal_o,
  output logic [31:0] debug_dpc_o, debug_dcsr_o,
  output logic [84:0] debug_access_o,
  output logic [96:0] irq_event_o,
  output logic i_req_valid_o,
  input logic i_req_ready_i,
  output logic [31:0] i_req_addr_o, i_req_tag_o,
  output logic [1:0] i_req_parcels_o,
  input logic i_rsp_valid_i,
  output logic i_rsp_ready_o,
  input logic [31:0] i_rsp_tag_i, i_rsp_data_i,
  input logic [1:0] i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i,
  output logic d_req_valid_o,
  input logic d_req_ready_i,
  output logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o,
  output logic d_req_write_o,
  output logic [1:0] d_req_size_o,
  output logic [3:0] d_req_wstrb_o,
  input logic d_rsp_valid_i,
  output logic d_rsp_ready_o,
  input logic [31:0] d_rsp_tag_i, d_rsp_rdata_i,
  input logic [1:0] d_rsp_status_i,
  output logic sb_req_valid_o,
  input logic sb_req_ready_i,
  output logic sb_req_write_o,
  output logic [31:0] sb_req_addr_o, sb_req_wdata_o,
  output logic [1:0] sb_req_size_o,
  output logic [3:0] sb_req_wstrb_o,
  input logic sb_rsp_valid_i,
  output logic sb_rsp_ready_o,
  input logic [31:0] sb_rsp_rdata_i,
  input logic [2:0] sb_rsp_error_i,
  input logic guard_arm_i,
  input logic guard_stop_i,
  input logic guard_qualified_i,
  input logic guard_memory_available_i,
  input logic guard_memory_deadline_i,
  input logic guard_lease_overrun_i,
  input logic guard_ring_space_i,
  input logic guard_record_credit_i,
  input logic [8:0] guard_fifo_occupancy_i,
  input logic [15:0] guard_clear_reasons_i,
  input logic guard_frame_valid_i,
  input logic guard_frame_good_i,
  input logic [63:0] guard_frame_slot_i,
  input logic [63:0] guard_frame_epoch_i,
  input logic [383:0] guard_frame_data_i,
  input logic guard_record_ready_i,
  input logic guard_drain_ack_i,
  input logic guard_drain_error_i,
  input logic [63:0] guard_drain_lost_i,
  input logic guard_event_ready_i,
  output logic guard_profile_ok_o,
  output logic guard_running_o,
  output logic guard_stopping_o,
  output logic guard_close_valid_o,
  output logic guard_closed_o,
  output logic [2:0] guard_state_o,
  output logic guard_trigger_o,
  output logic guard_block_reference_o,
  output logic guard_frame_ready_o,
  output logic [63:0] guard_trigger_slot_o,
  output logic [63:0] guard_trigger_tick_o,
  output logic [63:0] guard_trigger_epoch_o,
  output logic [63:0] guard_tick_o,
  output logic [63:0] guard_epoch_o,
  output logic [63:0] guard_epoch_slots_o,
  output logic [63:0] guard_scheduled_o,
  output logic [63:0] guard_emitted_o,
  output logic [63:0] guard_invalid_o,
  output logic [63:0] guard_not_triggered_o,
  output logic [63:0] guard_retained_o,
  output logic [63:0] guard_lost_tail_o,
  output logic [63:0] guard_lost_events_o,
  output logic [63:0] guard_delivered_events_o,
  output logic guard_accounting_exact_o,
  output logic guard_record_valid_o,
  output logic guard_record_invalid_o,
  output logic [383:0] guard_record_data_o,
  output logic [63:0] guard_record_slot_o,
  output logic [63:0] guard_record_tick_o,
  output logic [63:0] guard_record_epoch_o,
  output logic [15:0] guard_sticky_reasons_o,
  output logic [15:0] guard_first_reason_o,
  output logic [15:0] guard_latest_reason_o,
  output logic [63:0] guard_first_reason_tick_o,
  output logic [63:0] guard_latest_reason_tick_o,
  output logic guard_event_valid_o,
  output logic [15:0] guard_event_reasons_o,
  output logic [63:0] guard_event_tick_o,
  output logic [63:0] guard_event_epoch_o,
  output logic [63:0] guard_event_slot_o,
  output logic [63:0] guard_stop_tick_o,
  output logic [63:0] guard_stop_slot_tick_o,
  output logic [63:0] guard_stop_slot_o,
  output logic guard_stop_slot_valid_o,
  output drg5_control_pkg::trace_t trace_o,
  output logic [31:0] mepc_o, mcause_o, mtval_o,
  output logic [63:0] mcycle_o, minstret_o
);
  import drg5_control_pkg::*;
  localparam integer SBA_AGE_BITS = MAX_WAIT_CYCLES < 2 ? 1 : $clog2(MAX_WAIT_CYCLES + 1);
  logic dm_halt, dm_resume, dm_resethalt, dm_reset, resume_ack;
  logic reg_valid, reg_write, reg_ready;
  logic [15:0] reg_addr;
  logic [31:0] reg_wdata, reg_rdata;
  logic [2:0] reg_error;
  logic dmi_req_valid, dmi_req_ready, dmi_rsp_valid, dmi_rsp_ready;
  logic [6:0] dmi_addr;
  logic [31:0] dmi_wdata, dmi_rdata;
  logic [1:0] dmi_req_op, dmi_rsp_op;
  logic dm_sb_valid, dm_sb_ready, dm_sb_response, dm_sb_response_ready;
  logic [31:0] dm_sb_rdata;
  logic [2:0] dm_sb_error;
  logic sb_owned_q, sb_denied_q, sb_accepted_q, sb_fatal_q;
  logic [SBA_AGE_BITS-1:0] sb_age_q;
  logic sb_permitted, code_region, mmio_region, sb_region_allowed, sb_misaligned;
  logic [31:0] sb_guard_cause, sb_guard_data, sb_guard_load;
  logic [3:0] sb_guard_strobes;
  logic fetch_busy, fetch_fatal, core_fatal, entry_pending, idle;
  logic redirect, frontend_valid, frontend_ready;
  logic [31:0] redirect_pc;
  packet_t packet;
  logic reset_q, reset_pending_q;
  logic [1:0] fabric_reset_q;
  logic containment_q;
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
  logic unused_observation, acquisition_active_i;
  assign acquisition_active_i = guard_running_o;

  /* one acquisition clock and guard survive CPU reset and retain the stop reason. */
  drg5_acquisition_guard guard (
    .clk_i(clk_i),
    .power_reset_i(fabric_reset_q[1]),
    .arm_i(guard_arm_i),
    .stop_i(guard_stop_i),
    .qualified_i(guard_qualified_i),
    .debug_halt_i(dm_halt || halted_o),
    .cpu_reset_i(dm_reset || reset_pending_q || reset_q),
    .memory_available_i(guard_memory_available_i),
    .memory_deadline_i(guard_memory_deadline_i),
    .lease_overrun_i(guard_lease_overrun_i),
    .ring_space_i(guard_ring_space_i),
    .record_credit_i(guard_record_credit_i),
    .fifo_occupancy_i(guard_fifo_occupancy_i),
    .clear_reasons_i(guard_clear_reasons_i),
    .frame_valid_i(guard_frame_valid_i),
    .frame_good_i(guard_frame_good_i),
    .frame_slot_i(guard_frame_slot_i),
    .frame_epoch_i(guard_frame_epoch_i),
    .frame_data_i(guard_frame_data_i),
    .record_ready_i(guard_record_ready_i),
    .drain_ack_i(guard_drain_ack_i),
    .drain_error_i(guard_drain_error_i),
    .drain_lost_i(guard_drain_lost_i),
    .event_ready_i(guard_event_ready_i),
    .profile_ok_o(guard_profile_ok_o),
    .running_o(guard_running_o),
    .stopping_o(guard_stopping_o),
    .close_valid_o(guard_close_valid_o),
    .closed_o(guard_closed_o),
    .state_o(guard_state_o),
    .trigger_o(guard_trigger_o),
    .block_reference_o(guard_block_reference_o),
    .frame_ready_o(guard_frame_ready_o),
    .trigger_slot_o(guard_trigger_slot_o),
    .trigger_tick_o(guard_trigger_tick_o),
    .trigger_epoch_o(guard_trigger_epoch_o),
    .tick_o(guard_tick_o),
    .epoch_o(guard_epoch_o),
    .epoch_slots_o(guard_epoch_slots_o),
    .scheduled_o(guard_scheduled_o),
    .emitted_o(guard_emitted_o),
    .invalid_o(guard_invalid_o),
    .not_triggered_o(guard_not_triggered_o),
    .retained_o(guard_retained_o),
    .lost_tail_o(guard_lost_tail_o),
    .lost_events_o(guard_lost_events_o),
    .delivered_events_o(guard_delivered_events_o),
    .accounting_exact_o(guard_accounting_exact_o),
    .record_valid_o(guard_record_valid_o),
    .record_invalid_o(guard_record_invalid_o),
    .record_data_o(guard_record_data_o),
    .record_slot_o(guard_record_slot_o),
    .record_tick_o(guard_record_tick_o),
    .record_epoch_o(guard_record_epoch_o),
    .sticky_reasons_o(guard_sticky_reasons_o),
    .first_reason_o(guard_first_reason_o),
    .latest_reason_o(guard_latest_reason_o),
    .first_reason_tick_o(guard_first_reason_tick_o),
    .latest_reason_tick_o(guard_latest_reason_tick_o),
    .event_valid_o(guard_event_valid_o),
    .event_reasons_o(guard_event_reasons_o),
    .event_tick_o(guard_event_tick_o),
    .event_epoch_o(guard_event_epoch_o),
    .event_slot_o(guard_event_slot_o),
    .stop_tick_o(guard_stop_tick_o),
    .stop_slot_tick_o(guard_stop_slot_tick_o),
    .stop_slot_o(guard_stop_slot_o),
    .stop_slot_valid_o(guard_stop_slot_valid_o)
  );

  /* assert domain reset asynchronously and release it only on fabric clock edges. */
  always_ff @(posedge clk_i or posedge power_reset_i) begin
    if (power_reset_i) fabric_reset_q <= 2'b11;
    else fabric_reset_q <= {fabric_reset_q[0], 1'b0};
  end

  /* a simulation IDCODE is not an assigned physical-board JTAG identity. */
  drg5_debug_transport #(.IDCODE(JTAG_IDCODE)) transport (
    .clk_i, .power_reset_i, .tck_i, .tms_i, .tdi_i, .tdo_o,
    .dmi_req_valid_o(dmi_req_valid), .dmi_req_ready_i(dmi_req_ready),
    .dmi_req_addr_o(dmi_addr), .dmi_req_data_o(dmi_wdata), .dmi_req_op_o(dmi_req_op),
    .dmi_rsp_valid_i(dmi_rsp_valid), .dmi_rsp_ready_o(dmi_rsp_ready),
    .dmi_rsp_data_i(dmi_rdata), .dmi_rsp_op_i(dmi_rsp_op)
  );

  /* the DM survives non-debug reset and exposes actual hart availability. */
  drg5_debug_module dm (
    .clk_i, .power_reset_i(fabric_reset_q[1]), .hart_reset_i(reset_q),
    .system_reset_pending_i(reset_pending_q),
    .hart_unavailable_i(reset_q || reset_pending_q || containment_q), .hart_halted_i(halted_o), .hart_resumeack_i(resume_ack),
    .haltreq_o(dm_halt), .resumereq_o(dm_resume), .resethaltreq_o(dm_resethalt), .ndmreset_o(dm_reset),
    .debug_reg_valid_o(reg_valid), .debug_reg_write_o(reg_write), .debug_reg_addr_o(reg_addr),
    .debug_reg_wdata_o(reg_wdata), .debug_reg_ready_i(reg_ready),
    .debug_reg_rdata_i(reg_rdata), .debug_reg_error_i(reg_error),
    .dmi_req_valid_i(dmi_req_valid), .dmi_req_ready_o(dmi_req_ready),
    .dmi_req_addr_i(dmi_addr), .dmi_req_data_i(dmi_wdata), .dmi_req_op_i(dmi_req_op),
    .dmi_rsp_valid_o(dmi_rsp_valid), .dmi_rsp_ready_i(dmi_rsp_ready),
    .dmi_rsp_data_o(dmi_rdata), .dmi_rsp_op_o(dmi_rsp_op),
    .sb_req_valid_o(dm_sb_valid), .sb_req_ready_i(dm_sb_ready), .sb_req_write_o,
    .sb_req_addr_o, .sb_req_wdata_o, .sb_req_size_o, .sb_req_wstrb_o,
    .sb_rsp_valid_i(dm_sb_response), .sb_rsp_ready_o(dm_sb_response_ready),
    .sb_rsp_rdata_i(dm_sb_rdata), .sb_rsp_error_i(dm_sb_error)
  );

  /* latched SBA admission survives permission changes until its original reply. */
  drg5_lsu #(.TEST_REGIONS(1), .IRAM_WRITE(1), .TIMER_ENABLED(1)) sba_guard (
    .addr_i(sb_req_addr_o), .store_value_i(32'b0), .rsp_data_i(32'b0), .size_i(sb_req_size_o),
    .write_i(sb_req_write_o), .signed_i(1'b0), .allowed_o(sb_region_allowed),
    .misaligned_o(sb_misaligned), .cause_o(sb_guard_cause), .wdata_o(sb_guard_data),
    .load_value_o(sb_guard_load), .wstrb_o(sb_guard_strobes)
  );
  assign code_region = sb_req_addr_o >= 32'h00010000 && sb_req_addr_o <= 32'h0001ffff;
  assign mmio_region = sb_req_addr_o >= 32'h40000000 && sb_req_addr_o <= 32'h40001fff;
  assign sb_permitted = !reset_q && !reset_pending_q && !dm_reset && !fatal_o &&
      !(sb_rsp_valid_i && !sb_owned_q) &&
      sb_region_allowed &&
      (!sb_req_write_o || (!acquisition_active_i && !buffer_owned_i)) &&
      (!mmio_region || !acquisition_active_i) &&
      (!code_region || !sb_req_write_o || (halted_o && !dm_resume));
  assign sb_req_valid_o = dm_sb_valid && sb_owned_q && !sb_denied_q;
  assign dm_sb_ready = sb_owned_q && (sb_denied_q ? !sb_accepted_q : sb_req_ready_i);
  assign dm_sb_response = sb_owned_q && (sb_denied_q ? sb_accepted_q : sb_rsp_valid_i);
  assign dm_sb_rdata = sb_denied_q ? 32'b0 : sb_rsp_rdata_i;
  assign dm_sb_error = sb_denied_q ? 3'd2 :
      (sb_rsp_error_i == 5 || sb_rsp_error_i == 6) ? 3'd7 : sb_rsp_error_i;
  assign sb_rsp_ready_o = sb_owned_q && !sb_denied_q && dm_sb_response_ready;
  assign fatal_o = core_fatal || fetch_fatal || sb_fatal_q;
  assign system_reset_o = reset_q;
  assign irq_event_o = {irq_valid, irq_pc, irq_cause, mtvec};
  assign acquisition_stop_o = dm_halt || dm_reset || reset_pending_q || reset_q || halted_o || fatal_o;

  /* reset and resume cannot abandon an exposed SBA operation or reuse its effects. */
  always_ff @(posedge clk_i) begin
    /* preserve successful and rejected abstract accesses independently of retirement. */
    debug_access_o <= {reg_valid && reg_ready, reg_error, reg_write, reg_addr, reg_wdata, reg_rdata};
    /* only positively isolated power reset revokes external transaction ownership. */
    if (fabric_reset_q[1]) begin
      assert (isolated_i) else $fatal(1, "debug power reset requires isolation");
      sb_owned_q <= 0;
      sb_denied_q <= 0;
      sb_accepted_q <= 0;
      sb_fatal_q <= 0;
      sb_age_q <= 0;
      reset_q <= 0;
      reset_pending_q <= 0;
      containment_q <= 0;
      debug_access_o <= 0;
    /* normal operation retains outstanding reset and transaction obligations. */
    end else begin
      /* registered containment breaks status-feedback paths and remains sticky. */
      if (fatal_o) containment_q <= 1;
      /* a target must not save an unowned reply for a future SBA descriptor. */
      if (sb_rsp_valid_i && (!sb_owned_q || sb_denied_q || !sb_accepted_q ||
          sb_rsp_error_i == 5 || sb_rsp_error_i == 6)) sb_fatal_q <= 1;
      /* evaluate access once, before exposing the request to a peripheral. */
      if (dm_sb_valid && !sb_owned_q) begin
        sb_owned_q <= 1;
        sb_denied_q <= !sb_permitted;
        sb_accepted_q <= 0;
        sb_age_q <= 0;
      end
      /* timeout contains an uncertain owner without inventing a completion or retry. */
      if (sb_owned_q && !(dm_sb_response && dm_sb_response_ready)) begin
        if (sb_age_q == SBA_AGE_BITS'(MAX_WAIT_CYCLES - 1)) sb_fatal_q <= 1;
        else if (!sb_fatal_q) sb_age_q <= sb_age_q + 1'b1;
      end
      /* denial is also a two-phase accepted request and one response. */
      if (dm_sb_valid && dm_sb_ready) sb_accepted_q <= 1;
      /* uncertain completion survives DM reset and prohibits resume until recovery. */
      if (dm_sb_response && dm_sb_response_ready) begin
        sb_owned_q <= 0;
        sb_accepted_q <= 0;
        if (dm_sb_error == 7 || dm_sb_error == 1) sb_fatal_q <= 1;
      end
      /* non-debug reset waits for CPU and SBA owners; clocks continue throughout. */
      if (dm_reset) reset_pending_q <= 1;
      /* even a short control request causes at least one actual drained reset edge. */
      if ((reset_pending_q || dm_reset) && !reset_q &&
          ((halted_o && !fetch_busy && !mem_busy && !sb_owned_q && !dm_sb_valid) || isolated_i)) reset_q <= 1;
      /* after one actual reset edge, deassertion releases the request obligation. */
      if (reset_q && !dm_reset) begin
        reset_q <= 0;
        reset_pending_q <= 0;
      end
    end
  end

  /* redirect generation rejects pre-halt instruction parcels on every resume. */
  drg5_frontend #(.C_ENABLED(1), .GEN_BITS(2), .MAX_WAIT_CYCLES(MAX_WAIT_CYCLES)) frontend (
    .clk_i, .cold_reset_i(fabric_reset_q[1]), .isolated_i, .hart_reset_i(reset_q),
    .permit_i(!halted_o && !reset_q), .entry_pending_i(entry_pending),
    .core_fatal_i(core_fatal || sb_fatal_q || containment_q),
    .redirect_valid_i(redirect), .redirect_pc_i(redirect_pc),
    .i_req_valid_o, .i_req_ready_i, .i_req_addr_o, .i_req_tag_o, .i_req_parcels_o,
    .i_rsp_valid_i, .i_rsp_ready_o, .i_rsp_tag_i, .i_rsp_data_i, .i_rsp_parcels_i, .i_rsp_fault_i, .i_rsp_status_i,
    .insn_valid_o(frontend_valid), .insn_ready_i(frontend_ready), .insn_packet_o(packet),
    .busy_o(fetch_busy), .discard_o(fetch_discard), .fatal_o(fetch_fatal), .fatal_reason_o(fetch_reason),
    .generation_o(fetch_generation), .insn_generation_o(packet_generation),
    .launch_o(fetch_launch), .accept_o(fetch_accept), .complete_o(fetch_complete), .drop_o(fetch_drop)
  );

  /* direct abstract access is confined to halted state inside the core. */
  drg5_control #(.TEST_REGIONS(1), .C_ENABLED(1), .M_ENABLED(1), .IRQ_ENABLED(1), .TIMER_ENABLED(1),
      .ZIFENCEI_ENABLED(1), .IRAM_WRITE(1), .DIAGNOSTIC(0), .DEBUG_ENABLED(1),
      .D_MAX_WAIT_CYCLES(MAX_WAIT_CYCLES)) core (
    .clk_i, .cold_reset_i(fabric_reset_q[1]), .isolated_i, .hart_reset_i(reset_q), .mip_levels_i,
    .fetch_busy_i(fetch_busy), .entry_pending_o(entry_pending), .idle_o(idle),
    .irq_valid_o(irq_valid), .irq_pc_o(irq_pc), .irq_cause_o(irq_cause), .hold_i(5'b0),
    .in_valid_i(frontend_valid), .in_ready_o(frontend_ready), .in_packet_i(packet),
    .flush_valid_i(1'b0), .flush_ready_o(flush_ready), .flush_pc_i(32'b0), .flush_aborted_o(flush_aborted),
    .redirect_valid_o(redirect), .redirect_pc_o(redirect_pc),
    .d_req_valid_o, .d_req_ready_i, .d_req_addr_o, .d_req_wdata_o, .d_req_write_o, .d_req_size_o,
    .d_req_wstrb_o, .d_req_tag_o, .d_rsp_valid_i, .d_rsp_ready_o, .d_rsp_tag_i, .d_rsp_rdata_i,
    .d_rsp_status_i, .mem_launch_o(mem_launch), .mem_busy_o(mem_busy), .fatal_o(core_fatal),
    .fatal_record_o(fatal_record), .stage_valid_o(stages), .stage_token_o(stage_tokens),
    .transfer_o(transfers), .kill_valid_o(kills), .kill_uid_o(kill_uids), .trace_o,
    .inspect_reg_i(5'b0), .inspect_value_o(inspect_value), .inspect_defined_o(inspect_defined),
    .mstatus_o(mstatus), .mtvec_o(mtvec), .mscratch_o(mscratch), .mepc_o, .mcause_o, .mtval_o,
    .mie_o(mie), .mip_o(mip), .mcountinhibit_o(inhibit), .mcycle_o, .minstret_o,
    .debug_haltreq_i(dm_halt || ((dm_reset || reset_pending_q) && !reset_q) || containment_q),
    .debug_resumereq_i(dm_resume && !sb_owned_q && !dm_sb_valid && !dm_reset && !reset_pending_q && !containment_q),
    .debug_resethaltreq_i(dm_resethalt), .debug_halted_o(halted_o), .debug_resumeack_o(resume_ack),
    .debug_dpc_o, .debug_dcsr_o,
    .debug_reg_valid_i(reg_valid), .debug_reg_write_i(reg_write), .debug_reg_addr_i(reg_addr),
    .debug_reg_wdata_i(reg_wdata), .debug_reg_ready_o(reg_ready),
    .debug_reg_rdata_o(reg_rdata), .debug_reg_error_o(reg_error)
  );

  /* optional internal observations have no feedback into execution. */
  assign unused_observation = ^{idle, stages, kills, stage_tokens[0], stage_tokens[1], stage_tokens[2],
      stage_tokens[3], stage_tokens[4], kill_uids[0], kill_uids[1], kill_uids[2], kill_uids[3], kill_uids[4],
      transfers, fetch_generation, packet_generation, fetch_discard, fetch_launch, fetch_accept, fetch_complete,
      fetch_drop, fetch_reason, irq_valid, irq_pc, irq_cause, flush_ready, flush_aborted, mem_launch,
      inspect_value, inspect_defined, mstatus, mtvec, mscratch, mie, mip, inhibit, fatal_record,
      sb_misaligned, sb_guard_cause, sb_guard_data, sb_guard_load, sb_guard_strobes};
endmodule

/* decide fixed-grid slots without waiting for CPU execution or downstream service. */
module drg5_acquisition_scheduler #(
  parameter logic [63:0] COUNTER_LIMIT = 64'hffffffffffffffff,
  parameter integer HANDOFF_CYCLES = 80
) (
  input logic clk_i, system_reset_i,
  input logic [63:0] tick_i,
  input logic timebase_exhausted_i,
  input logic arm_i,
  input logic [63:0] arm_epoch_i, arm_first_tick_i,
  input logic [31:0] arm_period_i,
  output logic arm_ready_o, arm_accept_o,
  output logic [31:0] arm_result_o,
  input logic stop_i, cpu_reset_i, cpu_halt_i, qualified_i,
  input logic supervisor_fault_i, isolate_i,
  input logic capture_idle_i, record_credit_i, storage_available_i,
  input logic [8:0] fifo_occupancy_i,
  output logic active_o, pulse_busy_o, convst_o,
  output logic launch_o,
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
  output logic exact_o,
  output logic loss_valid_o, loss_last_known_o,
  output logic [63:0] loss_first_o, loss_last_o,
  output logic [31:0] end_causes_o,
  output logic fault_o, isolate_request_o,
  output logic [31:0] sticky_causes_o, first_fault_o, latest_fault_o,
  output logic [63:0] first_fault_tick_o, latest_fault_tick_o
);
  localparam logic [31:0] OK = 0, ACCEPTED = 1, INVALID_REQUEST = 2,
    STALE_COMMAND = 3, COMMAND_BUSY = 4, UNSUPPORTED_PROFILE = 5,
    UNQUALIFIED = 7, STOP_ACTIVE = 9, EMPTY = 17;
  localparam logic [31:0] CONTROL_STOP = 32'h1, CPU_RESET = 32'h2, CPU_HALT = 32'h4,
    QUALIFICATION = 32'h8, CAPTURE_BUSY = 32'h10, NO_CREDIT = 32'h20,
    STORAGE = 32'h40, HIGH_WATER = 32'h80, HANDOFF_TIMEOUT = 32'h100,
    TIMEBASE = 32'h200, COUNTER_FULL = 32'h400, ISOLATION = 32'h800,
    INTERNAL = 32'h1000, FAULT_MASK = 32'h1ff8;
  logic active_q, active_d, closing_q, closing_d, end_q, end_d;
  logic pulse_q, pulse_d, outcome_q, outcome_d, triggered_q, triggered_d;
  logic exact_q, exact_d, loss_q, loss_d, loss_last_known_q, loss_last_known_d;
  logic time_bad_q, time_bad_d, counter_bad_q, counter_bad_d, isolated_q, isolated_d;
  logic handoff_failed_q, handoff_failed_d, prev_valid_q, supervisor_q, isolation_q;
  logic [3:0] pulse_left_q, pulse_left_d;
  logic [31:0] handoff_age_q, handoff_age_d, reasons, boundary_q, boundary_d;
  logic [31:0] outcome_causes_q, outcome_causes_d;
  logic [63:0] previous_tick_q, epoch_q, epoch_d, last_epoch_q, last_epoch_d;
  logic [63:0] next_tick_q, next_tick_d, origin_q, origin_d;
  logic [63:0] scheduled_q, scheduled_d, emitted_q, emitted_d, missing_q, missing_d;
  logic [63:0] delivered_q, delivered_d, end_delivered_q, end_delivered_d;
  logic [63:0] last_tick_q, last_tick_d, end_tick_q, end_tick_d;
  logic [63:0] loss_first_q, loss_first_d, loss_last_q, loss_last_d;
  logic [63:0] outcome_epoch_q, outcome_epoch_d, outcome_slot_q, outcome_slot_d;
  logic [63:0] outcome_tick_q, outcome_tick_d;
  logic [31:0] sticky_q, sticky_d, first_q, first_d, latest_q, latest_d;
  logic [63:0] first_tick_q, first_tick_d, latest_tick_q, latest_tick_d;
  logic due, step_ok, local_free, stop_level, stop_now, can_launch, end_now;
  logic [64:0] step_sum, first_sum, frame_sum, next_sum, next_frame_sum;
  logic owner_busy, safe_arm;

  /* checked unsigned sums are ordered only inside this nonwrapping timebase lifetime. */
  assign step_sum = {1'b0, previous_tick_q} + 65'd1;
  assign first_sum = {1'b0, tick_i} + 65'd1;
  assign frame_sum = {1'b0, arm_first_tick_i} + 65'd1120;
  assign next_sum = {1'b0, next_tick_q} + 65'd1600;
  assign next_frame_sum = next_sum + 65'd1120;
  assign step_ok = !prev_valid_q || (!step_sum[64] && tick_i == step_sum[63:0]);
  assign owner_busy = active_q || closing_q || end_q || outcome_q || pulse_q;
  assign stop_level = stop_i || cpu_reset_i || cpu_halt_i;
  assign safe_arm = qualified_i && !supervisor_fault_i && !isolate_i &&
    !timebase_exhausted_i && !time_bad_q && !counter_bad_q && !isolated_q && step_ok &&
    capture_idle_i && record_credit_i && storage_available_i && fifo_occupancy_i < 192 &&
    tick_i <= 64'hfffffffffffffb9e;
  assign arm_ready_o = !system_reset_i && !owner_busy && safe_arm;
  assign arm_accept_o = !system_reset_i && arm_i && arm_result_o == ACCEPTED;

  /* ordinary admission rejects the complete envelope without changing any owner. */
  always_comb begin
    if (system_reset_i) arm_result_o = UNQUALIFIED;
    else if (arm_epoch_i == 0 || arm_first_tick_i <= tick_i)
      arm_result_o = INVALID_REQUEST;
    else if (arm_epoch_i <= last_epoch_q) arm_result_o = STALE_COMMAND;
    else if (owner_busy) arm_result_o = COMMAND_BUSY;
    else if (arm_period_i != 1600 || (!first_sum[64] && arm_first_tick_i != first_sum[63:0]))
      arm_result_o = UNSUPPORTED_PROFILE;
    else if (stop_level) arm_result_o = STOP_ACTIVE;
    else if (!safe_arm || first_sum[64] || frame_sum[64] || frame_sum[63:0] < arm_first_tick_i)
      arm_result_o = UNQUALIFIED;
    else arm_result_o = ACCEPTED;
  end

  /* termination acknowledgment releases only its receipt after local owners have retired. */
  always_comb begin
    if (!end_ack_i) end_ack_result_o = EMPTY;
    else if (system_reset_i) end_ack_result_o = UNQUALIFIED;
    else if (!end_q || end_ack_epoch_i != epoch_q) end_ack_result_o = STALE_COMMAND;
    else if (outcome_q || pulse_q || !capture_idle_i) end_ack_result_o = UNQUALIFIED;
    else end_ack_result_o = OK;
  end

  assign active_o = active_q;
  assign pulse_busy_o = pulse_q;
  assign convst_o = pulse_q;
  assign outcome_valid_o = outcome_q;
  assign outcome_triggered_o = triggered_q;
  assign outcome_epoch_o = outcome_epoch_q;
  assign outcome_slot_o = outcome_slot_q;
  assign outcome_tick_o = outcome_tick_q;
  assign outcome_causes_o = outcome_causes_q;
  assign end_valid_o = end_q;
  assign end_epoch_o = epoch_q;
  assign end_tick_o = end_tick_q;
  assign end_delivered_o = end_delivered_q;
  assign scheduled_o = scheduled_q;
  assign emitted_o = emitted_q;
  assign missing_o = missing_q;
  assign delivered_o = delivered_q;
  assign last_slot_known_o = scheduled_q != 0;
  assign last_slot_o = scheduled_q == 0 ? 64'b0 : scheduled_q - 1'b1;
  assign last_tick_o = last_tick_q;
  assign exact_o = exact_q;
  assign loss_valid_o = loss_q;
  assign loss_first_o = loss_first_q;
  assign loss_last_o = loss_last_q;
  assign loss_last_known_o = loss_last_known_q;
  assign end_causes_o = boundary_q;
  assign isolate_request_o = isolated_q;
  assign sticky_causes_o = sticky_q;
  assign first_fault_o = first_q;
  assign latest_fault_o = latest_q;
  assign first_fault_tick_o = first_tick_q;
  assign latest_fault_tick_o = latest_tick_q;
  assign launch_epoch_o = epoch_q;
  assign launch_slot_o = scheduled_q;
  assign launch_tick_o = tick_i;
  assign launch_o = can_launch && !system_reset_i;

  /* each edge has one slot decision, independent of the CPU or notification consumer. */
  always_comb begin
    active_d = active_q; closing_d = closing_q; end_d = end_q;
    pulse_d = pulse_q; pulse_left_d = pulse_left_q;
    outcome_d = outcome_q; triggered_d = triggered_q; outcome_causes_d = outcome_causes_q;
    outcome_epoch_d = outcome_epoch_q; outcome_slot_d = outcome_slot_q; outcome_tick_d = outcome_tick_q;
    exact_d = exact_q; loss_d = loss_q; loss_last_known_d = loss_last_known_q;
    time_bad_d = time_bad_q; counter_bad_d = counter_bad_q; isolated_d = isolated_q;
    handoff_failed_d = handoff_failed_q; handoff_age_d = handoff_age_q;
    epoch_d = epoch_q; last_epoch_d = last_epoch_q; next_tick_d = next_tick_q; origin_d = origin_q;
    scheduled_d = scheduled_q; emitted_d = emitted_q; missing_d = missing_q;
    delivered_d = delivered_q; end_delivered_d = end_delivered_q;
    last_tick_d = last_tick_q; end_tick_d = end_tick_q;
    loss_first_d = loss_first_q; loss_last_d = loss_last_q; boundary_d = boundary_q;
    sticky_d = sticky_q; first_d = first_q; latest_d = latest_q;
    first_tick_d = first_tick_q; latest_tick_d = latest_tick_q;
    reasons = 0; end_now = 0; can_launch = 0;
    due = active_q && step_ok && tick_i == next_tick_q;
    local_free = !outcome_q || outcome_ready_i;
    stop_now = stop_level;

    /* an emitted pulse finishes all eight ticks through ordinary stop or CPU reset. */
    if (pulse_q) begin
      pulse_left_d = pulse_left_q - 1'b1;
      if (pulse_left_q == 1) pulse_d = 0;
    end
    /* accepting a held notification releases that owner exactly once. */
    if (outcome_q && outcome_ready_i) begin
      outcome_d = 0; handoff_age_d = 0;
      if (delivered_q < COUNTER_LIMIT) delivered_d = delivered_q + 1'b1;
    /* backpressure is bounded for scheduling but never withdraws the offered tuple. */
    end else if (outcome_q && !handoff_failed_q) begin
      /* a same-edge handshake above wins over the inclusive timeout. */
      if (handoff_age_q >= 32'(HANDOFF_CYCLES - 1)) begin
        reasons |= HANDOFF_TIMEOUT; handoff_failed_d = 1; stop_now = 1;
        if (!end_q) exact_d = 0;
      /* count without consulting CPU run state. */
      end else begin
        handoff_age_d = handoff_age_q + 1'b1;
      end
    end

    /* clock discontinuity and exhaustion revoke this whole timebase lifetime. */
    if ((!step_ok || timebase_exhausted_i) && !time_bad_q) begin
      reasons |= TIMEBASE; time_bad_d = 1; isolated_d = 1; stop_now = 1;
      if (!end_q) exact_d = 0;
    end
    /* physical isolation may truncate a pulse, which is explicitly uncertain. */
    if (supervisor_fault_i || isolate_i) begin
      pulse_d = 0; pulse_left_d = 0; isolated_d = 1; stop_now = 1;
      if (!end_q) exact_d = 0;
      if ((supervisor_fault_i && !supervisor_q) || (isolate_i && !isolation_q)) reasons |= ISOLATION;
      if (supervisor_fault_i) time_bad_d = 1;
    end

    /* continuous safety faults stop before the next grid point, never defer that point. */
    if (active_q) begin
      if (stop_i) reasons |= CONTROL_STOP;
      if (cpu_reset_i) reasons |= CPU_RESET;
      if (cpu_halt_i) reasons |= CPU_HALT;
      /* revoked qualification forbids every later trigger. */
      if (!qualified_i) begin
        reasons |= QUALIFICATION; stop_now = 1;
      end
      /* lost storage service ends the grid without waiting for credit recovery. */
      if (!storage_available_i) begin
        reasons |= STORAGE; stop_now = 1;
      end
      /* the pre-edge high-water limit leaves space for bounded closure. */
      if (fifo_occupancy_i >= 192) begin
        reasons |= HIGH_WATER; stop_now = 1;
      end
      /* a skipped deadline is an uncertain tail, never a late conversion opportunity. */
      if (!step_ok || tick_i > next_tick_q) begin
        reasons |= TIMEBASE; stop_now = 1; time_bad_d = 1; isolated_d = 1; exact_d = 0;
        loss_d = 1; loss_first_d = scheduled_q; loss_last_d = 0; loss_last_known_d = 0;
      end
    end

    /* contradictory local owners cannot certify a normal scheduling decision. */
    if ((active_q && (closing_q || end_q)) || (pulse_q && pulse_left_q == 0) ||
        (outcome_q && outcome_slot_q >= scheduled_q)) begin
      reasons |= INTERNAL; stop_now = 1; isolated_d = 1;
      if (!end_q) exact_d = 0;
    end

    /* equality accounts exactly one scheduled slot; unsafe inputs cannot shift it. */
    if (due) begin
      /* capture and credit are pre-edge admission conditions, not future promises. */
      if (!capture_idle_i || pulse_q) begin
        reasons |= CAPTURE_BUSY; stop_now = 1;
      end
      /* external credit cannot be invented by a same-edge dequeue. */
      if (!record_credit_i || !local_free || fifo_occupancy_i >= 256) begin
        reasons |= NO_CREDIT; stop_now = 1;
      end
      /* frame completion needs a representable deadline before timebase exhaustion. */
      if (scheduled_q >= COUNTER_LIMIT || tick_i > 64'hfffffffffffffb9f) begin
        reasons |= COUNTER_FULL; stop_now = 1; counter_bad_d = 1;
      end
      /* a valid lifetime never schedules an index whose count would require 65 bits. */
      if (scheduled_q < COUNTER_LIMIT) begin
        scheduled_d = scheduled_q + 1'b1; last_tick_d = tick_i;
        can_launch = !stop_now && !time_bad_d && !isolated_d;
        /* capture observes launch and its identity on this exact edge, before CONVST rises. */
        if (can_launch) begin
          pulse_d = 1; pulse_left_d = 8; emitted_d = emitted_q + 1'b1;
          outcome_d = 1; triggered_d = 1; outcome_causes_d = 0;
          outcome_epoch_d = epoch_q; outcome_slot_d = scheduled_q; outcome_tick_d = tick_i;
          handoff_age_d = 0; handoff_failed_d = 0;
        /* missing means a retained typed decision, not an invented completed ADC record. */
        end else begin
          missing_d = missing_q + 1'b1;
          /* a reserved destination permits an explicit missing-slot notification. */
          if (local_free && record_credit_i && storage_available_i && fifo_occupancy_i < 256) begin
            outcome_d = 1; triggered_d = 0; outcome_causes_d = reasons;
            outcome_epoch_d = epoch_q; outcome_slot_d = scheduled_q; outcome_tick_d = tick_i;
            handoff_age_d = 0; handoff_failed_d = 0;
          /* no storage claim means a retained exact lost-slot interval instead. */
          end else begin
            loss_d = 1; loss_first_d = scheduled_q; loss_last_d = scheduled_q; loss_last_known_d = 1;
          end
        end
        /* a final representable slot remains on time even when no successor can exist. */
        if (next_sum[64] || next_frame_sum[64] || next_frame_sum[63:0] < next_sum[63:0] ||
            scheduled_d == COUNTER_LIMIT) begin
          reasons |= COUNTER_FULL; stop_now = 1; counter_bad_d = 1;
        /* only the fixed integer successor may become the next due marker. */
        end else begin
          next_tick_d = next_sum[63:0];
        end
      /* an inconsistent exhausted live epoch cannot wrap its slot count. */
      end else begin
        exact_d = 0;
      end
    end

    /* inhibition freezes the scheduled boundary; closure may finish the legal pulse afterward. */
    if (active_q && stop_now) begin
      active_d = 0; closing_d = 1; end_now = 1; end_tick_d = tick_i;
    end
    /* admission creates no slot until the independently validated next edge. */
    if (arm_accept_o) begin
      active_d = 1; closing_d = 0; end_d = 0; epoch_d = arm_epoch_i; last_epoch_d = arm_epoch_i;
      next_tick_d = arm_first_tick_i; origin_d = arm_first_tick_i;
      scheduled_d = 0; emitted_d = 0; missing_d = 0; delivered_d = 0; end_delivered_d = 0;
      exact_d = 1; loss_d = 0; loss_first_d = 0; loss_last_d = 0; loss_last_known_d = 0;
      last_tick_d = 0; end_tick_d = 0; boundary_d = 0; handoff_failed_d = 0;
    end
    /* the retained receipt includes all causes seen before its bounded sealing edge. */
    if ((closing_q || end_now) && !end_q) boundary_d |= reasons;
    /* a timed-out notification remains owned, but cannot hide the termination receipt. */
    if (closing_d && !pulse_d && (!outcome_d || handoff_failed_d)) begin
      closing_d = 0; end_d = 1; end_delivered_d = delivered_d;
    end
    /* acknowledgment cannot erase a pending notification or active pulse. */
    if (end_ack_i && end_ack_result_o == OK) begin
      end_d = 0;
      if (!time_bad_d && !counter_bad_d && !isolate_i && !supervisor_fault_i) isolated_d = 0;
    end
    /* idle service isolation clears only after positive requalification, never after timing loss. */
    if (!owner_busy && !isolate_i && !supervisor_fault_i && qualified_i && capture_idle_i &&
        !time_bad_d && !counter_bad_d) isolated_d = 0;
    /* first/latest fault evidence survives receipt acknowledgment and subsequent epochs. */
    if (reasons != 0) begin
      sticky_d |= reasons;
      /* normal software and CPU stops are observations rather than hardware faults. */
      if ((reasons & FAULT_MASK) != 0) begin
        /* the first fault survives every later occurrence and receipt acknowledgment. */
        if (first_q == 0) begin
          first_d = reasons; first_tick_d = tick_i;
        end
        latest_d = reasons; latest_tick_d = tick_i;
      end
    end
  end

  /* only isolated whole-domain reset erases schedule, notification and receipt ownership. */
  always_ff @(posedge clk_i) begin
    /* CPU-only reset is a stop input and never enters this destructive branch. */
    if (system_reset_i) begin
      active_q <= 0; closing_q <= 0; end_q <= 0; pulse_q <= 0; pulse_left_q <= 0;
      outcome_q <= 0; triggered_q <= 0; outcome_causes_q <= 0;
      outcome_epoch_q <= 0; outcome_slot_q <= 0; outcome_tick_q <= 0;
      exact_q <= 1; loss_q <= 0; loss_last_known_q <= 0;
      time_bad_q <= 0; counter_bad_q <= 0; isolated_q <= 0; handoff_failed_q <= 0; handoff_age_q <= 0;
      prev_valid_q <= 0; previous_tick_q <= 0; supervisor_q <= 0; isolation_q <= 0;
      epoch_q <= 0; last_epoch_q <= 0; next_tick_q <= 0; origin_q <= 0;
      scheduled_q <= 0; emitted_q <= 0; missing_q <= 0; delivered_q <= 0; end_delivered_q <= 0;
      last_tick_q <= 0; end_tick_q <= 0; loss_first_q <= 0; loss_last_q <= 0; boundary_q <= 0;
      sticky_q <= 0; first_q <= 0; latest_q <= 0; first_tick_q <= 0; latest_tick_q <= 0;
      fault_o <= 0;
    /* time observation and fault evidence continue without CPU execution or notification service. */
    end else begin
      active_q <= active_d; closing_q <= closing_d; end_q <= end_d; pulse_q <= pulse_d; pulse_left_q <= pulse_left_d;
      outcome_q <= outcome_d; triggered_q <= triggered_d; outcome_causes_q <= outcome_causes_d;
      outcome_epoch_q <= outcome_epoch_d; outcome_slot_q <= outcome_slot_d; outcome_tick_q <= outcome_tick_d;
      exact_q <= exact_d; loss_q <= loss_d; loss_last_known_q <= loss_last_known_d;
      time_bad_q <= time_bad_d; counter_bad_q <= counter_bad_d; isolated_q <= isolated_d;
      handoff_failed_q <= handoff_failed_d; handoff_age_q <= handoff_age_d;
      prev_valid_q <= 1; previous_tick_q <= tick_i; supervisor_q <= supervisor_fault_i; isolation_q <= isolate_i;
      epoch_q <= epoch_d; last_epoch_q <= last_epoch_d; next_tick_q <= next_tick_d; origin_q <= origin_d;
      scheduled_q <= scheduled_d; emitted_q <= emitted_d; missing_q <= missing_d;
      delivered_q <= delivered_d; end_delivered_q <= end_delivered_d;
      last_tick_q <= last_tick_d; end_tick_q <= end_tick_d;
      loss_first_q <= loss_first_d; loss_last_q <= loss_last_d; boundary_q <= boundary_d;
      sticky_q <= sticky_d; first_q <= first_d; latest_q <= latest_d;
      first_tick_q <= first_tick_d; latest_tick_q <= latest_tick_d;
      /* a registered occurrence avoids a combinational loop through the controller's STOP path. */
      fault_o <= (reasons & FAULT_MASK) != 0;
    end
  end

`ifndef SYNTHESIS
  /* elaboration-only test reductions cannot create zero-capacity or unbounded waits. */
  initial begin
    if (COUNTER_LIMIT == 0 || HANDOFF_CYCLES < 1 || HANDOFF_CYCLES > 80)
      $fatal(1, "invalid scheduler parameters");
  end
`endif
endmodule

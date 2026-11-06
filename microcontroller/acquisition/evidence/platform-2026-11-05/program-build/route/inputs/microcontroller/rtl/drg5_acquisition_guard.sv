/* supervise synthetic F-80 slots; external FIFO and DMA retain storage ownership. */
module drg5_acquisition_guard #(
  parameter integer CLOCK_HZ = 80000000,
  parameter integer SLOT_CYCLES = 1600,
  parameter integer STOP_CYCLES = 1600,
  parameter logic [63:0] COUNTER_LIMIT = 64'hffffffffffffffff
) (
  input logic clk_i, power_reset_i, arm_i, stop_i, qualified_i,
  input logic debug_halt_i, cpu_reset_i, memory_available_i,
  input logic memory_deadline_i, lease_overrun_i, ring_space_i, record_credit_i,
  input logic [8:0] fifo_occupancy_i,
  input logic [15:0] clear_reasons_i,
  input logic frame_valid_i, frame_good_i,
  input logic [63:0] frame_slot_i, frame_epoch_i,
  input logic [383:0] frame_data_i,
  input logic record_ready_i, drain_ack_i, drain_error_i,
  input logic [63:0] drain_lost_i,
  input logic event_ready_i,
  output logic profile_ok_o, running_o, stopping_o, close_valid_o, closed_o,
  output logic [2:0] state_o,
  output logic trigger_o, block_reference_o, frame_ready_o,
  output logic [63:0] trigger_slot_o, trigger_tick_o, trigger_epoch_o,
  output logic [63:0] tick_o, epoch_o, epoch_slots_o,
  output logic [63:0] scheduled_o, emitted_o, invalid_o, not_triggered_o,
  output logic [63:0] retained_o, lost_tail_o, lost_events_o, delivered_events_o,
  output logic accounting_exact_o,
  output logic record_valid_o, record_invalid_o,
  output logic [383:0] record_data_o,
  output logic [63:0] record_slot_o, record_tick_o, record_epoch_o,
  output logic [15:0] sticky_reasons_o, first_reason_o, latest_reason_o,
  output logic [63:0] first_reason_tick_o, latest_reason_tick_o,
  output logic event_valid_o,
  output logic [15:0] event_reasons_o,
  output logic [63:0] event_tick_o, event_epoch_o, event_slot_o,
  output logic [63:0] stop_tick_o, stop_slot_o, stop_slot_tick_o,
  output logic stop_slot_valid_o
);
  localparam logic [2:0] IDLE = 0, RUN = 1, STOPPING = 2, DRAIN = 3, SEALED = 4;
  localparam logic [15:0] SOFTWARE = 16'h0001, DEBUG = 16'h0002, CPU_RESET = 16'h0004,
    HIGH_WATER = 16'h0008, RING = 16'h0010, LEASE = 16'h0020, MEMORY_DEADLINE = 16'h0040,
    MEMORY_DOWN = 16'h0080, FRAME_BAD = 16'h0100, FRAME_TIMEOUT = 16'h0200,
    STALE_FRAME = 16'h0400, EVENT_OVERFLOW = 16'h0800, COUNTER_FULL = 16'h1000,
    UNQUALIFIED = 16'h2000, BAD_CLOSE = 16'h4000, NO_CREDIT = 16'h8000;
  logic [2:0] state_q, state_d;
  logic [63:0] tick_q, tick_d, epoch_q, epoch_d, epoch_slots_q, epoch_slots_d;
  logic [63:0] scheduled_q, scheduled_d, emitted_q, emitted_d, invalid_q, invalid_d;
  logic [63:0] not_triggered_q, not_triggered_d, retained_q, retained_d;
  logic [63:0] lost_tail_q, lost_tail_d, lost_events_q, lost_events_d, delivered_q, delivered_d;
  logic [63:0] epoch_retained_q, epoch_retained_d, last_slot_tick_q, last_slot_tick_d;
  logic exact_q, exact_d, debug_q, cpu_reset_q;
  logic [10:0] period_q, period_d, age_q, age_d;
  logic [7:0] block_slot_q, block_slot_d;
  logic frame_q, frame_d;
  logic [63:0] frame_slot_q, frame_slot_d, frame_tick_q, frame_tick_d;
  logic record_q, record_d, record_invalid_q, record_invalid_d;
  logic [383:0] record_data_q, record_data_d;
  logic [63:0] record_slot_q, record_slot_d, record_tick_q, record_tick_d, record_epoch_q, record_epoch_d;
  logic [15:0] sticky_q, sticky_d, first_q, first_d, latest_q, latest_d;
  logic [63:0] first_tick_q, first_tick_d, latest_tick_q, latest_tick_d;
  logic event_q, event_d;
  logic [15:0] event_reasons_q, event_reasons_d;
  logic [63:0] event_tick_q, event_tick_d, event_epoch_q, event_epoch_d, event_slot_q, event_slot_d;
  logic [63:0] stop_tick_q, stop_tick_d, stop_slot_q, stop_slot_d;
  logic [63:0] stop_slot_tick_q, stop_slot_tick_d;
  logic stop_slot_valid_q, stop_slot_valid_d;
  logic trigger_d, block_reference_d;
  logic [63:0] trigger_slot_d, trigger_tick_d, trigger_epoch_d;
  logic [15:0] reasons;
  logic stop_now, due, match_frame, finish_frame, bad_frame, record_free, exhausted;
  logic [63:0] add_scheduled, add_emitted, add_invalid, add_missing, add_retained, add_lost;
  logic [64:0] sum;

  /* saturate rather than wrap; the high bit records lost accounting precision. */
  function automatic logic [64:0] bounded_add(input logic [63:0] value, amount);
    logic [64:0] total;
    /* include the carry when comparing against the implementation limit. */
    begin
      total = {1'b0, value} + {1'b0, amount};
      bounded_add = total > {1'b0, COUNTER_LIMIT} ? {1'b1, COUNTER_LIMIT} : total;
    end
  endfunction

  /* CPU reset and debug never reset the acquisition clock or retained observations. */
  assign profile_ok_o = CLOCK_HZ == 80000000 && SLOT_CYCLES == 1600 && STOP_CYCLES == 1600;
  assign running_o = state_q == RUN;
  assign stopping_o = state_q == STOPPING;
  assign close_valid_o = state_q == DRAIN;
  assign closed_o = state_q == SEALED || state_q == IDLE;
  assign state_o = state_q;
  assign frame_ready_o = 1'b1;
  assign tick_o = tick_q;
  assign epoch_o = epoch_q;
  assign epoch_slots_o = epoch_slots_q;
  assign scheduled_o = scheduled_q;
  assign emitted_o = emitted_q;
  assign invalid_o = invalid_q;
  assign not_triggered_o = not_triggered_q;
  assign retained_o = retained_q;
  assign lost_tail_o = lost_tail_q;
  assign lost_events_o = lost_events_q;
  assign delivered_events_o = delivered_q;
  assign accounting_exact_o = exact_q;
  assign record_valid_o = record_q;
  assign record_invalid_o = record_invalid_q;
  assign record_data_o = record_data_q;
  assign record_slot_o = record_slot_q;
  assign record_tick_o = record_tick_q;
  assign record_epoch_o = record_epoch_q;
  assign sticky_reasons_o = sticky_q;
  assign first_reason_o = first_q;
  assign latest_reason_o = latest_q;
  assign first_reason_tick_o = first_tick_q;
  assign latest_reason_tick_o = latest_tick_q;
  assign event_valid_o = event_q;
  assign event_reasons_o = event_reasons_q;
  assign event_tick_o = event_tick_q;
  assign event_epoch_o = event_epoch_q;
  assign event_slot_o = event_slot_q;
  assign stop_tick_o = stop_tick_q;
  assign stop_slot_o = stop_slot_q;
  assign stop_slot_tick_o = stop_slot_tick_q;
  assign stop_slot_valid_o = stop_slot_valid_q;

  /* resolve each slot once, retaining offered records through external FIFO acceptance. */
  always_comb begin
    state_d = state_q; tick_d = tick_q; epoch_d = epoch_q; epoch_slots_d = epoch_slots_q;
    scheduled_d = scheduled_q; emitted_d = emitted_q; invalid_d = invalid_q;
    not_triggered_d = not_triggered_q; retained_d = retained_q; lost_tail_d = lost_tail_q;
    lost_events_d = lost_events_q; delivered_d = delivered_q; exact_d = exact_q;
    epoch_retained_d = epoch_retained_q; last_slot_tick_d = last_slot_tick_q;
    period_d = period_q; age_d = age_q; block_slot_d = block_slot_q;
    frame_d = frame_q; frame_slot_d = frame_slot_q; frame_tick_d = frame_tick_q;
    record_d = record_q; record_invalid_d = record_invalid_q; record_data_d = record_data_q;
    record_slot_d = record_slot_q; record_tick_d = record_tick_q; record_epoch_d = record_epoch_q;
    sticky_d = sticky_q & ~clear_reasons_i; first_d = first_q; latest_d = latest_q;
    first_tick_d = first_tick_q; latest_tick_d = latest_tick_q;
    event_d = event_q; event_reasons_d = event_reasons_q; event_tick_d = event_tick_q;
    event_epoch_d = event_epoch_q; event_slot_d = event_slot_q;
    stop_tick_d = stop_tick_q; stop_slot_d = stop_slot_q; stop_slot_valid_d = stop_slot_valid_q;
    stop_slot_tick_d = stop_slot_tick_q;
    trigger_d = 0; block_reference_d = 0;
    trigger_slot_d = trigger_slot_o; trigger_tick_d = trigger_tick_o; trigger_epoch_d = trigger_epoch_o;
    reasons = 0; stop_now = 0;
    add_scheduled = 0; add_emitted = 0; add_invalid = 0; add_missing = 0; add_retained = 0; add_lost = 0;
    due = state_q == RUN && period_q == 0;
    match_frame = frame_valid_i && frame_q && frame_slot_i == frame_slot_q && frame_epoch_i == epoch_q;
    finish_frame = frame_q && (match_frame || age_q == 11'(STOP_CYCLES - 1) || !qualified_i);
    bad_frame = !match_frame || !frame_good_i || !qualified_i;
    record_free = !record_q || record_ready_i;
    exhausted = scheduled_q == COUNTER_LIMIT || epoch_q == COUNTER_LIMIT ||
      lost_tail_q == COUNTER_LIMIT || lost_events_q == COUNTER_LIMIT || delivered_q == COUNTER_LIMIT;
    sum = 0;

    /* the free-running timestamp stops before wrapping and permanently blocks further arm. */
    if (&tick_q) begin
      /* report timestamp exhaustion once, while retaining permanent admission inhibition. */
      if (exact_q) reasons |= COUNTER_FULL;
      stop_now = 1; exact_d = 0;
    /* otherwise time advances independently of CPU run state. */
    end else begin
      tick_d = tick_q + 1'b1;
    end
    /* acknowledge external ownership transfers before admitting replacement records. */
    if (record_q && record_ready_i) begin
      record_d = 0; add_retained = 1; epoch_retained_d = epoch_retained_q + 1'b1;
    end
    /* event delivery releases only the notification slot, never sticky fault evidence. */
    if (event_q && event_ready_i) begin
      event_d = 0;
      sum = bounded_add(delivered_q, 1); delivered_d = sum[63:0]; exact_d &= !sum[64];
    end
    /* level-sensitive stops block acquisition even when their notification edge already occurred. */
    if (debug_halt_i || cpu_reset_i || !qualified_i || !profile_ok_o || !memory_available_i ||
        memory_deadline_i || lease_overrun_i || !ring_space_i || fifo_occupancy_i >= 192 || stop_i || exhausted) begin
      stop_now = 1;
    end
    /* pulse inputs represent distinct events; CPU/debug levels are logged once per assertion. */
    if (debug_halt_i && !debug_q) reasons |= DEBUG;
    if (cpu_reset_i && !cpu_reset_q) reasons |= CPU_RESET;
    if (memory_deadline_i) reasons |= MEMORY_DEADLINE;
    if (lease_overrun_i) reasons |= LEASE;
    /* persistent environmental failures produce one reason when ending an active run or rejecting arm. */
    if (state_q == RUN || arm_i) begin
      /* each independent stop cause remains observable when several arrive together. */
      if (stop_i) reasons |= SOFTWARE;
      if (!qualified_i || !profile_ok_o) reasons |= UNQUALIFIED;
      if (!memory_available_i) reasons |= MEMORY_DOWN;
      if (!ring_space_i) reasons |= RING;
      if (fifo_occupancy_i >= 192) reasons |= HIGH_WATER;
      if (exhausted) reasons |= COUNTER_FULL;
    end
    /* late or duplicate frames are consumed as stale; they never resolve a later slot. */
    if (frame_valid_i && !match_frame) begin
      reasons |= STALE_FRAME; stop_now = 1;
    end
    /* completion on the deadline edge wins over timeout if its identity and validity match. */
    if (finish_frame) begin
      frame_d = 0;
      /* a reserved slot must retain its completion even if the external FIFO stalls. */
      if (record_free) begin
        record_d = 1; record_invalid_d = bad_frame;
        /* preserve invalid raw evidence; only a missing completion produces zero data. */
        record_data_d = match_frame ? frame_data_i : 384'b0;
        record_slot_d = frame_slot_q; record_tick_d = frame_tick_q; record_epoch_d = epoch_q;
        record_free = 0;
      /* an impossible reservation collision is explicitly lost, never overwritten. */
      end else begin
        add_lost = add_lost + 1'b1; reasons |= NO_CREDIT; stop_now = 1;
      end
      /* invalid capture counts once whether retained as a placeholder or loss-accounted. */
      if (bad_frame) begin
        add_invalid = add_invalid + 1'b1;
        /* a matching integrity failure may remain a marked frame within the current epoch. */
        if (match_frame && qualified_i) begin
          reasons |= FRAME_BAD;
        /* missing completion or qualification loss ends the epoch. */
        end else begin
          reasons |= FRAME_TIMEOUT; stop_now = 1;
        end
      end
    /* retain the unresolved frame while its watchdog advances. */
    end else if (frame_q) begin
      age_d = age_q + 1'b1;
    end
    /* newly exhausted notification capacity participates in pretrigger arbitration. */
    if ((reasons != 0 && event_d) || (delivered_d == COUNTER_LIMIT && delivered_q != COUNTER_LIMIT) || !exact_d) begin
      stop_now = 1;
    end
    /* consume one fixed-grid slot even when a same-edge stop suppresses its trigger. */
    if (due) begin
      period_d = 11'(SLOT_CYCLES - 1);
      add_scheduled = 1; epoch_slots_d = epoch_slots_q + 1'b1;
      last_slot_tick_d = tick_q;
      block_reference_d = &block_slot_q; block_slot_d = block_slot_q + 1'b1;
      /* an outstanding frame or record cannot be overwritten by a later slot. */
      if (stop_now || frame_q || !record_free || !record_credit_i || fifo_occupancy_i >= 256) begin
        add_missing = 1; add_invalid = add_invalid + 1'b1;
        /* unused credit permits a deterministic placeholder; otherwise retain exact tail loss. */
        if (record_free && record_credit_i && fifo_occupancy_i < 256) begin
          record_d = 1; record_invalid_d = 1; record_data_d = 0;
          record_slot_d = epoch_slots_q; record_tick_d = tick_q; record_epoch_d = epoch_q;
        /* no reserved destination means an explicit unretained scheduled slot. */
        end else begin
          add_lost = add_lost + 1'b1;
        end
        /* capture congestion ends the epoch rather than retiming the scheduled edge. */
        if (frame_q || !record_free || !record_credit_i || fifo_occupancy_i >= 256) begin
          reasons |= NO_CREDIT; stop_now = 1;
        end
      /* launch only on the fixed scheduled edge with all required credit already granted. */
      end else begin
        trigger_d = 1; trigger_slot_d = epoch_slots_q; trigger_tick_d = tick_q; trigger_epoch_d = epoch_q;
        add_emitted = 1; frame_d = 1; frame_slot_d = epoch_slots_q; frame_tick_d = tick_q; age_d = 0;
      end
    /* count down without consulting CPU or downstream readiness. */
    end else if (state_q == RUN) begin
      period_d = period_q - 1'b1;
    end
    /* closure acknowledgement is an external attestation of retired or contained old storage. */
    if (drain_ack_i) begin
      /* an offered record still belongs to this guard until the FIFO accepts it. */
      if (state_q == DRAIN && !record_d && !frame_d && drain_lost_i <= epoch_retained_d) begin
        state_d = SEALED; add_lost = drain_lost_i;
        /* a fault closure remains distinguishable from successful tail publication. */
        if (drain_error_i) reasons |= BAD_CLOSE;
      /* reject acknowledgements that would abandon a live record or frame owner. */
      end else begin
        reasons |= BAD_CLOSE; stop_now = 1;
      end
    end
    /* all lifetime counters survive every halt, stop, epoch change and CPU reset. */
    sum = bounded_add(scheduled_q, add_scheduled); scheduled_d = sum[63:0]; exact_d &= !sum[64];
    sum = bounded_add(emitted_q, add_emitted); emitted_d = sum[63:0]; exact_d &= !sum[64];
    sum = bounded_add(invalid_q, add_invalid); invalid_d = sum[63:0]; exact_d &= !sum[64];
    sum = bounded_add(not_triggered_q, add_missing); not_triggered_d = sum[63:0]; exact_d &= !sum[64];
    sum = bounded_add(retained_q, add_retained); retained_d = sum[63:0]; exact_d &= !sum[64];
    sum = bounded_add(lost_tail_q, add_lost); lost_tail_d = sum[63:0]; exact_d &= !sum[64];
    /* reaching a counter limit ends the run before another slot can overflow it. */
    if ((scheduled_d == COUNTER_LIMIT && scheduled_q != COUNTER_LIMIT) ||
        (lost_tail_d == COUNTER_LIMIT && lost_tail_q != COUNTER_LIMIT) ||
        (delivered_d == COUNTER_LIMIT && delivered_q != COUNTER_LIMIT) || (exact_q && !exact_d)) begin
      reasons |= COUNTER_FULL; stop_now = 1;
    end
    /* the current frame may finish while stopping, but no following trigger is admitted. */
    if ((state_q == RUN && stop_now) || state_q == STOPPING) begin
      state_d = frame_d ? STOPPING : DRAIN;
      /* freeze the resolved boundary independently of later FIFO/DMA drain latency. */
      if (!frame_d) begin
        stop_tick_d = tick_q; stop_slot_valid_d = epoch_slots_d != 0;
        stop_slot_d = epoch_slots_d == 0 ? 64'b0 : epoch_slots_d - 1'b1;
        stop_slot_tick_d = last_slot_tick_d;
      end
    end
    /* rearm starts a new epoch only after the previous ownership closure completes. */
    if (arm_i && (state_q == IDLE || state_q == SEALED)) begin
      /* empty ingress and reserved capacity are admission conditions, not invented transfers. */
      if (!stop_now && !record_q && !frame_q && fifo_occupancy_i == 0 && record_credit_i) begin
        state_d = RUN; epoch_d = epoch_q + 1'b1; epoch_slots_d = 0;
        period_d = 0; block_slot_d = 0; stop_slot_valid_d = 0; epoch_retained_d = 0; last_slot_tick_d = 0;
      /* rejected arm commands preserve the current epoch and lifetime ledger. */
      end else begin
        reasons |= UNQUALIFIED;
      end
    end
    /* a one-entry event queue cannot erase overflow evidence when its consumer stalls. */
    if (reasons != 0) begin
      latest_d = reasons; latest_tick_d = tick_q;
      /* preserve the first lifetime reason independently of W1C pending state. */
      if (first_q == 0) begin
        first_d = reasons; first_tick_d = tick_q;
      end
      /* acceptance and a new event may share an edge without losing either event. */
      if (!event_d) begin
        event_d = 1; event_reasons_d = reasons; event_tick_d = tick_q;
        event_epoch_d = epoch_q; event_slot_d = frame_q ? frame_slot_q : epoch_slots_q;
        /* without a live frame, stale-response events retain the offending identity. */
        if (!frame_q && (reasons & STALE_FRAME) != 0) begin
          event_epoch_d = frame_epoch_i; event_slot_d = frame_slot_i;
        end
      /* preserve the queued event and count the new undeliverable event independently. */
      end else begin
        sum = bounded_add(lost_events_q, 1); lost_events_d = sum[63:0]; exact_d &= !sum[64];
        reasons |= EVENT_OVERFLOW;
        /* queue overflow ends the epoch without relying on CPU acknowledgement. */
        if (state_d == RUN) begin
          state_d = frame_d ? STOPPING : DRAIN;
          /* an idle capture already has a complete stop boundary. */
          if (!frame_d) begin
            stop_tick_d = tick_q; stop_slot_valid_d = epoch_slots_d != 0;
            stop_slot_d = epoch_slots_d == 0 ? 64'b0 : epoch_slots_d - 1'b1;
            stop_slot_tick_d = last_slot_tick_d;
          end
        end
        /* lost-event saturation forces containment even if firmware never reads status. */
        if (lost_events_d == COUNTER_LIMIT) begin
          reasons |= COUNTER_FULL;
        end
      end
      latest_d = reasons;
      sticky_d |= reasons;
    end
  end

  /* only qualified whole-domain power reset clears ownership and lifetime accounting. */
  always_ff @(posedge clk_i) begin
    /* CPU reset is a stop input and cannot enter this reset branch. */
    if (power_reset_i) begin
      state_q <= IDLE; tick_q <= 0; epoch_q <= 0; epoch_slots_q <= 0;
      scheduled_q <= 0; emitted_q <= 0; invalid_q <= 0; not_triggered_q <= 0; retained_q <= 0;
      lost_tail_q <= 0; lost_events_q <= 0; delivered_q <= 0; exact_q <= 1;
      epoch_retained_q <= 0; last_slot_tick_q <= 0;
      period_q <= 0; age_q <= 0; block_slot_q <= 0; frame_q <= 0; frame_slot_q <= 0; frame_tick_q <= 0;
      record_q <= 0; record_invalid_q <= 0; record_data_q <= 0;
      record_slot_q <= 0; record_tick_q <= 0; record_epoch_q <= 0;
      sticky_q <= 0; first_q <= 0; latest_q <= 0; first_tick_q <= 0; latest_tick_q <= 0;
      event_q <= 0; event_reasons_q <= 0; event_tick_q <= 0; event_epoch_q <= 0; event_slot_q <= 0;
      stop_tick_q <= 0; stop_slot_q <= 0; stop_slot_valid_q <= 0; stop_slot_tick_q <= 0;
      trigger_o <= 0; block_reference_o <= 0; trigger_slot_o <= 0; trigger_tick_o <= 0; trigger_epoch_o <= 0;
      debug_q <= 0; cpu_reset_q <= 0;
    /* update retained state even while the CPU is halted or held in reset. */
    end else begin
      state_q <= state_d; tick_q <= tick_d; epoch_q <= epoch_d; epoch_slots_q <= epoch_slots_d;
      scheduled_q <= scheduled_d; emitted_q <= emitted_d; invalid_q <= invalid_d;
      not_triggered_q <= not_triggered_d; retained_q <= retained_d; lost_tail_q <= lost_tail_d;
      lost_events_q <= lost_events_d; delivered_q <= delivered_d; exact_q <= exact_d;
      epoch_retained_q <= epoch_retained_d; last_slot_tick_q <= last_slot_tick_d;
      period_q <= period_d; age_q <= age_d; block_slot_q <= block_slot_d;
      frame_q <= frame_d; frame_slot_q <= frame_slot_d; frame_tick_q <= frame_tick_d;
      record_q <= record_d; record_invalid_q <= record_invalid_d; record_data_q <= record_data_d;
      record_slot_q <= record_slot_d; record_tick_q <= record_tick_d; record_epoch_q <= record_epoch_d;
      sticky_q <= sticky_d; first_q <= first_d; latest_q <= latest_d;
      first_tick_q <= first_tick_d; latest_tick_q <= latest_tick_d;
      event_q <= event_d; event_reasons_q <= event_reasons_d; event_tick_q <= event_tick_d;
      event_epoch_q <= event_epoch_d; event_slot_q <= event_slot_d;
      stop_tick_q <= stop_tick_d; stop_slot_q <= stop_slot_d; stop_slot_valid_q <= stop_slot_valid_d;
      stop_slot_tick_q <= stop_slot_tick_d;
      trigger_o <= trigger_d; block_reference_o <= block_reference_d;
      trigger_slot_o <= trigger_slot_d; trigger_tick_o <= trigger_tick_d; trigger_epoch_o <= trigger_epoch_d;
      debug_q <= debug_halt_i; cpu_reset_q <= cpu_reset_i;
    end
  end

`ifndef SYNTHESIS
  /* offered records and events cannot be overwritten during downstream backpressure. */
  assert property (@(posedge clk_i) disable iff (power_reset_i)
    record_valid_o && !record_ready_i |=> power_reset_i || (record_valid_o &&
      $stable({record_data_o, record_invalid_o, record_slot_o, record_tick_o, record_epoch_o})));
  assert property (@(posedge clk_i) disable iff (power_reset_i)
    event_valid_o && !event_ready_i |=> power_reset_i || (event_valid_o &&
      $stable({event_reasons_o, event_tick_o, event_epoch_o, event_slot_o})));
  /* every scheduled attempt either emitted its trigger or was explicitly not triggered. */
  assert property (@(posedge clk_i) disable iff (power_reset_i)
    accounting_exact_o |-> scheduled_o == emitted_o + not_triggered_o);
`endif
endmodule

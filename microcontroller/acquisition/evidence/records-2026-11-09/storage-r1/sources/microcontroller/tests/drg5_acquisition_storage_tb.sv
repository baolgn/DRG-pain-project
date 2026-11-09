`timescale 1ns/1ps
/* check the real scheduler against synthetic capture and independently retained DMA results. */
module drg5_acquisition_storage_tb;
  logic clk;
  /* one process owns every clock transition. */
  initial begin
    clk = 0;
    forever #6.25 clk = ~clk;
  end
  logic reset, prepare, stop, cpu_reset, arm, capture_enable, dma_enable;
  logic [63:0] tick, arm_epoch, first_tick;
  logic exhausted, active, pulse_busy, convst, launch, scheduler_accept, scheduler_ready;
  logic [31:0] scheduler_result, end_ack_result;
  logic [63:0] launch_epoch, launch_slot, launch_tick;
  logic outcome_valid, outcome_triggered, outcome_ready, storage_ready;
  logic [63:0] outcome_epoch, outcome_slot, outcome_tick;
  logic [31:0] outcome_causes;
  logic end_valid, end_ack, exact, loss_valid, loss_last_known, last_known;
  logic [63:0] end_epoch, end_tick, end_delivered, scheduled, emitted, missing, delivered;
  logic [63:0] last_slot, last_tick, loss_first, loss_last;
  logic [31:0] end_causes, scheduler_sticky, scheduler_first, scheduler_latest;
  logic scheduler_fault, isolate;
  logic [63:0] scheduler_first_tick, scheduler_latest_tick;
  logic storage_arm_ready, credit, capture_idle, drained, capture_start;
  logic [63:0] capture_id;
  logic complete_valid, complete_ready, cancel, dma_valid, dma_ready, dma_owned, dma_sent, dma_done;
  logic [63:0] complete_id, cancel_epoch, cancel_slot, dma_epoch, dma_slot, dma_done_epoch, dma_done_slot;
  logic [383:0] complete_record, dma_record;
  logic [3:0] complete_result, cancel_result, dma_done_result;
  logic [8:0] owned, reserved_count, capture_count, missing_count, assembler_count, fifo_count, dma_count;
  logic [63:0] allocated, released, retired, admitted;
  logic storage_stop, storage_fault;
  logic [31:0] link_faults, record_faults;
  logic forward_outcome, inject_launch, inject_missing;
  logic [63:0] injected_slot, injected_tick;
  integer checks = 0, cases = 0, requests, completions, launches, next_dma;
  integer capture_delay, dma_delay, poison;
  string wave;
  logic pending_capture, pending_dma, stalled;
  logic [63:0] pending_id, pending_slot, pending_dma_epoch, pending_dma_slot;
  logic [383:0] expected [0:31];
  logic expected_valid [0:31];
  logic [383:0] held_record;
  logic [63:0] held_epoch, held_slot;

  /* synthetic raw bytes are opaque buffer inputs; no serial or analog validity is claimed. */
  function automatic [383:0] sample_record(input logic [63:0] slot);
    integer c;
    /* assemble one complete test payload with explicit byte positions. */
    begin
      sample_record = 0;
      /* distinct sample and status positions expose truncation, reordering and stale payloads. */
      for (c = 0; c < 8; c = c + 1) begin
        sample_record[c*32 +: 32] = 32'(slot * 16 + 64'(c) + 1);
        sample_record[256+c*8 +: 8] = 8'(c);
      end
      sample_record[320 +: 16] = 16'h1234;
      sample_record[336 +: 8] = 8'hff;
      sample_record[352 +: 32] = 32'h00030000;
    end
  endfunction

  /* every failed predicate terminates the simulation with its named comparator. */
  task automatic check(input logic condition, input string name);
    /* unknown predicates fail rather than disappearing through Boolean coercion. */
    begin
      checks = checks + 1;
      if (condition !== 1'b1) $fatal(1, "%s case=%0d tick=%0d", name, cases, tick);
    end
  endtask

  /* one driver changes automatic inputs on falling edges and samples before sequential updates. */
  task automatic step;
    logic accepted_launch, accepted_missing;
    logic [383:0] observed_record;
    /* drive away from the sampling edge and compare both transfer and retained state. */
    begin
      @(negedge clk);
      complete_valid = pending_capture && capture_enable && capture_delay == 0;
      complete_id = pending_id; complete_record = sample_record(pending_slot);
      dma_ready = dma_enable;
      dma_done = pending_dma && dma_enable && dma_delay == 0;
      dma_done_epoch = pending_dma_epoch; dma_done_slot = pending_dma_slot;
      @(posedge clk);
      accepted_launch = capture_start;
      accepted_missing = (outcome_valid && !outcome_triggered && outcome_ready) ||
        (inject_missing && storage_ready);
      /* only a real scheduler launch authorizes a synthetic capture. */
      if (launch && !reset) begin
        check(capture_start, "binding comparator");
        check(launch_tick == first_tick + 1600 * launch_slot, "grid comparator");
      end
      /* a held complete record cannot change while the DMA request is backpressured. */
      if (stalled && !reset) begin
        check(dma_valid && dma_record === held_record && dma_epoch === held_epoch && dma_slot === held_slot,
              "stable comparator");
      end
      stalled = dma_valid && !dma_ready && !reset;
      held_record = dma_record; held_epoch = dma_epoch; held_slot = dma_slot;
      /* record the expected payload independently at the trigger or missing decision. */
      if (accepted_launch) begin
        check(!pending_capture, "capture owner comparator");
        check(launch_slot < 32, "scoreboard capacity comparator");
        expected[launch_slot[4:0]] = sample_record(launch_slot); expected_valid[launch_slot[4:0]] = 1;
        pending_capture = 1; pending_id = capture_id; pending_slot = launch_slot; capture_delay = 4;
        launches = launches + 1;
      end
      /* a canceled admitted conversion retains its zero-bit triggered placeholder. */
      if (cancel && cancel_result == 1 && !reset) begin
        expected[cancel_slot[4:0]] = 384'b0;
        expected[cancel_slot[4:0]][373] = 1; expected[cancel_slot[4:0]][368] = 1;
        pending_capture = 0;
      end
      /* the scheduler notification identifies an untriggered retained slot. */
      if (accepted_missing) begin
        check((inject_missing ? injected_slot : outcome_slot) < 32, "missing capacity comparator");
        check(!expected_valid[inject_missing ? injected_slot[4:0] : outcome_slot[4:0]], "missing identity comparator");
        expected[inject_missing ? injected_slot[4:0] : outcome_slot[4:0]] = 0;
        expected[inject_missing ? injected_slot[4:0] : outcome_slot[4:0]][373] = 1;
        expected_valid[inject_missing ? injected_slot[4:0] : outcome_slot[4:0]] = 1;
      end
      /* only an accepted response retires the synthetic capture owner's held input. */
      if (complete_valid && complete_ready) begin
        check(complete_result == 1, "completion comparator");
        pending_capture = 0;
      end
      if (capture_delay > 0) capture_delay = capture_delay - 1;
      /* request acceptance and completion remain distinct modeled DMA events. */
      if (dma_valid && dma_ready) begin
        check(!pending_dma && dma_slot == 64'(next_dma) && dma_epoch == arm_epoch, "order comparator");
        observed_record = dma_record;
        if (poison == 1) observed_record[0] = ~observed_record[0];
        if (poison == 3) observed_record[0] = 1'bx;
        check(expected_valid[dma_slot[4:0]] && observed_record === expected[dma_slot[4:0]], "payload comparator");
        pending_dma = 1; pending_dma_epoch = dma_epoch; pending_dma_slot = dma_slot; dma_delay = 3;
        next_dma = next_dma + 1; requests = requests + 1;
      end
      /* no credit returns at request acceptance; only matching completion retires storage. */
      if (dma_done && !reset) begin
        check(dma_done_result == 1, "DMA completion comparator");
        pending_dma = 0; completions = completions + 1;
      end
      if (dma_delay > 0) dma_delay = dma_delay - 1;
      #1;
      check(!$isunknown({owned, reserved_count, capture_count, missing_count, assembler_count,
        fifo_count, dma_count, allocated, released, retired, admitted, credit, capture_start,
        dma_valid, dma_owned, dma_sent, link_faults, record_faults, pulse_busy, convst, scheduler_result,
        outcome_causes, last_known, end_epoch, end_tick, end_delivered, emitted, delivered, last_slot,
        last_tick, end_causes, scheduler_sticky, scheduler_first, scheduler_latest, scheduler_fault,
        isolate, scheduler_first_tick, scheduler_latest_tick, storage_fault}), "unknown comparator");
      check(owned <= 4 && owned == reserved_count + capture_count + missing_count +
        assembler_count + fifo_count + dma_count, "ownership comparator");
      check({1'b0, allocated} == {1'b0, released} + {1'b0, retired} + 65'(owned), "credit comparator");
      if (poison == 2 && allocated != 0) check(owned == 0, "credit comparator");
    end
  endtask

  /* initialization asserts only the isolated synchronous system reset. */
  task automatic initialize(input string name);
    integer i;
    /* reset both synthetic peers under the same externally contained reset. */
    begin
      cases = cases + 1; $display("TEST %0d %s", cases, name);
      reset = 1; prepare = 0; stop = 0; cpu_reset = 0; arm = 0;
      arm_epoch = 1; first_tick = 0; end_ack = 0; capture_enable = 1; dma_enable = 1;
      cancel = 0; cancel_epoch = 1; cancel_slot = 0;
      forward_outcome = 1; inject_launch = 0; inject_missing = 0; injected_slot = 0; injected_tick = 0;
      pending_capture = 0; pending_dma = 0; stalled = 0; capture_delay = 0; dma_delay = 0;
      pending_id = 0; pending_slot = 0; pending_dma_epoch = 0; pending_dma_slot = 0;
      requests = 0; completions = 0; launches = 0; next_dma = 0;
      /* reset authorizes dropping this test's previous isolated scoreboard. */
      for (i = 0; i < 32; i = i + 1) begin
        expected[i] = 0; expected_valid[i] = 0;
      end
      step(); step(); reset = 0; step();
    end
  endtask

  /* prefetch precedes ARM; bind and scheduler acceptance share the same rising edge. */
  task automatic start_epoch;
    integer n;
    /* reserve an entry before committing the first future slot. */
    begin
      prepare = 1;
      /* a bounded wait proves the first slot has real reserved capacity. */
      for (n = 0; n < 8 && !storage_arm_ready; n = n + 1) step();
      check(storage_arm_ready && scheduler_ready, "prepared comparator");
      arm = 1; first_tick = tick + 1;
      #1; check(scheduler_accept, "ARM comparator");
      step(); arm = 0;
      check(admitted == 0 && owned == 1, "pre-slot reservation comparator");
    end
  endtask

  /* finish the retained prefix before acknowledging the scheduler receipt. */
  task automatic drain(input integer count);
    integer n;
    /* retirement precedes receipt acknowledgment. */
    begin
      prepare = 0; dma_enable = 1; capture_enable = 1;
      /* old captures, placeholders and DMA completions must all retire within this modeled service. */
      for (n = 0; n < 100 && (!drained || !end_valid); n = n + 1) step();
      check(drained && end_valid && completions == count && requests == count, "drain comparator");
      end_ack = 1; #1; check(end_ack_result == 0, "end acknowledgment comparator");
      step(); end_ack = 0; check(!end_valid, "end release comparator");
    end
  endtask

  /* the fixed timebase has no CPU or DMA enable. */
  drg5_acquisition_timebase timebase(.clk_i(clk), .system_reset_i(reset), .tick_o(tick), .exhausted_o(exhausted));
  /* the actual scheduler observes physical reservation occupancy and pre-edge capture ownership. */
  drg5_acquisition_scheduler scheduler (
    .clk_i(clk), .system_reset_i(reset), .tick_i(tick), .timebase_exhausted_i(exhausted),
    .arm_i(arm), .arm_epoch_i(arm_epoch), .arm_first_tick_i(first_tick), .arm_period_i(32'd1600),
    .arm_ready_o(scheduler_ready), .arm_accept_o(scheduler_accept), .arm_result_o(scheduler_result),
    .stop_i(stop || storage_stop), .cpu_reset_i(cpu_reset), .cpu_halt_i(1'b0), .qualified_i(1'b1),
    .supervisor_fault_i(1'b0), .isolate_i(1'b0), .capture_idle_i(capture_idle), .record_credit_i(credit),
    .storage_available_i(1'b1), .fifo_occupancy_i(owned), .active_o(active), .pulse_busy_o(pulse_busy),
    .convst_o(convst), .launch_o(launch), .launch_epoch_o(launch_epoch), .launch_slot_o(launch_slot), .launch_tick_o(launch_tick),
    .outcome_valid_o(outcome_valid), .outcome_ready_i(outcome_ready), .outcome_triggered_o(outcome_triggered),
    .outcome_epoch_o(outcome_epoch), .outcome_slot_o(outcome_slot), .outcome_tick_o(outcome_tick), .outcome_causes_o(outcome_causes),
    .end_valid_o(end_valid), .end_ack_i(end_ack), .end_ack_epoch_i(arm_epoch), .end_ack_result_o(end_ack_result),
    .end_epoch_o(end_epoch), .end_tick_o(end_tick), .end_delivered_o(end_delivered), .scheduled_o(scheduled),
    .emitted_o(emitted), .missing_o(missing), .delivered_o(delivered), .last_slot_known_o(last_known),
    .last_slot_o(last_slot), .last_tick_o(last_tick), .exact_o(exact), .loss_valid_o(loss_valid),
    .loss_last_known_o(loss_last_known), .loss_first_o(loss_first), .loss_last_o(loss_last), .end_causes_o(end_causes),
    .fault_o(scheduler_fault), .isolate_request_o(isolate), .sticky_causes_o(scheduler_sticky),
    .first_fault_o(scheduler_first), .latest_fault_o(scheduler_latest),
    .first_fault_tick_o(scheduler_first_tick), .latest_fault_tick_o(scheduler_latest_tick)
  );
  assign outcome_ready = forward_outcome && storage_ready;
  /* the production adapter carries complete records; only the capture and DMA peers are models. */
  drg5_acquisition_storage #(.DEPTH(4)) storage (
    .clk_i(clk), .system_reset_i(reset), .prepare_i(prepare), .stop_i(stop || cpu_reset),
    .arm_i(arm && scheduler_accept), .arm_epoch_i(arm_epoch), .arm_first_tick_i(first_tick),
    .scheduler_active_i(active), .scheduler_end_valid_i(end_valid),
    .launch_i(launch || inject_launch), .launch_epoch_i(launch_epoch),
    .launch_slot_i(inject_launch ? injected_slot : launch_slot), .launch_tick_i(inject_launch ? injected_tick : launch_tick),
    .outcome_valid_i((forward_outcome && outcome_valid) || inject_missing),
    .outcome_triggered_i(inject_missing ? 1'b0 : outcome_triggered),
    .outcome_epoch_i(outcome_epoch), .outcome_slot_i(inject_missing ? injected_slot : outcome_slot),
    .outcome_tick_i(inject_missing ? injected_tick : outcome_tick), .outcome_ready_o(storage_ready),
    .arm_ready_o(storage_arm_ready), .record_credit_o(credit), .capture_idle_o(capture_idle), .drained_o(drained),
    .occupancy_o(owned), .capture_start_o(capture_start), .capture_id_o(capture_id),
    .complete_valid_i(complete_valid), .complete_ready_o(complete_ready), .complete_id_i(complete_id),
    .complete_record_i(complete_record), .complete_result_o(complete_result),
    .cancel_i(cancel), .cancel_epoch_i(cancel_epoch), .cancel_slot_i(cancel_slot), .cancel_result_o(cancel_result),
    .dma_valid_o(dma_valid), .dma_ready_i(dma_ready), .dma_record_o(dma_record),
    .dma_epoch_o(dma_epoch), .dma_slot_o(dma_slot), .dma_owned_o(dma_owned), .dma_sent_o(dma_sent),
    .dma_done_i(dma_done), .dma_done_epoch_i(dma_done_epoch), .dma_done_slot_i(dma_done_slot), .dma_done_result_o(dma_done_result),
    .reserved_count_o(reserved_count), .capture_count_o(capture_count), .missing_count_o(missing_count),
    .assembler_count_o(assembler_count), .fifo_count_o(fifo_count), .dma_count_o(dma_count),
    .allocated_o(allocated), .unused_released_o(released), .retired_o(retired), .admitted_o(admitted),
    .stop_request_o(storage_stop), .fault_o(storage_fault), .link_faults_o(link_faults), .record_faults_o(record_faults)
  );

  /* every scenario uses bounded clock counts and publicly visible identities. */
  initial begin
    poison = 0;
    if ($value$plusargs("poison=%d", poison)) begin end
    wave = "acquisition-storage.vcd";
    if ($value$plusargs("wave=%s", wave)) begin end
    $dumpfile(wave); $dumpvars(0, drg5_acquisition_storage_tb);
    initialize("on-time grid with DMA response stalls"); start_epoch();
    /* exercise three full grid periods independently of the DMA model's response latency. */
    repeat (3205) step();
    check(launches == 3 && admitted == 3, "normal slots comparator");
    stop = 1; drain(3); check(link_faults == 0 && record_faults == 0, "normal fault comparator");

    initialize("first due STOP retains one missing record"); start_epoch();
    stop = 1; step(); step(); drain(1);
    check(launches == 0 && scheduled == 1 && missing == 1 && !loss_valid, "first missing comparator");

    initialize("placeholder cannot pass an unresolved older conversion"); capture_enable = 0; start_epoch();
    repeat (1605) step();
    check(launches == 1 && scheduled == 2 && missing == 1 && requests == 0, "blocked prefix comparator");
    check(admitted == 2 && capture_count == 1, "pending placeholder comparator");
    drain(2); check(!loss_valid && exact, "retained prefix comparator");

    initialize("full ring has no speculative same-edge credit"); dma_enable = 0; start_epoch();
    repeat (6410) step();
    check(owned == 4 && launches == 4 && scheduled == 5 && admitted == 4, "full reservation comparator");
    check(end_valid && loss_valid && loss_last_known && loss_first == 4 && loss_last == 4, "full loss comparator");
    drain(4);

    initialize("CPU reset and cancellation retain a triggered placeholder"); capture_enable = 0; start_epoch(); step();
    cancel = 1; cpu_reset = 1; prepare = 0; #1; check(cancel_result == 1, "cancel admission comparator");
    step(); cancel = 0; drain(1);
    check(tick > first_tick && scheduled == 1 && admitted == 1, "CPU retention comparator");

    initialize("pending confirmation rejects a second launch"); capture_enable = 0; forward_outcome = 0;
    start_epoch(); step(); step();
    injected_slot = 1; injected_tick = first_tick + 1600; inject_launch = 1;
    #1; check(!capture_start, "confirmation capacity comparator"); step(); inject_launch = 0;
    check(admitted == 1 && link_faults[4], "confirmation owner comparator");
    forward_outcome = 1; step(); drain(1);

    initialize("missing notification rejects a colliding launch"); capture_enable = 0; start_epoch(); step(); step();
    injected_slot = 1; injected_tick = first_tick + 1600; inject_missing = 1; inject_launch = 1;
    #1; check(!capture_start && storage_ready, "collision comparator"); step();
    inject_missing = 0; inject_launch = 0;
    check(admitted == 2 && link_faults[2], "collision owner comparator"); drain(2);
    $display("PASS acquisition-storage cases=%0d checks=%0d", cases, checks); $finish;
  end

  /* the wall-clock guard catches broken clocks or an accidental unbounded task. */
  initial begin
    #1000000; $fatal(1, "global timeout comparator");
  end
endmodule

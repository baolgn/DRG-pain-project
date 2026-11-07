/* compare scheduler behavior with an independent fixed-grid model and explicit edge expectations. */
module drg5_acquisition_scheduler_tb #(
  parameter logic [63:0] TEST_COUNTER_LIMIT = 64'hffffffffffffffff
);
  logic clk_i, system_reset_i = 1;
  logic [63:0] helper_tick, near_tick, tick_i, manual_tick = 0;
  logic helper_exhausted, near_exhausted, timebase_exhausted_i;
  logic manual_mode = 0, manual_advance = 1;
  logic arm_i = 0;
  logic [63:0] arm_epoch_i = 0, arm_first_tick_i = 0;
  logic [31:0] arm_period_i = 1600;
  logic arm_ready_o, arm_accept_o;
  logic [31:0] arm_result_o;
  logic stop_i = 0, cpu_reset_i = 0, cpu_halt_i = 0, qualified_i = 1;
  logic supervisor_fault_i = 0, isolate_i = 0;
  logic capture_idle_i = 1, record_credit_i = 1, storage_available_i = 1;
  logic [8:0] fifo_occupancy_i = 0;
  logic active_o, pulse_busy_o, convst_o, launch_o;
  logic [63:0] launch_epoch_o, launch_slot_o, launch_tick_o;
  logic outcome_valid_o, outcome_ready_i = 1, outcome_triggered_o;
  logic [63:0] outcome_epoch_o, outcome_slot_o, outcome_tick_o;
  logic [31:0] outcome_causes_o;
  logic end_valid_o, end_ack_i = 0;
  logic [63:0] end_ack_epoch_i = 0;
  logic [31:0] end_ack_result_o;
  logic [63:0] end_epoch_o, end_tick_o, end_delivered_o;
  logic [63:0] scheduled_o, emitted_o, missing_o, delivered_o;
  logic last_slot_known_o;
  logic [63:0] last_slot_o, last_tick_o;
  logic exact_o, loss_valid_o, loss_last_known_o;
  logic [63:0] loss_first_o, loss_last_o;
  logic [31:0] end_causes_o;
  logic fault_o, isolate_request_o;
  logic [31:0] sticky_causes_o, first_fault_o, latest_fault_o;
  logic [63:0] first_fault_tick_o, latest_fault_tick_o;
  int unsigned seed = 1, random_state = 1, checks = 0, cases = 0, random_cases = 0, edges = 0;
  string test_name = "initialization", wave_path;
  bit mutate_grid = 0, mutate_pulse = 0, mutate_decision = 0, mutate_terminal = 0, mutate_unknown = 0;
  bit applied_grid = 0, applied_pulse = 0, applied_decision = 0, applied_terminal = 0, applied_unknown = 0;
  logic [63:0] edge_tick, edge_launch_tick, edge_launch_slot, edge_launch_epoch;
  logic edge_launch;

  drg5_acquisition_timebase timebase (
    .clk_i, .system_reset_i, .tick_o(helper_tick), .exhausted_o(helper_exhausted)
  );
  drg5_acquisition_timebase #(.RESET_TICK(64'hfffffffffffffffc)) near_timebase (
    .clk_i, .system_reset_i, .tick_o(near_tick), .exhausted_o(near_exhausted)
  );
  drg5_acquisition_scheduler #(.COUNTER_LIMIT(TEST_COUNTER_LIMIT)) dut (.*);
  assign tick_i = manual_mode ? manual_tick : helper_tick;
  assign timebase_exhausted_i = manual_mode ? &manual_tick : helper_exhausted;

  /* this process alone drives the clock; inputs change only in its low phase. */
  initial begin
    clk_i = 0;
    /* the testbench never derives clocks from transactions or downstream readiness. */
    forever #6.25 clk_i = ~clk_i;
  end

  /* the global deadline contains any testbench wait that fails to make progress. */
  initial begin
    #20000000;
    $fatal(1, "global timeout case=%s edge=%0d", test_name, edges);
  end

  /* unknown conditions are failures in four-state simulation. */
  task automatic check(input logic condition, input string detail);
    checks++;
    if (condition !== 1'b1) $fatal(1, "case=%s seed=%0d edge=%0d: %s", test_name, seed, edges, detail);
  endtask

  /* explicit arithmetic gives both simulators the same randomized sequence. */
  function automatic logic [31:0] random_word();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction

  /* pre-edge markers identify the edge; output checks run after nonblocking updates. */
  task automatic tick();
    logic held_outcome, held_end;
    logic [224:0] old_outcome;
    logic [675:0] old_end;
    logic [63:0] old_helper;
    @(posedge clk_i);
    edge_tick = tick_i;
    edge_launch = launch_o;
    edge_launch_tick = launch_tick_o; edge_launch_slot = launch_slot_o; edge_launch_epoch = launch_epoch_o;
    held_outcome = outcome_valid_o && !outcome_ready_i && !system_reset_i;
    old_outcome = {outcome_triggered_o, outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o};
    held_end = end_valid_o && !(end_ack_i && end_ack_epoch_i == end_epoch_o) && !system_reset_i;
    old_end = {end_epoch_o, end_tick_o, end_delivered_o, scheduled_o, emitted_o, missing_o,
      last_slot_known_o, last_slot_o, last_tick_o, exact_o, loss_valid_o, loss_last_known_o,
      loss_first_o, loss_last_o, end_causes_o};
    old_helper = helper_tick;
    #1;
    edges++;
    check(!$isunknown({helper_tick, helper_exhausted, near_tick, near_exhausted,
      arm_ready_o, arm_accept_o, arm_result_o, active_o, pulse_busy_o, convst_o, launch_o,
      launch_epoch_o, launch_slot_o, launch_tick_o, outcome_valid_o, outcome_triggered_o,
      outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o, end_valid_o,
      end_ack_result_o, end_epoch_o, end_tick_o, end_delivered_o, scheduled_o, emitted_o,
      missing_o, delivered_o, last_slot_known_o, last_slot_o, last_tick_o, exact_o,
      loss_valid_o, loss_last_known_o, loss_first_o, loss_last_o, end_causes_o,
      fault_o, isolate_request_o, sticky_causes_o, first_fault_o, latest_fault_o,
      first_fault_tick_o, latest_fault_tick_o}), "unknown output");
    /* every represented slot has exactly one trigger or explicitly missing decision. */
    check({1'b0, scheduled_o} === ({1'b0, emitted_o} + {1'b0, missing_o}), "slot accounting identity");
    check(delivered_o <= scheduled_o, "notification delivery cannot invent a scheduled slot");
    /* exact loss intervals describe represented missing slots, never a fabricated slot zero. */
    if (loss_valid_o && loss_last_known_o) check(loss_first_o <= loss_last_o && loss_last_o < scheduled_o,
      "known loss interval lies inside the scheduled prefix");
    /* CPU stop levels and downstream stalls cannot stop the separate timebase. */
    if (!system_reset_i) check(helper_tick === (old_helper == 64'hffffffffffffffff ? old_helper : old_helper + 1), "timebase progression");
    /* offered decisions remain immutable through backpressure and timeout. */
    if (held_outcome) check(outcome_valid_o === 1 &&
      {outcome_triggered_o, outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o} === old_outcome,
      "decision comparator: held ownership");
    /* sealed stop evidence cannot be rewritten by late consumers. */
    if (held_end) check(end_valid_o === 1 &&
      {end_epoch_o, end_tick_o, end_delivered_o, scheduled_o, emitted_o, missing_o,
       last_slot_known_o, last_slot_o, last_tick_o, exact_o, loss_valid_o, loss_last_known_o,
       loss_first_o, loss_last_o, end_causes_o} === old_end, "terminal comparator: immutable evidence");
    @(negedge clk_i);
    /* the explicit test source advances only at falling edges and never edits DUT registers. */
    if (manual_mode && manual_advance && !system_reset_i && manual_tick != 64'hffffffffffffffff)
      manual_tick = manual_tick + 1;
    #1;
  endtask

  /* all idle loops have explicit finite lengths. */
  task automatic cycles(input int count);
    repeat (count) tick();
  endtask

  /* a named case is printed before any operation that can fail. */
  task automatic begin_case(input string name);
    test_name = name; cases++;
    $display("TEST %s", name);
  endtask

  /* only isolated system reset clears owners; CPU reset is tested separately. */
  task automatic reset_controller(input bit use_manual, input logic [63:0] first_tick);
    system_reset_i = 1; manual_mode = use_manual; manual_tick = first_tick; manual_advance = 1;
    arm_i = 0; arm_epoch_i = 0; arm_first_tick_i = 0; arm_period_i = 1600;
    stop_i = 0; cpu_reset_i = 0; cpu_halt_i = 0; qualified_i = 1;
    supervisor_fault_i = 0; isolate_i = 0;
    capture_idle_i = 1; record_credit_i = 1; storage_available_i = 1; fifo_occupancy_i = 0;
    outcome_ready_i = 1; end_ack_i = 0; end_ack_epoch_i = 0;
    cycles(2); system_reset_i = 0; tick();
    check(!active_o && !convst_o && !outcome_valid_o && !end_valid_o && scheduled_o === 0, "isolated initial state");
  endtask

  /* rejected requests must preserve owners, counters and pulse state. */
  task automatic arm_request(input logic [63:0] epoch, input logic [63:0] first_tick,
                             input logic [31:0] period, input logic [31:0] expected);
    logic [63:0] old_scheduled, old_emitted;
    logic old_active;
    arm_epoch_i = epoch; arm_first_tick_i = first_tick; arm_period_i = period; arm_i = 1;
    old_scheduled = scheduled_o; old_emitted = emitted_o; old_active = active_o;
    #1;
    check(arm_result_o === expected, $sformatf("ARM result=%0d expected=%0d", arm_result_o, expected));
    check(arm_accept_o === (expected == 1), "ARM acceptance predicate");
    tick(); arm_i = 0;
    /* tests issue rejected requests away from a due edge unless they explicitly test arbitration. */
    if (expected != 1) check(scheduled_o === old_scheduled && emitted_o === old_emitted && active_o === old_active,
                            "rejected ARM changed scheduling ownership");
  endtask

  /* successful ARM binds exactly the following tick without emitting a conversion early. */
  task automatic arm_next(input logic [63:0] epoch, output logic [63:0] first_tick);
    first_tick = tick_i + 1;
    arm_request(epoch, first_tick, 1600, 1);
    check(active_o && !convst_o && scheduled_o === 0, "ARM waits for future tick");
  endtask

  /* one due edge produces one identified conversion and matching retained outcome. */
  task automatic expect_launch(input logic [63:0] epoch, input logic [63:0] slot,
                               input logic [63:0] expected_tick);
    logic [63:0] observed_tick;
    logic observed_high, observed_triggered;
    tick();
    observed_tick = edge_launch_tick;
    observed_high = convst_o;
    observed_triggered = outcome_triggered_o;
    /* each detector corrupts only its sampled value before the normal comparator. */
    if (mutate_grid && !applied_grid) begin observed_tick ^= 1; applied_grid = 1; end
    /* pulse corruption must fail the ordinary sampled output comparison. */
    if (mutate_pulse && !applied_pulse) begin observed_high = !observed_high; applied_pulse = 1; end
    /* metadata corruption must fail the normal decision comparison. */
    if (mutate_decision && !applied_decision) begin observed_triggered = !observed_triggered; applied_decision = 1; end
    /* an injected unknown cannot compare equal to the expected triggered bit. */
    if (mutate_unknown && !applied_unknown) begin observed_triggered = 1'bx; applied_unknown = 1; end
    check(edge_launch === 1 && edge_tick === expected_tick && observed_tick === expected_tick &&
      edge_launch_slot === slot && edge_launch_epoch === epoch, "grid comparator: on-time launch identity");
    check(observed_high === 1 && pulse_busy_o === 1, "pulse comparator: registered CONVST rise");
    check(outcome_valid_o === 1 && observed_triggered === 1 && outcome_epoch_o === epoch &&
      outcome_slot_o === slot && outcome_tick_o === expected_tick && outcome_causes_o === 0,
      "decision comparator: triggered slot identity");
  endtask

  /* ordinary stop preserves all eight high intervals of an already emitted pulse. */
  task automatic finish_pulse();
    /* the rising edge already established the first high interval. */
    for (int high_edge = 1; high_edge < 8; high_edge++) begin
      tick(); check(convst_o === 1 && !edge_launch, "pulse comparator: high width");
    end
    tick(); check(convst_o === 0 && !edge_launch, "pulse comparator: falling edge at rise plus eight");
  endtask

  /* waiting for a scheduled edge never modifies its target timestamp. */
  task automatic until_tick(input logic [63:0] target);
    int waited;
    waited = 0;
    /* all local waits are limited to one nominal slot plus a guard. */
    while (tick_i < target && waited < 1700) begin
      tick(); waited++;
      check(edge_launch === 0, "grid comparator: no off-grid launch");
    end
    check(tick_i === target, "bounded wait reached exact tick");
  endtask

  /* stopping between slots closes without inventing another scheduled slot. */
  task automatic stop_between();
    stop_i = 1; tick(); stop_i = 0;
  endtask

  /* terminal receipt is bounded, while its ownership remains retained until acknowledgment. */
  task automatic terminal(input logic [63:0] expected_scheduled, input logic [63:0] expected_emitted,
                           input logic [63:0] expected_missing, input bit expected_exact);
    int waited;
    logic [63:0] observed_scheduled;
    waited = 0;
    /* a healthy pulse plus the eighty-tick handoff deadline bounds local termination. */
    while (end_valid_o !== 1'b1 && waited < 100) begin tick(); waited++; end
    check(end_valid_o === 1 && !active_o && !convst_o, "terminal comparator: bounded stopped outcome");
    observed_scheduled = scheduled_o;
    /* terminal corruption exercises the same accounting comparator as normal cases. */
    if (mutate_terminal && !applied_terminal) begin observed_scheduled ^= 1; applied_terminal = 1; end
    check(observed_scheduled === expected_scheduled && emitted_o === expected_emitted &&
      missing_o === expected_missing && exact_o === expected_exact, "terminal comparator: slot accounting");
  endtask

  /* full epoch identity prevents a stale receipt from clearing newer terminal evidence. */
  task automatic ack_terminal(input logic [63:0] epoch, input logic [31:0] expected);
    end_ack_epoch_i = epoch; end_ack_i = 1;
    #1; check(end_ack_result_o === expected, "terminal acknowledgment identity");
    tick(); end_ack_i = 0;
  endtask

  /* directed boundaries precede seeded stall sequences and explicit capacity limits. */
  initial begin : campaign
    logic [63:0] first_tick, saved_tick, saved_epoch, next_tick;
    logic [224:0] saved_outcome;
    logic [31:0] value;
    int stall_left, generated, max_wait;
    /* each seed is printed and drives only the explicit xorshift generator. */
    if ($value$plusargs("seed=%d", seed)) begin end
    random_state = seed == 0 ? 32'h6d2b79f5 : seed;
    mutate_grid = $test$plusargs("mutate_grid");
    mutate_pulse = $test$plusargs("mutate_pulse");
    mutate_decision = $test$plusargs("mutate_decision");
    mutate_terminal = $test$plusargs("mutate_terminal");
    mutate_unknown = $test$plusargs("mutate_unknown");
    /* detector runs omit traces while normal runs preserve complete signal histories. */
    if ($value$plusargs("wave=%s", wave_path)) begin
      $dumpfile(wave_path); $dumpvars(0, drg5_acquisition_scheduler_tb);
    end
    @(negedge clk_i);
    reset_controller(0, 0);

    /* the reduced limit reaches slot exhaustion without changing field widths. */
    if ($test$plusargs("small")) begin
      begin_case("slot count saturates without wrap");
      arm_next(1, first_tick);
      /* seven exact grid edges reach the configured test limit. */
      for (int slot = 0; slot < 7; slot++) begin
        until_tick(first_tick + 64'(slot) * 1600);
        expect_launch(1, 64'(slot), first_tick + 64'(slot) * 1600);
        finish_pulse();
      end
      terminal(7, 7, 0, 1);
      check(last_slot_known_o && last_slot_o === 6 && !loss_valid_o && (end_causes_o & 'h400) != 0,
            "counter terminal preserves final represented slot");
      cycles(32); check(scheduled_o === 7 && emitted_o === 7 && !convst_o, "saturated schedule cannot restart");
      $display("PASS acquisition-scheduler-small checks=%0d cases=%0d", checks, cases);
      $finish;
    end

    begin_case("free-running timebase and saturation");
    saved_tick = helper_tick;
    cpu_reset_i = 1; outcome_ready_i = 0; cycles(6);
    check(helper_tick === saved_tick + 6, "CPU reset cannot pause the timebase");
    check(near_tick === 64'hffffffffffffffff && near_exhausted === 1, "timestamp saturates at maximum");
    cycles(5); check(near_tick === 64'hffffffffffffffff, "timestamp never wraps to zero");
    cpu_reset_i = 0; outcome_ready_i = 1;

    begin_case("destructive reset inhibits ARM and a due launch");
    reset_controller(0, 0); arm_next(1, first_tick);
    system_reset_i = 1; arm_i = 1; arm_epoch_i = 2; arm_first_tick_i = tick_i + 1;
    #1; check(!arm_ready_o && !arm_accept_o && !launch_o, "reset fences both admission and due pulse");
    tick(); arm_i = 0; system_reset_i = 0; tick();
    check(!active_o && !convst_o && !outcome_valid_o && !end_valid_o && scheduled_o === 0,
          "reset does not fabricate outcomes");

    begin_case("idle service isolation can release after qualified containment");
    reset_controller(0, 0); isolate_i = 1; tick();
    check(isolate_request_o && !active_o, "idle isolation request is visible");
    isolate_i = 0; tick();
    check(!isolate_request_o, "idle service isolation releases without a fake epoch");
    arm_next(1, first_tick); expect_launch(1, 0, first_tick); finish_pulse(); stop_between(); terminal(1, 1, 0, 1);

    begin_case("future ARM validation has no scheduling side effects");
    reset_controller(0, 0);
    arm_request(0, tick_i + 1, 1600, 2);
    arm_request(1, tick_i, 1600, 2);
    arm_request(1, tick_i - 1, 1600, 2);
    arm_request(1, tick_i + 2, 1600, 5);
    arm_request(1, tick_i + 1, 1599, 5);
    arm_request(1, tick_i + 1, 1601, 5);
    check(first_fault_o === 0 && sticky_causes_o === 0, "rejections do not create fault events");

    begin_case("ARM qualification and capacity gates");
    qualified_i = 0; arm_request(1, tick_i + 1, 1600, 7); qualified_i = 1;
    record_credit_i = 0; arm_request(1, tick_i + 1, 1600, 7); record_credit_i = 1;
    capture_idle_i = 0; arm_request(1, tick_i + 1, 1600, 7); capture_idle_i = 1;
    storage_available_i = 0; arm_request(1, tick_i + 1, 1600, 7); storage_available_i = 1;
    fifo_occupancy_i = 192; arm_request(1, tick_i + 1, 1600, 7); fifo_occupancy_i = 0;
    stop_i = 1; arm_request(1, tick_i + 1, 1600, 9); stop_i = 0;
    cpu_reset_i = 1; arm_request(1, tick_i + 1, 1600, 9); cpu_reset_i = 0;
    cpu_halt_i = 1; arm_request(1, tick_i + 1, 1600, 9); cpu_halt_i = 0;

    begin_case("first future tick launches once with an eight-tick pulse");
    reset_controller(0, 0); arm_next(1, first_tick);
    expect_launch(1, 0, first_tick); finish_pulse();
    check(scheduled_o === 1 && emitted_o === 1 && missing_o === 0 && delivered_o === 1,
          "one first-slot decision and delivery");
    arm_request(1, tick_i + 1, 1600, 3);
    arm_request(2, tick_i + 1, 1599, 4);
    stop_between(); terminal(1, 1, 0, 1);
    check(end_epoch_o === 1 && last_slot_known_o && last_slot_o === 0 && last_tick_o === first_tick && !loss_valid_o,
          "terminal identity and known boundary");
    ack_terminal(99, 3); check(end_valid_o, "stale terminal ACK retains evidence");
    ack_terminal(1, 0); check(!end_valid_o, "matching terminal ACK releases receipt");
    arm_request(1, tick_i + 1, 1600, 3);
    arm_next(2, first_tick); expect_launch(2, 0, first_tick); finish_pulse(); stop_between(); terminal(1, 1, 0, 1);
    ack_terminal(1, 3); check(end_epoch_o === 2 && end_valid_o, "old epoch ACK cannot clear new terminal");
    ack_terminal(2, 0);

    begin_case("maximum epoch identity has no wrapped successor");
    reset_controller(0, 0); arm_next(64'hffffffffffffffff, first_tick);
    expect_launch(64'hffffffffffffffff, 0, first_tick); finish_pulse(); stop_between(); terminal(1, 1, 0, 1);
    ack_terminal(64'hffffffffffffffff, 0);
    arm_request(1, tick_i + 1, 1600, 3); arm_request(0, tick_i + 1, 1600, 2);

    begin_case("terminal acknowledgment waits for capture ownership");
    reset_controller(0, 0); arm_next(1, first_tick); expect_launch(1, 0, first_tick); finish_pulse();
    capture_idle_i = 0; stop_between(); terminal(1, 1, 0, 1);
    ack_terminal(1, 7); check(end_valid_o, "live capture owner blocks receipt retirement");
    capture_idle_i = 1; ack_terminal(1, 0); check(!end_valid_o, "contained capture permits receipt retirement");

    begin_case("normal stop completes the emitted pulse");
    reset_controller(0, 0); arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    stop_i = 1; finish_pulse(); stop_i = 0;
    terminal(1, 1, 0, 1); check(!loss_valid_o && end_tick_o === first_tick + 1, "stop boundary is independent of pulse drain");

    begin_case("CPU reset retains the emitted pulse and timebase");
    reset_controller(0, 0); arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    saved_tick = helper_tick; cpu_reset_i = 1; finish_pulse();
    terminal(1, 1, 0, 1); check(helper_tick > saved_tick && (end_causes_o & 2) != 0, "CPU reset records stop without resetting time");
    cpu_reset_i = 0; cycles(20); check(!active_o && !convst_o, "CPU resume cannot rearm");

    begin_case("STOP on first due edge retains a missing slot");
    reset_controller(0, 0); arm_next(1, first_tick); stop_i = 1;
    tick(); stop_i = 0;
    check(!edge_launch && !convst_o && outcome_valid_o && !outcome_triggered_o && outcome_slot_o === 0 &&
      outcome_tick_o === first_tick && outcome_epoch_o === 1, "decision comparator: due STOP placeholder");
    terminal(1, 0, 1, 1); check(!loss_valid_o && (end_causes_o & 1) != 0, "known missing slot retained");

    begin_case("CPU halt on a due edge retains the grid timestamp");
    reset_controller(0, 0); arm_next(1, first_tick); cpu_halt_i = 1;
    tick(); cpu_halt_i = 0;
    check(!edge_launch && outcome_valid_o && !outcome_triggered_o && outcome_tick_o === first_tick,
          "decision comparator: halt placeholder");
    terminal(1, 0, 1, 1); check((end_causes_o & 4) != 0, "halt cause retained");

    begin_case("no due credit produces exact loss rather than a late pulse");
    reset_controller(0, 0); arm_next(1, first_tick); record_credit_i = 0;
    tick(); record_credit_i = 1;
    check(!edge_launch && !convst_o && !outcome_valid_o, "no reservation means no outcome offer");
    terminal(1, 0, 1, 1);
    check(loss_valid_o && loss_last_known_o && loss_first_o === 0 && loss_last_o === 0 && last_tick_o === first_tick,
          "explicit inclusive lost slot interval");
    cycles(30); check(!convst_o && emitted_o === 0, "restored credit cannot issue catch-up");

    begin_case("busy capture before due suppresses the conversion");
    reset_controller(0, 0); arm_next(1, first_tick); capture_idle_i = 0;
    tick(); capture_idle_i = 1;
    check(!edge_launch && !convst_o && outcome_valid_o && !outcome_triggered_o && outcome_tick_o === first_tick,
          "decision comparator: busy pre-edge capture");
    terminal(1, 0, 1, 1); check((end_causes_o & 'h10) != 0, "capture ownership cause retained");

    begin_case("ordinary busy and credit gaps between slots do not retime the grid");
    reset_controller(0, 0); arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    capture_idle_i = 0; record_credit_i = 0; finish_pulse(); cycles(100);
    check(active_o && scheduled_o === 1, "in-flight gates do not stop between slots");
    capture_idle_i = 1; record_credit_i = 1;
    until_tick(first_tick + 1600); expect_launch(1, 1, first_tick + 1600);
    finish_pulse(); stop_between(); terminal(2, 2, 0, 1);

    begin_case("FIFO high water on due cannot be rescued by later dequeue");
    reset_controller(0, 0); arm_next(1, first_tick); fifo_occupancy_i = 192;
    tick(); fifo_occupancy_i = 191;
    check(!edge_launch && !convst_o, "high-water decision uses the pre-edge occupancy");
    terminal(1, 0, 1, 1); check((end_causes_o & 'h80) != 0, "high-water cause retained");

    begin_case("storage failure between slots stops without inventing another slot");
    reset_controller(0, 0); arm_next(1, first_tick); expect_launch(1, 0, first_tick); finish_pulse();
    storage_available_i = 0; tick(); storage_available_i = 1;
    terminal(1, 1, 0, 1); check((end_causes_o & 'h40) != 0 && !loss_valid_o, "storage fault boundary is explicit");

    begin_case("short downstream stalls preserve outcome and next grid edge");
    reset_controller(0, 0); outcome_ready_i = 0; arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    saved_outcome = {outcome_triggered_o, outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o};
    cycles(37); check(active_o && delivered_o === 0 &&
      {outcome_triggered_o, outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o} === saved_outcome,
      "decision comparator: short stall retention");
    outcome_ready_i = 1; tick();
    until_tick(first_tick + 1600); expect_launch(1, 1, first_tick + 1600);
    finish_pulse(); stop_between(); terminal(2, 2, 0, 1);

    begin_case("handoff exactly at its deadline is accepted");
    reset_controller(0, 0); outcome_ready_i = 0; arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    cycles(79); check(active_o && !end_valid_o && delivered_o === 0, "no early handoff timeout");
    outcome_ready_i = 1; tick(); check(active_o && delivered_o === 1, "inclusive handoff deadline");
    until_tick(first_tick + 1600); expect_launch(1, 1, first_tick + 1600);
    finish_pulse(); stop_between(); terminal(2, 2, 0, 1);

    begin_case("handoff timeout ends the grid but retains the offered owner");
    reset_controller(0, 0); outcome_ready_i = 0; arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    saved_outcome = {outcome_triggered_o, outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o};
    cycles(80); terminal(1, 1, 0, 0);
    check(outcome_valid_o && delivered_o === 0 && end_delivered_o === 0 && (end_causes_o & 'h100) != 0,
          "timed-out notification remains owned");
    saved_tick = end_tick_o; saved_epoch = end_epoch_o;
    arm_request(2, tick_i + 1, 1600, 4);
    ack_terminal(1, 7);
    arm_request(2, tick_i + 1, 1600, 4);
    outcome_ready_i = 1; tick();
    check(!outcome_valid_o && delivered_o === 1 && end_delivered_o === 0 &&
      end_tick_o === saved_tick && end_epoch_o === saved_epoch, "late delivery cannot rewrite sealed totals");
    check({outcome_triggered_o, outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o} === saved_outcome,
          "released payload stays identifiable");
    ack_terminal(1, 0);

    begin_case("qualification loss stops without CPU or consumer service");
    reset_controller(0, 0); outcome_ready_i = 0; arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    qualified_i = 0; finish_pulse(); terminal(1, 1, 0, 0);
    check(first_fault_o === 8 && latest_fault_o === 'h100 && outcome_valid_o && (sticky_causes_o & 'h108) == 'h108,
          "fault evidence survives stalled consumer");

    begin_case("independent isolation is explicit uncertainty");
    reset_controller(0, 0); arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    isolate_i = 1; tick();
    check(!convst_o && isolate_request_o, "isolation suppresses the pin request");
    isolate_i = 0; terminal(1, 1, 0, 0);
    check((end_causes_o & 'h800) != 0, "isolation cause cannot become clean closure");

    begin_case("tick jump across due never produces a catch-up conversion");
    reset_controller(1, 100); arm_next(1, first_tick); expect_launch(1, 0, first_tick); finish_pulse();
    manual_tick = first_tick + 1601; tick();
    check(!edge_launch && !convst_o, "grid comparator: no late catch-up");
    terminal(1, 1, 0, 0);
    check((end_causes_o & 'h200) != 0 && loss_valid_o && !loss_last_known_o && loss_first_o === 1,
          "missed grid retains an uncertain loss suffix");

    begin_case("backward tick change cannot replay an earlier slot");
    reset_controller(1, 1000); arm_next(1, first_tick); expect_launch(1, 0, first_tick); finish_pulse();
    manual_tick = 900; tick();
    check(!edge_launch && !convst_o, "backward time cannot trigger");
    terminal(1, 1, 0, 0); check((end_causes_o & 'h200) != 0, "backward time is visible");

    begin_case("repeated tick cannot silently pause the sampling grid");
    reset_controller(1, 500); arm_next(1, first_tick); expect_launch(1, 0, first_tick); finish_pulse();
    manual_advance = 0; tick(); tick();
    check(!edge_launch && !convst_o, "repeated time cannot trigger");
    manual_advance = 1; terminal(1, 1, 0, 0);
    check((end_causes_o & 'h200) != 0, "frozen timebase is observable");

    begin_case("supervisor fault cannot disappear when its input pulse ends");
    reset_controller(0, 0); arm_next(1, first_tick); expect_launch(1, 0, first_tick);
    supervisor_fault_i = 1; tick(); supervisor_fault_i = 0;
    terminal(1, 1, 0, 0);
    check(isolate_request_o && (end_causes_o & 'h800) != 0 && first_fault_o != 0,
          "supervisor uncertainty stays retained");

    begin_case("future comparison crosses bit63 without signed ordering");
    reset_controller(1, 64'h7ffffffffffffffe); arm_next(1, first_tick);
    check(first_tick === 64'h8000000000000000, "test crosses signed boundary");
    expect_launch(1, 0, first_tick); finish_pulse();
    until_tick(first_tick + 1600); expect_launch(1, 1, first_tick + 1600);
    finish_pulse(); stop_between(); terminal(2, 2, 0, 1);

    begin_case("last frame-safe tick is accepted without next-due wrap");
    reset_controller(1, 64'hffffffffffffffff - 1122); arm_next(1, first_tick);
    check(first_tick === 64'hffffffffffffffff - 1120, "last frame-safe first tick");
    expect_launch(1, 0, first_tick); finish_pulse(); terminal(1, 1, 0, 1);
    check((end_causes_o & 'h400) != 0 && !loss_valid_o && last_tick_o === first_tick,
          "unrepresentable successor terminates before wrap");

    begin_case("insufficient frame horizon rejects ARM");
    reset_controller(1, 64'hffffffffffffffff - 1121);
    arm_request(1, tick_i + 1, 1600, 7);
    check(!active_o && scheduled_o === 0, "future tick alone cannot waive frame horizon");

    begin_case("seeded downstream stalls preserve every accepted grid edge");
    reset_controller(0, 0); outcome_ready_i = 0; arm_next(1, first_tick);
    generated = 0; stall_left = 0;
    /* eighty frames use independent bounded consumer delays, not DUT-generated expected times. */
    for (int slot = 0; slot < 80; slot++) begin
      next_tick = first_tick + 64'(slot) * 1600;
      until_tick(next_tick);
      outcome_ready_i = 0;
      expect_launch(1, 64'(slot), next_tick);
      generated++; random_cases++;
      value = random_word(); stall_left = int'(value % 65);
      /* local stalls cannot change the independently computed next scheduled marker. */
      repeat (stall_left) begin
        tick(); check(!edge_launch && active_o, "bounded stall cannot trigger or end early");
      end
      outcome_ready_i = 1; tick();
      /* restore capture readiness before the next slot after arbitrary in-flight occupancy. */
      capture_idle_i = 0; record_credit_i = 0;
      max_wait = 8;
      cycles(max_wait);
      capture_idle_i = 1; record_credit_i = 1;
      check(scheduled_o === 64'(generated) && emitted_o === 64'(generated) && missing_o === 0,
            "random grid accounting");
    end
    stop_between(); terminal(80, 80, 0, 1);
    check(delivered_o === 80 && end_delivered_o === 80 && !loss_valid_o, "random sequence retains all decisions");
    check(cases >= 30 && random_cases == 80, "coverage guard");
    $display("PASS acquisition-scheduler seed=%0d checks=%0d cases=%0d random=%0d", seed, checks, cases, random_cases);
    $finish;
  end
endmodule

/* verify the connected control and scheduler through public MMIO and capture interfaces. */
module drg5_acquisition_timing_tb;
  localparam integer CONFIG_LIMIT = 4096, CLOSE_LIMIT = 512;
  logic clk_i, system_reset_i, cpu_reset_i, cpu_halt_i;
  logic req_valid_i;
  logic req_ready_o;
  logic req_write_i;
  logic [11:0] req_addr_i;
  logic [31:0] req_wdata_i, req_tag_i;
  logic [3:0] req_wstrb_i;
  logic rsp_valid_o;
  logic rsp_ready_i;
  logic [31:0] rsp_rdata_o, rsp_tag_o;
  logic rsp_error_o;
  logic session_verified_i;
  logic [127:0] session_id_i;
  logic qualification_valid_i;
  logic [63:0] qualification_config_id_i;
  logic [255:0] qualification_digest_i;
  logic [63:0] qualification_timebase_id_i;
  logic [31:0] qualification_manifest_length_i;
  logic physical_ready_i, metadata_archived_i, ownership_clear_i, pins_idle_i;
  logic [6:0] free_blocks_i;
  logic emergency_stop_i;
  logic [31:0] fault_i;
  logic supervisor_fault_i;
  logic backend_valid_i, backend_ok_i;
  logic [1:0] backend_phase_i;
  logic [63:0] backend_command_id_i;
  logic service_valid_o, service_cancel_o;
  logic [1:0] service_phase_o;
  logic [63:0] service_command_id_o;
  logic [767:0] service_config_o;
  logic close_valid_i;
  logic [63:0] close_epoch_i;
  logic [1:0] close_result_i;
  logic close_request_o;
  logic [63:0] epoch_o, first_tick_o;
  logic [63:0] tick_o, arm_commit_epoch_o, arm_commit_first_tick_o;
  logic arm_commit_o;
  logic arm_o, run_permit_o, stop_o, isolate_o, irq_o;
  logic [3:0] state_o;
  logic terminal_sealed_o;
  logic capture_idle_i, record_credit_i, storage_available_i;
  logic [8:0] fifo_occupancy_i;
  logic scheduler_active_o, pulse_busy_o, convst_o, launch_o;
  logic [63:0] launch_epoch_o, launch_slot_o, launch_tick_o;
  logic outcome_valid_o;
  logic outcome_ready_i;
  logic outcome_triggered_o;
  logic [63:0] outcome_epoch_o, outcome_slot_o, outcome_tick_o;
  logic [31:0] outcome_causes_o;
  logic end_valid_o;
  logic end_ack_i;
  logic [63:0] end_ack_epoch_i;
  logic [31:0] end_ack_result_o;
  logic [63:0] end_epoch_o, end_tick_o, end_delivered_o;
  logic [63:0] scheduled_o, emitted_o, missing_o, delivered_o;
  logic last_slot_known_o;
  logic [63:0] last_slot_o, last_tick_o;
  logic exact_o, loss_valid_o, loss_last_known_o;
  logic [63:0] loss_first_o, loss_last_o;
  logic [31:0] end_causes_o;
  logic scheduler_fault_o, scheduler_isolate_o;
  logic [31:0] scheduler_sticky_o, scheduler_first_fault_o, scheduler_latest_fault_o;
  logic [63:0] scheduler_first_fault_tick_o, scheduler_latest_fault_tick_o;
  integer checks = 0, cases = 0, edges = 0, launches = 0, bindings = 0;
  logic [31:0] next_tag = 1;
  logic [63:0] monitor_origin = 0, monitor_epoch = 0, monitor_slot = 0;
  logic monitor_valid = 0;
  string test_name = "reset", wave_path;
  bit mutate_binding = 0, mutate_closure = 0, changed_binding = 0, changed_closure = 0;
  drg5_acquisition_timing #(.CONFIG_CYCLES(CONFIG_LIMIT), .CANCEL_CYCLES(16),
    .CLOSE_CYCLES(CLOSE_LIMIT)) dut (.*);

  /* one process alone generates the fixed acquisition clock. */
  initial begin
    clk_i = 0;
    forever #6.25 clk_i = ~clk_i;
  end

  /* a global deadline also catches a broken clock or unexpectedly stalled helper. */
  initial begin
    #2000000;
    $fatal(1, "global timeout case=%s", test_name);
  end

  /* an unknown condition fails rather than being coerced into a passing boolean. */
  task automatic check(input logic condition, input string detail);
    checks++;
    if (condition !== 1'b1) $fatal(1, "case=%s edge=%0d: %s", test_name, edges, detail);
  endtask

  /* sample the driving event before NBA updates and its resulting pulse afterward. */
  task automatic step();
    logic [63:0] before_tick, event_tick, event_epoch, event_slot, origin, observed;
    logic binding, launch, prior_pulse;
    @(posedge clk_i);
    before_tick = tick_o; binding = arm_commit_o; launch = launch_o; prior_pulse = convst_o;
    event_tick = launch_tick_o; event_epoch = launch_epoch_o; event_slot = launch_slot_o;
    origin = arm_commit_first_tick_o;
    #1;
    edges++;
    /* reset invalidates the reference epoch but does not invent a binding or launch. */
    if (system_reset_i) begin
      monitor_valid = 0;
      check(arm_commit_o === 0 && launch_o === 0 && convst_o === 0, "reset has no pulse or accepted binding");
    /* the reference uses accepted identities and literal1600-tick arithmetic only. */
    end else begin
      check(tick_o === before_tick + 1, "shared timebase advances without CPU enable");
      check(!$isunknown({terminal_sealed_o, req_ready_o, rsp_valid_o, rsp_rdata_o, rsp_tag_o, rsp_error_o, service_valid_o, service_cancel_o, service_phase_o, service_command_id_o, service_config_o, close_request_o, epoch_o, first_tick_o, tick_o, arm_commit_epoch_o, arm_commit_first_tick_o, arm_commit_o, arm_o, run_permit_o, stop_o, isolate_o, irq_o, state_o, scheduler_active_o, pulse_busy_o, convst_o, launch_o, launch_epoch_o, launch_slot_o, launch_tick_o, outcome_valid_o, outcome_triggered_o, outcome_epoch_o, outcome_slot_o, outcome_tick_o, outcome_causes_o, end_valid_o, end_ack_result_o, end_epoch_o, end_tick_o, end_delivered_o, scheduled_o, emitted_o, missing_o, delivered_o, last_slot_known_o, last_slot_o, last_tick_o, exact_o, loss_valid_o, loss_last_known_o, loss_first_o, loss_last_o, end_causes_o, scheduler_fault_o, scheduler_isolate_o, scheduler_sticky_o, scheduler_first_fault_o, scheduler_latest_fault_o, scheduler_first_fault_tick_o, scheduler_latest_fault_tick_o}), "unknown integration output");
      /* ARM commits its future origin before any corresponding conversion exists. */
      if (binding) begin
        observed = origin;
        /* corrupt the sampled origin before its ordinary comparator. */
        if (mutate_binding && !changed_binding) begin
          observed ^= 1; changed_binding = 1;
        end
        check(observed === before_tick + 1, "binding comparator: future tick A+1");
        monitor_origin = origin; monitor_epoch = epoch_o; monitor_slot = 0; monitor_valid = 1;
        bindings++;
        check(!convst_o && !launch, "ARM acceptance is not a conversion edge");
      end
      /* a launch describes the same edge that raises the registered CONVST output. */
      if (launch) begin
        check(monitor_valid && !prior_pulse && convst_o, "on-time launch raises CONVST once");
        check(event_tick === before_tick && event_tick === monitor_origin + monitor_slot * 64'd1600,
              "grid comparator: no late or compressed launch");
        check(event_slot === monitor_slot && event_epoch === monitor_epoch, "launch identity matches accepted epoch");
        monitor_slot++; launches++;
      end
      /* no output-register rise may exist without the matching pre-edge launch event. */
      if (!prior_pulse && convst_o) check(launch, "CONVST rise has a matching timestamped event");
    end
    @(negedge clk_i);
  endtask

  /* finite repeats continue acquisition even while the CPU performs no service. */
  task automatic cycles(input integer count);
    repeat (count) step();
  endtask

  /* a whole-system reset is used only as an isolated start for independent scenarios. */
  task automatic reset_all();
    system_reset_i = 1;
    cpu_reset_i = 0;
    cpu_halt_i = 0;
    req_valid_i = 0;
    req_write_i = 0;
    req_addr_i = 0;
    req_wdata_i = 0;
    req_tag_i = 0;
    req_wstrb_i = 0;
    rsp_ready_i = 0;
    session_verified_i = 0;
    session_id_i = 0;
    qualification_valid_i = 0;
    qualification_config_id_i = 0;
    qualification_digest_i = 0;
    qualification_timebase_id_i = 0;
    qualification_manifest_length_i = 0;
    physical_ready_i = 0;
    metadata_archived_i = 0;
    ownership_clear_i = 0;
    pins_idle_i = 0;
    free_blocks_i = 0;
    emergency_stop_i = 0;
    fault_i = 0;
    supervisor_fault_i = 0;
    backend_valid_i = 0;
    backend_ok_i = 0;
    backend_phase_i = 0;
    backend_command_id_i = 0;
    close_valid_i = 0;
    close_epoch_i = 0;
    close_result_i = 0;
    capture_idle_i = 0;
    record_credit_i = 0;
    storage_available_i = 0;
    fifo_occupancy_i = 0;
    outcome_ready_i = 0;
    end_ack_i = 0;
    end_ack_epoch_i = 0;
    session_id_i = 128'h112233445566778899aabbccddeeff00;
    qualification_config_id_i = 1; qualification_digest_i = 256'h12345678;
    qualification_timebase_id_i = 1; qualification_manifest_length_i = 128;
    session_verified_i = 1; qualification_valid_i = 1; physical_ready_i = 1;
    metadata_archived_i = 1; ownership_clear_i = 1; pins_idle_i = 1;
    free_blocks_i = 64; capture_idle_i = 1; record_credit_i = 1; storage_available_i = 1;
    backend_ok_i = 1; outcome_ready_i = 1;
    cycles(2); system_reset_i = 0; step();
    check(state_o === 0 && !scheduler_active_o, "reset starts unqualified and disarmed");
  endtask

  /* names identify the failed obligation without requiring waveform inspection. */
  task automatic begin_case(input string name);
    test_name = name; cases++;
    $display("TEST %s", name);
  endtask

  /* one bus transfer has a bounded response independent of slow operation completion. */
  task automatic access(input bit writing, input logic [11:0] address,
                        input logic [31:0] data, output logic [31:0] result);
    logic [31:0] tag;
    integer wait_count;
    tag = next_tag; next_tag++;
    req_valid_i = 1; req_write_i = writing; req_addr_i = address; req_wdata_i = data;
    req_wstrb_i = writing ? 15 : 0; req_tag_i = tag; rsp_ready_i = 0;
    #1;
    wait_count = 0;
    /* transport waits cannot depend on a multi-second operation. */
    while (req_ready_o !== 1'b1 && wait_count < 4) begin
      step(); wait_count++;
    end
    check(req_ready_o === 1, "MMIO request deadline");
    step(); req_valid_i = 0;
    check(rsp_valid_o === 1 && rsp_error_o === 0 && rsp_tag_o === tag, "MMIO response ownership");
    result = rsp_rdata_o;
    rsp_ready_i = 1; step(); rsp_ready_i = 0;
  endtask

  /* exact numeric outcomes are independent of the DUT's localparam declarations. */
  task automatic wr(input logic [11:0] address, input logic [31:0] data, expected);
    logic [31:0] result;
    access(1, address, data, result);
    check(result === expected, $sformatf("MMIO write %03x got%0d expected%0d", address, result, expected));
  endtask

  /* reads do not acknowledge the retained source being observed. */
  task automatic rd(input logic [11:0] address, output logic [31:0] result);
    access(0, address, 0, result);
  endtask

  /* command and service-object identities occupy separate staging words. */
  task automatic command(input logic [63:0] identity, input logic [31:0] opcode, expected);
    wr('h010, identity[31:0], 0); wr('h014, identity[63:32], 0);
    wr('h020, opcode, expected);
  endtask

  /* service acknowledgments match complete identities rather than IRQ state. */
  task automatic object(input logic [63:0] identity);
    wr('h018, identity[31:0], 0); wr('h01c, identity[63:32], 0);
  endtask

  /* write the exact supported descriptor using literal host packing. */
  task automatic descriptor();
    logic [31:0] value;
    /* initialize every field, including reserved words. */
    for (integer n = 0; n < 24; n++) begin
      value = 0;
      case (n)
        0, 2, 20: value = 1;
        3: value = 1600;
        4: value = 80000000;
        5: value = 'h33;
        6: value = 'hff;
        8: value = 'h12345678;
        16: value = 'hddeeff00;
        17: value = 'h99aabbcc;
        18: value = 'h55667788;
        19: value = 'h11223344;
        22: value = 128;
        default: value = 0;
      endcase
      wr(12'('h100 + 4*n), value, 0);
    end
  endtask

  /* backend responses are modeled one-cycle attestations with explicit phase and identity. */
  task automatic service_reply(input logic [63:0] identity, input logic [1:0] phase, input bit good);
    backend_command_id_i = identity; backend_phase_i = phase; backend_ok_i = good; backend_valid_i = 1;
    step(); backend_valid_i = 0;
  endtask

  /* full startup and verification precede READY; success never arms the scheduler. */
  task automatic configure();
    descriptor(); command(1, 1, 1);
    check(state_o === 1 && !scheduler_active_o, "startup owns no recording epoch");
    service_reply(1, 0, 1); service_reply(1, 1, 1);
    check(state_o === 3 && !scheduler_active_o, "configuration publishes ready only");
    object(1); wr('h024, 1, 0);
  endtask

  /* retained snapshots expose the controller terminal independently of scheduler receipts. */
  task automatic terminal(input logic [31:0] expected);
    logic [31:0] value, id_low, id_high;
    wr('h030, 1, 1); rd('h448, value);
    /* corrupt the observation before the ordinary terminal comparator. */
    if (mutate_closure && !changed_closure) begin
      value ^= 1; changed_closure = 1;
    end
    check(value === expected, "closure comparator: terminal outcome");
    rd('h360, id_low); rd('h364, id_high); object({id_high,id_low}); wr('h048, 1, 0);
  endtask

  /* closure replies cannot bypass scheduler pulse and notification ownership. */
  task automatic close_reply(input logic [63:0] identity, input logic [1:0] result);
    close_valid_i = 1; close_epoch_i = identity; close_result_i = result;
    step(); close_valid_i = 0;
  endtask

  /* a bounded join waits for the scheduler's sealed receipt rather than assuming CPU progress. */
  task automatic wait_end();
    integer waited;
    waited = 0;
    /* a scheduler receipt must become visible within its handoff timeout plus pulse tail. */
    while (!end_valid_o && waited < 100) begin
      step(); waited++;
    end
    check(end_valid_o === 1, "scheduler end receipt deadline");
  endtask

  /* scheduler acknowledgment names its epoch and leaves the control terminal alone. */
  task automatic ack_end(input logic [63:0] epoch, input logic [31:0] expected);
    end_ack_i = 1; end_ack_epoch_i = epoch;
    #1; check(end_ack_result_o === expected, "scheduler end acknowledgment outcome");
    step(); end_ack_i = 0;
  endtask

  /* scenarios exercise the actual connected state machines, with modeled backend attestations. */
  initial begin : campaign
    logic [31:0] value, held_tag, held_data;
    logic [63:0] held_origin, held_slot, held_tick, before_reset_tick;
    integer before_launches, before_bindings;
    /* trace generation is explicit and omitted for negative controls. */
    if ($value$plusargs("wave=%s", wave_path)) begin
      $dumpfile(wave_path); $dumpvars(0, drg5_acquisition_timing_tb);
    end
    mutate_binding = $test$plusargs("mutate_binding");
    mutate_closure = $test$plusargs("mutate_closure");
    @(negedge clk_i);

    begin_case("MMIO response backpressure cannot move the grid");
    reset_all(); configure(); object(1);
    wr('h010, 2, 0); wr('h014, 0, 0);
    before_launches = launches; before_bindings = bindings;
    req_valid_i = 1; req_write_i = 1; req_addr_i = 'h020; req_wdata_i = 2;
    req_wstrb_i = 15; req_tag_i = 32'hfeed1234; rsp_ready_i = 0;
    step(); req_valid_i = 0;
    check(rsp_valid_o && rsp_rdata_o === 1 && bindings == before_bindings+1, "ARM admission returns before a conversion");
    held_tag = rsp_tag_o; held_data = rsp_rdata_o; held_origin = first_tick_o;
    /* the CPU consumes no response or interrupt while four fixed-grid conversions occur. */
    repeat (5001) begin
      step();
      check(rsp_valid_o && rsp_tag_o === held_tag && rsp_rdata_o === held_data, "CPU response remains immutable");
      check(first_tick_o === held_origin && state_o === 4, "CPU stall preserves active epoch");
    end
    check(launches == before_launches+4 && scheduled_o === 4 && emitted_o === 4, "four on-time pulses during CPU stall");
    rsp_ready_i = 1; step(); rsp_ready_i = 0;
    /* temporary in-flight ownership between slots is not a request to retime the next slot. */
    capture_idle_i = 0; record_credit_i = 0; cycles(20);
    check(state_o === 4 && scheduler_active_o, "off-due busy and credit absence do not stop");
    capture_idle_i = 1; record_credit_i = 1;
    /* ordinary CPU reads continue through the same fixed acquisition clock. */
    repeat (40) begin
      rd('h008, value); check(value === 4, "CPU reads observe the same running epoch");
    end
    cycles(1600);
    check(launches >= before_launches+5, "CPU traffic preserves future grid");
    emergency_stop_i = 1; step(); emergency_stop_i = 0; wait_end();
    close_reply(1, 0); check(state_o === 6, "clean explicit stop reaches stopped"); terminal(12);

    begin_case("short downstream stall preserves retained decision and next slot");
    reset_all(); configure(); object(1); outcome_ready_i = 0;
    command(2, 2, 1);
    check(outcome_valid_o && outcome_triggered_o, "first trigger has a retained decision");
    held_slot = outcome_slot_o; held_tick = outcome_tick_o;
    /* the pending tuple does not follow live time while its consumer is stalled. */
    repeat (40) begin
      step();
      check(outcome_valid_o && outcome_slot_o === held_slot && outcome_tick_o === held_tick && outcome_triggered_o,
            "short stall preserves outcome identity");
    end
    outcome_ready_i = 1; step();
    check(delivered_o === 1 && state_o === 4, "bounded handoff keeps epoch running");
    cycles(1600); check(emitted_o === 2, "short stall does not stretch cadence");

    begin_case("STOP on first due edge creates missing slot zero");
    reset_all(); configure(); object(1); wr('h010, 2, 0); wr('h014, 0, 0);
    outcome_ready_i = 0;
    req_valid_i = 1; req_write_i = 1; req_addr_i = 'h020; req_wdata_i = 2;
    req_wstrb_i = 15; req_tag_i = 99;
    step(); req_valid_i = 0; emergency_stop_i = 1;
    step();
    check(!convst_o && scheduled_o === 1 && emitted_o === 0 && missing_o === 1,
          "first due STOP suppresses conversion but accounts slot");
    check(outcome_valid_o && !outcome_triggered_o && outcome_slot_o === 0 && outcome_tick_o === first_tick_o,
          "missing slot retains its intended marker");
    emergency_stop_i = 0; rsp_ready_i = 1; outcome_ready_i = 1; step(); rsp_ready_i = 0;
    wait_end(); close_reply(1, 0); check(state_o === 6, "known missing first slot may close with backend accounting");

    begin_case("early scheduler receipt cannot bypass controller terminal sealing");
    reset_all(); configure(); object(1); wr('h010, 2, 0); wr('h014, 0, 0);
    req_valid_i = 1; req_write_i = 1; req_addr_i = 'h020; req_wdata_i = 2;
    req_wstrb_i = 15; req_tag_i = 100;
    step(); req_valid_i = 0; record_credit_i = 0;
    step();
    check(end_valid_o && !outcome_valid_o && state_o === 4 && !close_request_o && !terminal_sealed_o,
          "scheduler seals one edge before registered fault reaches control");
    ack_end(1, 7);
    check(end_valid_o && state_o === 5, "early end ACK cannot erase the only producer receipt");
    record_credit_i = 1; rsp_ready_i = 1; step(); rsp_ready_i = 0;
    close_reply(1, 0);
    check(terminal_sealed_o, "controller exposes positive terminal sealing authority");
    terminal(13); ack_end(1, 0);

    begin_case("ordinary STOP preserves the complete eight-tick pulse");
    reset_all(); configure(); object(1); command(2, 2, 1);
    check(convst_o, "first CONVST pulse has begun");
    emergency_stop_i = 1;
    /* seven further edges remain high; the eighth ends the emitted legal pulse. */
    repeat (7) begin
      step(); check(convst_o === 1, "STOP does not shorten CONVST");
    end
    step(); check(convst_o === 0 && scheduled_o === 1, "CONVST falls exactly eight ticks after marker");
    emergency_stop_i = 0; wait_end(); close_reply(1, 0); terminal(12);

    begin_case("long stall retains owner and cannot downgrade uncertainty");
    reset_all(); configure(); object(1); outcome_ready_i = 0; command(2, 2, 1);
    cycles(85);
    check(!scheduler_active_o && end_valid_o && outcome_valid_o && !exact_o && state_o === 5,
          "handoff timeout stops without withdrawing the old outcome");
    check(scheduled_o === 1 && end_delivered_o === 0 && delivered_o === 0,
          "timeout seals one scheduled slot with no delivered decisions");
    close_reply(1, 0); check(state_o === 5, "backend cannot close pending notification ownership");
    ack_end(1, 7);
    outcome_ready_i = 1; step();
    check(delivered_o === 1 && end_delivered_o === 0 && end_valid_o,
          "late handoff changes live count but not sealed receipt");
    capture_idle_i = 0; close_reply(1, 0); check(state_o === 5, "backend cannot close active capture owner");
    capture_idle_i = 1; close_reply(1, 0);
    check(state_o === 7, "known uncertainty forces fault terminal despite backend clean claim");
    terminal(14);
    object(2); wr('h024, 1, 0);
    object(1); wr('h038, 1, 0);
    command(3, 3, 7);
    check(end_valid_o, "control terminal acknowledgment leaves scheduler receipt owned");
    ack_end(1, 0);
    check(!end_valid_o, "explicit scheduler receipt acknowledgment retires its owner");
    command(4, 3, 1);
    service_reply(4, 0, 1); service_reply(4, 1, 1);
    check(state_o === 3 && !scheduler_active_o, "recovery succeeds only after both closure owners resolve");

    begin_case("scheduler acknowledgment cannot replace control terminal acknowledgment");
    reset_all(); configure(); object(1); command(2, 2, 1);
    emergency_stop_i = 1; step(); emergency_stop_i = 0; wait_end(); close_reply(1, 0);
    ack_end(1, 0);
    object(2); wr('h024, 1, 0);
    object(1); wr('h02c, 1, 0);
    command(3, 3, 7);
    terminal(12);
    object(1); wr('h038, 1, 0);
    command(4, 3, 1); service_reply(4, 0, 1); service_reply(4, 1, 1);
    object(4); wr('h024, 1, 0); object(1); wr('h034, 1, 0);
    object(1); command(5, 2, 1);
    check(epoch_o === 2 && scheduler_active_o && emitted_o === 1, "restart creates new epoch and slot zero");

    begin_case("CPU reset stops capture while retaining the free-running timebase");
    reset_all(); configure(); object(1); command(2, 2, 1);
    before_reset_tick = tick_o; cpu_reset_i = 1; cycles(12); cpu_reset_i = 0;
    check(tick_o === before_reset_tick + 12 && epoch_o === 1 && scheduled_o === 1 && !scheduler_active_o,
          "CPU reset retains time and scheduled history");
    wait_end(); close_reply(1, 0); terminal(13);
    check(state_o === 6 && !scheduler_active_o, "CPU resume cannot restart capture");

    begin_case("failed startup recovery does not strand idle isolation");
    reset_all(); descriptor(); command(1, 1, 1);
    service_reply(1, 0, 0);
    check(state_o === 7 && isolate_o && !end_valid_o, "startup failure isolates without inventing an epoch");
    object(1); wr('h024, 1, 0); command(2, 3, 1);
    check(!isolate_o && state_o === 1, "positive recovery clears service-only isolation");
    service_reply(2, 0, 1); service_reply(2, 1, 1);
    object(2); wr('h024, 1, 0); object(1); wr('h034, 1, 0);
    object(1); command(3, 2, 1);
    check(state_o === 4 && scheduler_active_o && emitted_o === 1, "recovered idle scheduler can arm");

    begin_case("same-edge stale response cannot orphan an ARM binding");
    reset_all(); configure(); object(1); wr('h010, 2, 0); wr('h014, 0, 0);
    before_bindings = bindings;
    backend_valid_i = 1; backend_command_id_i = 999; backend_phase_i = 1;
    wr('h020, 2, 7); backend_valid_i = 0;
    check(bindings == before_bindings && epoch_o === 0 && !scheduler_active_o && !convst_o,
          "stale response vetoes ARM before either owner accepts");

    check(cases == 10 && launches >= 10 && bindings >= 8, "scenario coverage is nonvacuous");
    $display("PASS acquisition-timing cases=%0d checks=%0d bindings=%0d launches=%0d", cases, checks, bindings, launches);
    $finish;
  end
endmodule

/* exercise control transactions using independent intent, bounded waits and retained observations. */
module drg5_acquisition_control_tb #(parameter logic [63:0] TEST_COUNTER_LIMIT = 64'hffffffffffffffff);
  localparam integer CONFIG_LIMIT = 2048, CANCEL_LIMIT = 16, CLOSE_LIMIT = 128;
  logic clk_i, system_reset_i = 1, cpu_reset_i = 0, cpu_halt_i = 0;
  logic req_valid_i = 0, req_ready_o, req_write_i = 0;
  logic [11:0] req_addr_i = 0;
  logic [31:0] req_wdata_i = 0, req_tag_i = 0;
  logic [3:0] req_wstrb_i = 0;
  logic rsp_valid_o, rsp_ready_i = 0, rsp_error_o;
  logic [31:0] rsp_rdata_o, rsp_tag_o;
  logic session_verified_i = 0;
  logic [127:0] session_id_i = 128'h112233445566778899aabbccddeeff00;
  logic qualification_valid_i = 0;
  logic [63:0] qualification_config_id_i = 1, qualification_timebase_id_i = 1;
  logic [31:0] qualification_manifest_length_i = 128;
  logic [255:0] qualification_digest_i = 256'h12345678;
  logic physical_ready_i = 0, metadata_archived_i = 0, ownership_clear_i = 1, pins_idle_i = 1;
  logic [6:0] free_blocks_i = 64;
  logic emergency_stop_i = 0;
  logic [31:0] fault_i = 0;
  logic supervisor_fault_i = 0;
  logic backend_valid_i = 0, backend_ok_i = 1;
  logic [1:0] backend_phase_i = 0;
  logic [63:0] backend_command_id_i = 0;
  logic service_valid_o, service_cancel_o;
  logic [1:0] service_phase_o;
  logic [63:0] service_command_id_o;
  logic [767:0] service_config_o;
  logic close_valid_i = 0;
  logic [63:0] close_epoch_i = 0;
  logic [1:0] close_result_i = 0;
  logic close_request_o;
  logic [63:0] epoch_o, first_tick_o;
  logic arm_o, run_permit_o, stop_o, isolate_o, irq_o;
  logic [3:0] state_o;
  int unsigned seed = 1, random_state = 1, checks = 0, cases = 0, random_cases = 0;
  int unsigned edges = 0, tag_next = 1, accepted_edge = 0;
  string test_name = "initialization", wave_path;
  bit mutation_response = 0, mutation_snapshot = 0, mutation_stop = 0, mutation_completion = 0;
  bit mutation_unknown = 0, fault_once_on_access = 0;
  bit applied_response = 0, applied_snapshot = 0, applied_stop = 0, applied_completion = 0;

  drg5_acquisition_control #(.CONFIG_CYCLES(CONFIG_LIMIT), .CANCEL_CYCLES(CANCEL_LIMIT),
                            .CLOSE_CYCLES(CLOSE_LIMIT), .COUNTER_LIMIT(TEST_COUNTER_LIMIT)) dut (.*);

  /* this process is the sole clock source; stimulus changes only while the clock is low. */
  initial begin
    clk_i = 0;
    /* no other process writes the clock. */
    forever #5 clk_i = ~clk_i;
  end

  /* one global deadline bounds every test even if an expected transition never arrives. */
  initial begin
    #20000000;
    $fatal(1, "global timeout case=%s edges=%0d", test_name, edges);
  end

  /* four-state predicates reject unknowns instead of coercing them to success. */
  task automatic check(input logic condition, input string detail);
    checks++;
    /* report the seed and named case so every failure can be replayed directly. */
    if (condition !== 1'b1) $fatal(1, "case=%s seed=%0d edge=%0d: %s", test_name, seed, edges, detail);
  endtask

  /* explicit xorshift arithmetic reproduces random vectors across both simulators. */
  function automatic logic [31:0] random_word();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction

  /* sample after nonblocking updates; no driver changes a DUT input on a rising edge. */
  task automatic tick();
    @(posedge clk_i);
    #1;
    edges++;
    check(!$isunknown({req_ready_o, rsp_valid_o, rsp_error_o, rsp_rdata_o, rsp_tag_o,
                      service_valid_o, service_cancel_o, service_phase_o, service_command_id_o,
                      service_config_o, close_request_o, epoch_o, first_tick_o,
                      arm_o, run_permit_o, stop_o, isolate_o, irq_o, state_o}), "unknown DUT output");
    @(negedge clk_i);
  endtask

  /* idle cycles remain bounded by the caller's finite repeat count. */
  task automatic cycles(input int count);
    /* consume complete low-to-low clock intervals without changing inputs. */
    repeat (count) tick();
  endtask

  /* each case reports its name before any activity that could fail. */
  task automatic begin_case(input string name);
    test_name = name;
    cases++;
    $display("TEST %s", name);
  endtask

  /* a reset starts a new isolated controller lifetime, never a CPU-only reset. */
  task automatic reset_controller();
    system_reset_i = 1;
    req_valid_i = 0; rsp_ready_i = 0;
    cpu_reset_i = 0; cpu_halt_i = 0; emergency_stop_i = 0;
    fault_i = 0; supervisor_fault_i = 0; backend_valid_i = 0; close_valid_i = 0;
    backend_ok_i = 1; backend_phase_i = 0; backend_command_id_i = 0;
    qualification_valid_i = 1; session_verified_i = 1;
    qualification_config_id_i = 1; qualification_digest_i = 256'h12345678;
    physical_ready_i = 1; metadata_archived_i = 1; ownership_clear_i = 1; pins_idle_i = 1;
    free_blocks_i = 64;
    cycles(2);
    system_reset_i = 0;
    tick();
    check(state_o === 0 && !run_permit_o && !service_valid_o && epoch_o === 0, "isolated reset state");
  endtask

  /* every MMIO beat owns one tag and receives its registered response within four cycles. */
  task automatic access(input bit write_access, input logic [11:0] address,
                        input logic [31:0] data, input logic [3:0] strobes,
                        input int held_cycles, output logic [31:0] result, output logic error);
    logic [31:0] tag, observed;
    int waited;
    tag = tag_next++;
    req_valid_i = 1; req_write_i = write_access; req_addr_i = address;
    req_wdata_i = data; req_wstrb_i = strobes; req_tag_i = tag; rsp_ready_i = 0;
    waited = 0;
    /* backpressure is legal only while an older bus response still owns the port. */
    while (req_ready_o !== 1'b1 && waited < 4) begin
      tick(); waited++;
    end
    check(req_ready_o === 1'b1, "MMIO request timeout");
    tick();
    req_valid_i = 0;
    accepted_edge = edges;
    /* coincidence tests offer one fault occurrence on the transaction acceptance edge only. */
    if (fault_once_on_access) begin
      fault_i = 0; fault_once_on_access = 0;
    end
    waited = 0;
    /* operation latency cannot extend the MMIO response deadline. */
    while (rsp_valid_o !== 1'b1 && waited < 4) begin
      tick(); waited++;
    end
    check(rsp_valid_o === 1'b1, "MMIO response timeout");
    result = rsp_rdata_o; error = rsp_error_o;
    observed = rsp_tag_o;
    /* a detector corrupts an observation before the ordinary tag comparator. */
    if (mutation_response && !applied_response) begin
      observed ^= 1;
      applied_response = 1;
    end
    check(observed === tag, "response comparator: transaction tag");
    /* stalled responses remain immutable while service and fault logic continue ticking. */
    repeat (held_cycles) begin
      tick();
      check(rsp_valid_o === 1'b1 && rsp_rdata_o === result && rsp_error_o === error &&
            rsp_tag_o === tag && req_ready_o === 1'b0, "response comparator: retained response");
    end
    rsp_ready_i = 1;
    tick();
    rsp_ready_i = 0;
    check(rsp_valid_o === 1'b0, "response comparator: consumed once");
  endtask

  /* ordinary fullword writes require a successful bus response and the documented result. */
  task automatic write_word(input logic [11:0] address, input logic [31:0] data,
                            input logic [31:0] expected);
    logic [31:0] result;
    logic error;
    access(1, address, data, 15, 0, result, error);
    check(error === 0 && result === expected, $sformatf("write %03x result=%08x expected=%08x", address, result, expected));
  endtask

  /* reads never acknowledge events, completions or terminal records. */
  task automatic read_word(input logic [11:0] address, output logic [31:0] result);
    logic error;
    access(0, address, 0, 0, 0, result, error);
    check(error === 0, $sformatf("read %03x bus error", address));
  endtask

  /* split identity writes are staging only; the command doorbell captures them atomically. */
  task automatic command_id(input logic [63:0] identity);
    write_word('h010, identity[31:0], 0);
    write_word('h014, identity[63:32], 0);
  endtask

  /* acknowledgements use their own object identity and cannot consume command sequences. */
  task automatic object_id(input logic [63:0] identity);
    write_word('h018, identity[31:0], 0);
    write_word('h01c, identity[63:32], 0);
  endtask

  /* the profile constant names the whole frozen ADC tuple; individual unsupported fields reject. */
  task automatic shadow_configuration(input logic [63:0] identity);
    logic [31:0] value;
    /* all 24 words are explicitly initialized, including reserved fields and manifest identity. */
    for (int index = 0; index < 24; index++) begin
      value = 0;
      /* independent numeric packing follows the documented host register map. */
      case (index)
        0: value = identity[31:0];
        1: value = identity[63:32];
        2: value = 1;
        3: value = 1600;
        4: value = 80000000;
        5: value = 'h33;
        6: value = 'hff;
        8: value = 'h12345678;
        16: value = 'hddeeff00;
        17: value = 'h99aabbcc;
        18: value = 'h55667788;
        19: value = 'h11223344;
        20: value = 1;
        22: value = 128;
        default: value = 0;
      endcase
      write_word(12'('h100 + index * 4), value, 0);
    end
  endtask

  /* backend attestations are independently scheduled and carry their exact command and phase. */
  task automatic backend_reply(input logic [63:0] identity, input logic [1:0] phase, input bit success);
    backend_command_id_i = identity; backend_phase_i = phase; backend_ok_i = success;
    backend_valid_i = 1;
    tick();
    backend_valid_i = 0;
  endtask

  /* snapshot capture freezes one edge and never changes until its exact identity is released. */
  task automatic snapshot(output logic [63:0] identity);
    logic [31:0] low_word, high_word;
    write_word('h030, 1, 1);
    read_word('h360, low_word);
    read_word('h364, high_word);
    identity = {high_word, low_word};
    check(identity !== 0, "snapshot identity is nonzero");
  endtask

  /* the frozen bank uses a single explicit word index for each host-visible field. */
  task automatic snapshot_word(input int index, input logic [31:0] expected);
    logic [31:0] value;
    read_word(12'('h300 + index * 4), value);
    /* corruption is injected before the same comparator used for every normal snapshot word. */
    if (mutation_snapshot && !applied_snapshot) begin
      value ^= 1;
      applied_snapshot = 1;
    end
    /* four-state negative control confirms that an X cannot satisfy an ordinary comparison. */
    if (mutation_unknown && !applied_snapshot) begin
      value = 'x; applied_snapshot = 1;
    end
    check(value === expected, $sformatf("snapshot comparator: index=%0d value=%08x expected=%08x", index, value, expected));
  endtask

  /* identity-qualified release cannot overwrite or acknowledge a different snapshot. */
  task automatic release_snapshot(input logic [63:0] identity);
    object_id(identity);
    write_word('h048, 1, 0);
  endtask

  /* verify retained completion fields through an ordinary immutable host snapshot. */
  task automatic completion(input logic [63:0] identity, input logic [31:0] expected);
    logic [63:0] snap;
    logic [31:0] flags, result;
    snapshot(snap);
    read_word('h304, flags);
    check(!$isunknown(flags) && flags[2] === 1'b1, "completion valid");
    snapshot_word(12, identity[31:0]); snapshot_word(13, identity[63:32]);
    read_word('h338, result);
    /* a negative control corrupts only the observed completion result. */
    if (mutation_completion && !applied_completion) begin
      result ^= 1;
      applied_completion = 1;
    end
    check(result === expected, "completion comparator: final operation result");
    release_snapshot(snap);
  endtask

  /* accepted commands reserve one final result until the matching acknowledgement. */
  task automatic ack_completion(input logic [63:0] identity);
    object_id(identity);
    write_word('h024, 1, 0);
  endtask

  /* successful service follows two independently acknowledged phases and never starts recording. */
  task automatic configure(input logic [63:0] identity);
    shadow_configuration(1);
    command_id(identity);
    write_word('h020, 1, 1);
    check(state_o === 1 && service_valid_o && service_phase_o === 0 && !run_permit_o,
          "configuration starts startup only");
    backend_reply(identity, 0, 1);
    check(state_o === 2 && service_valid_o && service_phase_o === 1, "startup advances to configuration");
    backend_reply(identity, 1, 1);
    check(state_o === 3 && !service_valid_o && !run_permit_o, "configuration publishes ready");
    completion(identity, 0);
    ack_completion(identity);
  endtask

  /* ARM has a terminal command result before a conversion or archive write can complete. */
  task automatic arm(input logic [63:0] identity, input logic [63:0] expected_epoch);
    object_id(1);
    command_id(identity);
    write_word('h020, 2, 1);
    check(state_o === 4 && run_permit_o && epoch_o === expected_epoch && first_tick_o !== 0,
          "ARM owns the next epoch and fixed origin");
    completion(identity, 0);
    ack_completion(identity);
  endtask

  /* matched closure describes completed or contained ownership, never CPU intent alone. */
  task automatic closure(input logic [63:0] identity, input logic [1:0] result);
    close_epoch_i = identity; close_result_i = result; close_valid_i = 1;
    tick();
    close_valid_i = 0;
  endtask

  /* independent fault occurrence pulses remain observable without any software acknowledgement. */
  task automatic inject_fault(input logic [31:0] causes);
    fault_i = causes;
    tick();
    fault_i = 0;
    tick();
  endtask

  /* the main suite names each independent obligation and checks all waits with finite bounds. */
  initial begin : campaign
    logic [31:0] value, flags, first_causes, result;
    logic error;
    logic [63:0] snap, held_tick, held_epoch, held_first_tick;
    logic [767:0] held_config;
    logic [31:0] expected_id;
    int choice;
    logic [23:0] command_matrix;
    int unsigned elapsed, accepted_at;
    bit stop_observed;
    command_matrix = 0;
    /* simulator-independent seeds never rely on implementation-specific random system calls. */
    if ($value$plusargs("seed=%d", seed)) begin end
    random_state = seed == 0 ? 32'h6d2b79f5 : seed;
    mutation_response = $test$plusargs("mutate_response");
    mutation_snapshot = $test$plusargs("mutate_snapshot");
    mutation_stop = $test$plusargs("mutate_stop");
    mutation_completion = $test$plusargs("mutate_completion");
    mutation_unknown = $test$plusargs("mutate_unknown");
    /* waveform creation is explicit so negative controls need no redundant trace files. */
    if ($value$plusargs("wave=%s", wave_path)) begin
      $dumpfile(wave_path);
      $dumpvars(0, drg5_acquisition_control_tb);
    end
    @(negedge clk_i);
    reset_controller();
    /* a separately compiled small counter profile verifies saturation without internal forcing. */
    if ($test$plusargs("small")) begin
      begin_case("counter exhaustion remains visible");
      /* eight occurrences exceed the externally configured seven-identity test limit. */
      repeat (10) inject_fault(1);
      snapshot(snap);
      snapshot_word(16, 7); snapshot_word(17, 0);
      snapshot_word(18, 7); snapshot_word(19, 0);
      read_word('h304, flags);
      check(!$isunknown(flags) && flags[8] === 1'b1 && state_o === 7 && !run_permit_o, "counter exhaustion cannot wrap or resume");
      release_snapshot(snap);
      $display("PASS acquisition-control-small checks=%0d cases=%0d", checks, cases);
      $finish;
    end

    begin_case("MMIO shape and response ownership");
    read_word('h000, value); check(value === 'h41435143, "interface identity");
    read_word('h004, value); check(value === 'h00010000, "interface version");
    access(0, 'h000, 0, 0, 7, value, error);
    check(!error && value === 'h41435143, "read survives response stalls");
    access(1, 'h100, 55, 3, 0, value, error); check(error === 1, "partial write rejected");
    access(0, 'h001, 0, 0, 0, value, error); check(error === 1, "unaligned read rejected");
    access(0, 'h0fc, 0, 0, 0, value, error); check(error === 1, "unmapped read rejected");
    access(1, 'h200, 55, 15, 0, value, error); check(error === 1, "active bank is read-only");
    access(0, 'h300, 0, 0, 0, value, error); check(value === 17 && !error, "empty snapshot reports EMPTY");

    begin_case("configuration validation and command precedence");
    shadow_configuration(1);
    command_id(1); write_word('h020, 'h10001, 2);
    command_id(1); write_word('h020, 99, 2);
    command_id(0); write_word('h020, 1, 2);
    command_id(1); write_word('h10c, 1599, 0); write_word('h020, 1, 5);
    check(state_o === 0 && !service_valid_o, "rejected tuple causes no service");
    command_id(1); write_word('h020, 1, 3);
    command_id(2); write_word('h10c, 1600, 0); qualification_valid_i = 0;
    write_word('h020, 1, 7);
    qualification_valid_i = 1;
    command_id(3); write_word('h020, 3, 6);
    snapshot(snap); snapshot_word(16, 0); snapshot_word(18, 0); release_snapshot(snap);

    begin_case("accepted service is independent of bus and shadow edits");
    reset_controller(); shadow_configuration(1); command_id(1);
    access(1, 'h020, 1, 15, 9, value, error);
    check(!error && value === 1 && state_o === 1 && service_valid_o, "startup outlives completed MMIO response");
    held_config = service_config_o;
    write_word('h10c, 999, 0);
    check(service_config_o === held_config, "candidate configuration is immutable");
    command_id(2); write_word('h020, 1, 4);
    command_id(1); write_word('h020, 1, 3);
    backend_reply(1, 0, 1);
    check(state_o === 2 && service_config_o === held_config, "phase advance preserves candidate");
    backend_reply(1, 1, 1);
    check(state_o === 3, "service completes independently");
    snapshot(snap);
    read_word('h20c, value); check(value === 1600, "active configuration publishes captured value");
    release_snapshot(snap);
    command_id(2); write_word('h020, 2, 4);
    completion(1, 0);
    object_id(2); write_word('h024, 1, 3); ack_completion(1);
    command_id(2); object_id(1); write_word('h020, 2, 1);
    check(state_o === 4 && epoch_o === 1, "busy rejection permits retry of same command ID");
    completion(2, 0); ack_completion(2);
    command_id(3); write_word('h020, 1, 5);
    check(state_o === 4 && run_permit_o, "unsupported request preserves recording");
    write_word('h10c, 1600, 0); command_id(4); write_word('h020, 1, 6);
    check(state_o === 4 && run_permit_o, "wrong-state configuration preserves recording");

    begin_case("fault closure proceeds while the ARM bus response is stalled");
    reset_controller(); configure(1); object_id(1); command_id(2);
    req_valid_i = 1; req_write_i = 1; req_addr_i = 'h020; req_wdata_i = 2;
    req_wstrb_i = 15; req_tag_i = 'habc; rsp_ready_i = 0;
    tick(); req_valid_i = 0;
    check(rsp_valid_o && rsp_rdata_o === 1 && rsp_tag_o === 'habc && arm_o && epoch_o === 1,
          "ARM admission response and binding are independently retained");
    fault_i = 1;
    #1;
    check(stop_o && !run_permit_o && arm_o, "later fault vetoes triggers without erasing accepted ARM binding");
    tick(); fault_i = 0;
    check(state_o === 5 && rsp_valid_o && !req_ready_o, "fault closure ignores bus response backpressure");
    closure(1, 1);
    check(state_o === 7 && rsp_valid_o && rsp_rdata_o === 1 && rsp_tag_o === 'habc,
          "closure cannot overwrite the accepted bus response");
    rsp_ready_i = 1; tick(); rsp_ready_i = 0;
    completion(2, 0);
    snapshot(snap); snapshot_word(18, 1); snapshot_word(82, 13); release_snapshot(snap);

    begin_case("coherent frozen snapshots through live changes");
    reset_controller(); configure(1); arm(2, 1);
    snapshot(snap);
    read_word('h308, value); held_tick[31:0] = value;
    read_word('h30c, value); held_tick[63:32] = value;
    held_epoch = epoch_o; held_first_tick = first_tick_o;
    inject_fault(1);
    check(state_o === 5 && !run_permit_o, "fault starts autonomous closing");
    snapshot_word(0, 4); snapshot_word(2, held_tick[31:0]); snapshot_word(3, held_tick[63:32]);
    snapshot_word(4, held_epoch[31:0]); snapshot_word(5, held_epoch[63:32]);
    snapshot_word(6, held_first_tick[31:0]); snapshot_word(7, held_first_tick[63:32]);
    write_word('h030, 1, 4);
    object_id(snap + 1); write_word('h048, 1, 3);
    release_snapshot(snap);
    closure(1, 0);
    check(!run_permit_o, "fault cannot silently recover");

    begin_case("ARM independently validates metadata capacity ownership and identity");
    reset_controller(); configure(1); object_id(1);
    metadata_archived_i = 0; command_id(2); write_word('h020, 2, 7); metadata_archived_i = 1;
    free_blocks_i = 23; command_id(3); write_word('h020, 2, 8); free_blocks_i = 24;
    ownership_clear_i = 0; command_id(4); write_word('h020, 2, 7); ownership_clear_i = 1;
    object_id(2); command_id(5); write_word('h020, 2, 7);
    check(state_o === 3 && epoch_o === 0 && !run_permit_o, "rejected ARM requests create no epoch");
    arm(6, 1);

    begin_case("STOP vetoes ARM and cancels service completion");
    reset_controller(); configure(1);
    command_id(2); object_id(1); emergency_stop_i = 1;
    write_word('h020, 2, 9);
    check(epoch_o === 0 && !run_permit_o, "same-edge STOP vetoes ARM");
    emergency_stop_i = 0;
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    backend_reply(1, 0, 1);
    emergency_stop_i = 1; backend_valid_i = 1; backend_ok_i = 1; backend_phase_i = 1; backend_command_id_i = 1;
    tick(); backend_valid_i = 0; emergency_stop_i = 0;
    check(!run_permit_o && state_o !== 3, "STOP beats successful configuration completion");
    /* cancellation requires explicit safe termination, independently of a CPU response. */
    if (service_cancel_o) backend_reply(1, 2, 1);
    completion(1, 10);
    check(state_o === 0, "cancelled service returns unqualified");

    begin_case("first latest overflow evidence survives CPU reset");
    reset_controller(); configure(1); arm(2, 1);
    cpu_reset_i = 1; fault_i = 'h3;
    #1; stop_observed = stop_o;
    /* corrupting this sample must fail the ordinary hardware-stop comparator. */
    if (mutation_stop && !applied_stop) begin
      stop_observed = !stop_observed; applied_stop = 1;
    end
    check(stop_observed === 1'b1 && !run_permit_o, "stop comparator: CPU-independent critical inhibit");
    tick(); fault_i = 0;
    inject_fault('h4);
    snapshot(snap);
    snapshot_word(18, 2); snapshot_word(20, 1);
    read_word('h3a0, first_causes);
    check((first_causes & 'h3) === 'h3, "first fault retains simultaneous cause set");
    read_word('h3e0, value);
    check((value & 'h4) === 'h4 && value !== first_causes, "latest fault retains overflowed occurrence");
    snapshot_word(64, 1); snapshot_word(48, 2);
    read_word('h304, flags);
    check(!$isunknown(flags) && flags[3] && flags[7], "CPU reset retains event and qualification fault");
    release_snapshot(snap);
    cpu_reset_i = 0;
    closure(1, 0);
    check(!run_permit_o, "CPU resume cannot restart");

    begin_case("CPU reset preserves completion and an already frozen snapshot");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    backend_reply(1, 0, 1); backend_reply(1, 1, 1);
    snapshot(snap); read_word('h308, value); held_tick[31:0] = value;
    read_word('h30c, value); held_tick[63:32] = value;
    cpu_reset_i = 1; cycles(5);
    snapshot_word(0, 3); snapshot_word(2, held_tick[31:0]); snapshot_word(3, held_tick[63:32]);
    snapshot_word(12, 1); snapshot_word(14, 0);
    release_snapshot(snap);
    completion(1, 0);
    cpu_reset_i = 0;
    ack_completion(1);
    snapshot(snap); snapshot_word(64, 1); release_snapshot(snap);

    begin_case("IRQ masking and W1C cannot erase fault evidence or suppress stop");
    reset_controller(); inject_fault(1);
    check(!irq_o && state_o === 7 && stop_o, "masked IRQ leaves autonomous stop active");
    write_word('h040, 1, 0);
    check(irq_o, "unmask exposes retained fault notification");
    fault_i = 2; fault_once_on_access = 1;
    write_word('h03c, 1, 0);
    check(irq_o, "new fault wins simultaneous IRQ clear");
    write_word('h03c, 1, 0);
    check(!irq_o && state_o === 7 && stop_o, "fault acknowledgement cannot recover qualification");
    write_word('h03c, 2, 0); read_word('h044, value);
    check((value & 2) === 2, "unread event reasserts its pending level");
    write_word('h040, 16, 2); read_word('h040, value); check(value === 1, "unsupported IRQ mask rejected whole");
    snapshot(snap); snapshot_word(32, 1); snapshot_word(48, 2); snapshot_word(18, 2); release_snapshot(snap);

    begin_case("service deadline is bounded and recoverable explicitly");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    accepted_at = accepted_edge;
    elapsed = edges - accepted_at;
    /* no backend completion means the configured total service deadline must fire. */
    while (state_o !== 7 && elapsed < CONFIG_LIMIT + 4) begin
      tick(); elapsed++;
    end
    check(state_o === 7 && elapsed == CONFIG_LIMIT, "startup timeout fires on its exact deadline");
    completion(1, 11); ack_completion(1);
    command_id(2); write_word('h020, 3, 1);
    backend_reply(2, 0, 1); backend_reply(2, 1, 1);
    check(state_o === 3 && !run_permit_o, "RECOVER requalifies but never arms");
    completion(2, 0); ack_completion(2);

    begin_case("configuration completion wins exactly on the total deadline");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    accepted_at = accepted_edge;
    backend_reply(1, 0, 1);
    cycles(CONFIG_LIMIT - int'(edges - accepted_at) - 1);
    check(state_o === 2, "configuration remains live one edge before deadline");
    backend_reply(1, 1, 1);
    check(state_o === 3 && edges - accepted_at == CONFIG_LIMIT, "matching completion wins deadline arbitration");
    completion(1, 0);

    begin_case("late configuration completion cannot replace timeout");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    accepted_at = accepted_edge;
    backend_reply(1, 0, 1);
    cycles(CONFIG_LIMIT - int'(edges - accepted_at));
    check(state_o === 7, "deadline resolves before late completion");
    backend_reply(1, 1, 1);
    check(state_o === 7, "late response cannot restore ready");
    completion(1, 11);

    begin_case("stale backend identity cannot finish another command");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    backend_reply(2, 0, 1);
    check(state_o === 7 && !service_valid_o, "stale backend response forces fault");
    completion(1, 11);

    begin_case("safe cancellation timeout isolates");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    pins_idle_i = 0; cpu_halt_i = 1; tick(); cpu_halt_i = 0;
    elapsed = 0;
    /* an unresponsive service owner cannot postpone isolation indefinitely. */
    while (state_o !== 7 && elapsed < CANCEL_LIMIT + 4) begin
      tick(); elapsed++;
    end
    check(state_o === 7 && isolate_o && elapsed <= CANCEL_LIMIT, "cancel deadline isolates pins");
    completion(1, 11);

    begin_case("closure timeout retains uncertain terminal");
    reset_controller(); configure(1); arm(2, 1);
    write_word('h028, 1, 1);
    elapsed = 0;
    /* stalled drain ownership never holds the STOP or terminal outcome open forever. */
    while (state_o !== 7 && elapsed < CLOSE_LIMIT + 4) begin
      tick(); elapsed++;
    end
    check(state_o === 7 && isolate_o && elapsed <= CLOSE_LIMIT, "close timeout isolates");
    snapshot(snap); snapshot_word(80, 1); snapshot_word(82, 14); release_snapshot(snap);

    begin_case("clean closure terminal identity and explicit restart");
    reset_controller(); configure(1); arm(2, 1);
    write_word('h028, 1, 1); write_word('h028, 1, 1);
    closure(1, 0);
    check(state_o === 6 && !run_permit_o, "clean closure stops");
    snapshot(snap); snapshot_word(80, 1); snapshot_word(82, 12); snapshot_word(86, 12); release_snapshot(snap);
    command_id(3); write_word('h020, 3, 9);
    object_id(1); write_word('h02c, 1, 0);
    command_id(4); write_word('h020, 3, 7);
    object_id(2); write_word('h038, 1, 3);
    object_id(1); write_word('h038, 1, 0); write_word('h038, 1, 3);
    command_id(5); write_word('h020, 3, 1);
    backend_reply(5, 0, 1); backend_reply(5, 1, 1);
    completion(5, 0); ack_completion(5);
    object_id(1); write_word('h034, 1, 0);
    arm(6, 2);
    check(epoch_o === 2, "restart allocates a distinct epoch");

    begin_case("independent STOP identity rejects stale no-epoch acknowledgement");
    reset_controller();
    write_word('h028, 1, 15);
    snapshot(snap); snapshot_word(84, 1); snapshot_word(94, 0); release_snapshot(snap);
    object_id(1); write_word('h02c, 1, 0);
    write_word('h028, 1, 15);
    object_id(1); write_word('h02c, 1, 3);
    snapshot(snap); snapshot_word(84, 2); snapshot_word(87, 1); release_snapshot(snap);
    object_id(2); write_word('h02c, 1, 0);

    begin_case("new configuration proposal preserves old active bytes until success");
    reset_controller(); configure(1);
    shadow_configuration(2);
    qualification_config_id_i = 2;
    tick();
    check(state_o === 3, "proposal binding does not revoke qualified active configuration");
    snapshot(snap); snapshot_word(96, 1); release_snapshot(snap);
    command_id(2); write_word('h020, 1, 1);
    snapshot(snap); snapshot_word(96, 1); release_snapshot(snap);
    backend_reply(2, 0, 1); backend_reply(2, 1, 1);
    completion(2, 0);
    snapshot(snap); snapshot_word(96, 2); release_snapshot(snap);

    begin_case("fault wins over simultaneous STOP and service success");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    backend_reply(1, 0, 1);
    backend_command_id_i = 1; backend_phase_i = 1; backend_ok_i = 1; backend_valid_i = 1;
    emergency_stop_i = 1; fault_i = 1;
    tick(); backend_valid_i = 0; emergency_stop_i = 0; fault_i = 0;
    check(state_o === 7 && !run_permit_o, "fault takes precedence over cancellation and success");
    completion(1, 11);

    begin_case("event acknowledgement frees same-edge replacement");
    reset_controller(); inject_fault(1);
    object_id(1);
    fault_i = 2; fault_once_on_access = 1;
    write_word('h034, 1, 0);
    fault_i = 0;
    snapshot(snap); snapshot_word(20, 0); snapshot_word(64, 2); snapshot_word(72, 2);
    release_snapshot(snap);
    object_id(1); write_word('h034, 1, 3);
    object_id(2); write_word('h034, 1, 0);
    snapshot(snap); read_word('h304, flags); check(!$isunknown(flags) && !flags[3], "event acknowledged exactly once"); release_snapshot(snap);

    begin_case("idle CPU reset does not poison a later clean epoch");
    reset_controller(); cpu_reset_i = 1; tick(); cpu_reset_i = 0; tick();
    object_id(1); write_word('h034, 1, 0);
    configure(1); arm(2, 1);
    write_word('h028, 1, 1); closure(1, 0);
    snapshot(snap); snapshot_word(82, 12); release_snapshot(snap);

    begin_case("supervisor pulse preserves terminal uncertainty");
    reset_controller(); configure(1); arm(2, 1);
    supervisor_fault_i = 1; tick(); supervisor_fault_i = 0; tick();
    closure(1, 0);
    snapshot(snap); snapshot_word(82, 14); release_snapshot(snap);
    check(state_o === 7 && isolate_o, "cleared supervisor input cannot erase uncertain ownership");

    begin_case("same-edge stale response vetoes ARM without orphan epoch");
    reset_controller(); configure(1); object_id(1); command_id(2);
    backend_valid_i = 1; backend_command_id_i = 99; backend_phase_i = 0;
    write_word('h020, 2, 7);
    backend_valid_i = 0;
    check(state_o === 7 && epoch_o === 0 && !run_permit_o, "stale completion cannot create an orphan epoch");
    snapshot(snap); read_word('h304, flags);
    check(!$isunknown(flags) && !flags[1] && !flags[2], "rejected ARM owns no operation or completion");
    release_snapshot(snap);

    begin_case("same-edge stale response vetoes CONFIGURE without orphan service");
    reset_controller(); shadow_configuration(1); command_id(1);
    backend_valid_i = 1; backend_command_id_i = 99; backend_phase_i = 0;
    write_word('h020, 1, 7);
    backend_valid_i = 0;
    check(state_o === 7 && !service_valid_o, "rejected configuration cannot orphan backend ownership");
    snapshot(snap); read_word('h304, flags);
    check(!$isunknown(flags) && !flags[1] && !flags[2], "rejected configuration owns no completion");
    release_snapshot(snap);

    begin_case("repeated STOP during cancellation joins one occurrence");
    reset_controller(); shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
    write_word('h028, 1, 1);
    write_word('h028, 1, 1); write_word('h028, 1, 1);
    check(service_cancel_o && state_o !== 7, "joined STOP does not fault cancellation");
    backend_reply(1, 2, 1);
    completion(1, 10);
    snapshot(snap); snapshot_word(16, 1); snapshot_word(20, 0); release_snapshot(snap);

    begin_case("admission counter exhaustion rejects reuse");
    reset_controller(); command_id(64'hffffffffffffffff); write_word('h020, 2, 6);
    command_id(1); write_word('h020, 2, 3);
    command_id(64'hffffffffffffffff); write_word('h020, 2, 3);
    check(!run_permit_o, "command sequence cannot wrap");

    /* independently construct each lifecycle state before exercising all ordinary opcodes. */
    for (int lifecycle = 0; lifecycle < 8; lifecycle++) begin
      /* reinitialization prevents one admitted command from biasing the next matrix entry. */
      for (int opcode = 1; opcode <= 3; opcode++) begin
        begin_case($sformatf("state/opcode matrix state=%0d opcode=%0d", lifecycle, opcode));
        reset_controller();
        /* startup and configuration intentionally retain their ordinary operation slot. */
        if (lifecycle == 1 || lifecycle == 2) begin
          shadow_configuration(1); command_id(1); write_word('h020, 1, 1);
          if (lifecycle == 2) backend_reply(1, 0, 1);
        /* all later states begin with an independently completed configuration. */
        end else if (lifecycle >= 3) begin
          configure(1);
          /* running, closing and stopped retain actual epoch history in the fixture. */
          if (lifecycle >= 4 && lifecycle <= 6) begin
            arm(2, 1);
            if (lifecycle >= 5) write_word('h028, 1, 1);
            /* remove delivery obligations only after the requested clean closure. */
            if (lifecycle == 6) begin
              closure(1, 0);
              object_id(1); write_word('h02c, 1, 0); write_word('h038, 1, 0); write_word('h034, 1, 0);
            end
          end
          if (lifecycle == 7) inject_fault(1);
        /* an initially unqualified controller has no retained operation or epoch. */
        end else begin
          shadow_configuration(1);
        end
        /* a new CONFIGURE descriptor cannot reuse the previously accepted identity. */
        if ((lifecycle == 3 || lifecycle == 6) && opcode == 1) begin
          shadow_configuration(2); qualification_config_id_i = 2;
        end
        check(state_o === 4'(lifecycle), "matrix state setup");
        command_id(100); object_id(1);
        /* the expected matrix comes from lifecycle permissions and single-slot ownership. */
        if (lifecycle == 1 || lifecycle == 2) value = 4;
        else if ((lifecycle == 0 && opcode == 1) ||
                 (lifecycle == 3 && opcode <= 2) ||
                 (lifecycle == 6 && opcode != 2) ||
                 (lifecycle == 7 && opcode == 3)) value = 1;
        else value = 6;
        write_word('h020, 32'(opcode), value);
        command_matrix[(lifecycle * 3) + opcode - 1] = 1;
      end
    end
    check(command_matrix === 24'hffffff, "all eight states and three command opcodes covered");

    begin_case("seeded malformed requests preserve reference state");
    reset_controller();
    /* independently generated invalid requests may not mutate the shadow bank or start service. */
    for (int iteration = 0; iteration < 160; iteration++) begin
      choice = int'(random_word() % 4);
      expected_id = random_word();
      /* each branch has an independent expected outcome derived from the specified address shape. */
      case (choice)
        /* partial stores cannot change a staged field. */
        0: begin
          access(1, 'h100, expected_id, 1, int'(random_word() % 4), result, error);
          check(error === 1, "random partial write rejected");
        end
        /* unaligned reads cannot alias valid words. */
        1: begin
          access(0, 'h007, 0, 0, int'(random_word() % 4), result, error);
          check(error === 1, "random unaligned read rejected");
        end
        /* legal shadow writes retain arbitrary staging bytes. */
        2: begin
          write_word('h100, expected_id, 0);
          read_word('h100, result); check(result === expected_id, "random shadow round trip");
        end
        /* reserved command bits reject before ID or state checks. */
        default: begin
          command_id(64'(iteration + 1));
          write_word('h020, 32'h80000000 | expected_id, 2);
        end
      endcase
      check(state_o === 0 && !service_valid_o && !run_permit_o && epoch_o === 0,
            "random rejected access preserves operation state");
      random_cases++;
    end
    check(cases >= 15 && random_cases == 160, "mandatory coverage complete");
    $display("PASS acquisition-control seed=%0d checks=%0d cases=%0d random=%0d", seed, checks, cases, random_cases);
    $finish;
  end
endmodule

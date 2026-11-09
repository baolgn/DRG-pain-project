/* compare public record ownership with an independent ordered synthetic ledger. */
module drg5_acquisition_records_tb #(
  parameter integer TEST_DEPTH = 4,
  parameter logic [63:0] TEST_COUNTER_LIMIT = 64'hffffffffffffffff
);
  localparam logic [3:0] ACCEPTED = 1, STALE = 2, BUSY = 3,
    INVALID = 4, TOO_LATE = 5, EXHAUSTED = 6, INHIBITED = 7;
  logic clk_i, system_reset_i = 1, inhibit_i = 0;
  logic bind_i = 0, reserve_i = 0, release_i = 0, admit_i = 0;
  logic [63:0] bind_epoch_i = 0, bind_first_tick_i = 0;
  logic [3:0] bind_result_o, reserve_result_o, release_result_o, admit_result_o;
  logic [63:0] epoch_o, first_tick_o, reservation_id_o;
  logic bound_o, reserve_ready_o, reserved_o;
  logic [63:0] release_id_i = 0, admit_id_i = 0, admit_epoch_i = 0;
  logic [63:0] admit_slot_i = 0, admit_tick_i = 0;
  logic admit_triggered_i = 0;
  logic complete_valid_i = 0, complete_ready_o;
  logic [63:0] complete_id_i = 0;
  logic [383:0] complete_record_i = 0;
  logic [3:0] complete_result_o;
  logic cancel_i = 0;
  logic [63:0] cancel_epoch_i = 0, cancel_slot_i = 0;
  logic [3:0] cancel_result_o;
  logic dma_valid_o, dma_ready_i = 0;
  logic [383:0] dma_record_o;
  logic [63:0] dma_epoch_o, dma_slot_o;
  logic dma_owned_o, dma_sent_o, dma_done_i = 0;
  logic [63:0] dma_done_epoch_i = 0, dma_done_slot_i = 0;
  logic [3:0] dma_done_result_o;
  logic [8:0] owned_o, reserved_count_o, capture_count_o, missing_count_o;
  logic [8:0] assembler_count_o, fifo_count_o, dma_count_o;
  logic [63:0] allocated_o, unused_released_o, retired_o, admitted_o;
  logic capture_idle_o;
  logic [31:0] sticky_faults_o;
  logic fault_o;
  logic [383:0] expected_record [0:4095];
  bit resolved [0:4095];
  bit model_spare = 0, model_capture = 0, model_bound = 0;
  logic [63:0] model_allocated = 0, model_released = 0, model_retired = 0;
  logic [63:0] model_epoch = 0, model_origin = 0, model_token = 0, capture_token = 0;
  int unsigned model_head = 0, model_tail = 0, capture_slot = 0;
  int unsigned checks = 0, cases = 0, edges = 0, seed = 1, random_state = 1;
  int unsigned random_records = 0, dma_requests = 0, completed_records = 0;
  logic [3:0] edge_bind, edge_reserve, edge_release, edge_admit, edge_complete, edge_cancel, edge_done;
  logic edge_complete_ready;
  bit mutate_record = 0, mutate_ledger = 0, mutate_order = 0, mutate_unknown = 0;
  bit applied_record = 0, applied_ledger = 0, applied_order = 0, applied_unknown = 0;
  string test_name = "initialization", wave_path;
  logic [63:0] saved_token, older_token;
  int unsigned random_cycles;
  bit held_completion;
  logic [383:0] held_record;
  logic [63:0] held_token;

  drg5_acquisition_records #(.DEPTH(TEST_DEPTH), .COUNTER_LIMIT(TEST_COUNTER_LIMIT)) dut (.*);

  /* only this process changes the clock; transaction helpers drive in the low phase. */
  initial begin
    clk_i = 0;
    forever #6.25 clk_i = ~clk_i;
  end

  /* a global deadline contains even a broken helper or simulator scheduling error. */
  initial begin
    #10000000;
    $fatal(1, "global timeout case=%s edge=%0d", test_name, edges);
  end

  /* four-state comparisons treat unknown predicates as failures. */
  task automatic check(input logic condition, input string detail);
    checks++;
    if (condition !== 1'b1) $fatal(1, "case=%s seed=%0d edge=%0d: %s", test_name, seed, edges, detail);
  endtask

  /* a fixed integer generator avoids simulator-dependent random sequences. */
  function automatic logic [31:0] random_word();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction

  /* synthetic payloads cover every byte; the buffer does not interpret ADC integrity. */
  function automatic logic [383:0] synthetic_record(input logic [63:0] slot, input logic [31:0] salt);
    logic [383:0] value;
    value = 0;
    /* each byte depends on its position and the independent slot identity. */
    for (int n = 0; n < 48; n++) begin
      value[n*8 +: 8] = 8'(slot >> ((n % 8)*8)) ^ 8'(n*37) ^ 8'(salt >> ((n % 4)*8));
    end
    return value;
  endfunction

  /* a missing record has no invented samples, status, trailer or present pairs. */
  function automatic logic [383:0] missing_record(input bit triggered);
    logic [383:0] value;
    value = 0; value[373] = 1; value[368] = triggered;
    return value;
  endfunction

  /* compare an offered DMA record without relying on internal ring addresses or state encodings. */
  task automatic compare_dma();
    logic [383:0] observed;
    logic [63:0] observed_slot;
    observed = dma_record_o; observed_slot = dma_slot_o;
    /* detector controls corrupt only sampled observations, never the DUT or model. */
    if (mutate_record && !applied_record) begin
      observed[17] = ~observed[17]; applied_record = 1;
    end
    /* a four-state detector checks the same ordinary byte comparator. */
    if (mutate_unknown && !applied_unknown) begin
      observed[0] = 1'bx; applied_unknown = 1;
    end
    /* wrong identity must fail independently of payload correctness. */
    if (mutate_order && !applied_order) begin
      observed_slot ^= 64'd1; applied_order = 1;
    end
    check(model_head < model_tail && resolved[model_head], "order comparator: only a resolved oldest slot may leave");
    check(dma_epoch_o === model_epoch && observed_slot === 64'(model_head), "order comparator: epoch and slot");
    check(observed === expected_record[model_head], "record comparator: all 48 bytes");
  endtask

  /* model transactions at their sampling edge, then check registered state after NBA updates. */
  task automatic tick();
    bit hold_offer, hold_owner;
    logic [511:0] previous_dma;
    logic [8:0] observed_owned;
    @(posedge clk_i);
    edge_bind = bind_result_o; edge_reserve = reserve_result_o;
    edge_release = release_result_o; edge_admit = admit_result_o;
    edge_complete = complete_result_o; edge_cancel = cancel_result_o;
    edge_done = dma_done_result_o; edge_complete_ready = complete_ready_o;
    hold_offer = dma_valid_o && !dma_ready_i && !system_reset_i;
    hold_owner = dma_owned_o && !(dma_done_i && edge_done == ACCEPTED) && !system_reset_i;
    previous_dma = {dma_epoch_o, dma_slot_o, dma_record_o};
    /* every visible owner must already have a resolved entry in the independent ledger. */
    if (dma_owned_o && !system_reset_i) compare_dma();
    /* isolated system reset destroys local context; it cannot fabricate a transfer. */
    if (system_reset_i) begin
      check(!(reserve_ready_o || complete_ready_o || dma_valid_o), "reset suppresses handshakes");
      model_spare = 0; model_capture = 0; model_bound = 0;
      model_allocated = 0; model_released = 0; model_retired = 0;
      model_epoch = 0; model_origin = 0; model_token = 0; capture_token = 0;
      model_head = 0; model_tail = 0; capture_slot = 0;
    /* only accepted public transactions change the scoreboard's owners. */
    end else begin
      /* epoch replacement cannot erase any admitted record. */
      if (bind_i && edge_bind == ACCEPTED) begin
        check(model_head == model_tail && !model_capture, "binding requires retired admitted records");
        model_epoch = bind_epoch_i; model_origin = bind_first_tick_i; model_bound = 1;
        model_head = 0; model_tail = 0;
      end
      /* a new token consumes capacity before the slot exists. */
      if (reserve_i && edge_reserve == ACCEPTED) begin
        check(!model_spare && model_allocated-model_released-model_retired < 64'(TEST_DEPTH),
          "ledger comparator: no over-admission");
        model_allocated++; model_token = model_allocated; model_spare = 1;
      end
      /* only the unused matching token can return uncommitted capacity. */
      if (release_i && edge_release == ACCEPTED) begin
        check(model_spare && release_id_i === model_token, "release matches unused token");
        model_spare = 0; model_released++;
      end
      /* admission changes the owner rather than freeing or reallocating storage. */
      if (admit_i && edge_admit == ACCEPTED) begin
        check(model_spare && admit_id_i === model_token, "admission consumes the held reservation once");
        check(admit_epoch_i === model_epoch && admit_slot_i === 64'(model_tail) &&
          admit_tick_i === model_origin + 64'(model_tail)*1600, "admission preserves contiguous identity");
        check(model_tail < 4096, "scoreboard capacity");
        model_spare = 0; resolved[model_tail] = !admit_triggered_i;
        expected_record[model_tail] = missing_record(0);
        /* the capture owner retains its token until completion or cancellation. */
        if (admit_triggered_i) begin
          check(!model_capture, "one conversion owner");
          model_capture = 1; capture_token = admit_id_i; capture_slot = model_tail;
        end
        model_tail++;
      end
      /* cancellation resolves capture into a placeholder instead of dropping the slot. */
      if (cancel_i && edge_cancel == ACCEPTED) begin
        check(model_capture && cancel_epoch_i === model_epoch && cancel_slot_i === 64'(capture_slot),
          "cancel matches unresolved capture");
        expected_record[capture_slot] = missing_record(1); resolved[capture_slot] = 1; model_capture = 0;
      end
      /* accepted complete records retain every input bit at their one ownership transfer. */
      if (complete_valid_i && edge_complete_ready && edge_complete == ACCEPTED) begin
        check(model_capture && complete_id_i === capture_token, "completion consumes the capture token once");
        expected_record[capture_slot] = complete_record_i; resolved[capture_slot] = 1; model_capture = 0;
        completed_records++;
      end
      /* a request handshake alone does not retire capacity. */
      if (dma_valid_o && dma_ready_i) dma_requests++;
      /* positive completion retires exactly the previously sent oldest record. */
      if (dma_done_i && edge_done == ACCEPTED) begin
        check(dma_owned_o && dma_sent_o && dma_done_epoch_i === model_epoch &&
          dma_done_slot_i === 64'(model_head), "retirement requires matching prior DMA ownership");
        model_head++; model_retired++;
      end
    end
    #1; edges++;
    check(!$isunknown({bind_result_o, reserve_ready_o, reserve_result_o, reserved_o, reservation_id_o,
      epoch_o, first_tick_o, bound_o, release_result_o, admit_result_o, complete_ready_o,
      complete_result_o, cancel_result_o, dma_valid_o, dma_record_o, dma_epoch_o, dma_slot_o,
      dma_owned_o, dma_sent_o, dma_done_result_o, owned_o, reserved_count_o, capture_count_o,
      missing_count_o, assembler_count_o, fifo_count_o, dma_count_o, allocated_o,
      unused_released_o, retired_o, admitted_o, capture_idle_o, sticky_faults_o, fault_o}), "unknown output");
    observed_owned = owned_o;
    /* a corrupted occupancy observation must fail the ordinary ledger equation. */
    if (mutate_ledger && !applied_ledger && model_allocated != 0) begin
      observed_owned ^= 9'd1; applied_ledger = 1;
    end
    check(64'(observed_owned) === model_allocated-model_released-model_retired, "ledger comparator: allocated minus released and retired");
    check(int'(owned_o) == int'(reserved_count_o)+int'(capture_count_o)+int'(missing_count_o)+
      int'(assembler_count_o)+int'(fifo_count_o)+int'(dma_count_o), "ledger comparator: stage partition");
    check(int'(owned_o) <= TEST_DEPTH, "ledger comparator: bounded physical capacity");
    check(allocated_o === model_allocated && unused_released_o === model_released && retired_o === model_retired,
      "ledger comparator: lifetime counters");
    check(admitted_o === 64'(model_tail), "ledger comparator: admitted slot count");
    check(reserved_o === model_spare && reserved_count_o === 9'(model_spare), "unused reservation owner");
    if (model_spare) check(reservation_id_o === model_token, "reservation generation");
    check(capture_idle_o === !model_capture && capture_count_o === 9'(model_capture), "capture owner partition");
    check(bound_o === model_bound && epoch_o === model_epoch && first_tick_o === model_origin, "immutable epoch binding");
    check(assembler_count_o <= 1 && dma_count_o <= 1, "single assembler and DMA owner");
    /* backpressure and accepted DMA requests cannot withdraw an unretired record. */
    if (hold_offer) check(dma_valid_o === 1 && {dma_epoch_o,dma_slot_o,dma_record_o} === previous_dma,
      "stable complete-record offer under backpressure");
    if (hold_owner) check(dma_owned_o === 1 && {dma_epoch_o,dma_slot_o,dma_record_o} === previous_dma,
      "stable DMA owner before matching completion");
    if (dma_owned_o) compare_dma();
    @(negedge clk_i); #1;
  endtask

  /* helpers return in the low phase so callers never race the sampling edge. */
  task automatic cycles(input int count);
    repeat (count) tick();
  endtask

  /* clear requests without touching retained peripheral owners. */
  task automatic clear_inputs();
    inhibit_i = 0; bind_i = 0; reserve_i = 0; release_i = 0; admit_i = 0;
    complete_valid_i = 0; cancel_i = 0; dma_ready_i = 0; dma_done_i = 0;
  endtask

  /* isolated reset is explicit and followed by an edge with every request idle. */
  task automatic reset_all();
    clear_inputs(); system_reset_i = 1; cycles(2); system_reset_i = 0; tick();
  endtask

  /* names identify the exact case that failed in retained simulator logs. */
  task automatic begin_case(input string name);
    test_name = name; cases++; $display("TEST %s", name);
  endtask

  /* bind requests have independent explicit expected outcomes. */
  task automatic bind_epoch(input logic [63:0] identity, input logic [63:0] origin, input logic [3:0] expected);
    bind_i = 1; bind_epoch_i = identity; bind_first_tick_i = origin;
    tick(); check(edge_bind === expected, "binding result"); bind_i = 0;
  endtask

  /* reservation acquisition never assumes same-edge retirement supplies capacity. */
  task automatic reserve_one(input logic [3:0] expected);
    reserve_i = 1; tick(); check(edge_reserve === expected, "reservation result"); reserve_i = 0;
  endtask

  /* only an unused token can be returned without retaining a record. */
  task automatic release_one(input logic [63:0] token, input logic [3:0] expected);
    release_i = 1; release_id_i = token; tick(); check(edge_release === expected, "release result"); release_i = 0;
  endtask

  /* each synthetic admission carries the expected epoch, slot and scheduled tick. */
  task automatic admit_one(input bit triggered, input logic [3:0] expected);
    admit_i = 1; admit_id_i = reservation_id_o; admit_epoch_i = model_epoch;
    admit_slot_i = 64'(model_tail); admit_tick_i = model_origin + 64'(model_tail)*1600;
    admit_triggered_i = triggered; tick(); check(edge_admit === expected, "admission result"); admit_i = 0;
  endtask

  /* completion holds all payload bits until one bounded ready/valid handshake. */
  task automatic complete_one(input logic [63:0] token, input logic [383:0] record_value, input logic [3:0] expected);
    bit accepted;
    complete_valid_i = 1; complete_id_i = token; complete_record_i = record_value; accepted = 0;
    /* a stalled assembler cannot turn this bounded test into an unbounded wait. */
    for (int n = 0; n < 32; n++) begin
      tick();
      /* acceptance includes explicit rejection of stale responses. */
      if (edge_complete_ready) begin
        check(edge_complete === expected, "complete-record result"); accepted = 1; break;
      end
    end
    check(accepted, "completion timeout"); complete_valid_i = 0;
  endtask

  /* waiting for an offered record never assumes asynchronous FIFO behavior. */
  task automatic wait_offer();
    bit seen;
    seen = 0;
    /* every stage has bounded local progression when its predecessors are resolved. */
    for (int n = 0; n < 32; n++) begin
      if (dma_valid_o) begin seen = 1; break; end
      tick();
    end
    check(seen, "DMA offer timeout");
  endtask

  /* request acceptance and positive DMA completion occur on separate edges. */
  task automatic retire_one();
    wait_offer(); dma_ready_i = 1; tick(); dma_ready_i = 0;
    check(dma_owned_o && dma_sent_o && !dma_valid_o, "DMA request retains reservation");
    dma_done_i = 1; dma_done_epoch_i = model_epoch; dma_done_slot_i = 64'(model_head);
    tick(); check(edge_done === ACCEPTED, "DMA completion result"); dma_done_i = 0;
  endtask

  /* draining does not release an unused reservation or unresolved conversion. */
  task automatic drain_all();
    int remaining;
    remaining = model_tail-model_head;
    repeat (remaining) retire_one();
    check(model_head == model_tail, "all admitted records retired once");
  endtask

  /* a run is deterministic for each explicit seed and independently names directed cases. */
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    random_state = seed == 0 ? 1 : seed;
    mutate_record = $test$plusargs("mutate_record"); mutate_ledger = $test$plusargs("mutate_ledger");
    mutate_order = $test$plusargs("mutate_order"); mutate_unknown = $test$plusargs("mutate_unknown");
    /* waveforms are optional only for negative detector controls. */
    if ($value$plusargs("wave=%s", wave_path)) begin
      $dumpfile(wave_path); $dumpvars(0, drg5_acquisition_records_tb);
    end
    @(negedge clk_i); #1;
    /* a reduced elaborated limit reaches exhaustion without forcing internal registers. */
    if ($test$plusargs("small")) begin
      begin_case("reservation generation exhaustion"); reset_all(); bind_epoch(1, 100, ACCEPTED);
      /* unused release returns space but never recycles the unique token. */
      for (int n = 0; n < 7; n++) begin
        reserve_one(ACCEPTED); check(reservation_id_o === 64'(n+1), "monotonic reduced token");
        release_one(reservation_id_o, ACCEPTED);
      end
      reserve_one(EXHAUSTED); bind_epoch(2, 200, ACCEPTED); reserve_one(EXHAUSTED);
      check(allocated_o === 7 && owned_o === 0, "exhaustion retains zero owners without wrap");
      $display("PASS acquisition-records-small checks=%0d cases=%0d", checks, cases); $finish;
    end

    begin_case("reset and idle ownership"); reset_all(); cycles(4);
    check(owned_o === 0 && !dma_valid_o && !reserved_o && capture_idle_o, "empty reset state");

    begin_case("reserve before epoch binding"); reserve_one(ACCEPTED); saved_token = reservation_id_o;
    bind_epoch(1, 100, ACCEPTED); check(reservation_id_o === saved_token, "binding retains unused token");
    release_one(saved_token, ACCEPTED); release_one(saved_token, STALE);

    begin_case("unsupported and stale bindings"); bind_epoch(0, 100, INVALID);
    bind_epoch(2, 0, INVALID); bind_epoch(1, 100, STALE);
    check(sticky_faults_o != 0, "rejections remain observable");

    begin_case("inhibit blocks allocation without erasing owners"); inhibit_i = 1; reserve_one(INHIBITED);
    inhibit_i = 0; reserve_one(ACCEPTED); saved_token = reservation_id_o;
    inhibit_i = 1; release_one(saved_token, ACCEPTED); inhibit_i = 0;

    begin_case("complete record remains stable under backpressure"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; admit_one(1, ACCEPTED);
    complete_one(saved_token, synthetic_record(0, 32'h89abcdef), ACCEPTED);
    wait_offer(); inhibit_i = 1; cycles(17); check(owned_o === 1, "held request retains capacity");
    inhibit_i = 0; retire_one();

    begin_case("request acceptance alone cannot retire DMA ownership"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; admit_one(1, ACCEPTED);
    complete_one(saved_token, synthetic_record(1, 32'h10203040), ACCEPTED); wait_offer();
    dma_ready_i = 1; dma_done_i = 1; dma_done_epoch_i = model_epoch; dma_done_slot_i = 64'(model_head);
    tick(); check(edge_done === TOO_LATE, "same-edge first DMA request is not completion");
    dma_ready_i = 0; dma_done_i = 0; cycles(9); check(owned_o === 1, "sent DMA owner retains capacity");
    dma_done_i = 1; tick(); check(edge_done === ACCEPTED, "later matching completion retires");
    tick(); check(edge_done === STALE, "duplicate completion cannot retire again"); dma_done_i = 0;

    begin_case("missing placeholder without a trigger"); reserve_one(ACCEPTED); admit_one(0, ACCEPTED); retire_one();

    begin_case("capture cancellation retains a triggered placeholder"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; admit_one(1, ACCEPTED);
    cancel_i = 1; cancel_epoch_i = model_epoch; cancel_slot_i = 64'(capture_slot);
    tick(); check(edge_cancel === ACCEPTED, "capture cancellation result"); cancel_i = 0;
    complete_one(saved_token, synthetic_record(3, 0), STALE); retire_one();

    begin_case("simultaneous cancellation wins over completion"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; admit_one(1, ACCEPTED);
    cancel_i = 1; cancel_epoch_i = model_epoch; cancel_slot_i = 64'(capture_slot);
    complete_valid_i = 1; complete_id_i = saved_token; complete_record_i = synthetic_record(4, 1);
    tick(); check(edge_cancel === ACCEPTED && edge_complete_ready && edge_complete === TOO_LATE,
      "cancel and completion have one winner"); cancel_i = 0; complete_valid_i = 0; retire_one();

    begin_case("later placeholder cannot pass unresolved older capture"); reserve_one(ACCEPTED);
    older_token = reservation_id_o; admit_one(1, ACCEPTED);
    reserve_one(ACCEPTED); admit_one(0, ACCEPTED); cycles(12);
    check(!dma_valid_o && capture_count_o === 1, "unresolved head blocks later placeholder");
    complete_one(older_token, synthetic_record(5, 32'hdeadbeef), ACCEPTED); drain_all();

    begin_case("stale completion cannot overwrite current capture"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; admit_one(1, ACCEPTED);
    complete_one(saved_token-1, synthetic_record(7, 0), STALE);
    complete_one(saved_token, synthetic_record(7, 32'h55aa55aa), ACCEPTED);
    complete_one(saved_token, synthetic_record(7, 32'hffffffff), STALE); retire_one();

    begin_case("unused release defeats simultaneous admission"); reserve_one(ACCEPTED);
    release_i = 1; release_id_i = reservation_id_o;
    admit_i = 1; admit_id_i = reservation_id_o; admit_epoch_i = model_epoch;
    admit_slot_i = 64'(model_tail); admit_tick_i = model_origin+64'(model_tail)*1600; admit_triggered_i = 0;
    tick(); check(edge_release === ACCEPTED && edge_admit === BUSY, "release precedes admission");
    release_i = 0; admit_i = 0;

    begin_case("released reservation identity cannot acquire a later owner"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; release_one(saved_token, ACCEPTED); reserve_one(ACCEPTED);
    release_one(saved_token, STALE); check(reserved_o, "stale release preserves replacement token");
    release_one(reservation_id_o, ACCEPTED);

    begin_case("wrong admission identity and tick preserve reservation"); reserve_one(ACCEPTED);
    admit_i = 1; admit_id_i = reservation_id_o; admit_epoch_i = model_epoch;
    admit_slot_i = 64'(model_tail); admit_tick_i = model_origin+64'(model_tail)*1600+1; admit_triggered_i = 0;
    tick(); check(edge_admit === INVALID && reserved_o, "wrong tick rejection");
    admit_tick_i--; admit_id_i--;
    tick(); check(edge_admit === STALE && reserved_o, "wrong token rejection");
    admit_i = 0; admit_one(0, ACCEPTED); retire_one();

    begin_case("binding cannot replace admitted owners"); reserve_one(ACCEPTED); admit_one(0, ACCEPTED);
    bind_epoch(2, 200, BUSY); drain_all(); bind_epoch(2, 200, ACCEPTED);

    begin_case("binding defeats simultaneous reservation commands"); bind_i = 1; bind_epoch_i = 3; bind_first_tick_i = 300;
    reserve_i = 1; tick(); check(edge_bind === ACCEPTED && edge_reserve === BUSY, "bind command priority");
    bind_i = 0; reserve_i = 0;

    begin_case("full ring refuses speculative same-edge DMA credit");
    /* default and reduced depths both reach real full capacity through public operations. */
    for (int n = 0; n < TEST_DEPTH; n++) begin
      reserve_one(ACCEPTED); admit_one(0, ACCEPTED);
    end
    wait_offer(); check(int'(owned_o) == TEST_DEPTH, "physical capacity reached"); reserve_one(BUSY);
    dma_ready_i = 1; tick(); dma_ready_i = 0;
    dma_done_i = 1; dma_done_epoch_i = model_epoch; dma_done_slot_i = 64'(model_head); reserve_i = 1;
    tick(); check(edge_done === ACCEPTED && edge_reserve === BUSY, "no speculative credit from retirement");
    dma_done_i = 0; reserve_i = 0; reserve_one(ACCEPTED); admit_one(0, ACCEPTED); drain_all();

    begin_case("ring wrap preserves records through repeated reuse");
    /* repeated fill and drain crosses every ring address several times. */
    for (int n = 0; n < TEST_DEPTH*3; n++) begin
      reserve_one(ACCEPTED); saved_token = reservation_id_o; admit_one(1, ACCEPTED);
      complete_one(saved_token, synthetic_record(64'(model_tail-1), 32'(n)), ACCEPTED); retire_one();
    end

    begin_case("wrong and early DMA completions preserve the head"); reserve_one(ACCEPTED); admit_one(0, ACCEPTED);
    wait_offer(); dma_done_i = 1; dma_done_epoch_i = model_epoch; dma_done_slot_i = 64'(model_head+1);
    tick(); check(edge_done === STALE, "wrong DMA identity"); dma_done_slot_i = 64'(model_head);
    tick(); check(edge_done === TOO_LATE, "unsent DMA owner cannot retire"); dma_done_i = 0; retire_one();

    begin_case("cancellation cannot rewrite assembled or DMA-owned bytes"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; admit_one(1, ACCEPTED);
    complete_one(saved_token, synthetic_record(64'(model_tail-1), 32'ha5a5a5a5), ACCEPTED);
    cancel_i = 1; cancel_epoch_i = model_epoch; cancel_slot_i = 64'(model_tail-1);
    tick(); check(edge_cancel === TOO_LATE, "assembled record cancellation rejection");
    wait_offer(); tick(); check(edge_cancel === TOO_LATE, "offered record cancellation rejection");
    cancel_i = 0; retire_one();

    begin_case("checked scheduled tick cannot wrap"); bind_epoch(4, 64'hffffffffffffff00, ACCEPTED);
    reserve_one(ACCEPTED); admit_one(0, ACCEPTED); retire_one(); reserve_one(ACCEPTED); admit_one(0, INVALID);
    release_one(reservation_id_o, ACCEPTED); bind_epoch(5, 500, ACCEPTED);

    begin_case("isolated reset cannot create acknowledgments or records"); reserve_one(ACCEPTED);
    saved_token = reservation_id_o; admit_one(1, ACCEPTED); reserve_one(ACCEPTED);
    complete_one(saved_token, synthetic_record(0, 99), ACCEPTED); wait_offer();
    system_reset_i = 1; reserve_i = 1; complete_valid_i = 1; complete_id_i = saved_token;
    dma_ready_i = 1; dma_done_i = 1; dma_done_epoch_i = model_epoch; dma_done_slot_i = 0;
    tick(); check(edge_reserve !== ACCEPTED && edge_complete !== ACCEPTED && edge_done !== ACCEPTED,
      "reset cannot claim accepted requests"); clear_inputs(); system_reset_i = 0; cycles(5);
    check(owned_o === 0 && !dma_valid_o && !bound_o, "reset leaves no phantom owner");

    begin_case("seeded stalls and simultaneous stage transfers"); bind_epoch(1, 100, ACCEPTED);
    random_records = 0; random_cycles = 0; held_completion = 0;
    /* the model drives valid requests and retains completion data through assembler stalls. */
    while ((random_records < 160 || model_head != model_tail || model_spare || model_capture) && random_cycles < 20000) begin
      clear_inputs(); random_cycles++;
      inhibit_i = (random_word() % 11) == 0;
      /* allocation decisions use modeled ownership, not a speculative DUT-ready promise. */
      if (!model_spare && model_allocated-model_released-model_retired < 64'(TEST_DEPTH) && random_records < 160 &&
          (random_word() % 3) != 0) reserve_i = 1;
      /* a later missing slot may be retained while an older conversion remains unresolved. */
      if (model_spare && random_records < 160 && (random_word() % 3) != 0) begin
        admit_i = 1; admit_id_i = model_token; admit_epoch_i = model_epoch;
        admit_slot_i = 64'(model_tail); admit_tick_i = model_origin+64'(model_tail)*1600;
        admit_triggered_i = !model_capture && ((random_word() % 4) != 0);
      end
      /* a completion producer holds its entire tuple until the public handshake. */
      if (!held_completion && model_capture && (random_word() % 3) != 0) begin
        held_completion = 1; held_token = capture_token;
        held_record = synthetic_record(64'(capture_slot), random_word());
      end
      /* occasional cancellation races a held completion and retains the admitted slot. */
      if (model_capture && (random_word() % 9) == 0) begin
        cancel_i = 1; cancel_epoch_i = model_epoch; cancel_slot_i = 64'(capture_slot);
      end
      complete_valid_i = held_completion; complete_id_i = held_token; complete_record_i = held_record;
      dma_ready_i = (random_word() % 5) == 0;
      /* completion is independent of the request-ready stalling pattern. */
      if (dma_sent_o && (random_word() % 4) == 0) begin
        dma_done_i = 1; dma_done_epoch_i = model_epoch; dma_done_slot_i = 64'(model_head);
      end
      tick();
      if (admit_i) begin check(edge_admit === ACCEPTED, "random admission result"); random_records++; end
      if (reserve_i) check(edge_reserve === (inhibit_i ? INHIBITED : ACCEPTED), "random reservation result");
      if (cancel_i) check(edge_cancel === ACCEPTED, "random cancellation result");
      if (dma_done_i) check(edge_done === ACCEPTED, "random DMA completion result");
      if (held_completion && edge_complete_ready) held_completion = 0;
    end
    clear_inputs(); check(random_records == 160 && model_head == model_tail && !model_capture && !model_spare,
      "bounded randomized campaign drains every admitted owner");
    check(cases == 23 && dma_requests >= 170 && completed_records >= 10, "directed and randomized coverage");
    $display("PASS acquisition-records seed=%0d checks=%0d cases=%0d random=%0d", seed, checks, cases, random_records);
    $finish;
  end
endmodule

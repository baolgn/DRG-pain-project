/* compare accepted commands and retained interrupt sources with an independent model. */
module drg5_irq_platform_tb;
  logic clk_i = 0, system_reset_i = 0, command_i = 0, write_i = 0;
  logic [31:0] addr_i = 0, wdata_i = 0;
  logic [1:0] size_i = 2;
  logic [3:0] wstrb_i = 0;
  logic [31:1] event_set_i = 0;
  logic block_ready_i = 0;
  logic [2:0] error_o, msip_o, overflow_o, stop_o;
  logic [31:0] rdata_o [0:2], mip_levels_o [0:2];
  logic [63:0] mtime_o [0:2], mtimecmp_o [0:2];
  logic [31:0] ext_pending_o [0:2], ext_enable_o [0:2], block_count_o [0:2];

  /* minimum, small and intended capacities share the same independent command stream. */
  for (genvar profile = 0; profile < 3; profile++) begin : platforms
    drg5_irq_platform #(.BLOCK_CAPACITY(profile == 0 ? 1 : profile == 1 ? 4 : 64)) dut (
      .clk_i, .system_reset_i, .command_i, .write_i, .addr_i, .wdata_i, .size_i, .wstrb_i,
      .event_set_i, .block_ready_i, .error_o(error_o[profile]), .rdata_o(rdata_o[profile]),
      .mip_levels_o(mip_levels_o[profile]), .mtime_o(mtime_o[profile]),
      .mtimecmp_o(mtimecmp_o[profile]), .msip_o(msip_o[profile]),
      .ext_pending_o(ext_pending_o[profile]), .ext_enable_o(ext_enable_o[profile]),
      .block_count_o(block_count_o[profile]), .overflow_o(overflow_o[profile]), .stop_o(stop_o[profile])
    );
  end

  /* reference state never consumes a DUT value as its expected next state. */
  typedef struct packed {
    logic [63:0] time_value, comparison;
    logic [31:1] events;
    logic [31:0] enables, count;
    logic software_pending, overflow;
  } model_t;
  model_t model [0:2];
  int unsigned edges = 0, checks = 0, seed = 1, random_state = 1;
  int unsigned writes = 0, reads = 0, errors = 0, timer_overrides = 0;
  int unsigned set_clear_collisions = 0, empty_ack_arrivals = 0, full_ack_arrivals = 0;
  int unsigned overflow_edges = 0, masked_pending_edges = 0, timer_wraps = 0;
  int unsigned address_bins = 0, direction_bins = 0, width_bins = 0;
  bit mutation_applied = 0;

  /* retain the full command and source vector on every failure. */
  function automatic void check(input bit condition, input string reason, input int profile);
    checks++;
    /* an intended corruption must fail the ordinary comparator. */
    if (!condition) $fatal(1, "edge=%0d profile=%0d seed=%0d reset=%b command=%b write=%b addr=%08x data=%08x size=%0d strobe=%x events=%08x block=%b: %s",
        edges, profile, seed, system_reset_i, command_i, write_i, addr_i, wdata_i,
        size_i, wstrb_i, event_set_i, block_ready_i, reason);
  endfunction

  /* capacities are separately declared test expectations. */
  function automatic int unsigned capacity(input int profile);
    return profile == 0 ? 1 : profile == 1 ? 4 : 64;
  endfunction

  /* arithmetic range decoding is independent of the RTL address case statement. */
  function automatic int register_index();
    /* all ten aligned words are present, and no aliases outside this interval exist. */
    if (addr_i < 32'h40001000 || addr_i > 32'h40001024 || addr_i[1:0] != 0) return -1;
    return int'((addr_i - 32'h40001000) / 4);
  endfunction

  /* empty acknowledgements reject against pre-edge queue state. */
  function automatic bit rejected(input int profile, input int index);
    /* an inactive port neither performs an access nor publishes an error. */
    if (!command_i) return 0;
    /* width, byte enables, complete address and direction are independent requirements. */
    if (index < 0 || size_i != 2 || wstrb_i != (write_i ? 15 : 0)) return 1;
    /* count and overflow are read-only, while acknowledgement is write-only. */
    if ((index == 7 || index == 9) && write_i) return 1;
    /* an arriving event cannot retroactively authorize a decrement of an empty queue. */
    if (index == 8 && (!write_i || (wdata_i[0] && model[profile].count == 0))) return 1;
    return 0;
  endfunction

  /* reconstruct external pending independently from the retained state. */
  function automatic logic [31:0] pending(input int profile);
    return {model[profile].events, model[profile].count != 0};
  endfunction

  /* reads expose pre-edge state without a snapshot or acknowledgement. */
  function automatic logic [31:0] read_value(input int profile, input int index);
    /* unsupported or suppressed reads have canonical zero data. */
    if (!command_i || write_i || rejected(profile, index)) return 0;
    /* the model uses numbered register slots rather than copied RTL addresses. */
    case (index)
      0: return 32'(model[profile].time_value);
      1: return 32'(model[profile].time_value >> 32);
      2: return 32'(model[profile].comparison);
      3: return 32'(model[profile].comparison >> 32);
      4: return {31'b0, model[profile].software_pending};
      5: return pending(profile);
      6: return model[profile].enables;
      7: return model[profile].count;
      9: return {31'b0, model[profile].overflow};
      default: return 0;
    endcase
  endfunction

  /* advance only from command intent, pre-edge reference state and scheduled events. */
  task automatic update_model(input int profile, input int index);
    model_t old;
    bit effect, pop;
    logic [31:1] clear_mask;
    old = model[profile];
    effect = command_i && write_i && !rejected(profile, index);
    pop = effect && index == 8 && wdata_i[0];
    clear_mask = effect && index == 5 ? wdata_i[31:1] : 0;
    /* only the platform system-reset edge starts a new timer and event epoch. */
    if (system_reset_i) begin
      model[profile] = '0;
      model[profile].comparison = '1;
    end
    /* normal ticking and event retention continue independently of CPU activity. */
    else begin
      model[profile].time_value = old.time_value + 1;
      model[profile].events = (old.events & ~clear_mask) | event_set_i;
      /* expected population uses signed arithmetic followed by explicit saturation. */
      if (pop) model[profile].count = old.count - 1;
      /* new blocks are added after any accepted acknowledgement. */
      if (block_ready_i) begin
        /* a full ledger reports its inability to retain an additional notification. */
        if (model[profile].count == capacity(profile)) begin
          model[profile].overflow = 1;
          overflow_edges++;
        end
        /* no overflow path is allowed to wrap the visible count. */
        else model[profile].count++;
      end
      /* accepted register writes override only the specified state. */
      if (effect) begin
        /* timer-half writes preserve the other old half and suppress the entire tick. */
        case (index)
          0: model[profile].time_value = (old.time_value & 64'hffffffff00000000) | {32'b0, wdata_i};
          1: model[profile].time_value = {wdata_i, old.time_value[31:0]};
          2: model[profile].comparison[31:0] = wdata_i;
          3: model[profile].comparison[63:32] = wdata_i;
          4: model[profile].software_pending = wdata_i[0];
          6: model[profile].enables = wdata_i;
          /* pending and queue effects were already modeled above. */
          default: begin end
        endcase
      end
      /* coverage observes chosen input obligations, not DUT internal control signals. */
      if (effect && index <= 1) timer_overrides++;
      /* simultaneous assertions must remain pending after a clear. */
      if (|(clear_mask & event_set_i)) set_clear_collisions++;
      /* a rejected empty acknowledgement must retain the new arrival. */
      if (command_i && write_i && index == 8 && wdata_i[0] && old.count == 0 && block_ready_i)
        empty_ack_arrivals++;
      /* a valid pop provides capacity even when the queue started full. */
      if (pop && old.count == capacity(profile) && block_ready_i) full_ack_arrivals++;
      /* the visible queue and sticky events survive platform delivery masking. */
      if (pending(profile) != 0 && model[profile].enables == 0) masked_pending_edges++;
      /* count actual unsigned timer wrap edges rather than a near-boundary value. */
      if (old.time_value == 64'hffffffffffffffff && !(effect && index <= 1)) timer_wraps++;
    end
  endtask

  /* score each combinational preview and every stored/source output at the sampling edge. */
  task automatic step();
    int index;
    bit observed_error;
    logic [31:0] observed_data, observed_pending, observed_count, observed_irq, expected_irq;
    logic [63:0] observed_time;
    #1;
    index = register_index();
    /* query checks happen before the reference changes or the clock rises. */
    for (int profile = 0; profile < 3; profile++) begin
      observed_error = error_o[profile];
      observed_data = rdata_o[profile];
      /* corrupt one illegal-access observation to calibrate permission detection. */
      if ($test$plusargs("mutate_error") && !mutation_applied && rejected(profile, index)) begin
        observed_error = !observed_error;
        mutation_applied = 1;
      end
      check(observed_error == rejected(profile, index), "MMIO permission mismatch", profile);
      check(observed_data == read_value(profile, index), "MMIO read snapshot mismatch", profile);
      /* retained counts distinguish legal transactions from rejected physical commands. */
      if (command_i && !system_reset_i) begin
        /* error responses never imply a permitted register action. */
        if (rejected(profile, index)) errors++;
        /* writes and reads are counted independently, including legal no-ops. */
        else if (write_i) writes++;
        else reads++;
      end
    end
    /* advance independent state before checking the resulting registered DUT state. */
    for (int profile = 0; profile < 3; profile++) update_model(profile, index);
    clk_i = 1;
    #1;
    edges++;
    /* each configured capacity has its own retained state and permission consequences. */
    for (int profile = 0; profile < 3; profile++) begin
      observed_time = mtime_o[profile];
      observed_pending = ext_pending_o[profile];
      observed_count = block_count_o[profile];
      observed_irq = mip_levels_o[profile];
      expected_irq = 0;
      expected_irq[3] = model[profile].software_pending;
      expected_irq[7] = model[profile].time_value >= model[profile].comparison;
      expected_irq[11] = (pending(profile) & model[profile].enables) != 0;
      /* mutate observations only; expected state remains independent. */
      if ($test$plusargs("mutate_timer") && !mutation_applied && !system_reset_i && index == 0 && write_i) begin
        observed_time ^= 1;
        mutation_applied = 1;
      end
      /* a missing pending bit must be detected even while delivery is masked. */
      if ($test$plusargs("mutate_pending") && !mutation_applied && event_set_i != 0 && !system_reset_i) begin
        observed_pending ^= 32'h2;
        mutation_applied = 1;
      end
      /* losing a counted notification cannot be hidden behind a single external IRQ bit. */
      if ($test$plusargs("mutate_count") && !mutation_applied && block_ready_i && !system_reset_i) begin
        observed_count ^= 1;
        mutation_applied = 1;
      end
      /* source level comparison is independent from pending-storage comparison. */
      if ($test$plusargs("mutate_irq") && !mutation_applied && expected_irq != 0) begin
        observed_irq ^= 32'h800;
        mutation_applied = 1;
      end
      check(observed_time == model[profile].time_value, "timer edge mismatch", profile);
      check(mtimecmp_o[profile] == model[profile].comparison, "timer compare mismatch", profile);
      check(msip_o[profile] == model[profile].software_pending, "software pending mismatch", profile);
      check(observed_pending == pending(profile), "external pending mismatch", profile);
      check(ext_enable_o[profile] == model[profile].enables, "external enables mismatch", profile);
      check(observed_count == model[profile].count, "notification count mismatch", profile);
      check(overflow_o[profile] == model[profile].overflow && stop_o[profile] == model[profile].overflow,
          "overflow containment mismatch", profile);
      check(observed_irq == expected_irq, "interrupt level mismatch", profile);
    end
    clk_i = 0;
  endtask

  /* inactive commands preserve platform state except the normal timer and source evolution. */
  task automatic defaults();
    system_reset_i = 0; command_i = 0; write_i = 0; addr_i = 0; wdata_i = 0;
    size_i = 2; wstrb_i = 0; event_set_i = 0; block_ready_i = 0;
  endtask

  /* explicit reset is a platform event, never an alias for CPU hart reset. */
  task automatic reset_platform();
    defaults(); system_reset_i = 1; step(); defaults();
  endtask

  /* form one aligned word command and retain its acceptance for exactly one scored edge. */
  task automatic command(input bit write_access, input int offset, input logic [31:0] data = 0);
    defaults(); command_i = 1; write_i = write_access; addr_i = 32'h40001000 + 32'(offset);
    wdata_i = data; wstrb_i = write_access ? 15 : 0; step(); defaults();
  endtask

  /* choose deterministic high bits so adjacent generator draws do not collapse coverage. */
  function automatic logic [31:0] random_word();
    random_state = random_state * 32'd1664525 + 32'd1013904223;
    return random_state;
  endfunction

  /* exercise exact timer boundaries, source persistence and independently rejected commands. */
  initial begin
    logic [31:0] draw;
    /* each reported seed is independent of Verilator's initialization seed. */
    if ($value$plusargs("seed=%d", seed)) begin end
    random_state = seed;
    /* models begin only with defined platform reset state. */
    for (int profile = 0; profile < 3; profile++) model[profile] = '0;
    reset_platform();
    command(1, 0, 32'hffffffff); command(1, 4, 32'hffffffff);
    defaults(); step();
    command(1, 0, 32'hffffffff); command(1, 4, 0);
    command(0, 4); command(0, 0); command(0, 4);
    command(1, 8, 0); command(1, 12, 0);
    command(1, 8, 32'hffffffff); command(1, 12, 32'hffffffff);
    command(1, 8, 1000);
    command(1, 16, 32'hffffffff); command(0, 16); command(1, 16, 32'hfffffffe);
    /* every coalescible source survives masking and wins over its simultaneous clear. */
    for (int bit_index = 1; bit_index < 32; bit_index++) begin
      defaults(); event_set_i = 31'(32'b1 << (bit_index - 1)); step();
      command(0, 20); command(1, 24, 32'b1 << bit_index);
      defaults(); command_i = 1; write_i = 1; addr_i = 32'h40001014;
      wstrb_i = 15; wdata_i = 32'b1 << bit_index;
      event_set_i = 31'(32'b1 << (bit_index - 1)); step();
      command(1, 20, 32'b1 << bit_index); command(1, 24, 0);
    end
    reset_platform();
    /* empty acknowledgement is rejected while a simultaneous arrival remains queued. */
    defaults(); command_i = 1; write_i = 1; addr_i = 32'h40001020;
    wdata_i = 1; wstrb_i = 15; block_ready_i = 1; step();
    /* repeated pulses fill every capacity without depending on the delivery mask. */
    for (int event_index = 0; event_index < 64; event_index++) begin
      defaults(); block_ready_i = 1; step();
    end
    command(1, 24, 1);
    /* full queue pop plus push conserves notifications and does not create a new overflow. */
    defaults(); command_i = 1; write_i = 1; addr_i = 32'h40001020;
    wdata_i = 1; wstrb_i = 15; block_ready_i = 1; step();
    /* a pending-word write cannot acknowledge the counted block source. */
    command(1, 20, 1); command(0, 28); command(0, 36);
    /* accepted acknowledgements consume one notification rather than clearing the whole queue. */
    for (int event_index = 0; event_index < 66; event_index++) command(1, 32, 1);
    command(1, 32, 0); command(0, 32); command(1, 28, '1); command(1, 36, '1);
    /* decoded reserved words and nearby aliases reject in both directions. */
    for (int offset = -4; offset <= 80; offset++) begin
      command(0, offset); command(1, offset, 32'hdeadbeef);
    end
    /* malformed widths and byte lanes cannot affect a valid timer register. */
    for (int width = 0; width < 4; width++) begin
      /* every strobe pattern is tested for both read and write commands. */
      for (int strobe = 0; strobe < 16; strobe++) begin
        /* reads and writes have different canonical strobes. */
        for (int direction = 0; direction < 2; direction++) begin
          defaults(); command_i = 1; write_i = 1'(direction); addr_i = 32'h40001000;
          size_i = 2'(width); wstrb_i = 4'(strobe); wdata_i = 32'h12345678; step();
        end
      end
    end
    /* this idle interval represents an always-clocked platform while the CPU is inactive. */
    defaults(); event_set_i = '1; block_ready_i = 1; step();
    defaults();
    /* neither waiting software nor absent MMIO traffic may stop the timer. */
    repeat (128) step();
    /* reset dominates coincident source sets, commands, acknowledgements and ticks. */
    defaults(); system_reset_i = 1; command_i = 1; write_i = 1;
    addr_i = 32'h40001018; wdata_i = '1; wstrb_i = 15; event_set_i = '1; block_ready_i = 1; step();
    defaults(); step();
    /* random full-width operands and event/control collisions supplement directed cases. */
    for (int vector = 0; vector < 12000; vector++) begin
      defaults(); draw = random_word();
      addr_i = 32'h40001000 + {26'b0, draw[31:28], 2'b0};
      address_bins |= 1 << draw[31:28];
      command_i = draw[23]; write_i = draw[22]; system_reset_i = draw[21:16] == 0;
      direction_bins |= 1 << int'(write_i);
      draw = random_word(); wdata_i = draw;
      draw = random_word(); size_i = draw[31:30]; wstrb_i = draw[23:20];
      width_bins |= 1 << size_i;
      /* some random accesses use canonical width/strobes to reach actual register effects. */
      if (draw[19]) begin size_i = 2; wstrb_i = write_i ? 15 : 0; end
      draw = random_word(); event_set_i = draw[31:1];
      draw = random_word(); block_ready_i = draw[31]; step();
    end
    check(address_bins == 'hffff && direction_bins == 3 && width_bins == 15, "random coverage incomplete", 0);
    check(timer_overrides > 10 && set_clear_collisions >= 93 && empty_ack_arrivals >= 3 &&
        full_ack_arrivals >= 3 && overflow_edges > 0 && masked_pending_edges > 0 && timer_wraps == 3,
        "directed coverage incomplete", 0);
    check(!$test$plusargs("mutate_error") && !$test$plusargs("mutate_timer") &&
        !$test$plusargs("mutate_pending") && !$test$plusargs("mutate_count") && !$test$plusargs("mutate_irq"),
        "requested mutation did not fire", 0);
    $display("PASS irq-platform seed=%0d profiles=3 capacities=1,4,64 edges=%0d checks=%0d reads=%0d writes=%0d errors=%0d timer_overrides=%0d set_clear=%0d empty_ack_arrival=%0d full_ack_arrival=%0d overflow_edges=%0d masked_pending=%0d timer_wraps=%0d address_bins=%04x direction_bins=%x width_bins=%x",
        seed, edges, checks, reads, writes, errors, timer_overrides, set_clear_collisions,
        empty_ack_arrivals, full_ack_arrivals, overflow_edges, masked_pending_edges, timer_wraps,
        address_bins, direction_bins, width_bins);
    $finish;
  end
endmodule

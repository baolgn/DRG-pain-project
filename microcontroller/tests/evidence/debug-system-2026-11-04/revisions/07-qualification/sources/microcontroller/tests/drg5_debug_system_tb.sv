/* exercise the complete debug wrapper through JTAG and independently owned memory targets. */
module drg5_debug_system_tb;
  import drg5_control_pkg::*;
  logic clk_i, power_reset_i, isolated_i;
  logic tck_i, tms_i, tdi_i;
  logic tdo_o;
  logic [31:0] mip_levels_i;
  logic acquisition_active_i, buffer_owned_i;
  logic acquisition_stop_o, system_reset_o, halted_o, fatal_o;
  logic [31:0] debug_dpc_o, debug_dcsr_o;
  logic [84:0] debug_access_o;
  logic [96:0] irq_event_o;
  logic i_req_valid_o;
  logic i_req_ready_i;
  logic [31:0] i_req_addr_o, i_req_tag_o;
  logic [1:0] i_req_parcels_o;
  logic i_rsp_valid_i;
  logic i_rsp_ready_o;
  logic [31:0] i_rsp_tag_i, i_rsp_data_i;
  logic [1:0] i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i;
  logic d_req_valid_o;
  logic d_req_ready_i;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o;
  logic d_req_write_o;
  logic [1:0] d_req_size_o;
  logic [3:0] d_req_wstrb_o;
  logic d_rsp_valid_i;
  logic d_rsp_ready_o;
  logic [31:0] d_rsp_tag_i, d_rsp_rdata_i;
  logic [1:0] d_rsp_status_i;
  logic sb_req_valid_o;
  logic sb_req_ready_i;
  logic sb_req_write_o;
  logic [31:0] sb_req_addr_o, sb_req_wdata_o;
  logic [1:0] sb_req_size_o;
  logic [3:0] sb_req_wstrb_o;
  logic sb_rsp_valid_i;
  logic sb_rsp_ready_o;
  logic [31:0] sb_rsp_rdata_i;
  logic [2:0] sb_rsp_error_i;
  drg5_control_pkg::trace_t trace_o;
  logic [31:0] mepc_o, mcause_o, mtval_o;
  logic [63:0] mcycle_o, minstret_o;
  logic unused_outputs;
  assign unused_outputs = ^{debug_access_o, irq_event_o, i_req_parcels_o, d_req_addr_o,
      d_req_wdata_o, d_req_write_o, d_req_size_o, d_req_wstrb_o, sb_req_size_o,
      sb_req_wstrb_o, mepc_o, mcause_o, mtval_o, mcycle_o, minstret_o, debug_dcsr_o, trace_o};

  /* keep the production deadline and all external debug blocks in this composition. */
  drg5_debug_system #(.MAX_WAIT_CYCLES(128)) dut (.*);
  bit i_owned = 0, i_accepted = 0, d_owned = 0, d_accepted = 0, s_owned = 0, s_accepted = 0;
  logic [31:0] i_tag, i_addr, d_tag, s_addr, s_data;
  logic [1:0] i_parcels;
  bit s_write;
  int i_age = 0, d_age = 0, s_age = 0;
  int i_delay = 1, d_delay = 1, s_delay = 1, s_accept_delay = 0, s_offer_age = 0;
  logic [2:0] s_error = 0;
  bit rogue_response = 0;
  int rom_mode = 0, checks = 0, cycles = 0, resets = 0, retires = 0, cases = 0;
  int i_responses = 0, d_effects = 0, d_responses = 0, s_effects = 0, s_responses = 0;
  int reads = 0, writes = 0, max_reset_wait = 0, last_s_launch = 0;
  int seed = 1, random_q = 1;
  logic [31:0] iram_word = 32'h00100293;
  bit unused_bit;
  logic [40:0] scan_result;

  /* assertions report public state and the independent physical-owner ledger. */
  task automatic check(input bit condition, input string message);
    checks++;
    if (!condition) $fatal(1, "SYSTEM_CHECK seed=%0d case=%0d cycle=%0d I=%0d D=%0d S=%0d: %s",
        seed, cases, cycles, i_owned, d_owned, s_owned, message);
  endtask

  /* instruction memory is synchronous and has no device read effect. */
  function automatic logic [31:0] instruction(input logic [31:0] address);
    if (address == 'h10000) return iram_word;
    if (address == 'h10004) return 32'h00100073;
    /* one mode launches a single MMIO read before a local loop. */
    if (rom_mode == 1) begin
      if (address == 0) return 32'h400000b7;
      if (address == 4) return 32'h0000a003;
    end
    return 32'h0000006f;
  endfunction

  /* advance a fabric edge independently from TCK and service each accepted owner once. */
  task automatic tick();
    bit ia, ir, da, dr, sa, sr, old_reset;
    /* capture immutable descriptors before their first acceptance. */
    if (i_req_valid_o && !i_owned) begin
      i_owned = 1; i_accepted = 0; i_tag = i_req_tag_o; i_addr = i_req_addr_o;
      i_parcels = i_req_parcels_o; i_age = 0;
    end
    /* CPU data transactions have their own response owner and age. */
    if (d_req_valid_o && !d_owned) begin
      d_owned = 1; d_accepted = 0; d_tag = d_req_tag_o; d_age = 0;
    end
    /* SBA lifetime begins at public request presentation, before acceptance. */
    if (sb_req_valid_o && !s_owned) begin
      s_owned = 1; s_accepted = 0; s_addr = sb_req_addr_o; s_data = sb_req_wdata_o;
      s_write = sb_req_write_o; s_age = 0; s_offer_age = 0;
      last_s_launch = cycles;
    end
    i_req_ready_i = i_owned && !i_accepted;
    i_rsp_valid_i = i_owned && i_accepted && i_age >= i_delay;
    i_rsp_tag_i = i_tag; i_rsp_data_i = instruction(i_addr);
    /* unrequested parcels carry zero even when the backing word contains other code. */
    if (!i_parcels[0]) i_rsp_data_i[15:0] = 0;
    if (!i_parcels[1]) i_rsp_data_i[31:16] = 0;
    i_rsp_parcels_i = i_parcels; i_rsp_fault_i = 0; i_rsp_status_i = 0;
    d_req_ready_i = d_owned && !d_accepted;
    d_rsp_valid_i = d_owned && d_accepted && d_age >= d_delay;
    d_rsp_tag_i = d_tag; d_rsp_rdata_i = 32'h12345678; d_rsp_status_i = 0;
    sb_req_ready_i = s_owned && !s_accepted && s_offer_age >= s_accept_delay;
    sb_rsp_valid_i = rogue_response || (s_owned && s_accepted && s_age >= s_delay);
    sb_rsp_rdata_i = s_addr == 'h10000 ? iram_word : 32'hcafebabe;
    sb_rsp_error_i = s_error;
    #1;
    ia = i_req_valid_o && i_req_ready_i; ir = i_rsp_valid_i && i_rsp_ready_o;
    da = d_req_valid_o && d_req_ready_i; dr = d_rsp_valid_i && d_rsp_ready_o;
    sa = sb_req_valid_o && sb_req_ready_i; sr = sb_rsp_valid_i && sb_rsp_ready_o;
    old_reset = system_reset_o;
    /* every stalled offer retains its originally latched descriptor. */
    if (sb_req_valid_o) check(!s_accepted && s_addr == sb_req_addr_o && s_data == sb_req_wdata_o &&
        s_write == sb_req_write_o, "SBA offer ownership changed");
    clk_i = 1; #1;
    cycles++;
    /* remove completed target pulses before evaluating the next request generation. */
    i_rsp_valid_i = 0; d_rsp_valid_i = 0; sb_rsp_valid_i = 0;
    /* power isolation is the only event that abandons a physical test target owner. */
    if (power_reset_i) begin
      i_owned = 0; d_owned = 0; s_owned = 0;
      i_accepted = 0; d_accepted = 0; s_accepted = 0;
    /* ordinary reset and halt cannot abandon any physical target state. */
    end else begin
      if (ia) i_accepted = 1;
      /* an accepted CPU read creates one peripheral effect. */
      if (da) begin d_accepted = 1; d_effects++; end
      /* external effects occur only at a permitted, sampled SBA acceptance. */
      if (sa) begin
        s_accepted = 1; s_effects++;
        if (s_write) writes++;
        else reads++;
        if (s_write && s_addr == 'h10000) iram_word = s_data;
      end
      /* instruction responses release only their own ledger entry. */
      if (ir) begin i_owned = 0; i_accepted = 0; i_responses++; end
      /* data completion follows its single prior peripheral acceptance. */
      if (dr) begin d_owned = 0; d_accepted = 0; d_responses++; end
      /* SBA completion never synthesizes another read or write effect. */
      if (sr) begin s_owned = 0; s_accepted = 0; s_responses++; end
    end
    if (i_accepted) i_age++;
    if (d_accepted) d_age++;
    if (s_accepted) s_age++;
    if (s_owned && !s_accepted) s_offer_age++;
    if (trace_o.valid && !trace_o.trap) retires++;
    if (system_reset_o && !old_reset) resets++;
    clk_i = 0; #1;
  endtask

  /* JTAG scans can continue while the fabric clock is paused; CDC service is explicit. */
  task automatic tap(input bit mode, data, output bit result);
    tms_i = mode; tdi_i = data; tck_i = 0; #2;
    result = tdo_o;
    tck_i = 1; #2;
    check(tdo_o == result, "TDO changed on sampling edge");
  endtask

  /* enter idle from any TAP state without resetting the CPU or physical owners. */
  task automatic tap_reset();
    repeat (6) tap(1, 0, unused_bit);
    tap(0, 0, unused_bit);
  endtask

  /* select a five-bit JTAG instruction with the mandatory capture pattern. */
  task automatic select_ir(input logic [4:0] instruction_ir);
    logic [4:0] capture;
    tap(1, 0, unused_bit); tap(1, 0, unused_bit); tap(0, 0, unused_bit); tap(0, 0, unused_bit);
    for (int bit_index = 0; bit_index < 5; bit_index++)
      tap(bit_index == 4, instruction_ir[bit_index], capture[bit_index]);
    tap(1, 0, unused_bit); tap(0, 0, unused_bit);
    check(capture == 1, "IR capture mismatch");
  endtask

  /* shift exactly one DMI descriptor and return the previous completed response. */
  task automatic scan(input logic [40:0] outgoing, output logic [40:0] incoming);
    tap(1, 0, unused_bit); tap(0, 0, unused_bit); tap(0, 0, unused_bit);
    for (int bit_index = 0; bit_index < 41; bit_index++)
      tap(bit_index == 40, outgoing[bit_index], incoming[bit_index]);
    tap(1, 0, unused_bit); tap(0, 0, unused_bit);
  endtask

  /* every request crosses into the fabric before its response is captured through TCK. */
  task automatic dmi(input logic [1:0] op, input logic [6:0] address,
      input logic [31:0] value, output logic [31:0] result);
    scan({address, value, op}, scan_result);
    repeat (8) tick();
    repeat (5) tap(0, 0, unused_bit);
    scan(0, scan_result);
    check(scan_result[1:0] == 0 && scan_result[40:34] == address, "DMI response failed");
    result = scan_result[33:2];
    repeat (2) tick();
  endtask

  /* writes retain their own DMI completion even when they launch a longer SBA owner. */
  task automatic dw(input logic [6:0] address, input logic [31:0] value);
    logic [31:0] unused_result;
    dmi(2, address, value, unused_result);
  endtask

  /* abstract accesses are issued through data0 and command, never through internal hierarchy. */
  task automatic reg_write(input logic [15:0] address, input logic [31:0] value);
    logic [31:0] unused_status;
    dw('h04, value); dw('h17, 32'h00230000 | {16'b0, address});
    dmi(1, 'h16, 0, unused_status);
    check(unused_status[12] == 0 && unused_status[10:8] == 0, "abstract write failed");
  endtask

  /* register reads check actual Debug Module data after abstract completion. */
  task automatic reg_read(input logic [15:0] address, input logic [31:0] expected_value);
    logic [31:0] result, unused_status;
    dw('h17, 32'h00220000 | {16'b0, address});
    dmi(1, 'h16, 0, unused_status); dmi(1, 'h04, 0, result);
    check(unused_status[12] == 0 && unused_status[10:8] == 0 && result == expected_value, "abstract read mismatch");
  endtask

  /* a new isolated power-reset session may discard the old physical ledger explicitly. */
  task automatic initialize(input int mode);
    cases++;
    power_reset_i = 1; isolated_i = 1; clk_i = 0; tck_i = 0; tms_i = 1; tdi_i = 0;
    mip_levels_i = 0; acquisition_active_i = 0; buffer_owned_i = 0;
    rogue_response = 0; s_error = 0; s_accept_delay = 0;
    i_delay = 1; d_delay = 1; s_delay = 1; rom_mode = mode;
    repeat (4) tick();
    tap_reset();
    power_reset_i = 0;
    repeat (4) tick();
    isolated_i = 0;
    tap_reset(); select_ir('h11);
    dw('h10, 1);
    check(!fatal_o, "power reset failed to clear containment");
  endtask

  /* wait for a true CPU halt rather than a DM request bit. */
  task automatic halt();
    int start;
    dw('h10, 'h80000001);
    start = cycles;
    while (!halted_o && cycles-start < 160) tick();
    check(halted_o && !i_owned && !d_owned, "wrapper halt did not drain CPU owners");
    check(acquisition_stop_o, "halt did not request acquisition stop");
    dw('h10, 1);
  endtask

  /* SBA status is checked separately from the external physical-effect count. */
  task automatic sba_status(input logic [2:0] expected_error);
    logic [31:0] unused_status;
    dmi(1, 'h38, 0, unused_status);
    check(!unused_status[21] && unused_status[14:12] == expected_error, "SBA completion status mismatch");
  endtask

  /* clear both sticky SBA error fields while selecting word accesses. */
  task automatic clear_sba();
    dw('h38, 'h00447000);
  endtask

  /* launch a physical-address read through the advertised SBA register interface. */
  task automatic sba_read(input logic [31:0] address);
    dw('h38, 'h00140000); dw('h39, address);
  endtask

  /* launch one physical-address write; all effects remain visible in the independent ledger. */
  task automatic sba_write(input logic [31:0] address, value);
    dw('h38, 'h00040000); dw('h39, address); dw('h3c, value);
  endtask

  /* a short reset request must survive deassertion until every exposed owner finishes. */
  task automatic reset_pulse();
    int prior_resets, start, prior_retires;
    prior_resets = resets;
    start = cycles;
    dw('h10, 3); dw('h10, 1);
    while ((resets == prior_resets || system_reset_o) && cycles-start < 180) tick();
    check(resets == prior_resets+1 && !system_reset_o, "short ndmreset request lost");
    if (cycles-start > max_reset_wait) max_reset_wait = cycles-start;
    /* subsequent boot traffic uses normal service after the old owners have drained. */
    i_delay = 1; d_delay = 1; s_delay = 1;
    prior_retires = retires;
    repeat (40) tick();
    check(!halted_o && retires > prior_retires, "reset drain halt leaked into reset exit");
  endtask

  /* exercise permission guards, reset ownership, resume synchronization and containment. */
  initial begin
    int before_effects, before_responses, before_retires, start;
    logic [31:0] unused_status;
    if ($value$plusargs("seed=%d", seed)) begin end
    random_q = seed == 0 ? 'h1a2b3c4d : seed;
    random_q ^= random_q << 13; random_q ^= random_q >> 17; random_q ^= random_q << 5;
    initialize(0);
    halt();
    acquisition_active_i = 1;
    before_effects = s_effects;
    sba_write('h20000000, 'h12345678); sba_status(2);
    check(s_effects == before_effects, "acquisition write guard produced an effect");
    clear_sba(); sba_read('h40000000); sba_status(2);
    check(s_effects == before_effects, "acquisition MMIO read guard produced an effect");
    clear_sba(); sba_read('h20000000); sba_status(0);
    check(s_effects == before_effects+1, "acquisition ordinary RAM read was lost");
    acquisition_active_i = 0; buffer_owned_i = 1;
    before_effects = s_effects;
    clear_sba(); sba_write('h20000000, 1); sba_status(2);
    check(s_effects == before_effects, "owned-buffer write guard produced an effect");
    buffer_owned_i = 0;

    clear_sba(); reg_write('h7b1, 'h10000); reg_write('h7b0, 'h8004);
    s_delay = 60 + int'(32'(random_q) % 12);
    before_effects = s_effects; before_responses = s_responses;
    sba_write('h10000, 'h00900293);
    check(s_owned && halted_o, "code write did not acquire its delayed owner");
    dw('h10, 'h40000001);
    check(halted_o && s_owned, "resume bypassed an unfinished code write");
    start = cycles;
    while (s_owned && cycles-start < 120) tick();
    while ((!halted_o || debug_dpc_o != 'h10004) && cycles-start < 170) tick();
    check(halted_o && debug_dpc_o == 'h10004 && s_effects == before_effects+1 &&
          s_responses == before_responses+1, "code write/resume ownership mismatch");
    reg_read('h1005, 9);

    initialize(0);
    before_effects = s_effects;
    sba_write('h10000, 'h00700293); sba_status(2);
    check(!halted_o && s_effects == before_effects, "running code write bypassed halted ownership");

    initialize(0);
    i_delay = 80;
    start = cycles;
    while (!i_owned && cycles-start < 30) tick();
    check(i_owned, "I request not exposed before reset pulse");
    reset_pulse();

    initialize(1);
    d_delay = 80;
    start = cycles;
    while (!d_owned && cycles-start < 50) tick();
    check(d_owned, "D request not exposed before reset pulse");
    before_effects = d_effects; before_responses = d_responses;
    reset_pulse();
    check(d_responses >= before_responses+1 && d_effects <= before_effects+1,
          "reset duplicated the old D owner");

    initialize(0);
    s_delay = 80;
    sba_read('h20000000);
    check(s_owned, "SBA owner absent before reset pulse");
    before_effects = s_effects; before_responses = s_responses;
    reset_pulse();
    check(s_effects == before_effects && s_responses == before_responses+1,
          "reset duplicated the old SBA owner");

    initialize(0);
    dw('h10, 9); dw('h10, 3); dw('h10, 1);
    start = cycles;
    while (!halted_o && cycles-start < 160) tick();
    check(halted_o && debug_dpc_o == 0 && debug_dcsr_o[8:6] == 5,
          "DM reset-halt did not stop at the reset vector");
    before_retires = retires;
    repeat (20) tick();
    check(retires == before_retires, "halted system continued normal execution");

    /* unowned and reserved-error replies cannot be mistaken for later successful requests. */
    for (int bad = 0; bad < 3; bad++) begin
      initialize(0);
      halt();
      /* an unowned pulse has no descriptor to which it can belong. */
      if (bad == 0) begin rogue_response = 1; tick(); rogue_response = 0; end
      /* reserved response codes invalidate an otherwise owned transaction. */
      else begin s_error = 3'(bad+4); sba_read('h20000000); end
      repeat (3) tick();
      check(fatal_o, "invalid SBA response escaped containment");
      dw('h10, 0); dw('h10, 1); dw('h10, 'h40000001);
      check(fatal_o && halted_o, "DM reset or resume cleared fatal containment");
    end

    /* timeout retains the exposed offer; DM reset cannot withdraw or replay it. */
    initialize(0);
    halt();
    s_accept_delay = 1000;
    sba_write('h20000000, 77);
    before_effects = s_effects;
    start = cycles;
    while (!fatal_o && cycles-start < 140) tick();
    check(fatal_o && sb_req_valid_o && s_owned && !s_accepted,
          "SBA timeout lost its exposed owner");
    check(cycles-last_s_launch == 128, "SBA deadline was not exactly 128 sampled edges");
    dw('h10, 0); dw('h10, 1); dw('h10, 'h40000001);
    check(fatal_o && sb_req_valid_o && halted_o && s_effects == before_effects,
          "timeout owner was withdrawn or replayed");
    s_accept_delay = 0; s_delay = 2;
    repeat (8) tick();
    check(s_effects == before_effects+1 && !s_owned && fatal_o,
          "late timeout response failed exact-once drainage");
    /* deactivation completes only after the old owner drains; reactivate before querying status. */
    dw('h10, 1);
    dmi(1, 'h11, 0, unused_status);
    check(unused_status[12] && unused_status[13], "fatal hart was not reported unavailable");

    initialize(0);
    halt();
    s_delay = 1000;
    sba_read('h20000000);
    before_effects = s_effects; before_responses = s_responses;
    start = cycles;
    while (!fatal_o && cycles-start < 140) tick();
    check(fatal_o && s_owned && s_accepted && !sb_req_valid_o &&
          cycles-last_s_launch == 128, "accepted SBA timeout replayed or lost its owner");
    dw('h10, 0); dw('h10, 1); dw('h10, 'h40000001);
    check(halted_o && s_effects == before_effects && s_responses == before_responses,
          "accepted timeout replayed after DM reset");
    s_delay = 0;
    repeat (8) tick();
    check(!s_owned && s_effects == before_effects && s_responses == before_responses+1 && fatal_o,
          "late accepted response failed containment drainage");
    $display("SYSTEM_PASS seed=%0d cases=%0d cycles=%0d checks=%0d retires=%0d resets=%0d I_responses=%0d D_effects=%0d D_responses=%0d SBA_effects=%0d SBA_responses=%0d reads=%0d writes=%0d max_reset_wait=%0d",
        seed, cases, cycles, checks, retires, resets, i_responses, d_effects, d_responses,
        s_effects, s_responses, reads, writes, max_reset_wait);
    $finish;
  end
endmodule

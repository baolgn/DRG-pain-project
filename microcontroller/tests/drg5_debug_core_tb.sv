/* exercise architectural debug boundaries independently of the external Debug Module. */
module drg5_debug_core_tb #(parameter bit C_ENABLED = 1, parameter bit DIAGNOSTIC = 0);
  import drg5_control_pkg::*;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
  logic [31:0] mip_levels_i = 0;
  logic fetch_busy_i = 0, entry_pending_o, idle_o, irq_valid_o;
  logic [31:0] irq_pc_o, irq_cause_o;
  logic [4:0] hold_i = 0;
  logic in_valid_i = 0, in_ready_o;
  packet_t in_packet_i;
  logic flush_valid_i = 0, flush_ready_o, flush_aborted_o, redirect_valid_o;
  logic [31:0] flush_pc_i = 0, redirect_pc_o;
  logic d_req_valid_o, d_req_ready_i = 0, d_req_write_o;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o;
  logic [1:0] d_req_size_o;
  logic [3:0] d_req_wstrb_o;
  logic d_rsp_valid_i = 0, d_rsp_ready_o;
  logic [31:0] d_rsp_tag_i = 0, d_rsp_rdata_i = 0;
  logic [1:0] d_rsp_status_i = 0;
  logic mem_launch_o, mem_busy_o, fatal_o;
  fatal_record_t fatal_record_o;
  logic [4:0] stage_valid_o, kill_valid_o;
  token_t stage_token_o [0:4];
  logic [3:0] transfer_o;
  logic [63:0] kill_uid_o [0:4];
  trace_t trace_o;
  logic [4:0] inspect_reg_i = 0;
  logic [31:0] inspect_value_o;
  logic inspect_defined_o;
  logic [31:0] mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o;
  logic [31:0] mie_o, mip_o, mcountinhibit_o;
  logic [63:0] mcycle_o, minstret_o;
  logic debug_haltreq_i = 0, debug_resumereq_i = 0, debug_resethaltreq_i = 0;
  logic debug_halted_o, debug_resumeack_o, debug_reg_valid_i = 0, debug_reg_write_i = 0;
  logic [15:0] debug_reg_addr_i = 0;
  logic [31:0] debug_reg_wdata_i = 0, debug_reg_rdata_o, debug_dpc_o, debug_dcsr_o;
  logic debug_reg_ready_o;
  logic [2:0] debug_reg_error_o;
  logic unused_outputs;
  assign unused_outputs = ^{flush_ready_o, flush_aborted_o, irq_pc_o, irq_cause_o, d_req_size_o,
      fatal_record_o, transfer_o, kill_valid_o, kill_uid_o[0], kill_uid_o[1], kill_uid_o[2],
      kill_uid_o[3], kill_uid_o[4], inspect_value_o, inspect_defined_o, mscratch_o, mip_o, mie_o,
      trace_o, mstatus_o, mtvec_o, entry_pending_o, mem_launch_o};

  /* enable the same ordered admission path in overlapping and diagnostic builds. */
  drg5_control #(.C_ENABLED(C_ENABLED), .DIAGNOSTIC(DIAGNOSTIC), .DEBUG_ENABLED(1),
      .IRQ_ENABLED(1), .M_ENABLED(1), .ZIFENCEI_ENABLED(1), .D_MAX_WAIT_CYCLES(128)) dut (.*);

  byte unsigned code [0:4095];
  logic [31:0] issue_pc = 0;
  bit feed = 0;
  int feed_limit = 4096;
  bit owner = 0, accepted = 0;
  int accept_delay = 0, response_delay = 1, age = 0, response_age = 0;
  logic [31:0] owner_tag, owner_addr, owner_data, reply;
  logic [3:0] owner_strobes;
  bit owner_write;
  logic [1:0] configured_status = 0, owner_status;
  int seed = 1, random_state = 1, checks = 0, edges = 0, cases = 0;
  int retires = 0, traps = 0, irqs = 0, reads = 0, writes = 0, responses = 0;
  int halt_entries = 0, resumes = 0, max_halt = 0;
  logic [63:0] cycle_ref = 0, instret_ref = 0;
  logic [31:0] inhibit_ref = 5;

  /* every failure retains the reproducible schedule and public architectural state. */
  task automatic check(input bit condition, input string message);
    checks++;
    /* preserve ordinary detector text for intentional corruption controls. */
    if (!condition) $fatal(1, "debug-core seed=%0d case=%0d edge=%0d dpc=%08x: %s",
        seed, cases, edges, debug_dpc_o, message);
  endtask

  /* use nonzero xorshift state to vary independent memory service phases. */
  function automatic int random_word();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state & 'h7fffffff;
  endfunction

  /* write original instruction bytes without using a production decoder. */
  task automatic put32(input int address, input logic [31:0] raw);
    /* little-endian byte layout also permits halfword-aligned wide instructions. */
    for (int lane = 0; lane < 4; lane++) code[address+lane] = raw[8*lane +: 8];
  endtask

  /* short encodings retain their two original bytes. */
  task automatic put16(input int address, input logic [15:0] raw);
    code[address] = raw[7:0];
    code[address+1] = raw[15:8];
  endtask

  /* the fixture varies acceptance and response latency without repeating device effects. */
  task automatic tick();
    bit before_halted, before_reset, before_ebreak, command_write, accept_now, respond_now;
    logic [15:0] command_addr;
    logic [31:0] command_data, observed_pc, raw;
    logic [63:0] observed_cycle;
    bit entered;
    in_valid_i = feed && issue_pc < 32'(feed_limit);
    in_packet_i = '0;
    in_packet_i.pc = issue_pc;
    in_packet_i.op = OP_MACHINE;
    /* an out-of-image fetch becomes a precise instruction access fault. */
    if (issue_pc >= 4096) begin
      in_packet_i.length = 4;
      in_packet_i.fault = 1;
      in_packet_i.cause = 1;
      in_packet_i.mtval = issue_pc;
    /* deliver raw bytes and architectural length, never decoded execution intent. */
    end else begin
      raw = {code[issue_pc+3], code[issue_pc+2], code[issue_pc+1], code[issue_pc]};
      in_packet_i.length = C_ENABLED && raw[1:0] != 3 ? 3'd2 : 3'd4;
      in_packet_i.raw_valid = in_packet_i.length == 2 ? 4'h3 : 4'hf;
      in_packet_i.raw = in_packet_i.length == 2 ? {16'b0, raw[15:0]} : raw;
    end
    /* first request presentation establishes an immutable physical owner. */
    if (d_req_valid_o && !owner) begin
      owner = 1;
      accepted = 0;
      age = 0;
      response_age = 0;
      owner_tag = d_req_tag_o;
      owner_addr = d_req_addr_o;
      owner_data = d_req_wdata_o;
      owner_strobes = d_req_wstrb_o;
      owner_write = d_req_write_o;
      owner_status = configured_status;
      reply = 32'h12345678;
    end
    d_req_ready_i = owner && !accepted && age >= accept_delay;
    d_rsp_valid_i = owner && accepted && response_age >= response_delay;
    d_rsp_tag_i = owner_tag;
    d_rsp_rdata_i = owner_status == 0 && !owner_write ? reply : 0;
    d_rsp_status_i = owner_status;
    #1;
    before_halted = debug_halted_o;
    before_reset = cold_reset_i || hart_reset_i;
    before_ebreak = stage_valid_o[4] && stage_token_o[4].p.op == OP_EBREAK && debug_dcsr_o[15];
    command_write = debug_reg_valid_i && debug_reg_ready_o && debug_reg_write_i && debug_reg_error_o == 0;
    command_addr = debug_reg_addr_i;
    command_data = debug_reg_wdata_i;
    accept_now = d_req_valid_o && d_req_ready_i;
    respond_now = d_rsp_valid_i && d_rsp_ready_o;
    /* all offered descriptors remain identical through acceptance. */
    if (d_req_valid_o) check(owner && !accepted &&
        {d_req_tag_o, d_req_addr_o, d_req_wdata_o, d_req_write_o, d_req_wstrb_o} ==
        {owner_tag, owner_addr, owner_data, owner_write, owner_strobes}, "owned request changed");
    /* acceptance alone creates one device effect when the responder guarantees success. */
    if (accept_now) begin
      accepted = 1;
      /* no-effect error responses cannot touch the modeled MMIO device. */
      if (owner_status == 0) begin
        if (owner_write) writes++;
        else reads++;
      end
    end
    /* the independent stream advances only on input acceptance or a registered redirect. */
    if (in_valid_i && in_ready_o) issue_pc += {29'b0, in_packet_i.length};
    clk_i = 1;
    #1;
    edges++;
    entered = debug_halted_o && !before_halted;
    /* reset clears counters; all other edges use the independently retained old inhibit. */
    if (before_reset) begin
      cycle_ref = 0;
      instret_ref = 0;
      inhibit_ref = 5;
    /* debug entry by EBREAK suppresses both increments on that entry edge. */
    end else begin
      if (!before_halted && !(entered && before_ebreak) && !inhibit_ref[0]) cycle_ref++;
      if (trace_o.valid && !trace_o.trap && !before_halted && !inhibit_ref[2]) instret_ref++;
      /* explicit debug writes replace the addressed half without an implicit increment. */
      if (command_write) begin
        /* no running instruction can compete with a permitted halted write. */
        case (command_addr)
          16'hb00: cycle_ref[31:0] = command_data;
          16'hb80: cycle_ref[63:32] = command_data;
          16'hb02: instret_ref[31:0] = command_data;
          16'hb82: instret_ref[63:32] = command_data;
          16'h320: inhibit_ref = command_data & 5;
          default: begin end
        endcase
      end
    end
    observed_cycle = mcycle_o;
    /* corrupt a halted counter observation to calibrate the ordinary edge comparator. */
    if ($test$plusargs("mutate_counter") && before_halted) observed_cycle++;
    check(observed_cycle == cycle_ref && minstret_o == instret_ref && mcountinhibit_o == inhibit_ref,
          "independent debug counter mismatch");
    check(!fatal_o, "unexpected fatal containment");
    /* terminal records are counted separately from debugger register transactions. */
    if (trace_o.valid) begin
      if (trace_o.trap) traps++;
      else retires++;
    end
    if (irq_valid_o) irqs++;
    if (entered) halt_entries++;
    if (debug_resumeack_o) resumes++;
    /* halted state never coexists with a physical request or a normal instruction. */
    if (debug_halted_o) check(!mem_busy_o && !fetch_busy_i && stage_valid_o == 0 &&
        !trace_o.valid && !irq_valid_o, "halt before physical and instruction drainage");
    /* an injected repeated device effect must fail the same ordinary transaction ledger. */
    if ($test$plusargs("mutate_duplicate") && entered && writes > 0) writes++;
    /* mutation changes only observation, not the RTL or test's expected continuation. */
    observed_pc = debug_dpc_o;
    if ($test$plusargs("mutate_dpc") && entered && debug_dcsr_o[8:6] == 4) observed_pc ^= 4;
    /* a completed step reports the last terminal continuation, including a trap vector. */
    if (entered && debug_dcsr_o[8:6] == 4)
      check(observed_pc == issue_pc, "step continuation mismatch");
    if (redirect_valid_o) issue_pc = redirect_pc_o;
    /* response completion releases the physical owner exactly once. */
    if (respond_now) begin
      responses++;
      owner = 0;
      accepted = 0;
    end
    if (owner && !accepted) age++;
    if (owner && accepted) response_age++;
    clk_i = 0;
    #1;
  endtask

  /* bounded waits turn deadlocked halt sequencing into a reproducible failure. */
  task automatic await_halt();
    int start;
    start = edges;
    /* hold the request and every bus owner until actual halted status appears. */
    while (!debug_halted_o && edges-start < 160) tick();
    check(debug_halted_o, "debug halt deadline exceeded");
    if (edges-start > max_halt) max_halt = edges-start;
  endtask

  /* abstract register access checks accepted commands before mutating reference state. */
  task automatic access(input bit write_reg, input logic [15:0] address,
      input logic [31:0] value, input logic [2:0] expected_error, output logic [31:0] result);
    debug_reg_valid_i = 1;
    debug_reg_write_i = write_reg;
    debug_reg_addr_i = address;
    debug_reg_wdata_i = value;
    #1;
    check(debug_reg_ready_o && debug_reg_error_o == expected_error, "abstract access status mismatch");
    result = debug_reg_rdata_o;
    tick();
    debug_reg_valid_i = 0;
    debug_reg_write_i = 0;
  endtask

  /* debugger writes are explicit commands, never direct hierarchical state injection. */
  task automatic wr(input logic [15:0] address, input logic [31:0] value);
    logic [31:0] unused_result;
    access(1, address, value, 0, unused_result);
  endtask

  /* compare readback against the scenario's independent expected value. */
  task automatic rd(input logic [15:0] address, input logic [31:0] expected_value);
    logic [31:0] result;
    access(0, address, 0, 0, result);
    check(result == expected_value, "abstract register value mismatch");
  endtask

  /* each scenario starts with reset-halt before any instruction can execute. */
  task automatic initialize();
    cases++;
    feed = 0;
    feed_limit = 4096;
    hold_i = 0;
    fetch_busy_i = 0;
    debug_haltreq_i = 0;
    debug_resumereq_i = 0;
    debug_resethaltreq_i = 1;
    debug_reg_valid_i = 0;
    mip_levels_i = 0;
    configured_status = 0;
    accept_delay = random_word() % 5;
    response_delay = 1 + random_word() % 8;
    /* clear every code byte so each scenario supplies its complete program. */
    for (int address = 0; address < 4096; address += 4) put32(address, 32'h00000013);
    check(!owner, "reset scenario retained a bus owner");
    cold_reset_i = 1;
    tick();
    tick();
    cold_reset_i = 0;
    issue_pc = 0;
    feed = 1;
    await_halt();
    debug_resethaltreq_i = 0;
    check(debug_dpc_o == 0 && debug_dcsr_o[8:6] == 5 && stage_valid_o == 0,
          "reset-halt executed an instruction");
    wr('h320, 0);
    /* initialize GPRs deliberately; normal reset promises only x0. */
    for (int regno = 1; regno < 32; regno++) wr(16'('h1000+regno), 0);
  endtask

  /* one resume request must acknowledge once even if the hart halts again quickly. */
  task automatic resume_run(input bit stepping, input bit breakpoint_debug = 1);
    wr('h7b0, (breakpoint_debug ? 32'h8000 : 32'b0) | (stepping ? 32'h4 : 32'b0));
    debug_haltreq_i = 0;
    debug_resumereq_i = 1;
    tick();
    check(debug_resumeack_o && !debug_halted_o, "resume acknowledgement missing");
    debug_resumereq_i = 0;
  endtask

  /* independent instruction and trap totals verify exactly one attempted step. */
  task automatic step_to(input logic [31:0] expected_pc, input bit traps_expected,
      input bit breakpoint_debug = 1);
    int before_retire, before_trap;
    before_retire = retires;
    before_trap = traps;
    resume_run(1, breakpoint_debug);
    await_halt();
    check(debug_dcsr_o[8:6] == 4 && debug_dpc_o == expected_pc, "step PC or cause mismatch");
    check(retires == before_retire + (traps_expected ? 0 : 1) &&
          traps == before_trap + (traps_expected ? 1 : 0), "step executed wrong instruction count");
  endtask

  /* directed and seeded schedules cover each advertised CPU-side debug operation. */
  initial begin
    logic [31:0] unused_result;
    int old_reads, old_writes, old_responses, start, old_irqs;
    if ($value$plusargs("seed=%d", seed)) begin end
    random_state = seed == 0 ? 32'h6d2b79f5 : seed;
    initialize();
    /* every GPR is writable except x0, and fixed debug fields resist all-one writes. */
    for (int regno = 0; regno < 32; regno++) begin
      wr(16'('h1000+regno), 32'h12340000 + 32'(regno));
      rd(16'('h1000+regno), regno == 0 ? 0 : 32'h12340000 + 32'(regno));
    end
    wr('h7b0, '1);
    check((debug_dcsr_o & ~32'h1c0) == 32'h40008407, "DCSR WARL fields mismatch");
    wr('h7b1, 7);
    rd('h7b1, C_ENABLED ? 6 : 4);
    access(0, 'h7b2, 0, 3, unused_result);
    access(0, 'h7a0, 0, 3, unused_result);
    access(1, 'hf11, 1, 3, unused_result);
    access(0, 'hc00, 0, 3, unused_result);

    initialize();
    put32(0, 'h00500093);
    put32(4, 'h00500113);
    put32(8, 'h00208463);
    put32(16, 'h008001ef);
    put32(24, 'h00128267);
    wr('h1005, 32);
    step_to(4, 0);
    rd('h1001, 5);
    step_to(8, 0);
    step_to(16, 0);
    step_to(24, 0);
    rd('h1003, 20);
    step_to(32, 0);
    rd('h1004, 28);
    /* mixed width link/continuation checks include a wide instruction at pc+2. */
    if (C_ENABLED) begin
      put16(32, 'h0085);
      put32(34, 'h00900313);
      step_to(34, 0);
      rd('h1001, 6);
      step_to(38, 0);
      rd('h1006, 9);
    end

    initialize();
    put32(0, 'h00000073);
    put32('h100, 'h00100393);
    wr('h305, 'h100);
    step_to('h100, 1);
    check(mepc_o == 0 && mcause_o == 11 && mtval_o == 0, "stepped trap state mismatch");
    rd('h1007, 0);
    step_to('h104, 0);
    rd('h1007, 1);
    /* ordinary M-mode reads of DCSR are illegal despite debugger access permission. */
    put32('h104, 'h7b002473);
    step_to('h100, 1);
    check(mepc_o == 'h104 && mcause_o == 2, "debug CSR exposed to M mode");

    initialize();
    put32(0, 'h10500073);
    step_to(4, 0);
    check(!idle_o, "stepped WFI entered sleep");
    wr('h7b1, 0);
    resume_run(0);
    start = edges;
    while (!idle_o && edges-start < 50) tick();
    check(idle_o, "ordinary WFI failed to sleep");
    debug_haltreq_i = 1;
    await_halt();
    check(debug_dpc_o == 4 && !idle_o, "halt failed to release WFI");

    initialize();
    put32(0, 'h00100093);
    wr('h305, 'h100);
    wr('h304, 'h800);
    wr('h300, 'h1808);
    mip_levels_i = 'h800;
    old_irqs = irqs;
    step_to(4, 0);
    check(irqs == old_irqs && mstatus_o[3], "stepie zero admitted an interrupt");
    resume_run(0);
    start = edges;
    while (irqs == old_irqs && edges-start < 80) tick();
    check(irqs == old_irqs+1 && mepc_o == 4 && mcause_o == 'h8000000b,
          "pending interrupt lost across step");
    debug_haltreq_i = 1;
    await_halt();

    initialize();
    put32(0, 'h00100073);
    resume_run(0);
    await_halt();
    check(debug_dcsr_o[8:6] == 1 && debug_dpc_o == 0, "ordinary debug EBREAK failed");
    /* the compressed breakpoint uses the same debug-entry path without retirement. */
    if (C_ENABLED) begin
      put16(0, 'h9002);
      resume_run(0);
      await_halt();
      check(debug_dcsr_o[8:6] == 1 && debug_dpc_o == 0, "debug C.EBREAK failed");
    end

    /* delayed loads to x0 and stores must finish once before halt, then never replay. */
    for (int store = 0; store < 2; store++) begin
      initialize();
      put32(0, store != 0 ? 32'h0020a023 : 32'h0000a003);
      put32(4, 'h00118193);
      put32(8, 'h00100073);
      wr('h1001, 'h40000000);
      wr('h1002, 13);
      feed_limit = 4;
      accept_delay = 7 + random_word() % 9;
      response_delay = 9 + random_word() % 11;
      old_reads = reads;
      old_writes = writes;
      old_responses = responses;
      resume_run(0);
      start = edges;
      while (!d_req_valid_o && edges-start < 60) tick();
      check(d_req_valid_o, "memory operation failed to launch");
      debug_haltreq_i = 1;
      fetch_busy_i = 1;
      /* a live fetch independently delays debug entry after the data transaction drains. */
      repeat (4) tick();
      check(!debug_halted_o, "halt discarded launched ownership");
      fetch_busy_i = 0;
      await_halt();
      check(debug_dpc_o == 4 && reads == old_reads + (store == 0 ? 1 : 0) &&
          writes == old_writes + (store != 0 ? 1 : 0) && responses == old_responses+1,
          "MMIO effect missing or duplicated");
      feed_limit = 4096;
      resume_run(0);
      await_halt();
      rd('h1003, 1);
      check(reads == old_reads + (store == 0 ? 1 : 0) &&
          writes == old_writes + (store != 0 ? 1 : 0), "MMIO operation replayed after resume");
    end

    initialize();
    put32(0, 'h0220d1b3);
    wr('h1001, 100);
    wr('h1002, 7);
    step_to(4, 0);
    rd('h1003, 14);

    initialize();
    put32(0, 'h0000a003);
    wr('h1001, 'h40000000);
    wr('h305, 'h100);
    configured_status = 1;
    old_reads = reads;
    step_to('h100, 1);
    check(mepc_o == 0 && mcause_o == 5 && mtval_o == 'h40000000 && reads == old_reads,
          "stepped no-effect access fault mismatch");

    initialize();
    put32(0, 'h00100073);
    wr('h305, 'h100);
    step_to('h100, 1, 0);
    check(mepc_o == 0 && mcause_o == 3 && mtval_o == 0,
          "stepped exception EBREAK failed");
    /* C.EBREAK also updates machine state when its debug-routing bit is clear. */
    if (C_ENABLED) begin
      put16(0, 'h9002);
      wr('h7b1, 0);
      step_to('h100, 1, 0);
      check(mepc_o == 0 && mcause_o == 3, "stepped exception C.EBREAK failed");
    end

    initialize();
    put32(0, 'h00008067);
    wr('h1001, 'h2000);
    wr('h305, 'h100);
    feed_limit = 'h2004;
    step_to('h2000, 0);
    check(mcause_o == 0, "branch destination fault occurred before next resume");
    step_to('h100, 1);
    check(mepc_o == 'h2000 && mcause_o == 1 && mtval_o == 'h2000,
          "deferred target fetch fault lost instruction PC");

    initialize();
    put32(0, 'h00108067);
    wr('h1001, 6);
    wr('h305, 'h100);
    /* JALR clears bit zero before the active IALIGN check. */
    if (C_ENABLED) step_to(6, 0);
    /* the non-C target fails before any destination instruction can execute. */
    else begin
      step_to('h100, 1);
      check(mepc_o == 0 && mcause_o == 0 && mtval_o == 6,
            "non-C target alignment fault mismatch");
    end

    initialize();
    put32(0, 'h0220d1b3);
    wr('h1001, 100);
    wr('h1002, 7);
    feed_limit = 4;
    resume_run(0);
    start = edges;
    /* the admitted divider must complete rather than being replaced on halt selection. */
    while (!(stage_valid_o[2] && stage_token_o[2].md_issued) && edges-start < 50) tick();
    check(stage_valid_o[2] && stage_token_o[2].md_issued, "division did not acquire its token");
    debug_haltreq_i = 1;
    await_halt();
    check(debug_dpc_o == 4 && debug_dcsr_o[8:6] == 3, "halt failed to drain division");
    rd('h1003, 14);

    initialize();
    put32(0, 'h0000a003);
    wr('h1001, 'h40000000);
    wr('h305, 'h100);
    configured_status = 1;
    feed_limit = 4;
    resume_run(0);
    start = edges;
    while (!d_req_valid_o && edges-start < 60) tick();
    check(d_req_valid_o, "older fault request failed to launch");
    debug_haltreq_i = 1;
    await_halt();
    check(debug_dpc_o == 'h100 && mepc_o == 0 && mcause_o == 5 &&
          debug_dcsr_o[8:6] == 3, "halt bypassed an older synchronous fault");

    initialize();
    put32(0, 'h00108093);
    put32(4, 'hffdff06f);
    resume_run(0);
    access(1, 'h1001, 'hdeadbeef, 4, unused_result);
    /* a running command cannot modify GPR state or steal a normal retirement edge. */
    debug_haltreq_i = 1;
    await_halt();
    access(0, 'h1001, 0, 0, unused_result);
    check(unused_result != 'hdeadbeef, "running abstract write modified a GPR");
    /* request priority prevents resume while haltreq remains asserted. */
    debug_resumereq_i = 1;
    repeat (3) tick();
    check(debug_halted_o && !debug_resumeack_o, "resume defeated simultaneous halt request");
    debug_resumereq_i = 0;

    initialize();
    put32(0, 'h00100073);
    resume_run(0);
    start = edges;
    /* a halt that arrives after EBREAK admission outranks its entry cause. */
    while (!(stage_valid_o[4] && stage_token_o[4].admitted) && edges-start < 60) tick();
    check(stage_valid_o[4] && stage_token_o[4].admitted, "EBREAK never became ordered");
    debug_haltreq_i = 1;
    await_halt();
    check(debug_dpc_o == 0 && debug_dcsr_o[8:6] == 3, "halt and EBREAK priority mismatch");

    initialize();
    put32(0, 'h00100093);
    wr('hb00, '1);
    wr('hb80, '1);
    wr('hb02, '1);
    wr('hb82, '1);
    rd('hb00, '1);
    rd('hb80, '1);
    step_to(4, 0);
    check(minstret_o == 0 && mcycle_o < 100, "counter rollover across debug resume mismatch");

    initialize();
    debug_resethaltreq_i = 0;
    hart_reset_i = 1;
    tick();
    hart_reset_i = 0;
    debug_resethaltreq_i = 1;
    start = retires;
    await_halt();
    check(debug_dpc_o == 0 && debug_dcsr_o[8:6] == 5 && retires == start,
          "late reset-halt request missed reset release");
    debug_resethaltreq_i = 0;

    initialize();
    put32(0, 'h0020a023);
    put32(4, 'h00100073);
    wr('h1001, 'h40000000);
    wr('h1002, 19);
    feed_limit = 4;
    accept_delay = 9;
    response_delay = 13;
    old_writes = writes;
    old_responses = responses;
    resume_run(0);
    start = edges;
    while (!d_req_valid_o && edges-start < 60) tick();
    check(d_req_valid_o, "reset-halt owner failed to launch");
    hart_reset_i = 1;
    debug_resethaltreq_i = 1;
    tick();
    hart_reset_i = 0;
    start = retires;
    await_halt();
    check(debug_dpc_o == 0 && debug_dcsr_o[8:6] == 5 && retires == start &&
          writes == old_writes+1 && responses == old_responses+1,
          "reset-halt lost or duplicated exposed memory work");
    debug_resethaltreq_i = 0;
    wr('h7b1, 4);
    feed_limit = 4096;
    resume_run(0);
    await_halt();
    check(writes == old_writes+1, "reset-halt resumed an orphaned memory owner");
    $display("PASS debug-core C=%0d diagnostic=%0d seed=%0d cases=%0d edges=%0d checks=%0d retires=%0d traps=%0d irqs=%0d halt_entries=%0d resumes=%0d reads=%0d writes=%0d responses=%0d max_halt=%0d",
        C_ENABLED, DIAGNOSTIC, seed, cases, edges, checks, retires, traps, irqs,
        halt_entries, resumes, reads, writes, responses, max_halt);
    $finish;
  end
endmodule

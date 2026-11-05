/* check real fetch ownership across precise interrupt admission. */
module drg5_irq_fetch_tb #(parameter integer I_LIMIT = 4);
  import drg5_control_pkg::*;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
  logic [4:0] hold_i = 0;
  logic in_valid_i, in_ready_o;
  packet_t in_packet_i;
  logic flush_valid_i = 0, flush_ready_o, flush_aborted_o;
  logic [31:0] flush_pc_i = 0;
  logic redirect_valid_o;
  logic [31:0] redirect_pc_o;
  logic d_req_valid_o, d_req_ready_i, d_req_write_o;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o;
  logic [1:0] d_req_size_o;
  logic [3:0] d_req_wstrb_o;
  logic d_rsp_valid_i, d_rsp_ready_o;
  logic [31:0] d_rsp_tag_i, d_rsp_rdata_i;
  logic [1:0] d_rsp_status_i;
  logic mem_launch_o, mem_busy_o, fatal_o;
  fatal_record_t fatal_record_o;
  logic [4:0] stage_valid_o, kill_valid_o;
  token_t stage_token_o [0:4];
  logic [3:0] transfer_o;
  logic [63:0] kill_uid_o [0:4];
  trace_t trace_o;
  logic unused_detail;
  assign unused_detail = ^fatal_record_o;
  logic [4:0] inspect_reg_i = 0;
  logic [31:0] inspect_value_o;
  logic inspect_defined_o;
  logic [31:0] mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o;
  logic [31:0] mie_o, mip_o, mcountinhibit_o;
  logic [63:0] mcycle_o, minstret_o;
  logic [31:0] mip_levels_i = 0;
  logic fetch_busy_i, irq_valid_o, idle_o, entry_pending_o;
  logic [31:0] irq_pc_o, irq_cause_o;

  /* consume diagnostic outputs without replacing independent semantic checks. */
  wire unused_core = ^{flush_ready_o, flush_aborted_o, mem_launch_o, mem_busy_o,
      transfer_o, kill_valid_o, kill_uid_o[0], kill_uid_o[1], kill_uid_o[2], kill_uid_o[3],
      kill_uid_o[4], inspect_value_o, inspect_defined_o, mscratch_o, mcountinhibit_o,
      mcycle_o, minstret_o, stage_valid_o, mstatus_o, mip_o, idle_o,
      stage_token_o[0], stage_token_o[1], stage_token_o[2],
      stage_token_o[3], stage_token_o[4], trace_o};
  logic run_enable = 0, launch_enable = 1;
  int wfi_retirements = 0, continuation_retirements = 0;
  logic request_valid, request_ready, response_valid, response_ready;
  logic [31:0] request_addr, request_tag, response_tag, response_data;
  logic [1:0] request_parcels, response_parcels, response_fault, response_status;
  logic fetch_valid, fetch_ready, fetch_supported, fetch_fault, fetch_discard, fetch_fatal;
  logic [31:0] fetch_pc, fetch_raw, fetch_cause, fetch_mtval;
  logic [3:0] fetch_raw_valid;
  logic [1:0] fetch_kind;
  logic [2:0] fetch_length, fetch_fatal_reason;
  logic [7:0] fetch_generation, current_generation;
  logic fetch_launch, fetch_accept, fetch_complete, fetch_drop;
  wire unused_fetch = ^{fetch_kind, fetch_supported, fetch_generation, current_generation, fetch_discard};
  bit i_owner = 0, i_accepted = 0, trigger_seen = 0, irq_seen = 0;
  logic [31:0] owner_addr = 0, owner_tag = 0, owner_data = 0;
  logic [1:0] owner_parcels = 0;
  int owner_age = 0, response_age = 0, first_offer_edge = 0;
  int scenario = 0, edges = 0, checks = 0, offers = 0, accepts = 0, replies = 0;
  int retirements = 0, entry_edge = 0, level_edge = 0, first_handler_d = 0;
  int max_entry = 0, max_handler = 0, max_i_age = 0, error_replies = 0;
  int store_effects = 0, store_retirements = 0, waiting_edges = 0;
  bit d_owner = 0, d_accepted = 0, mutation_applied = 0;
  logic [31:0] data_tag = 0, arch_pc = 0;

  /* the bridge preserves raw bytes and admits every instruction through machine decode. */
  always_comb begin
    in_packet_i = '0;
    in_packet_i.op = OP_MACHINE;
    in_packet_i.pc = fetch_pc;
    in_packet_i.raw = fetch_raw;
    in_packet_i.raw_valid = fetch_raw_valid;
    in_packet_i.length = fetch_length;
    in_packet_i.fault = fetch_fault;
    in_packet_i.cause = fetch_cause;
    in_packet_i.mtval = fetch_mtval;
    in_valid_i = fetch_valid && run_enable;
    fetch_ready = in_ready_o && run_enable;
  end

  /* real manager ownership, rather than a fixture busy flag, delays interrupt entry. */
  drg5_fetch #(.MAX_WAIT_CYCLES(I_LIMIT)) fetch (
    .clk_i, .cold_reset_i, .isolated_i, .hart_reset_i,
    .permit_i(run_enable && launch_enable && !entry_pending_o), .redirect_valid_i(redirect_valid_o),
    .redirect_pc_i(redirect_pc_o), .i_req_valid_o(request_valid), .i_req_ready_i(request_ready),
    .i_req_addr_o(request_addr), .i_req_tag_o(request_tag), .i_req_parcels_o(request_parcels),
    .i_rsp_valid_i(response_valid), .i_rsp_ready_o(response_ready), .i_rsp_tag_i(response_tag),
    .i_rsp_data_i(response_data), .i_rsp_parcels_i(response_parcels),
    .i_rsp_fault_i(response_fault), .i_rsp_status_i(response_status), .insn_valid_o(fetch_valid),
    .insn_ready_i(fetch_ready), .insn_pc_o(fetch_pc), .insn_raw_o(fetch_raw),
    .insn_raw_valid_o(fetch_raw_valid), .insn_length_kind_o(fetch_kind),
    .insn_length_supported_o(fetch_supported), .insn_length_bytes_o(fetch_length),
    .insn_generation_o(fetch_generation), .insn_fault_o(fetch_fault), .insn_cause_o(fetch_cause),
    .insn_mtval_o(fetch_mtval), .busy_o(fetch_busy_i), .discard_o(fetch_discard),
    .fatal_o(fetch_fatal), .fatal_reason_o(fetch_fatal_reason), .generation_o(current_generation),
    .launch_o(fetch_launch), .accept_o(fetch_accept), .complete_o(fetch_complete), .drop_o(fetch_drop)
  );

  /* no debug subsystem, compressed expansion or multiplication is supplied by this fixture. */
  drg5_control #(.DIAGNOSTIC(0), .FORWARDING(1), .IRQ_ENABLED(1)) dut (.*);

  /* the original program explicitly initializes every source register it consumes. */
  function automatic logic [31:0] program_word(input logic [31:0] address);
    /* IRQ setup precedes a long enough NOP prefix to make eligibility unambiguous. */
    case (address)
      0: return 32'h10000093;
      4: return 32'h30509073;
      8: return 32'h000010b7;
      12: return 32'h80008093;
      16: return 32'h30409073;
      20: return scenario >= 2 && scenario < 5 ? 32'h00000013 : 32'h30046073;
      32'h40: return scenario >= 2 ? 32'h10500073 : 32'h00000013;
      32'h100: return 32'h200005b7;
      32'h104: return 32'h0015a023;
      default: return 32'h00000013;
    endcase
  endfunction

  /* acceptance and response delays are independently chosen for the targeted offer. */
  function automatic int accept_delay(input logic [31:0] address);
    return address == 32'h40 && scenario == 0 ? (I_LIMIT == 4 ? 1 : 20) :
        address == 32'h44 && scenario == 3 ? 20 : 0;
  endfunction

  /* the accepted-owner case spends its delay after physical acceptance. */
  function automatic int reply_delay(input logic [31:0] address);
    return address == 32'h40 && scenario == 1 ? (I_LIMIT == 4 ? 2 : 20) :
        address == 32'h44 && scenario >= 4 ? 20 : 0;
  endfunction

  /* synchronous target replies are registered by the independently retained owner. */
  always_comb begin
    request_ready = request_valid && !i_accepted && !cold_reset_i &&
        (i_owner ? owner_age >= accept_delay(owner_addr) : accept_delay(request_addr) == 0);
    response_valid = i_owner && i_accepted && response_age >= reply_delay(owner_addr) && !cold_reset_i;
    response_tag = owner_tag;
    response_parcels = owner_parcels;
    response_fault = (scenario < 2 && owner_addr == 32'h40) ||
        (scenario == 5 && owner_addr == 32'h44) ? 3 : 0;
    response_status = response_fault != 0 ? 1 : 0;
    response_data = response_fault != 0 ? 0 : owner_data;
    d_req_ready_i = !d_accepted && !cold_reset_i;
    d_rsp_valid_i = d_owner && d_accepted && !cold_reset_i;
    d_rsp_tag_i = data_tag;
    d_rsp_rdata_i = 0;
    d_rsp_status_i = 0;
  end

  /* every diagnostic retains the case, sampling edge and physical instruction owner. */
  task automatic check(input bit condition, input string message);
    checks++;
    /* expected detector failures must name their actual semantic comparator. */
    if (!condition) $fatal(1, "IRQ_FETCH_CHECK_FAILED %s limit=%0d case=%0d edge=%0d pc=%08x owner=%b accepted=%b addr=%08x tag=%08x age=%0d",
        message, I_LIMIT, scenario, edges, arch_pc, i_owner, i_accepted, owner_addr, owner_tag, owner_age);
  endtask

  /* sample bus obligations before the edge and compare registered architectural events afterward. */
  task automatic cycle();
    bit req, accept_i, complete_i, accept_d, complete_d, was_busy, was_pending, new_launch;
    logic [31:0] address, tag, observed_epc;
    logic [1:0] parcels;
    #1;
    req = request_valid; accept_i = req && request_ready;
    complete_i = response_valid && response_ready;
    accept_d = d_req_valid_o && d_req_ready_i;
    complete_d = d_rsp_valid_i && d_rsp_ready_o;
    address = request_addr; tag = request_tag; parcels = request_parcels;
    was_busy = fetch_busy_i; was_pending = entry_pending_o; new_launch = fetch_launch;
    /* new grants cannot invalidate an existing offer or bypass an interrupt boundary. */
    if (!cold_reset_i) begin
      check(!fatal_o && !fetch_fatal && fetch_fatal_reason == 0, "no fatal containment");
      check(fetch_busy_i == i_owner || (req && !i_owner), "independent physical ownership");
      check(fetch_accept == accept_i && fetch_complete == complete_i, "physical handshakes");
      check(!entry_pending_o || !fetch_launch, "entry veto before new launch");
      /* the original address, tag and parcel mask survive every acceptance stall. */
      if (i_owner && !i_accepted) check(req && address == owner_addr && tag == owner_tag &&
          parcels == owner_parcels, "nonwithdrawable I offer");
      /* an accepted request cannot be repeated while its response is pending. */
      if (i_accepted) check(!req, "no duplicate accepted request");
      /* the offered reply precedes IRQ redirect, so its fault must remain architecturally suppressed. */
      if (complete_i && response_fault != 0) begin
        check(entry_pending_o && !irq_seen && !fetch_drop && response_fault == 3 && response_data == 0,
            "fault response drains before IRQ redirect");
      end
    end
    clk_i = 1; #1; clk_i = 0; edges++;
    /* qualified resets occur only after all prior target obligations have drained. */
    if (!cold_reset_i) begin
      /* first valid reserves an independently checked responder descriptor. */
      if (req && !i_owner) begin
        check(address < 32'h2000 && address[1:0] == 0 && parcels == 3 && tag == 32'(offers),
            "instruction request identity");
        i_owner = 1; i_accepted = 0; owner_addr = address; owner_tag = tag;
        owner_parcels = parcels; owner_age = 0; response_age = 0;
        first_offer_edge = edges; offers++;
      end
      /* exactly one physical acceptance samples the synchronous RAM word. */
      if (accept_i) begin
        check(i_owner && !i_accepted, "single I acceptance");
        i_accepted = 1; owner_data = program_word(owner_addr); response_age = 0; accepts++;
      end
      /* each response belongs to the retained request and meets this profile's deadline. */
      if (complete_i) begin
        check(i_owner && i_accepted, "response has owner");
        check(edges - first_offer_edge + 1 <= I_LIMIT, "I service deadline");
        max_i_age = edges - first_offer_edge + 1 > max_i_age ? edges - first_offer_edge + 1 : max_i_age;
        /* count the deliberate error independently of retirement records. */
        if (response_fault != 0) error_replies++;
        i_owner = 0; i_accepted = 0; replies++;
      end
      /* age only transactions that remained exposed without their terminal reply. */
      else if (i_owner && !accept_i) begin
        /* acceptance delay and response latency use separate clocks. */
        if (i_accepted) response_age++;
        else owner_age++;
      end
      /* assert the retained source at a measured offered or accepted owner boundary. */
      if (scenario < 2 && !trigger_seen && i_owner && owner_addr == 32'h40 &&
          (scenario == 0 ? !i_accepted : i_accepted)) begin
        check(mstatus_o[3] && mie_o == 32'h800 && mtvec_o == 32'h100, "encoded interrupt setup retired");
        mip_levels_i = 32'h800; trigger_seen = 1; level_edge = edges + 1;
      end
      /* an actual occupied manager must delay IRQ entry, including its completion edge. */
      if (trigger_seen && was_busy && was_pending) begin
        waiting_edges++;
        check(!irq_valid_o, "IRQ waits for I owner");
      end
      /* retirement follows an independently maintained PC, with no wrong-path fault record. */
      if (trace_o.valid) begin
        check(!trace_o.trap && !trace_o.packet.fault && trace_o.packet.pc == arch_pc &&
            trace_o.packet.raw == program_word(arch_pc) && trace_o.packet.raw_valid == 15 &&
            trace_o.packet.length == 4 && trace_o.next_pc == arch_pc + 4 &&
            trace_o.order == 64'(retirements), "ordered original instruction retirement");
        check(!(scenario < 2 && trace_o.packet.pc == 32'h40) &&
            !(scenario == 5 && trace_o.packet.pc == 32'h44), "wrong-path fetch fault never retires");
        /* WFI retires once; its sleep edge cannot expose a fresh fetch request. */
        if (scenario >= 2 && trace_o.packet.pc == 32'h40) begin
          wfi_retirements++;
          check(idle_o && !new_launch, "WFI retirement vetoes first fetch launch");
        end
        /* an MIE-clear wake resumes exactly at the sequential continuation. */
        if (scenario >= 2 && scenario < 5 && trace_o.packet.pc == 32'h44) begin
          continuation_retirements++; run_enable = 0;
        end
        /* the one handler store must retire only after its exactly-once device effect. */
        if (trace_o.packet.pc == 32'h104) begin
          store_retirements++;
          check(store_effects == 1, "handler effect precedes store retirement");
          run_enable = 0;
        end
        arch_pc += 4; retirements++;
      end
      /* IRQ records name the next unretired PC, without inventing an instruction retirement. */
      if (irq_valid_o) begin
        observed_epc = irq_pc_o;
        /* calibrate the boundary comparator without modifying the DUT or its expected PC. */
        if ($test$plusargs("mutate_epc") && !mutation_applied) begin
          observed_epc ^= 4; mutation_applied = 1;
        end
        check(trigger_seen && !irq_seen && !was_busy && !trace_o.valid && error_replies == 1,
            "single IRQ after response drain");
        check(observed_epc == arch_pc && mepc_o == arch_pc && irq_cause_o == 32'h8000000b &&
            mcause_o == 32'h8000000b && mtval_o == 0 && redirect_valid_o && redirect_pc_o == 32'h100,
            "precise IRQ boundary and trap state");
        check(scenario < 2 ? arch_pc <= 32'h40 && arch_pc >= 32'h38 : arch_pc == 32'h44,
            "bounded interrupted prefix");
        irq_seen = 1; entry_edge = edges; arch_pc = 32'h100;
      end
      /* measure actual handler decode arrival through the real fetch/control path. */
      if (irq_seen && first_handler_d == 0 && stage_valid_o[1] && stage_token_o[1].p.pc == 32'h100) begin
        first_handler_d = edges;
        check(first_handler_d - level_edge <= 224, "first handler D deadline");
      end
      /* the handler's initialized base and value determine the sole permitted store. */
      if (accept_d) begin
        check(!d_owner && irq_seen && d_req_addr_o == 32'h20000000 && d_req_wdata_o == 32'h800 &&
            d_req_write_o && d_req_size_o == 2 && d_req_wstrb_o == 15 && d_req_tag_o == 1,
            "exact handler store effect");
        d_owner = 1; d_accepted = 1; data_tag = d_req_tag_o; store_effects++;
      end
      /* completing the store never replays its independently counted physical effect. */
      if (complete_d) begin
        check(d_owner && d_accepted, "D response has owner");
        d_owner = 0; d_accepted = 0;
      end
    end
  endtask

  /* two scenarios separate offered-owner and accepted-owner interrupt drain. */
  initial begin
    /* each case starts a new isolated CPU, fetch-tag and memory-target epoch. */
    for (scenario = 0; scenario < 2; scenario++) begin
      cold_reset_i = 1; run_enable = 0; mip_levels_i = 0;
      i_owner = 0; i_accepted = 0; d_owner = 0; d_accepted = 0;
      offers = 0; accepts = 0; replies = 0; retirements = 0; arch_pc = 0;
      trigger_seen = 0; irq_seen = 0; entry_edge = 0; level_edge = 0; first_handler_d = 0;
      error_replies = 0; store_effects = 0; store_retirements = 0; waiting_edges = 0;
      cycle(); cold_reset_i = 0; run_enable = 1;
      /* a finite bound makes deadlock an explicit failure with the current owner vector. */
      for (int attempt = 0; attempt < 2000 && store_retirements == 0; attempt++) cycle();
      run_enable = 0;
      /* drain any ordinary handler prefetch without authorizing a new one. */
      for (int attempt = 0; attempt < 40 && (i_owner || fetch_busy_i || d_owner); attempt++) cycle();
      check(trigger_seen && irq_seen && first_handler_d != 0 && waiting_edges > 0 &&
          store_retirements == 1 && store_effects == 1 && error_replies == 1 &&
          offers == accepts && accepts == replies && !i_owner && !fetch_busy_i && !d_owner,
          "scenario coverage and conservation");
      max_entry = entry_edge - level_edge > max_entry ? entry_edge - level_edge : max_entry;
      max_handler = first_handler_d - level_edge > max_handler ? first_handler_d - level_edge : max_handler;
      $display("IRQ_FETCH_CASE limit=%0d case=%0d entry=%0d handler_D=%0d I_max=%0d waiting=%0d offers=%0d accepts=%0d replies=%0d",
          I_LIMIT, scenario, entry_edge-level_edge, first_handler_d-level_edge, max_i_age,
          waiting_edges, offers, accepts, replies);
    end
    /* the free-manager case is qualified at I4; retained idle ownership uses I32 stress. */
    for (scenario = 2; scenario < (I_LIMIT == 4 ? 3 : 6); scenario++) begin
      cold_reset_i = 1; run_enable = 0; launch_enable = 1; mip_levels_i = 0; hold_i = 0;
      i_owner = 0; i_accepted = 0; d_owner = 0; d_accepted = 0;
      offers = 0; accepts = 0; replies = 0; retirements = 0; arch_pc = 0;
      trigger_seen = 0; irq_seen = 0; entry_edge = 0; level_edge = 0; first_handler_d = 0;
      error_replies = 0; store_effects = 0; store_retirements = 0; waiting_edges = 0;
      wfi_retirements = 0; continuation_retirements = 0;
      cycle(); cold_reset_i = 0; run_enable = 1;
      /* catch the actual WFI fetch acceptance before the manager can launch its continuation. */
      for (int attempt = 0; attempt < 2000 && !(stage_valid_o[0] &&
          stage_token_o[0].p.pc == 'h40); attempt++) cycle();
      check(stage_valid_o[0] && stage_token_o[0].p.pc == 'h40, "WFI F arrival timeout");
      /* only the free-manager case delays fetch permission until the terminal W edge. */
      if (scenario == 2) begin launch_enable = 0; hold_i[4] = 1; end
      /* the two owned cases deliberately allow one continuation request before idle. */
      for (int attempt = 0; attempt < 100 && !(stage_valid_o[4] &&
          stage_token_o[4].p.pc == 'h40 && (scenario == 2 || stage_token_o[4].serial_ready)); attempt++) cycle();
      check(stage_valid_o[4] && stage_token_o[4].p.pc == 'h40, "WFI W arrival timeout");
      /* release W and fetch permission together to test first-valid arbitration. */
      if (scenario == 2) begin
        check(!fetch_busy_i && !i_owner, "WFI free launch fixture owner mismatch");
        hold_i[4] = 0;
        /* preparation remains separate from retirement while new fetches remain vetoed. */
        for (int attempt = 0; attempt < 8 && !stage_token_o[4].serial_ready; attempt++) cycle();
        check(stage_token_o[4].serial_ready, "WFI preparation timeout");
        launch_enable = 1;
      end
      cycle(); check(idle_o && wfi_retirements == 1, "WFI retirement or idle timeout");
      /* OFFER and WAIT retain their exact descriptor across idle without new work. */
      if (scenario >= 3) check(i_owner && owner_addr == 'h44 &&
          i_accepted == (scenario != 3), "WFI did not retain targeted I owner");
      repeat (2) cycle();
      check(idle_o && wfi_retirements == 1, "WFI idle repeated retirement or woke spuriously");
      mip_levels_i = 'h800; trigger_seen = 1; level_edge = edges + 1;
      /* local pending wakes with MIE clear; enabled wake drains the owner then traps. */
      for (int attempt = 0; attempt < 300 &&
          (scenario == 5 ? store_retirements == 0 : continuation_retirements == 0); attempt++) cycle();
      run_enable = 0;
      /* all physical owners drain even after the architectural stopping point. */
      for (int attempt = 0; attempt < 40 && (i_owner || fetch_busy_i || d_owner); attempt++) cycle();
      check(wfi_retirements == 1 && !idle_o && offers == accepts && accepts == replies &&
          !i_owner && !fetch_busy_i && !d_owner, "WFI ownership conservation");
      check(scenario == 5 ? irq_seen && store_retirements == 1 && error_replies == 1 :
          !irq_seen && continuation_retirements == 1 && error_replies == 0,
          "WFI wake continuation or interrupt mismatch");
      $display("WFI_FETCH_CASE limit=%0d case=%0d offers=%0d accepts=%0d replies=%0d IRQ=%b",
          I_LIMIT, scenario, offers, accepts, replies, irq_seen);
    end
    check(!$test$plusargs("mutate_epc"), "requested mutation did not fire");
    $display("IRQ_FETCH_PASS limit=%0d cases=2 checks=%0d max_entry=%0d max_handler_D=%0d max_I=%0d",
        I_LIMIT, checks, max_entry, max_handler, max_i_age);
    $finish;
  end
endmodule


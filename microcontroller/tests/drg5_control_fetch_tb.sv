/* verify a fetch-to-control bridge without claiming a complete CPU frontend. */
module drg5_control_fetch_tb;
  import drg5_control_pkg::*;
  /* disconnected debug outputs retain named endpoints in legacy configurations. */
  logic unused_debug_halted, unused_debug_resumeack, unused_debug_reg_ready;
  logic [31:0] unused_debug_dpc, unused_debug_dcsr, unused_debug_reg_rdata;
  logic [2:0] unused_debug_reg_error;
  /* preserve the explicitly IRQ-disabled compatibility profile. */
  logic unused_entry_pending, unused_idle, unused_irq_valid;
  logic [31:0] unused_irq_pc, unused_irq_cause;
  logic clk = 0, cold_reset = 0, run_enable = 0, bridge_enable = 0;
  logic [4:0] hold = 0;
  logic request_valid, request_ready, response_valid, response_ready;
  logic [31:0] request_addr, request_tag, response_tag, response_data;
  logic [1:0] request_parcels, response_parcels, response_fault, response_status;
  logic fetch_valid, fetch_ready, fetch_supported, fetch_fault, fetch_busy, fetch_discard, fetch_fatal;
  logic [31:0] fetch_pc, fetch_raw, fetch_cause, fetch_mtval;
  logic [3:0] fetch_raw_valid;
  logic [1:0] fetch_kind;
  logic [2:0] fetch_length, fetch_fatal_reason;
  logic [7:0] fetch_generation, current_generation;
  logic fetch_launch, fetch_accept, fetch_complete, fetch_drop;
  logic input_ready, redirect_valid, d_request_valid, control_fatal;
  fatal_record_t control_fatal_record;
  logic [31:0] redirect_pc, inspect_value;
  logic inspect_defined;
  logic [4:0] stage_valid;
  token_t stage_token [0:4];
  packet_t bridge_packet;
  trace_t trace_record;
  logic unused_flush_ready, unused_flush_aborted, unused_d_write, unused_d_response_ready;
  logic unused_mem_launch, unused_mem_busy;
  logic [31:0] unused_d_addr, unused_d_data, unused_d_tag;
  logic [1:0] unused_d_size;
  logic [3:0] unused_d_mask, unused_transfer;
  logic [4:0] unused_kill;
  logic [63:0] unused_kill_uid [0:4];
  logic [31:0] unused_mstatus, unused_mtvec, unused_mscratch, unused_mepc, unused_mcause, unused_mtval;
  /* pending-level visibility and machine counters are outside this fetch bridge fixture. */
  logic [31:0] unused_mie, unused_mip, unused_mcountinhibit;
  logic [63:0] unused_mcycle, unused_minstret;
  wire unused_token_fields = ^{stage_token[0], stage_token[1], stage_token[2], stage_token[3], stage_token[4]};
  wire unused_trace_fields = ^trace_record;
  logic [31:0] ram [0:2047];
  bit target_active = 0, target_accepted = 0, target_stale = 0, response_pending = 0;
  logic [31:0] target_addr = 0, target_tag = 0, captured_data = 0;
  logic [1:0] target_parcels = 0, captured_fault = 0, captured_status = 0;
  int unsigned acceptance_wait = 0, response_wait = 0;
  int unsigned scenario = 0, edges = 0, checks = 0, offers = 0, accepts = 0, completions = 0;
  int unsigned launches = 0, normal_records = 0, terminal_records = 0, jump_redirects = 0;
  int unsigned trap_redirects = 0, held_output = 0, held_writeback = 0, stale_errors = 0;
  bit wrongpath_offered = 0, terminal_seen = 0, offered_across_redirect = 0;
  bit accepted_across_redirect = 0;
  bit mutate_target_fault = 0, mutate_stale_drop = 0;

  /* preserve the original instruction bytes and fetch fault at the packet boundary. */
  always_comb begin
    bridge_packet = '0;
    bridge_packet.op = OP_CONTROL;
    bridge_packet.pc = fetch_pc;
    bridge_packet.raw = fetch_raw;
    bridge_packet.raw_valid = fetch_raw_valid;
    bridge_packet.length = fetch_length;
    bridge_packet.fault = fetch_fault;
    bridge_packet.cause = fetch_cause;
    bridge_packet.mtval = fetch_mtval;
    fetch_ready = input_ready && run_enable && bridge_enable;
  end

  /* the stress deadline permits deliberately delayed replies, not F80 timing claims. */
  drg5_fetch #(.MAX_WAIT_CYCLES(32)) fetch (
    .clk_i(clk), .cold_reset_i(cold_reset), .isolated_i(1'b1), .hart_reset_i(1'b0),
    .permit_i(run_enable), .redirect_valid_i(redirect_valid), .redirect_pc_i(redirect_pc),
    .i_req_valid_o(request_valid), .i_req_ready_i(request_ready),
    .i_req_addr_o(request_addr), .i_req_tag_o(request_tag), .i_req_parcels_o(request_parcels),
    .i_rsp_valid_i(response_valid), .i_rsp_ready_o(response_ready), .i_rsp_tag_i(response_tag),
    .i_rsp_data_i(response_data), .i_rsp_parcels_i(response_parcels),
    .i_rsp_fault_i(response_fault), .i_rsp_status_i(response_status),
    .insn_valid_o(fetch_valid), .insn_ready_i(fetch_ready), .insn_pc_o(fetch_pc), .insn_raw_o(fetch_raw),
    .insn_raw_valid_o(fetch_raw_valid), .insn_length_kind_o(fetch_kind),
    .insn_length_supported_o(fetch_supported), .insn_length_bytes_o(fetch_length),
    .insn_generation_o(fetch_generation), .insn_fault_o(fetch_fault), .insn_cause_o(fetch_cause),
    .insn_mtval_o(fetch_mtval), .busy_o(fetch_busy), .discard_o(fetch_discard), .fatal_o(fetch_fatal),
    .fatal_reason_o(fetch_fatal_reason), .generation_o(current_generation),
    .launch_o(fetch_launch), .accept_o(fetch_accept), .complete_o(fetch_complete), .drop_o(fetch_drop)
  );

  /* this bridge admits only fetched control instructions or precise fault packets. */
  drg5_control #(.IRQ_ENABLED(0), .FORWARDING(0), .DIAGNOSTIC(0)) control (
    .debug_haltreq_i(1'b0), .debug_resumereq_i(1'b0), .debug_resethaltreq_i(1'b0),
    .debug_halted_o(unused_debug_halted), .debug_resumeack_o(unused_debug_resumeack), .debug_dpc_o(unused_debug_dpc), .debug_dcsr_o(unused_debug_dcsr), .debug_reg_valid_i(1'b0), .debug_reg_write_i(1'b0),
    .debug_reg_addr_i(16'b0), .debug_reg_wdata_i(32'b0), .debug_reg_ready_o(unused_debug_reg_ready),
    .debug_reg_rdata_o(unused_debug_reg_rdata), .debug_reg_error_o(unused_debug_reg_error),
    .clk_i(clk), .cold_reset_i(cold_reset), .isolated_i(1'b1), .hart_reset_i(1'b0), .hold_i(hold),
    .in_valid_i(fetch_valid && run_enable && bridge_enable), .in_ready_o(input_ready),
    .in_packet_i(bridge_packet), .flush_valid_i(1'b0), .flush_ready_o(unused_flush_ready),
    .flush_pc_i(32'b0), .flush_aborted_o(unused_flush_aborted),
    .redirect_valid_o(redirect_valid), .redirect_pc_o(redirect_pc),
    .d_req_valid_o(d_request_valid), .d_req_ready_i(1'b0), .d_req_addr_o(unused_d_addr),
    .d_req_wdata_o(unused_d_data), .d_req_write_o(unused_d_write), .d_req_size_o(unused_d_size),
    .d_req_wstrb_o(unused_d_mask), .d_req_tag_o(unused_d_tag), .d_rsp_valid_i(1'b0),
    .d_rsp_ready_o(unused_d_response_ready), .d_rsp_tag_i(32'b0), .d_rsp_rdata_i(32'b0),
    .d_rsp_status_i(2'b0), .mem_launch_o(unused_mem_launch), .mem_busy_o(unused_mem_busy),
    .fatal_o(control_fatal), .fatal_record_o(control_fatal_record), .stage_valid_o(stage_valid), .stage_token_o(stage_token),
    .transfer_o(unused_transfer), .kill_valid_o(unused_kill), .kill_uid_o(unused_kill_uid),
    .trace_o(trace_record), .inspect_reg_i(5'd1), .inspect_value_o(inspect_value),
    .inspect_defined_o(inspect_defined), .mstatus_o(unused_mstatus), .mtvec_o(unused_mtvec),
    .mscratch_o(unused_mscratch), .mepc_o(unused_mepc), .mcause_o(unused_mcause), .mtval_o(unused_mtval),
    .mip_levels_i(32'b0), .fetch_busy_i(1'b0),
    .entry_pending_o(unused_entry_pending), .idle_o(unused_idle), .irq_valid_o(unused_irq_valid),
    .irq_pc_o(unused_irq_pc), .irq_cause_o(unused_irq_cause), .mie_o(unused_mie), .mip_o(unused_mip),
    .mcountinhibit_o(unused_mcountinhibit), .mcycle_o(unused_mcycle), .minstret_o(unused_minstret)
  );

  /* delay acceptance independently from the post-acceptance response schedule. */
  function automatic int unsigned acceptance_delay(input logic [31:0] addr);
    return scenario == 2 && addr == 4 ? 18 : addr == 32'h100 ? 2 : 1;
  endfunction

  /* the wrong-path reply arrives after redirect in both accepted and offered cases. */
  function automatic int unsigned response_delay(input logic [31:0] addr);
    return scenario == 1 && addr == 4 ? 18 : addr == 32'h100 ? 3 : 1;
  endfunction

  /* target outputs depend only on its independent transaction record. */
  always_comb begin
    request_ready = target_active && !target_accepted &&
                    acceptance_wait >= acceptance_delay(target_addr) && !cold_reset;
    response_valid = response_pending && !cold_reset;
    response_tag = target_tag;
    response_parcels = target_parcels;
    response_data = captured_data;
    response_fault = captured_fault;
    response_status = captured_status;
  end

  /* every failure identifies the independent bridge checker. */
  task automatic check(input bit condition, input string label_text);
    checks = checks + 1;
    /* unrelated simulator exits never qualify as an intended detector. */
    if (!condition) $fatal(1, "CONTROL_FETCH_CHECK_FAILED %s case=%0d edge=%0d", label_text, scenario, edges);
  endtask

  /* sample handshakes before the edge and update the target only afterward. */
  task automatic cycle;
    bit req, accept, complete, launch, drop, redirect, stalled_w, output_blocked;
    logic [31:0] addr, tag;
    logic [1:0] parcels;
    #1;
    req = request_valid; accept = request_valid && request_ready;
    complete = response_valid && response_ready;
    launch = fetch_launch; drop = fetch_drop; redirect = redirect_valid;
    addr = request_addr; tag = request_tag; parcels = request_parcels;
    stalled_w = stage_valid[4] && stage_token[4].p.pc == 0 && hold[4];
    output_blocked = fetch_valid && !bridge_enable;
    /* the fixture independently observes manager handshakes and held packet identity. */
    if (!cold_reset) begin
      check(fetch_accept == accept && fetch_complete == complete, "handshake observations");
      check(!(launch && complete), "no completion-edge owner reuse");
      check(!redirect || !launch, "redirect prevents a new I offer");
      check(!fetch_fatal && fetch_fatal_reason == 0 && !control_fatal && control_fatal_record == '0 && !d_request_valid,
            "no fatal or data access");
      /* numerical stream changes cannot restore an already revoked owner. */
      if (target_active && target_stale) check(fetch_discard, "sticky stale request disposition");
      /* backpressure cannot turn the original JAL into a different packet. */
      if (output_blocked) begin
        check(fetch_pc == 0 && fetch_raw == 32'h100000ef && fetch_raw_valid == 15 &&
              fetch_kind == 2 && fetch_supported && fetch_length == 4 && !fetch_fault,
              "held original fetch packet");
      end
      /* any useful output belongs to the selected fetch generation. */
      if (fetch_valid) check(fetch_generation == current_generation, "active stream generation");
    end
    clk = 1; #1; clk = 0;
    edges = edges + 1;
    /* positive isolation is used only after all preceding modeled obligations drained. */
    if (!cold_reset) begin
      /* launch and first-valid observation are separate conservation counters. */
      if (launch) launches = launches + 1;
      /* redirect revokes the existing target record before same-edge completion. */
      if (redirect && target_active) begin
        target_stale = 1;
        /* scenario two specifically crosses redirect while acceptance is withheld. */
        if (!target_accepted && !accept && target_addr == 4) offered_across_redirect = 1;
        /* scenario one keeps a request accepted before its later stream revocation. */
        if (target_accepted && target_addr == 4) accepted_across_redirect = 1;
      end
      /* a live offered descriptor cannot disappear or change before acceptance. */
      if (target_active && !target_accepted) begin
        check(req && addr == target_addr && tag == target_tag && parcels == target_parcels,
              "nonwithdrawable I offer");
      end
      /* an accepted request cannot be offered again while awaiting its reply. */
      if (target_active && target_accepted) check(!req, "no duplicate accepted offer");
      /* a completed stale reply must drain without producing an architectural fault. */
      if (complete) begin
        check(target_active && target_accepted, "response owns an accepted request");
        check((drop ^ (mutate_stale_drop && scenario != 0 && target_addr == 4)) == target_stale,
              "live versus stale reply disposition");
        /* both delayed wrong-path errors must occur after actual invalidation. */
        if (scenario != 0 && target_addr == 4) begin
          check(target_stale && captured_fault == 3 && drop, "wrong-path access error discarded");
          stale_errors = stale_errors + 1;
        end
        target_active = 0; target_accepted = 0; response_pending = 0;
        completions = completions + 1;
      end
      /* target memory data are sampled once at physical acceptance. */
      else if (accept) begin
        check(target_active && !target_accepted, "single physical acceptance");
        target_accepted = 1;
        accepts = accepts + 1;
        response_wait = 0;
        captured_data = ram[target_addr[12:2]];
        captured_fault = 0; captured_status = 0;
        /* the allowed target rejects its requested beat without bus side effects. */
        if (scenario == 0 && target_addr == 32'h100) begin
          captured_data = 0; captured_fault = 3; captured_status = 1;
        end
        /* stale fault parcels remain canonical even though they will be discarded. */
        else if (scenario != 0 && target_addr == 4) begin
          captured_data = 0; captured_fault = 3;
        end
      end
      /* response latency starts only after the independently scheduled acceptance. */
      else if (target_active && target_accepted && !response_pending) begin
        /* hold the final response stable until the actual ready handshake. */
        if (response_wait >= response_delay(target_addr)) response_pending = 1;
        /* continue the independent response timer before its selected deadline. */
        else response_wait = response_wait + 1;
      end
      /* acceptance latency is independent of downstream instruction readiness. */
      else if (target_active && !target_accepted) acceptance_wait = acceptance_wait + 1;
      /* first valid creates exactly one responder-side offered record. */
      else if (req) begin
        check(addr < 8192 && addr[1:0] == 0 && parcels == 3 && tag == 32'(offers),
              "RAM request identity and width");
        /* target access cannot precede the source jump's architectural completion. */
        if (addr == 32'h100) check(normal_records == 1, "target fetch follows retired JAL");
        target_active = 1; target_accepted = 0; target_stale = redirect;
        target_addr = addr; target_tag = tag; target_parcels = parcels;
        acceptance_wait = 0;
        offers = offers + 1;
        /* prove that a wrong-path request existed, rather than merely assuming one. */
        if (addr == 4) wrongpath_offered = 1;
        /* first observation can coincide with revocation of an already presented offer. */
        if (redirect && addr == 4) offered_across_redirect = 1;
      end
      /* hold the real fetch packet for four clocks before allowing F admission. */
      if (output_blocked) begin
        held_output = held_output + 1;
        /* release only after repeated stable-output observations. */
        if (held_output == 4) bridge_enable = 1;
      end
      /* keep W occupied long enough to expose duplicate redirect or link commits. */
      if (stalled_w) begin
        held_writeback = held_writeback + 1;
        check(!trace_record.valid && !redirect_valid, "held W has no retirement or redirect");
        /* the release waits for a concrete wrong-path transaction. */
        if (held_writeback >= 5 && wrongpath_offered) hold[4] = 0;
      end
      /* the supplied sentinel is deliberately outside this control-only bridge. */
      if (trace_record.valid) begin
        check(inspect_defined && inspect_value == 4, "retired link retained");
        /* the source JAL retires before any target failure and writes its link once. */
        if (!trace_record.trap) begin
          check(trace_record.packet.pc == 0 && trace_record.packet.raw == 32'h100000ef &&
                trace_record.packet.raw_valid == 15 && trace_record.packet.length == 4 &&
                trace_record.rd_write && trace_record.rd == 1 && trace_record.value == 4 &&
                trace_record.next_pc == 32'h100 && redirect_valid && redirect_pc == 32'h100,
                "source JAL retirement");
          normal_records = normal_records + 1;
          jump_redirects = jump_redirects + 1;
        end
        /* target bus rejection and the successful-fetch sentinel have distinct faults. */
        else begin
          check(normal_records == 1 && trace_record.packet.pc == 32'h100 &&
                (trace_record.packet.cause ^ (mutate_target_fault && scenario == 0 ? 32'd1 : 32'd0)) ==
                (scenario == 0 ? 1 : 2) &&
                trace_record.packet.mtval == (scenario == 0 ? 32'h100 : 0) &&
                !trace_record.rd_write && redirect_valid && redirect_pc == 0,
                "target instruction owns its fault");
          check(trace_record.packet.raw_valid == (scenario == 0 ? 0 : 15) &&
                trace_record.packet.raw == (scenario == 0 ? 0 : 32'h00000013),
                "target raw-byte evidence");
          terminal_records = terminal_records + 1;
          trap_redirects = trap_redirects + 1;
          terminal_seen = 1;
          run_enable = 0;
        end
      end
      /* no autonomous redirect may appear without its same-edge terminal record. */
      if (redirect_valid) check(trace_record.valid, "redirect accompanies W disposition");
    end
  endtask

  /* each scenario starts from an isolated, empty pair of managers. */
  task automatic start_case(input int unsigned number);
    check(!target_active && !fetch_busy, "previous transaction drainage");
    scenario = number;
    run_enable = 0; bridge_enable = 0; hold = 5'b10000; cold_reset = 1;
    offers = 0; accepts = 0; completions = 0; launches = 0;
    normal_records = 0; terminal_records = 0; jump_redirects = 0; trap_redirects = 0;
    held_output = 0; held_writeback = 0; stale_errors = 0;
    wrongpath_offered = 0; terminal_seen = 0; offered_across_redirect = 0;
    accepted_across_redirect = 0;
    /* ordinary RAM words provide a non-control sentinel for this restricted bridge. */
    for (int word_index = 0; word_index < 2048; word_index = word_index + 1) ram[word_index] = 32'h00000013;
    ram[0] = 32'h100000ef;
    cycle(); cycle();
    cold_reset = 0;
    cycle(); cycle();
    check(stage_valid == 0, "reset empties control slots");
    run_enable = 1;
  endtask

  /* prove actual target errors and stale error drainage through the connected modules. */
  initial begin
    mutate_target_fault = $test$plusargs("mutate_target_fault");
    mutate_stale_drop = $test$plusargs("mutate_stale_drop");
    /* establish defined DUT state before checking the first empty boundary. */
    cold_reset = 1;
    cycle(); cycle();
    cold_reset = 0;
    cycle(); cycle();
    /* separate accepted and unaccepted wrong-path obligations around the redirect. */
    for (int test_case = 0; test_case < 3; test_case = test_case + 1) begin
      start_case(32'(test_case));
      /* a finite bound turns deadlock into an explicit failing fixture result. */
      for (int budget = 0; budget < 240 && !terminal_seen; budget = budget + 1) cycle();
      check(terminal_seen, "target terminal reached");
      /* continue clocking old obligations after the architectural terminal. */
      for (int drain = 0; drain < 80 && (target_active || fetch_busy || redirect_valid); drain = drain + 1) cycle();
      check(!target_active && !fetch_busy && stage_valid == 0, "terminal drainage");
      check(offers == accepts && accepts == completions && launches == offers,
            "independent I transaction conservation");
      check(normal_records == 1 && terminal_records == 1 && jump_redirects == 1 && trap_redirects == 1,
            "one source retirement and one target terminal");
      check(held_output == 4 && held_writeback >= 5 && wrongpath_offered, "nonvacuous backpressure");
      check(scenario == 0 || stale_errors == 1, "delayed stale error reached");
      check(scenario != 1 || accepted_across_redirect, "accepted request survives redirect");
      check(scenario != 2 || offered_across_redirect, "unaccepted offer survives redirect");
      $display("CONTROL_FETCH_CASE_PASS case=%0d offers=%0d accepted=%0d completed=%0d heldW=%0d stale_errors=%0d accepted_redirect=%0d offered_redirect=%0d",
               scenario, offers, accepts, completions, held_writeback, stale_errors,
               accepted_across_redirect, offered_across_redirect);
    end
    $display("CONTROL_FETCH_PASS cases=3 edges=%0d checks=%0d", edges, checks);
    $finish;
  end
endmodule

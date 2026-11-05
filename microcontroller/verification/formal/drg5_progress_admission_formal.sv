/* prove early admission and terminal progress under explicit finite service and no external flush. */
module drg5_progress_admission_formal #(
  parameter bit PROGRESS = 1,
  parameter bit SINGLE = 1,
  parameter integer CAPACITY = 32,
  parameter integer PROGRESS_BOUND = 32
) (
  input logic clk_i,
  input logic [4:0] watched,
  input logic input_valid_i,
  input logic [2:0] operation_i,
  input logic [7:0] value_i,
  input logic [4:0] holds_i,
  input logic flush_i, target_accept_i, target_response_i, target_error_i,
  output logic retirement_seen_o = 0, kill_seen_o = 0,
  output logic memory_seen_o = 0, overlap_seen_o = 0, stalled_seen_o = 0,
  output logic tracked_done_o = 0,
  output logic [5:0] tracked_age_o = 0
);
  import drg5_control_pkg::*;
  logic [1:0] boot = 0;
  logic [5:0] elapsed = 0;
  wire reset = boot != 2;
  logic [5:0] allocated = 0;
  logic [CAPACITY-1:0] live = 0, disposed = 0;
  logic [63:0] terminal_order = 0, last_terminal = 0;
  logic have_terminal = 0;
  logic expected_defined = 0;
  logic [31:0] expected_value = 0, expected_epc = 0, expected_cause = 0, expected_tval = 0;
  wire [4:0] selected = SINGLE ? 5'd0 : watched;
  logic [1:0] hold_age [0:4];
  packet_t packet;
  logic input_ready, request_valid, request_ready, response_ready;
  logic request_write, launch, busy, fatal;
  logic [31:0] request_address, request_data, request_tag;
  logic [1:0] request_size;
  logic [3:0] request_strobes;
  logic [4:0] valid, killed;
  token_t token [0:4];
  logic [63:0] killed_uid [0:4];
  trace_t terminal;
  logic [3:0] transfers;
  logic flush_ready;
  logic owned = 0, accepted = 0, owner_write = 0;
  logic [31:0] owner_tag = 0;
  logic [63:0] owner_uid = 0;
  logic [102:0] owner_descriptor = 0;
  logic [3:0] offer_age = 0, reply_age = 0;
  wire response_valid = target_response_i && owned && accepted;
  wire input_valid = input_valid_i && allocated < (SINGLE ? 1 : CAPACITY);
  wire [31:0] response_data = owner_write || target_error_i ? 32'b0 : 32'h87654321;
  wire [1:0] response_status = target_error_i ? 2'd1 : 2'd0;
  logic [CAPACITY-1:0] killed_mask;
  logic unused_entry, unused_idle, unused_irq, unused_flush_abort, unused_redirect;
  logic unused_defined, unused_debug_halted, unused_debug_ack, unused_debug_ready;
  logic [31:0] unused_irq_pc, unused_irq_cause, unused_redirect_pc, unused_inspect;
  logic [31:0] unused_status, unused_vector, unused_scratch, unused_epc, unused_cause, unused_tval;
  logic [31:0] unused_mie, unused_mip, unused_inhibit, unused_dpc, unused_dcsr, unused_debug_value;
  logic [2:0] unused_debug_error;
  logic [63:0] unused_cycle, unused_instret;
  fatal_record_t unused_fatal_record;

  /* the packet subset exercises transfers, effects, redirects and synchronous exceptions. */
  always_comb begin
    packet = '0;
    packet.pc = {24'b0, allocated, 2'b0};
    packet.raw = 32'h00000013;
    packet.raw_valid = 15;
    packet.length = 4;
    packet.next_pc = packet.pc + 4;
    packet.op = OP_RESULT;
    packet.rd = 1;
    packet.rd_write = 1;
    packet.result = {24'b0, value_i};
    packet.mem_addr = 32'h20000000;
    packet.mem_wdata = {24'b0, value_i};
    packet.mem_size = 2;
    /* trusted packets deliberately avoid making a raw decoder correctness claim. */
    case (operation_i)
      1: packet.op = OP_LOAD;
      /* stores preserve their data access without a register write. */
      2: begin packet.op = OP_STORE; packet.rd_write = 0; end
      /* redirect packets exercise younger instruction discard. */
      3: begin packet.op = OP_REDIRECT; packet.next_pc = 32'h10000; end
      /* fault packets exercise precise synchronous traps. */
      4: begin packet.fault = 1; packet.cause = 11; end
      /* fences serialize the memory owner. */
      5: begin packet.op = OP_FENCE; packet.rd_write = 0; end
      default: packet.op = OP_RESULT;
    endcase
    killed_mask = 0;
    /* the independent scoreboard receives registered disposition lanes only. */
    for (int stage = 0; stage < 5; stage++) begin
      if (killed[stage] && killed_uid[stage] < CAPACITY) killed_mask[killed_uid[stage][4:0]] = 1;
    end
  end
  assign request_ready = target_accept_i;

  /* instantiate the production overlapping controller without replacing its state machine. */
  drg5_control #(.DIAGNOSTIC(0), .FORWARDING(1), .D_MAX_WAIT_CYCLES(32)) dut (
    .clk_i, .cold_reset_i(reset), .isolated_i(1'b1), .hart_reset_i(1'b0),
    .mip_levels_i(32'b0), .fetch_busy_i(1'b0), .entry_pending_o(unused_entry), .idle_o(unused_idle),
    .irq_valid_o(unused_irq), .irq_pc_o(unused_irq_pc), .irq_cause_o(unused_irq_cause),
    .hold_i(holds_i), .in_valid_i(input_valid), .in_ready_o(input_ready), .in_packet_i(packet),
    .flush_valid_i(flush_i), .flush_ready_o(flush_ready), .flush_pc_i(32'h10000), .flush_aborted_o(unused_flush_abort),
    .redirect_valid_o(unused_redirect), .redirect_pc_o(unused_redirect_pc),
    .d_req_valid_o(request_valid), .d_req_ready_i(request_ready), .d_req_addr_o(request_address),
    .d_req_wdata_o(request_data), .d_req_write_o(request_write), .d_req_size_o(request_size),
    .d_req_wstrb_o(request_strobes), .d_req_tag_o(request_tag), .d_rsp_valid_i(response_valid),
    .d_rsp_ready_o(response_ready), .d_rsp_tag_i(owner_tag), .d_rsp_rdata_i(response_data), .d_rsp_status_i(response_status),
    .mem_launch_o(launch), .mem_busy_o(busy), .fatal_o(fatal), .fatal_record_o(unused_fatal_record),
    .stage_valid_o(valid), .stage_token_o(token), .transfer_o(transfers), .kill_valid_o(killed), .kill_uid_o(killed_uid),
    .trace_o(terminal), .inspect_reg_i(5'd1), .inspect_value_o(unused_inspect), .inspect_defined_o(unused_defined),
    .mstatus_o(unused_status), .mtvec_o(unused_vector), .mscratch_o(unused_scratch), .mepc_o(unused_epc),
    .mcause_o(unused_cause), .mtval_o(unused_tval), .mie_o(unused_mie), .mip_o(unused_mip), .mcountinhibit_o(unused_inhibit),
    .mcycle_o(unused_cycle), .minstret_o(unused_instret), .debug_haltreq_i(1'b0), .debug_resumereq_i(1'b0),
    .debug_resethaltreq_i(1'b0), .debug_halted_o(unused_debug_halted), .debug_resumeack_o(unused_debug_ack),
    .debug_dpc_o(unused_dpc), .debug_dcsr_o(unused_dcsr), .debug_reg_valid_i(1'b0), .debug_reg_write_i(1'b0),
    .debug_reg_addr_i(16'b0), .debug_reg_wdata_i(32'b0), .debug_reg_ready_o(unused_debug_ready),
    .debug_reg_rdata_o(unused_debug_value), .debug_reg_error_o(unused_debug_error)
  );

  /* assumptions describe the source and memory service, never the desired disposition. */
  always @(posedge clk_i) begin
    if (boot != 2) boot <= boot + 1'b1;
    elapsed <= elapsed + 1'b1;
    /* two-edge reset drains pre-reset kill reports and initializes the actual controller and the independent scoreboards. */
    if (reset) begin
      allocated <= 0;
      live <= 0;
      disposed <= 0;
      terminal_order <= 0;
      last_terminal <= 0;
      have_terminal <= 0;
      owned <= 0;
      accepted <= 0;
      offer_age <= 0;
      reply_age <= 0;
      /* progress fairness ages begin at their real reset values. */
      for (int stage = 0; stage < 5; stage++) hold_age[stage] <= 0;
    /* normal cycles retain all independent observation state. */
    end else begin
      /* this responsive environment permits no external flush after startup. */
      assume(!flush_i);
      /* two reset edges and recovery must admit the one offered packet by edge four. */
      if (elapsed >= 4) assert(allocated == 1);
      /* no external cancellation exists, so disposal must be a terminal event. */
      assert(!killed_mask[0]);
      /* the universally selected tracked identity remains constant for this run. */
      assume(watched == $past(watched));
      /* a source cannot withdraw or change a packet already offered under backpressure. */
      if ($past(input_valid && !input_ready && !reset)) begin
        assume(input_valid);
        assume(packet == $past(packet));
      end
      /* the isolated progress profile offers exactly one instruction immediately. */
      if (PROGRESS && SINGLE) begin
        assume(input_valid_i);
        assume(watched == 0);
      end
      /* only progress mode limits stalls; the safety proof allows indefinite holds. */
      for (int stage = 0; stage < 5; stage++) begin
        if (holds_i[stage]) hold_age[stage] <= hold_age[stage] + 1'b1;
        else hold_age[stage] <= 0;
        if (PROGRESS && hold_age[stage] == 2) assume(!holds_i[stage]);
      end
      /* targets may delay acceptance by two and responses by three sampled clocks. */
      if (PROGRESS && request_valid && offer_age == 2) assume(target_accept_i);
      if (PROGRESS && owned && accepted && reply_age == 3) assume(target_response_i);
      /* no second physical acceptance can belong to the same owner. */
      if (request_valid) begin
        if (!PROGRESS) assert(!accepted);
        /* first presentation records the descriptor before acceptance. */
        if (!owned) begin
          if (!PROGRESS) assert($past(launch));
          owned <= 1;
          owner_tag <= request_tag;
          owner_write <= request_write;
          owner_descriptor <= {request_address, request_data, request_write, request_size, request_strobes, request_tag};
        end
        /* acceptance starts the independent response deadline. */
        if (request_ready) begin accepted <= 1; offer_age <= 0; reply_age <= 0; end
        else offer_age <= offer_age + 1'b1;
      end
      /* the target remembers the accepted owner until its one terminal response. */
      if (owned && accepted) reply_age <= reply_age + 1'b1;
      /* a response releases the external target owner once. */
      if (response_valid && response_ready) begin owned <= 0; accepted <= 0; reply_age <= 0; end
      /* a held request cannot change, even if a redirect is selected meanwhile. */
      if ($past(request_valid && !request_ready && !reset)) begin
        if (!PROGRESS) assert(request_valid);
        if (!PROGRESS) assert({request_address, request_data, request_write, request_size, request_strobes, request_tag} ==
            $past({request_address, request_data, request_write, request_size, request_strobes, request_tag}));
      end
      /* acceptance never releases descriptor or instruction ownership before response. */
      if (owned) begin
        if (!PROGRESS) assert(busy && valid[3] && token[3].uid == owner_uid);
        if (!PROGRESS) assert({request_address, request_data, request_write, request_size, request_strobes, request_tag} == owner_descriptor);
      end
      /* launch reserves the first presentation cycle before the target observes valid. */
      if (busy) if (!PROGRESS) assert(owned || $past(launch));
      /* first exposure belongs to exactly one still-live memory instruction. */
      if (launch) begin
        if (!PROGRESS) assert(!owned && !busy);
        if (!PROGRESS) assert(valid[3] && live[token[3].uid[4:0]]);
        memory_seen_o <= 1;
        owner_uid <= token[3].uid;
      end
      /* progress checks omit the independent safety assertions already proved separately. */
      /* actual GPR state may change only with the corresponding terminal write. */
      if (!PROGRESS) assert(unused_defined == (expected_defined || (terminal.valid && terminal.rd_write)));
      /* retirement supplies the sole new value for the exercised destination. */
      if (terminal.valid && terminal.rd_write) begin
        if (!PROGRESS) assert(unused_inspect == terminal.value);
        expected_defined <= 1;
        expected_value <= terminal.value;
      /* undefined initial GPR data has no asserted reset value. */
      end else if (expected_defined) if (!PROGRESS) assert(unused_inspect == expected_value);
      /* machine trap state follows synchronous terminal events in this configuration. */
      if (terminal.valid && terminal.trap) begin
        if (!PROGRESS) assert(unused_epc == terminal.packet.pc);
        if (!PROGRESS) assert(unused_cause == terminal.packet.cause);
        if (!PROGRESS) assert(unused_tval == terminal.packet.mtval);
        expected_epc <= terminal.packet.pc;
        expected_cause <= terminal.packet.cause;
        expected_tval <= terminal.packet.mtval;
      /* no CSR instructions or interrupts may independently write these three fields. */
      end else begin
        if (!PROGRESS) assert(unused_epc == expected_epc);
        if (!PROGRESS) assert(unused_cause == expected_cause);
        if (!PROGRESS) assert(unused_tval == expected_tval);
      end
      /* successful dispositions and exceptions share one monotonically ordered terminal lane. */
      if (terminal.valid) begin
        if (!PROGRESS) assert(terminal.uid < allocated && terminal.uid < CAPACITY);
        if (!PROGRESS) assert(live[terminal.uid[4:0]] && !disposed[terminal.uid[4:0]]);
        if (!PROGRESS) assert(terminal.order == terminal_order);
        if (!PROGRESS) assert(!have_terminal || terminal.uid > last_terminal);
        if (!PROGRESS) assert(!killed_mask[terminal.uid[4:0]]);
        /* no older live instruction may be bypassed by this terminal. */
        for (int index = 0; index < CAPACITY; index++) begin
          if (index < terminal.uid) if (!PROGRESS) assert(!live[index] || killed_mask[index]);
        end
        if (terminal.trap) if (!PROGRESS) assert(!terminal.rd_write && !terminal.csr_write);
        live[terminal.uid[4:0]] <= 0;
        disposed[terminal.uid[4:0]] <= 1;
        terminal_order <= terminal_order + 1;
        last_terminal <= terminal.uid;
        have_terminal <= 1;
        retirement_seen_o <= 1;
      end
      /* every killed identity is disposed once and is never accepted as a later terminal. */
      for (int stage = 0; stage < 5; stage++) begin
        /* discard reports must refer to a live allocated identity. */
        if (killed[stage]) begin
          if (!PROGRESS) assert(killed_uid[stage] < allocated && killed_uid[stage] < CAPACITY);
          if (!PROGRESS) assert(live[killed_uid[stage][4:0]] && !disposed[killed_uid[stage][4:0]]);
          live[killed_uid[stage][4:0]] <= 0;
          disposed[killed_uid[stage][4:0]] <= 1;
          kill_seen_o <= 1;
        end
        /* holds preserve the owner; M may still capture its response while held. */
        if ($past(valid[stage] && holds_i[stage] && !reset) && !killed[stage]) begin
          if (!PROGRESS) assert(valid[stage] && token[stage].uid == $past(token[stage].uid));
          if (!PROGRESS) assert(stage == 3 || token[stage] == $past(token[stage]));
          if (!PROGRESS) assert(stage != 3 || {token[stage].p.pc, token[stage].p.raw, token[stage].p.mem_addr, token[stage].p.mem_wdata} ==
              $past({token[stage].p.pc, token[stage].p.raw, token[stage].p.mem_addr, token[stage].p.mem_wdata}));
          stalled_seen_o <= 1;
        end
      end
      /* input allocation is counted independently from the controller's UID register. */
      if (input_valid && input_ready) begin
        live[allocated[4:0]] <= 1;
        allocated <= allocated + 1'b1;
      end
      /* the one-edge reporting lag is explicit in independent instruction conservation. */
      if (!PROGRESS) assert($countones(live) == $countones(valid) + $countones(killed) + int'(terminal.valid));
      if ($countones(valid) >= 3) overlap_seen_o <= 1;
      /* one reachable run must include overlap, hold, memory, retirement and discard. */
      if (!SINGLE) cover(retirement_seen_o && kill_seen_o && memory_seen_o && overlap_seen_o && stalled_seen_o);
      /* the progress profile must reach a serviced, stalled memory instruction. */
      if (SINGLE) cover(tracked_done_o && memory_seen_o && stalled_seen_o && retirement_seen_o);
      /* a universally selected UID must retire or be discarded within the stated bound. */
      if (input_valid && input_ready && allocated == {1'b0, selected}) tracked_age_o <= 0;
      else if ((SINGLE && allocated != 0 && !tracked_done_o) || (!SINGLE && live[selected] && !disposed[selected])) tracked_age_o <= tracked_age_o + 1'b1;
      if ((terminal.valid && terminal.uid == {59'b0, selected}) || killed_mask[selected]) tracked_done_o <= 1;
      /* finite service must prevent timeout and bound every accepted instruction. */
      if (PROGRESS) begin
        assert(!fatal);
        if (allocated != 0 && !tracked_done_o) assert(tracked_age_o <= PROGRESS_BOUND);
      end
    end
  end
endmodule

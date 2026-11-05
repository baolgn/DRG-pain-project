/* retain each I request from first valid through delivery or contained discard. */
module drg5_fetch #(
  parameter bit C_FETCH = 0,
  parameter integer GEN_BITS = 8,
  parameter integer TAG_BITS = 32,
  parameter integer MAX_WAIT_CYCLES = 4,
  parameter bit TEST_REGIONS = 0,
  parameter logic [31:0] RESET_PC = 0
) (
  input logic clk_i, cold_reset_i, isolated_i, hart_reset_i, permit_i,
  input logic redirect_valid_i,
  input logic [31:0] redirect_pc_i,
  output logic i_req_valid_o,
  input logic i_req_ready_i,
  output logic [31:0] i_req_addr_o, i_req_tag_o,
  output logic [1:0] i_req_parcels_o,
  input logic i_rsp_valid_i,
  output logic i_rsp_ready_o,
  input logic [31:0] i_rsp_tag_i, i_rsp_data_i,
  input logic [1:0] i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i,
  output logic insn_valid_o,
  input logic insn_ready_i,
  output logic [31:0] insn_pc_o, insn_raw_o,
  output logic [3:0] insn_raw_valid_o,
  output logic [1:0] insn_length_kind_o,
  output logic insn_length_supported_o,
  output logic [2:0] insn_length_bytes_o,
  output logic [GEN_BITS-1:0] insn_generation_o,
  output logic insn_fault_o,
  output logic [31:0] insn_cause_o, insn_mtval_o,
  output logic busy_o, discard_o, fatal_o,
  output logic [2:0] fatal_reason_o,
  output logic [GEN_BITS-1:0] generation_o,
  output logic launch_o, accept_o, complete_o, drop_o
);
  localparam integer AGE_BITS = MAX_WAIT_CYCLES < 2 ? 1 : $clog2(MAX_WAIT_CYCLES + 1);
  localparam logic [1:0] FREE = 0, OFFER = 1, WAIT_RESPONSE = 2, RECOVER = 3;
  logic [1:0] state_q;
  logic [31:0] owner_addr_q, owner_tag_q;
  logic [1:0] owner_parcels_q;
  logic [GEN_BITS-1:0] generation_q, owner_generation_q, restart_generation;
  logic [TAG_BITS-1:0] next_tag_q;
  logic [AGE_BITS-1:0] age_q;
  logic discard_q, exhausted_q, fatal_q, reset_hold_q;
  logic [2:0] reason_q, event_reason;
  logic cold, invalidate, response, matching, bad_payload, bad_response, timeout;
  logic can_start, local_deny, tag_failure, fatal_event, live_fill;
  logic need_valid, fill_valid, buffer_reset;
  logic [31:0] need_addr, fill_addr, fill_data, restart_pc;
  logic [1:0] need_parcels, allowed, denied, fill_parcels, fill_fault;
  logic [GEN_BITS-1:0] fill_generation;

  /* a qualified cold reset is a positive old-traffic isolation boundary. */
  assign cold = cold_reset_i && isolated_i;
  assign invalidate = hart_reset_i || redirect_valid_i;
  assign restart_pc = hart_reset_i || cold ? RESET_PC : redirect_pc_i;
  assign restart_generation = cold ? {GEN_BITS{1'b0}} : generation_q + 1'b1;
  assign generation_o = generation_q;
  assign busy_o = state_q != FREE;
  assign discard_o = discard_q;
  assign i_req_valid_o = state_q == OFFER && !cold;
  assign i_req_addr_o = owner_addr_q;
  assign i_req_tag_o = owner_tag_q;
  assign i_req_parcels_o = owner_parcels_q;
  assign i_rsp_ready_o = !cold;
  assign accept_o = i_req_valid_o && i_req_ready_i;
  assign response = i_rsp_valid_i && i_rsp_ready_o;
  assign matching = response && (state_q == WAIT_RESPONSE || accept_o) &&
                    i_rsp_tag_i == owner_tag_q && i_rsp_parcels_i == owner_parcels_q;
  assign complete_o = matching;

  /* canonical replies distinguish precise rejection from broken ownership. */
  always_comb begin
    bad_payload = 0;
    /* successful parcel results cannot carry data in absent or faulted lanes. */
    if (i_rsp_status_i == 0) begin
      bad_payload = (i_rsp_fault_i & ~owner_parcels_q) != 0 ||
          ((!owner_parcels_q[0] || i_rsp_fault_i[0]) && i_rsp_data_i[15:0] != 0) ||
          ((!owner_parcels_q[1] || i_rsp_fault_i[1]) && i_rsp_data_i[31:16] != 0);
    end
    /* a proven whole-beat rejection faults every requested parcel with no data. */
    else if (i_rsp_status_i == 1) begin
      bad_payload = i_rsp_data_i != 0 || i_rsp_fault_i != owner_parcels_q;
    end
  end
  assign bad_response = response && (!matching || i_rsp_status_i[1] || bad_payload);
  assign timeout = (state_q == OFFER || state_q == WAIT_RESPONSE) && !matching &&
                   age_q == AGE_BITS'(MAX_WAIT_CYCLES - 1) && !cold;

  /* the guard sees the full address before any first-valid presentation. */
  drg5_fetch_guard #(.TEST_REGIONS(TEST_REGIONS)) guard (
    .word_addr_i(need_addr), .want_i(need_parcels), .allow_o(allowed)
  );
  assign denied = need_parcels & ~allowed;
  assign can_start = state_q == FREE && permit_i && !fatal_q && !bad_response && !reset_hold_q &&
                     !cold_reset_i && !hart_reset_i && !redirect_valid_i;
  assign local_deny = can_start && need_valid && denied != 0;
  assign tag_failure = can_start && need_valid && denied == 0 && exhausted_q;
  assign launch_o = can_start && need_valid && denied == 0 && !exhausted_q;
  assign fatal_event = bad_response || timeout || tag_failure || (cold_reset_i && !isolated_i);
  assign fatal_o = fatal_q || fatal_event;
  assign fatal_reason_o = fatal_q ? reason_q : event_reason;
  /* tag exhaustion is registered to avoid feeding need back into its own reset. */
  assign buffer_reset = cold || hart_reset_i || fatal_q || bad_response || timeout ||
                        (cold_reset_i && !isolated_i);
  assign live_fill = matching && !fatal_o && !discard_q && !invalidate &&
                     owner_generation_q == generation_q;
  assign drop_o = matching && !live_fill;

  /* preserve the first failure reason until isolated cold recovery. */
  always_comb begin
    event_reason = 0;
    /* unsafe reset requests do not authorize withdrawing an offered request. */
    if (cold_reset_i && !isolated_i) event_reason = 4;
    /* protocol failures remain fatal even for a stale stream. */
    else if (bad_response) event_reason = 1;
    /* a terminal matching response on the deadline edge defeats timeout. */
    else if (timeout) event_reason = 2;
    /* exhausted tags require isolation, never modulo reuse. */
    else if (tag_failure) event_reason = 3;
  end

  /* a local deny fills only denied parcels and never touches an external target. */
  always_comb begin
    fill_valid = local_deny || live_fill;
    fill_addr = local_deny ? need_addr : owner_addr_q;
    fill_generation = local_deny ? generation_q : owner_generation_q;
    fill_parcels = local_deny ? denied : owner_parcels_q;
    fill_data = local_deny ? 32'b0 : i_rsp_data_i;
    fill_fault = local_deny ? denied : i_rsp_fault_i;
  end

  /* the assembly window owns buffered parcels and the held instruction packet. */
  drg5_fetch_buffer #(.C_FETCH(C_FETCH), .GEN_BITS(GEN_BITS)) buffer (
    .clk_i, .reset_i(buffer_reset), .restart_i(redirect_valid_i),
    .restart_pc_i(restart_pc), .restart_generation_i(restart_generation),
    .fill_valid_i(fill_valid), .fill_addr_i(fill_addr), .fill_generation_i(fill_generation),
    .fill_parcels_i(fill_parcels), .fill_data_i(fill_data), .fill_fault_i(fill_fault),
    .need_valid_o(need_valid), .need_addr_o(need_addr), .need_parcels_o(need_parcels),
    .insn_valid_o, .insn_ready_i, .insn_pc_o, .insn_raw_o, .insn_raw_valid_o,
    .insn_length_kind_o, .insn_length_supported_o, .insn_length_bytes_o,
    .insn_generation_o, .insn_fault_o, .insn_cause_o, .insn_mtval_o
  );

  /* architectural redirects never reset the surviving transaction manager. */
  always_ff @(posedge clk_i) begin
    /* only positive isolation permits abandoning an old external obligation. */
    if (cold) begin
      state_q <= FREE;
      owner_addr_q <= 0;
      owner_tag_q <= 0;
      owner_parcels_q <= 0;
      owner_generation_q <= 0;
      generation_q <= 0;
      next_tag_q <= 0;
      age_q <= 0;
      discard_q <= 0;
      exhausted_q <= 0;
      fatal_q <= 0;
      reason_q <= 0;
      reset_hold_q <= 1;
    end
    /* keep acceptance and response accounting active during architectural reset. */
    else begin
      /* the first edge releasing reset cannot allocate a new external offer. */
      reset_hold_q <= hart_reset_i || cold_reset_i;
      /* sticky revocation survives any number of generation-counter wraps. */
      if (invalidate) begin
        generation_q <= generation_q + 1'b1;
        /* no live owner can regain permission through a later numerical alias. */
        if (state_q != FREE) discard_q <= 1;
      end
      /* fatal containment also revokes delivery without erasing bus ownership. */
      if (fatal_event) begin
        fatal_q <= 1;
        discard_q <= 1;
        /* later symptoms cannot erase the first diagnosed failure. */
        if (!fatal_q) reason_q <= event_reason;
      end
      /* launch reserves the exact descriptor and sink before valid becomes visible. */
      if (launch_o) begin
        state_q <= OFFER;
        owner_addr_q <= need_addr;
        owner_parcels_q <= need_parcels;
        owner_tag_q <= 32'(next_tag_q);
        owner_generation_q <= generation_q;
        next_tag_q <= next_tag_q + 1'b1;
        exhausted_q <= &next_tag_q;
        discard_q <= 0;
        age_q <= 0;
      end
      /* an accepted offer cannot be offered again while its response is pending. */
      else if (accept_o) begin
        state_q <= WAIT_RESPONSE;
      end
      /* capture ends a normal owner, or preserves a fatal recovery record. */
      if (matching) begin
        state_q <= fatal_o ? RECOVER : FREE;
      end
      /* saturating age counts all acceptance and response waiting edges. */
      if ((state_q == OFFER || state_q == WAIT_RESPONSE) && !matching &&
          age_q < AGE_BITS'(MAX_WAIT_CYCLES - 1)) begin
        age_q <= age_q + 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  /* reject unsupported elaboration settings before verification starts. */
  initial begin
    assert (GEN_BITS >= 1 && GEN_BITS <= 32 && TAG_BITS >= 1 && TAG_BITS <= 32 &&
            MAX_WAIT_CYCLES >= 1) else $fatal(1, "invalid fetch parameters");
  end
`endif
endmodule

/* observe settled architectural events without changing CPU execution or storing a trace buffer. */
module drg5_observe #(
  parameter integer SEQUENCE_BITS = 64,
  parameter integer EPOCH_BITS = 64,
  parameter integer RETIRED_BITS = 64
) (
  input logic clk_i, capture_reset_i,
  input logic cold_reset_i, isolated_i, hart_reset_i,
  input logic debug_mode_i, debug_ebreak_entry_i,
  input logic [4:0] hold_i, stage_valid_i,
  input logic [3:0] transfer_i,
  input drg5_control_pkg::token_t stage_token_i [0:4],
  input logic in_valid_i, in_ready_i,
  input drg5_control_pkg::packet_t in_packet_i,
  input logic [31:0] mip_levels_i,
  input logic [63:0] mcycle_i, minstret_i,
  input logic [31:0] mcountinhibit_i,
  input drg5_control_pkg::trace_t trace_i,
  input logic [4:0] kill_valid_i,
  input logic [63:0] kill_uid_i [0:4],
  input logic irq_valid_i, idle_i, fatal_i,
  input logic [31:0] irq_pc_i, irq_cause_i,
  input drg5_control_pkg::fatal_record_t fatal_record_i,
  input logic redirect_valid_i,
  input logic [31:0] redirect_pc_i,
  input logic flush_valid_i, flush_ready_i, flush_aborted_i,
  input logic [31:0] flush_pc_i,
  input logic mem_launch_i,
  input logic d_req_valid_i, d_req_ready_i, d_req_write_i,
  input logic [31:0] d_req_addr_i, d_req_wdata_i, d_req_tag_i,
  input logic [1:0] d_req_size_i,
  input logic [3:0] d_req_wstrb_i,
  input logic d_rsp_valid_i, d_rsp_ready_i,
  input logic [31:0] d_rsp_tag_i, d_rsp_rdata_i,
  input logic [1:0] d_rsp_status_i,
  input logic i_req_valid_i, i_req_ready_i,
  input logic [31:0] i_req_addr_i, i_req_tag_i,
  input logic [1:0] i_req_parcels_i,
  input logic i_rsp_valid_i, i_rsp_ready_i, i_drop_i,
  input logic [31:0] i_rsp_tag_i, i_rsp_data_i,
  input logic [1:0] i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i,
  output drg5_control_pkg::observe_t record_o
);
  import drg5_control_pkg::*;
  observe_t sampled_q;
  logic [SEQUENCE_BITS-1:0] sequence_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic [RETIRED_BITS-1:0] retired_q;
  logic [2:0] overflow_q;
  logic active_q, reset_active_q, current_retirement, retirement_overflow;
  logic unused_stage_payload;

  /* reduced widths exercise observation exhaustion without wrapping architectural counters. */
  initial begin
    assert (SEQUENCE_BITS >= 1 && SEQUENCE_BITS <= 64 && EPOCH_BITS >= 1 && EPOCH_BITS <= 64 &&
        RETIRED_BITS >= 1 && RETIRED_BITS <= 64) else $fatal(1, "invalid observation widths");
  end

  /* these stage payloads remain available through accepted and terminal packets. */
  assign unused_stage_payload = ^{stage_token_i[0], stage_token_i[1], stage_token_i[2],
                                  stage_token_i[3], stage_token_i[4]};
  assign current_retirement = trace_i.valid && !trace_i.trap;
  assign retirement_overflow = active_q && (&retired_q) && current_retirement;

  /* after the edge, registered core outputs pair with this edge's captured pre-state. */
  always_comb begin
    record_o = sampled_q;
    record_o.overflow = overflow_q | {retirement_overflow, 2'b0};
    record_o.valid = active_q && !(|record_o.overflow);
    record_o.sequence_id = 64'(sequence_q);
    record_o.epoch = 64'(epoch_q);
    record_o.retired_before = 64'(retired_q);
    record_o.retired_after = 64'(retired_q) + ((current_retirement && !retirement_overflow) ? 64'd1 : 64'b0);
    record_o.cycle_after = mcycle_i;
    record_o.instret_after = minstret_i;
    record_o.inhibit_after = mcountinhibit_i;
    record_o.terminal = trace_i;
    record_o.stages_after = stage_valid_i;
    record_o.kill_valid = kill_valid_i;
    /* UID lanes use stage order F, D, X, M, W from least significant to most. */
    for (int stage = 0; stage < 5; stage++) begin
      record_o.kill_uid[64*stage +: 64] = kill_uid_i[stage];
      record_o.stage_uid[64*stage +: 64] = stage_token_i[stage].uid;
    end
    record_o.irq = irq_valid_i;
    record_o.irq_pc = irq_pc_i;
    record_o.irq_cause = irq_cause_i;
    record_o.idle = idle_i;
    record_o.fatal = fatal_i;
    record_o.fatal_record = fatal_record_i;
    record_o.redirect = redirect_valid_i;
    record_o.redirect_pc = redirect_pc_i;
    record_o.flush_aborted = flush_aborted_i;
  end

  /* capture only pre-edge inputs; no core output is sampled a clock late into the record. */
  always_ff @(posedge clk_i) begin
    sampled_q <= '0;
    sampled_q.cold_reset <= cold_reset_i;
    sampled_q.hart_reset <= hart_reset_i;
    sampled_q.isolated <= isolated_i;
    sampled_q.debug_mode <= debug_mode_i;
    sampled_q.debug_ebreak_entry <= debug_ebreak_entry_i;
    sampled_q.hold <= hold_i;
    sampled_q.stages_before <= stage_valid_i;
    sampled_q.transfers <= transfer_i;
    sampled_q.input_accept <= in_valid_i && in_ready_i;
    sampled_q.input_packet <= in_packet_i;
    sampled_q.irq_levels <= mip_levels_i;
    sampled_q.cycle_before <= mcycle_i;
    sampled_q.instret_before <= minstret_i;
    sampled_q.inhibit_before <= mcountinhibit_i;
    sampled_q.flush_accept <= flush_valid_i && flush_ready_i;
    sampled_q.flush_pc <= flush_pc_i;
    sampled_q.d_launch <= mem_launch_i;
    sampled_q.d_launch_uid <= stage_token_i[3].uid;
    sampled_q.d_offer <= d_req_valid_i;
    sampled_q.d_accept <= d_req_valid_i && d_req_ready_i;
    sampled_q.d_response <= d_rsp_valid_i && d_rsp_ready_i;
    sampled_q.d_write <= d_req_write_i;
    sampled_q.d_addr <= d_req_addr_i;
    sampled_q.d_wdata <= d_req_wdata_i;
    sampled_q.d_tag <= d_req_tag_i;
    sampled_q.d_size <= d_req_size_i;
    sampled_q.d_strobes <= d_req_wstrb_i;
    sampled_q.d_response_tag <= d_rsp_tag_i;
    sampled_q.d_rdata <= d_rsp_rdata_i;
    sampled_q.d_status <= d_rsp_status_i;
    sampled_q.i_offer <= i_req_valid_i;
    sampled_q.i_accept <= i_req_valid_i && i_req_ready_i;
    sampled_q.i_addr <= i_req_addr_i;
    sampled_q.i_tag <= i_req_tag_i;
    sampled_q.i_parcels <= i_req_parcels_i;
    sampled_q.i_response <= i_rsp_valid_i && i_rsp_ready_i;
    sampled_q.i_response_tag <= i_rsp_tag_i;
    sampled_q.i_rdata <= i_rsp_data_i;
    sampled_q.i_response_parcels <= i_rsp_parcels_i;
    sampled_q.i_fault <= i_rsp_fault_i;
    sampled_q.i_status <= i_rsp_status_i;
    sampled_q.i_drop <= i_drop_i;
    reset_active_q <= cold_reset_i || hart_reset_i;
    /* rearming declares a new capture and requires a positively isolated CPU reset. */
    if (capture_reset_i) begin
      assert (cold_reset_i && isolated_i) else $fatal(1, "observation rearm requires isolated cold reset");
      sequence_q <= 0;
      epoch_q <= 0;
      retired_q <= 0;
      overflow_q <= 0;
      active_q <= 0;
    end
    /* an invalid capture stays invalid until the explicit new-session handshake. */
    else begin
      active_q <= 1;
      overflow_q <= record_o.overflow;
      /* sequence exhaustion reports loss without wrapping identity or stalling the CPU. */
      if (!(|record_o.overflow)) begin
        /* the next observed edge must have a distinct sequence number. */
        if (&sequence_q) overflow_q[0] <= 1;
        else sequence_q <= sequence_q + 1'b1;
        /* one epoch covers an entire asserted CPU-reset episode. */
        if ((cold_reset_i || hart_reset_i) && !reset_active_q) begin
          if (&epoch_q) overflow_q[1] <= 1;
          else epoch_q <= epoch_q + 1'b1;
        end
        /* accumulate the preceding settled terminal before presenting this edge's record. */
        if (active_q && current_retirement) retired_q <= retired_q + 1'b1;
      end
    end
  end
endmodule

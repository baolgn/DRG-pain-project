/* check fetch ownership with arbitrary latency, redirects and response contents. */
module drg5_fetch_formal #(
  parameter C_FETCH = 0,
  parameter MUTATE_DROP = 0
) (
  input clk_i, cold_reset_i, isolated_i, hart_reset_i, permit_i,
  input redirect_valid_i,
  input [31:0] redirect_pc_i,
  input i_req_ready_i, i_rsp_valid_i,
  input [31:0] i_rsp_tag_i, i_rsp_data_i,
  input [1:0] i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i,
  input insn_ready_i,
  output reg wrap_live_seen_o = 0
);
  wire i_req_valid_o, i_rsp_ready_o, insn_valid_o;
  wire [31:0] i_req_addr_o, i_req_tag_o;
  wire [1:0] i_req_parcels_o;
  wire [31:0] insn_pc_o, insn_raw_o, insn_cause_o, insn_mtval_o;
  wire [3:0] insn_raw_valid_o;
  wire [1:0] insn_length_kind_o, insn_generation_o, generation_o;
  wire [2:0] insn_length_bytes_o, fatal_reason_o;
  wire insn_length_supported_o, insn_fault_o;
  wire busy_o, discard_o, fatal_o, launch_o, accept_o, complete_o, drop_o;
  wire [140:0] packet = {insn_pc_o, insn_raw_o, insn_raw_valid_o,
      insn_length_kind_o, insn_length_supported_o, insn_length_bytes_o,
      insn_generation_o, insn_fault_o, insn_cause_o, insn_mtval_o};
  wire cold = cold_reset_i && isolated_i;
  reg past_valid = 0;
  reg revoked = 0;
  reg [1:0] owner_generation = 0;
  reg alias_seen = 0;
  reg [31:0] alias_tag = 0;
  wire alias_now = generation_o == owner_generation && busy_o && revoked && !fatal_o && !cold;

  /* short generations make numerical reuse reachable within the proof horizon. */
  drg5_fetch #(.C_FETCH(C_FETCH), .GEN_BITS(2), .TAG_BITS(4), .MAX_WAIT_CYCLES(8)) dut (
    .clk_i, .cold_reset_i, .isolated_i, .hart_reset_i, .permit_i,
    .redirect_valid_i, .redirect_pc_i, .i_req_valid_o, .i_req_ready_i,
    .i_req_addr_o, .i_req_tag_o, .i_req_parcels_o, .i_rsp_valid_i, .i_rsp_ready_o,
    .i_rsp_tag_i, .i_rsp_data_i, .i_rsp_parcels_i, .i_rsp_fault_i, .i_rsp_status_i,
    .insn_valid_o, .insn_ready_i, .insn_pc_o, .insn_raw_o, .insn_raw_valid_o,
    .insn_length_kind_o, .insn_length_supported_o, .insn_length_bytes_o,
    .insn_generation_o, .insn_fault_o, .insn_cause_o, .insn_mtval_o,
    .busy_o, .discard_o, .fatal_o, .fatal_reason_o, .generation_o,
    .launch_o, .accept_o, .complete_o, .drop_o
  );

  /* only the initial isolated reset is assumed; target progress is unrestricted. */
  always @(posedge clk_i) begin
    past_valid <= 1;
    /* initialize through the actual reset interface, not assumed DUT state. */
    if (!past_valid) assume(cold);
    /* the reference revocation bit ignores numerical generation equality. */
    if (cold || launch_o) revoked <= 0;
    /* once revoked, this owner remains revoked until a fresh isolated launch. */
    else if (hart_reset_i || redirect_valid_i || fatal_o) revoked <= 1;
    /* remember the generation assigned to each newly reserved owner. */
    if (launch_o) owner_generation <= generation_o;
    /* a fresh owner cannot inherit an earlier alias witness. */
    if (cold || launch_o) alias_seen <= 0;
    /* capture the still-live owner when its revoked generation becomes equal again. */
    else if (alias_now) begin
      alias_seen <= 1;
      alias_tag <= i_req_tag_o;
    end

    /* all observable-state checks follow the initial qualified reset. */
    if (past_valid) begin
      /* require a nonfatal matching drop from that same numerically aliased owner. */
      if ((alias_seen || alias_now) && complete_o && drop_o && !fatal_o && !cold &&
          (alias_now || i_rsp_tag_i == alias_tag)) begin
        wrap_live_seen_o <= 1;
      end
      /* a stalled offer survives every event except positive isolation. */
      if ($past(i_req_valid_o && !i_req_ready_i) && !cold) begin
        assert(i_req_valid_o);
        assert({i_req_addr_o, i_req_tag_o, i_req_parcels_o} ==
               $past({i_req_addr_o, i_req_tag_o, i_req_parcels_o}));
      end
      /* an unconsumed instruction survives until an explicitly killing event. */
      if ($past(insn_valid_o && !insn_ready_i) && !cold && !hart_reset_i &&
          !redirect_valid_i && !fatal_o) begin
        assert(insn_valid_o);
        assert(packet == $past(packet));
      end
      /* numerical generation reuse never restores a revoked response. */
      if (complete_o && (revoked || hart_reset_i || redirect_valid_i || fatal_o)) begin
        assert(drop_o != MUTATE_DROP);
      end
      /* current output is always from the active, nonredirected generation. */
      if (insn_valid_o) begin
        assert(insn_generation_o == generation_o);
        assert(!cold && !hart_reset_i && !redirect_valid_i && !fatal_o);
      end
      /* a capture cannot allocate a new transaction on the same edge. */
      assert(!(launch_o && complete_o));
      /* an occupied owner prevents allocation independently of reply arrival. */
      assert(!(launch_o && busy_o));
      /* only the declared ordinary ROM/RAM can receive physical I requests. */
      if (i_req_valid_o) begin
        assert(i_req_addr_o[1:0] == 0 && i_req_parcels_o != 0);
        assert(i_req_addr_o[31:13] == 0 || i_req_addr_o[31:16] == 16'h0001);
      end
      /* both reset assertion and its first release edge prohibit a new offer. */
      if (cold_reset_i || hart_reset_i || $past(cold_reset_i || hart_reset_i)) begin
        assert(!launch_o);
      end
    end
  end
endmodule

/* preserve fetched identity and faults at the raw-machine pipeline boundary. */
module drg5_frontend #(
  parameter bit C_ENABLED = 0,
  parameter integer GEN_BITS = 8,
  parameter integer TAG_BITS = 32,
  parameter integer MAX_WAIT_CYCLES = 4,
  parameter bit TEST_REGIONS = 0,
  parameter logic [31:0] RESET_PC = 0
) (
  input logic clk_i, cold_reset_i, isolated_i, hart_reset_i, permit_i,
  input logic entry_pending_i, core_fatal_i,
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
  output drg5_control_pkg::packet_t insn_packet_o,
  output logic [GEN_BITS-1:0] insn_generation_o,
  output logic busy_o, discard_o, fatal_o,
  output logic [2:0] fatal_reason_o,
  output logic [GEN_BITS-1:0] generation_o,
  output logic launch_o, accept_o, complete_o, drop_o
);
  import drg5_control_pkg::*;
  logic fetch_valid, fetch_ready, supported, fault;
  logic [31:0] pc, raw, cause, mtval;
  logic [3:0] raw_valid;
  logic [2:0] length;
  logic [1:0] unused_length_kind;

  /* stop new launches before entry while owned requests keep their manager. */
  drg5_fetch #(.C_FETCH(C_ENABLED), .GEN_BITS(GEN_BITS), .TAG_BITS(TAG_BITS),
      .MAX_WAIT_CYCLES(MAX_WAIT_CYCLES), .TEST_REGIONS(TEST_REGIONS), .RESET_PC(RESET_PC)) fetch (
    .clk_i, .cold_reset_i, .isolated_i, .hart_reset_i,
    .permit_i(permit_i && !entry_pending_i && !core_fatal_i), .redirect_valid_i, .redirect_pc_i,
    .i_req_valid_o, .i_req_ready_i, .i_req_addr_o, .i_req_tag_o, .i_req_parcels_o,
    .i_rsp_valid_i, .i_rsp_ready_o, .i_rsp_tag_i, .i_rsp_data_i, .i_rsp_parcels_i,
    .i_rsp_fault_i, .i_rsp_status_i, .insn_valid_o(fetch_valid), .insn_ready_i(fetch_ready),
    .insn_pc_o(pc), .insn_raw_o(raw), .insn_raw_valid_o(raw_valid),
    .insn_length_kind_o(unused_length_kind), .insn_length_supported_o(supported),
    .insn_length_bytes_o(length), .insn_generation_o, .insn_fault_o(fault),
    .insn_cause_o(cause), .insn_mtval_o(mtval), .busy_o, .discard_o, .fatal_o,
    .fatal_reason_o, .generation_o, .launch_o, .accept_o, .complete_o, .drop_o
  );

  /* a fetched packet has no trusted execution annotations or supplied expansion. */
  always_comb begin
    insn_packet_o = '0;
    insn_packet_o.op = OP_MACHINE;
    insn_packet_o.pc = pc;
    insn_packet_o.raw = raw;
    insn_packet_o.raw_valid = raw_valid;
    insn_packet_o.length = length;
    insn_packet_o.fault = fault || !supported;
    insn_packet_o.cause = fault ? cause : !supported ? 32'd2 : 32'b0;
    insn_packet_o.mtval = fault ? mtval : 32'b0;
    insn_valid_o = fetch_valid && !core_fatal_i;
    fetch_ready = insn_ready_i && !core_fatal_i;
  end
endmodule

/* bridge a standard JTAG DTM to one clocked DMI owner. */
module drg5_debug_transport #(
  /* this development ID is unassigned; a physical release must supply its assigned IDCODE. */
  parameter logic [31:0] IDCODE = 32'h00000001
) (
  input logic clk_i, power_reset_i,
  input logic tck_i, tms_i, tdi_i,
  output logic tdo_o,
  output logic dmi_req_valid_o,
  input logic dmi_req_ready_i,
  output logic [6:0] dmi_req_addr_o,
  output logic [31:0] dmi_req_data_o,
  output logic [1:0] dmi_req_op_o,
  input logic dmi_rsp_valid_i,
  output logic dmi_rsp_ready_o,
  input logic [31:0] dmi_rsp_data_i,
  input logic [1:0] dmi_rsp_op_i
);
  /* the TAP remains independent of the system clock and hart reset. */
  typedef enum logic [3:0] {
    TEST_RESET, RUN_IDLE, SELECT_DR, CAPTURE_DR, SHIFT_DR, EXIT1_DR, PAUSE_DR,
    EXIT2_DR, UPDATE_DR, SELECT_IR, CAPTURE_IR, SHIFT_IR, EXIT1_IR, PAUSE_IR,
    EXIT2_IR, UPDATE_IR
  } tap_state_t;
  tap_state_t tap_q, tap_next;
  logic [4:0] ir_q, ir_shift_q;
  logic [40:0] dr_shift_q, request_payload_q;
  logic bypass_q, request_toggle_q, response_toggle_q;
  (* async_reg = "true" *) logic response_meta_q, response_sync_q;
  (* async_reg = "true" *) logic request_meta_q, request_sync_q;
  logic response_seen_q, request_seen_q;
  logic [31:0] response_data_q, last_data_q;
  logic [1:0] response_op_q, status_q;
  logic [6:0] last_addr_q;
  logic discard_q, bridge_wait_q, bridge_offer_q;
  logic busy, tdo_next, fresh_response;
  logic [1:0] effective_status;
  logic [31:0] effective_data;
  logic [31:0] dtmcs;

  /* bundled payloads stay stable from toggle launch through synchronized acknowledgement. */
  assign busy = request_toggle_q != response_sync_q;
  assign dmi_req_valid_o = bridge_offer_q;
  assign dmi_rsp_ready_o = bridge_wait_q;
  assign fresh_response = response_sync_q != response_seen_q && !discard_q;
  assign effective_status = status_q != 0 ? status_q :
      fresh_response && response_op_q != 0 ? 2'd2 : 2'd0;
  assign effective_data = fresh_response ? response_data_q : last_data_q;
  assign dtmcs = 32'h00005071 | (32'(effective_status) << 10);

  /* every unimplemented instruction selects the one-bit BYPASS register. */
  always_comb begin
    tdo_next = 0;
    if (tap_q == SHIFT_IR) tdo_next = ir_shift_q[0];
    /* select the current data-register serial output. */
    else if (tap_q == SHIFT_DR) begin
      if (ir_q == 5'h01 || ir_q == 5'h10 || ir_q == 5'h11) tdo_next = dr_shift_q[0];
      else tdo_next = bypass_q;
    end
  end

  /* TDO changes only on falling TCK and remains stable through the sampling edge. */
  always_ff @(negedge tck_i or posedge power_reset_i) begin
    if (power_reset_i) tdo_o <= 0;
    else tdo_o <= tdo_next;
  end

  /* IEEE 1149.1 TAP transitions preserve pending DMI work through TAP reset. */
  always_comb begin
    case (tap_q)
      TEST_RESET: tap_next = tms_i ? TEST_RESET : RUN_IDLE;
      RUN_IDLE: tap_next = tms_i ? SELECT_DR : RUN_IDLE;
      SELECT_DR: tap_next = tms_i ? SELECT_IR : CAPTURE_DR;
      CAPTURE_DR: tap_next = tms_i ? EXIT1_DR : SHIFT_DR;
      SHIFT_DR: tap_next = tms_i ? EXIT1_DR : SHIFT_DR;
      EXIT1_DR: tap_next = tms_i ? UPDATE_DR : PAUSE_DR;
      PAUSE_DR: tap_next = tms_i ? EXIT2_DR : PAUSE_DR;
      EXIT2_DR: tap_next = tms_i ? UPDATE_DR : SHIFT_DR;
      UPDATE_DR: tap_next = tms_i ? SELECT_DR : RUN_IDLE;
      SELECT_IR: tap_next = tms_i ? TEST_RESET : CAPTURE_IR;
      CAPTURE_IR: tap_next = tms_i ? EXIT1_IR : SHIFT_IR;
      SHIFT_IR: tap_next = tms_i ? EXIT1_IR : SHIFT_IR;
      EXIT1_IR: tap_next = tms_i ? UPDATE_IR : PAUSE_IR;
      PAUSE_IR: tap_next = tms_i ? EXIT2_IR : PAUSE_IR;
      EXIT2_IR: tap_next = tms_i ? UPDATE_IR : SHIFT_IR;
      UPDATE_IR: tap_next = tms_i ? SELECT_DR : RUN_IDLE;
      default: tap_next = TEST_RESET;
    endcase
  end

  /* the system side never withdraws an offered request or reuses its response slot. */
  always_ff @(posedge clk_i or posedge power_reset_i) begin
    /* power reset initializes both toggle generations. */
    if (power_reset_i) begin
      request_meta_q <= 0;
      request_sync_q <= 0;
      request_seen_q <= 0;
      response_toggle_q <= 0;
      response_data_q <= 0;
      response_op_q <= 0;
      bridge_wait_q <= 0;
      bridge_offer_q <= 0;
      dmi_req_addr_o <= 0;
      dmi_req_data_o <= 0;
      dmi_req_op_o <= 0;
    /* synchronize new request identity before descriptor capture. */
    end else begin
      request_meta_q <= request_toggle_q;
      request_sync_q <= request_meta_q;
      /* two synchronizer stages precede capture of the stable bundled descriptor. */
      if (!bridge_offer_q && !bridge_wait_q && request_sync_q != request_seen_q) begin
        request_seen_q <= request_sync_q;
        dmi_req_addr_o <= request_payload_q[40:34];
        dmi_req_data_o <= request_payload_q[33:2];
        dmi_req_op_o <= request_payload_q[1:0];
        bridge_offer_q <= 1;
      end
      /* acceptance transfers ownership to the response wait state exactly once. */
      if (bridge_offer_q && dmi_req_ready_i) begin
        bridge_offer_q <= 0;
        bridge_wait_q <= 1;
      end
      /* response data remains stable until the next distinct request completes. */
      if (bridge_wait_q && dmi_rsp_valid_i) begin
        bridge_wait_q <= 0;
        response_data_q <= dmi_rsp_data_i;
        response_op_q <= dmi_rsp_op_i;
        response_toggle_q <= request_seen_q;
      end
    end
  end

  /* the transport sticky state never retries a transaction after any reset. */
  always_ff @(posedge tck_i or posedge power_reset_i) begin
    /* initialize TAP and logical response history. */
    if (power_reset_i) begin
      tap_q <= TEST_RESET;
      ir_q <= 5'h01;
      ir_shift_q <= 5'h01;
      dr_shift_q <= 0;
      bypass_q <= 0;
      request_payload_q <= 0;
      request_toggle_q <= 0;
      response_meta_q <= 0;
      response_sync_q <= 0;
      response_seen_q <= 0;
      last_data_q <= 0;
      last_addr_q <= 0;
      status_q <= 0;
      discard_q <= 0;
    /* advance TAP and synchronize response identity. */
    end else begin
      tap_q <= tap_next;
      response_meta_q <= response_toggle_q;
      response_sync_q <= response_meta_q;
      /* synchronized completion cannot overwrite a sticky busy/failure condition. */
      if (response_sync_q != response_seen_q) begin
        response_seen_q <= response_sync_q;
        discard_q <= 0;
        /* publish a completion only in its original transport generation. */
        if (!discard_q) begin
          last_data_q <= response_data_q;
          if (status_q == 0 && response_op_q != 0) status_q <= 2;
        end
      end
      /* TAP reset restores IDCODE without cancelling the owned DMI transfer. */
      if (tap_next == TEST_RESET) ir_q <= 5'h01;
      if (tap_q == CAPTURE_IR) ir_shift_q <= 5'h01;
      if (tap_q == SHIFT_IR) ir_shift_q <= {tdi_i, ir_shift_q[4:1]};
      if (tap_q == UPDATE_IR) ir_q <= ir_shift_q;
      /* capture is the deadline at which the preceding DMI response must be ready. */
      if (tap_q == CAPTURE_DR) begin
        case (ir_q)
          5'h01: dr_shift_q <= {9'b0, IDCODE};
          5'h10: dr_shift_q <= {9'b0, dtmcs};
          /* capture completion data and sticky status together. */
          5'h11: begin
            dr_shift_q <= {last_addr_q, effective_data, effective_status != 0 ? effective_status : busy ? 2'd3 : 2'd0};
            if (effective_status == 0 && busy) status_q <= 3;
          end
          default: bypass_q <= 0;
        endcase
      end
      /* narrow data registers shift through their actual length. */
      if (tap_q == SHIFT_DR) begin
        if (ir_q == 5'h11) dr_shift_q <= {tdi_i, dr_shift_q[40:1]};
        else if (ir_q == 5'h01 || ir_q == 5'h10) dr_shift_q <= {9'b0, tdi_i, dr_shift_q[31:1]};
        else bypass_q <= tdi_i;
      end
      /* reset controls change transport bookkeeping only, never DM/device effects. */
      if (tap_q == UPDATE_DR && ir_q == 5'h10) begin
        if (dr_shift_q[16]) status_q <= 0;
        /* clear history while retaining any physical orphan. */
        if (dr_shift_q[17]) begin
          status_q <= 0;
          last_data_q <= 0;
          last_addr_q <= 0;
          discard_q <= busy;
        end
      end
      /* a hard-reset orphan drains before the bridge can be reused. */
      if (tap_q == UPDATE_DR && ir_q == 5'h11 && dr_shift_q[1:0] != 0 && effective_status == 0) begin
        if (busy) status_q <= 3;
        else if (dr_shift_q[1:0] == 3) status_q <= 2;
        /* launch a distinct stable request only when the bridge is free. */
        else begin
          request_payload_q <= dr_shift_q;
          request_toggle_q <= !request_toggle_q;
          last_addr_q <= dr_shift_q[40:34];
        end
      end
    end
  end
endmodule

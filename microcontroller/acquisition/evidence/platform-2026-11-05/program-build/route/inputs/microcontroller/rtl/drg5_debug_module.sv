/* implement the single-hart debug 1.0 DM outside the CPU. */
module drg5_debug_module (
  input logic clk_i, power_reset_i,
  input logic hart_reset_i, system_reset_pending_i, hart_unavailable_i, hart_halted_i, hart_resumeack_i,
  output logic haltreq_o, resumereq_o, resethaltreq_o, ndmreset_o,
  output logic debug_reg_valid_o, debug_reg_write_o,
  output logic [15:0] debug_reg_addr_o,
  output logic [31:0] debug_reg_wdata_o,
  input logic debug_reg_ready_i,
  input logic [31:0] debug_reg_rdata_i,
  input logic [2:0] debug_reg_error_i,
  input logic dmi_req_valid_i,
  output logic dmi_req_ready_o,
  input logic [6:0] dmi_req_addr_i,
  input logic [31:0] dmi_req_data_i,
  input logic [1:0] dmi_req_op_i,
  output logic dmi_rsp_valid_o,
  input logic dmi_rsp_ready_i,
  output logic [31:0] dmi_rsp_data_o,
  output logic [1:0] dmi_rsp_op_o,
  output logic sb_req_valid_o,
  input logic sb_req_ready_i,
  output logic sb_req_write_o,
  output logic [31:0] sb_req_addr_o, sb_req_wdata_o,
  output logic [1:0] sb_req_size_o,
  output logic [3:0] sb_req_wstrb_o,
  input logic sb_rsp_valid_i,
  output logic sb_rsp_ready_o,
  input logic [31:0] sb_rsp_rdata_i,
  input logic [2:0] sb_rsp_error_i
);
  /* accepted SBA descriptors remain owned through their terminal response. */
  typedef enum logic [1:0] {SB_FREE, SB_OFFER, SB_WAIT} sb_state_t;
  sb_state_t sb_state_q;
  logic active_q, deactivate_q, halt_q, resume_q, resumeack_q, resethalt_q;
  logic ndmreset_q, havereset_q, abstract_busy_q, abstract_write_q;
  logic [15:0] abstract_addr_q;
  logic [31:0] abstract_data_q, data_q;
  logic [2:0] cmderr_q, sb_error_q, sb_access_q;
  logic sb_busyerror_q, sb_readaddr_q, sb_readdata_q, sb_increment_q;
  logic [31:0] sb_address_q, sb_data_q, owner_address_q, owner_data_q;
  logic owner_write_q, owner_increment_q;
  logic [1:0] owner_size_q;
  logic accept, read_access, write_access, revoke, sb_busy, unavailable, new_halt;
  logic sb_start, sb_start_write;
  logic [31:0] sb_start_address, sb_start_data, read_value, sb_shifted;
  logic [2:0] sb_start_error;

  /* DMI responses are held until accepted; no request is executed twice. */
  assign dmi_req_ready_o = !dmi_rsp_valid_o;
  assign accept = dmi_req_valid_i && dmi_req_ready_o;
  assign read_access = accept && dmi_req_op_i == 1;
  assign write_access = accept && dmi_req_op_i == 2;
  assign revoke = write_access && dmi_req_addr_i == 7'h10 && !dmi_req_data_i[0];
  assign new_halt = write_access && dmi_req_addr_i == 7'h10 && dmi_req_data_i[0] &&
      dmi_req_data_i[31] && active_q && !abstract_busy_q;
  assign sb_busy = sb_state_q != SB_FREE;
  assign unavailable = hart_unavailable_i || hart_reset_i || system_reset_pending_i || ndmreset_q;
  assign haltreq_o = active_q && !deactivate_q && !revoke && (halt_q || new_halt);
  assign resethaltreq_o = active_q && !deactivate_q && !revoke && resethalt_q;
  assign ndmreset_o = active_q && ndmreset_q;
  /* a queued resume cannot pass an owned SBA access or a revoked DM generation. */
  assign resumereq_o = active_q && !deactivate_q && !revoke && resume_q &&
      !halt_q && !new_halt && !abstract_busy_q && !sb_busy && !unavailable;
  assign debug_reg_valid_o = active_q && !deactivate_q && !revoke && abstract_busy_q && !unavailable;
  assign debug_reg_write_o = abstract_write_q;
  assign debug_reg_addr_o = abstract_addr_q;
  assign debug_reg_wdata_o = abstract_data_q;
  assign sb_req_valid_o = sb_state_q == SB_OFFER;
  assign sb_req_write_o = owner_write_q;
  assign sb_req_addr_o = owner_address_q;
  assign sb_req_size_o = owner_size_q;
  assign sb_req_wdata_o = owner_data_q << (8 * owner_address_q[1:0]);
  assign sb_req_wstrb_o = !owner_write_q ? 4'b0 : (owner_size_q == 0 ? 4'b0001 :
      owner_size_q == 1 ? 4'b0011 : 4'b1111) << owner_address_q[1:0];
  assign sb_rsp_ready_o = sb_state_q == SB_WAIT;
  assign sb_shifted = sb_rsp_rdata_i >> (8 * owner_address_q[1:0]);

  /* absent DMI registers read zero; command fields are write-only. */
  always_comb begin
    read_value = 0;
    /* inactive state exposes only activation state. */
    if (dmi_req_addr_i == 7'h10) read_value = {30'b0, ndmreset_q, active_q};
    /* capability fields and live hart status remain responsive during hart reset. */
    else if (active_q && !deactivate_q) begin
      case (dmi_req_addr_i)
        7'h04: read_value = abstract_busy_q ? 32'b0 : data_q;
        /* report reset, acknowledgement and exactly one live hart state. */
        7'h11: begin
          read_value = 32'h000000a3;
          read_value[24] = ndmreset_q || hart_reset_i || system_reset_pending_i;
          read_value[19:18] = {2{havereset_q}};
          read_value[17:16] = {2{resumeack_q}};
          read_value[13:12] = {2{unavailable}};
          read_value[11:10] = {2{!unavailable && !hart_halted_i}};
          read_value[9:8] = {2{!unavailable && hart_halted_i}};
        end
        7'h16: read_value = {19'b0, abstract_busy_q, 1'b0, cmderr_q, 4'b0, 4'd1};
        /* advertise supported bus widths and sticky access status. */
        7'h38: begin
          read_value = 32'h20000407;
          read_value[22] = sb_busyerror_q;
          read_value[21] = sb_busy;
          read_value[20] = sb_readaddr_q;
          read_value[19:17] = sb_access_q;
          read_value[16] = sb_increment_q;
          read_value[15] = sb_readdata_q;
          read_value[14:12] = sb_error_q;
        end
        7'h39: read_value = sb_address_q;
        7'h3c: read_value = sb_busy || sb_busyerror_q || sb_error_q != 0 ? 32'b0 : sb_data_q;
        default: read_value = 0;
      endcase
    end
  end

  /* size and alignment reject before platform permissions or physical exposure. */
  always_comb begin
    sb_start = 0;
    sb_start_write = 0;
    sb_start_address = sb_address_q;
    sb_start_data = dmi_req_data_i;
    /* sticky errors suppress new effects without replacing the first error. */
    if (active_q && !deactivate_q && !sb_busy && !sb_busyerror_q && sb_error_q == 0) begin
      /* address-triggered reads use the newly written byte address. */
      if (write_access && dmi_req_addr_i == 7'h39 && sb_readaddr_q) begin
        sb_start = 1;
        sb_start_address = dmi_req_data_i;
      end
      /* data-triggered reads return the previous value before launching the next. */
      if (dmi_req_addr_i == 7'h3c && (write_access || (read_access && sb_readdata_q))) begin
        sb_start = 1;
        sb_start_write = write_access;
      end
    end
    sb_start_error = 0;
    /* unsupported widths outrank alignment and unavailable-platform errors. */
    if (sb_access_q > 2) sb_start_error = 4;
    else if ((sb_access_q == 1 && sb_start_address[0]) ||
             (sb_access_q == 2 && |sb_start_address[1:0])) sb_start_error = 3;
    else if (unavailable || resume_q) sb_start_error = 2;
  end

  /* reset requests revoke uncommitted actions but retain exposed SBA ownership. */
  always_ff @(posedge clk_i) begin
    /* power reset requires platform-wide isolation and resets every debug domain. */
    if (power_reset_i) begin
      active_q <= 0;
      deactivate_q <= 0;
      halt_q <= 0;
      resume_q <= 0;
      resumeack_q <= 0;
      resethalt_q <= 0;
      ndmreset_q <= 0;
      havereset_q <= 0;
      abstract_busy_q <= 0;
      abstract_write_q <= 0;
      abstract_addr_q <= 0;
      abstract_data_q <= 0;
      data_q <= 0;
      cmderr_q <= 0;
      sb_state_q <= SB_FREE;
      sb_error_q <= 0;
      sb_access_q <= 2;
      sb_busyerror_q <= 0;
      sb_readaddr_q <= 0;
      sb_readdata_q <= 0;
      sb_increment_q <= 0;
      sb_address_q <= 0;
      sb_data_q <= 0;
      owner_address_q <= 0;
      owner_data_q <= 0;
      owner_write_q <= 0;
      owner_increment_q <= 0;
      owner_size_q <= 0;
      dmi_rsp_valid_o <= 0;
      dmi_rsp_data_o <= 0;
      dmi_rsp_op_o <= 0;
    /* advance live protocol owners and accepted control requests. */
    end else begin
      /* one response belongs to exactly one accepted DMI request. */
      if (dmi_rsp_valid_o && dmi_rsp_ready_i) dmi_rsp_valid_o <= 0;
      /* capture one immutable DMI response. */
      if (accept) begin
        dmi_rsp_valid_o <= 1;
        dmi_rsp_data_o <= dmi_req_op_i == 1 ? read_value : 32'b0;
        dmi_rsp_op_o <= dmi_req_op_i == 3 ? 2'd2 : 2'd0;
      end
      /* stale reset epochs never refill a new DM instance. */
      if (sb_state_q == SB_OFFER && sb_req_ready_i) sb_state_q <= SB_WAIT;
      /* release the response owner after physical completion. */
      if (sb_state_q == SB_WAIT && sb_rsp_valid_i) begin
        sb_state_q <= SB_FREE;
        /* a revoked response drains physically and has no architectural DM effect. */
        if (!deactivate_q && !revoke) begin
          sb_error_q <= sb_rsp_error_i;
          /* failed responses cannot update data or advance an address. */
          if (sb_rsp_error_i == 0) begin
            if (!owner_write_q) sb_data_q <= owner_size_q == 0 ? {24'b0, sb_shifted[7:0]} :
                owner_size_q == 1 ? {16'b0, sb_shifted[15:0]} : sb_shifted;
            if (owner_increment_q) sb_address_q <= owner_address_q + (32'd1 << owner_size_q);
          end
        end
      end
      /* reset is observed even when it did not originate in the DM. */
      if (active_q && hart_reset_i) havereset_q <= 1;
      /* acknowledge only an actual hart resume. */
      if (active_q && !deactivate_q && hart_resumeack_i) begin
        resumeack_q <= 1;
        resume_q <= 0;
      end
      /* abstract transfer completion and data become visible atomically. */
      if (abstract_busy_q && !deactivate_q && !revoke) begin
        /* unavailable state ends an uncommitted abstract request. */
        if (unavailable) begin
          abstract_busy_q <= 0;
          if (cmderr_q == 0) cmderr_q <= 4;
        /* complete a successful register handshake once. */
        end else if (debug_reg_ready_i) begin
          abstract_busy_q <= 0;
          if (cmderr_q == 0) cmderr_q <= debug_reg_error_i;
          if (debug_reg_error_i == 0 && !abstract_write_q) data_q <= debug_reg_rdata_i;
        end
      end
      /* a new physical owner is created only after local checks pass. */
      if (sb_start) begin
        if (sb_start_error != 0) sb_error_q <= sb_start_error;
        /* capture the checked bus descriptor before exposure. */
        else begin
          sb_state_q <= SB_OFFER;
          owner_address_q <= sb_start_address;
          owner_data_q <= sb_start_data;
          owner_write_q <= sb_start_write;
          owner_size_q <= sb_access_q[1:0];
          owner_increment_q <= sb_increment_q;
        end
      end
      /* busy conflicts never alter the currently owned descriptor or command. */
      if (active_q && !deactivate_q && accept) begin
        if (abstract_busy_q && cmderr_q == 0 &&
            ((dmi_req_addr_i == 7'h04 && (read_access || write_access)) ||
             (write_access && (dmi_req_addr_i == 7'h16 || dmi_req_addr_i == 7'h17 ||
                               dmi_req_addr_i == 7'h18)))) cmderr_q <= 1;
        if (sb_busy && ((write_access && dmi_req_addr_i == 7'h39) ||
            ((read_access || write_access) && dmi_req_addr_i == 7'h3c))) sb_busyerror_q <= 1;
      end
      /* active register writes use pre-edge busy and sticky-error state. */
      if (active_q && !deactivate_q && write_access) begin
        case (dmi_req_addr_i)
          7'h04: if (!abstract_busy_q) data_q <= dmi_req_data_i;
          7'h16: if (!abstract_busy_q) cmderr_q <= cmderr_q & ~dmi_req_data_i[10:8];
          /* decode a new command only when the engine is idle. */
          7'h17: begin
            /* unsupported options precede hart-state and register checks. */
            if (!abstract_busy_q && cmderr_q == 0) begin
              if (dmi_req_data_i[31:24] != 0 || dmi_req_data_i[23] ||
                  dmi_req_data_i[19:18] != 0) cmderr_q <= 2;
              else if (unavailable || !hart_halted_i) cmderr_q <= 4;
              /* validate transfer width only when transfer is requested. */
              else if (dmi_req_data_i[17]) begin
                if (dmi_req_data_i[22:20] != 2) cmderr_q <= 2;
                /* retain register identity and source until completion. */
                else begin
                  abstract_busy_q <= 1;
                  abstract_write_q <= dmi_req_data_i[16];
                  abstract_addr_q <= dmi_req_data_i[15:0];
                  abstract_data_q <= data_q;
                end
              end
            end
          end
          /* update bus controls only between physical owners. */
          7'h38: begin
            /* writes while busy are ignored; the current access remains immutable. */
            if (!sb_busy) begin
              sb_busyerror_q <= sb_busyerror_q && !dmi_req_data_i[22];
              sb_error_q <= sb_error_q & ~dmi_req_data_i[14:12];
              sb_access_q <= dmi_req_data_i[19:17];
              sb_readaddr_q <= dmi_req_data_i[20];
              sb_readdata_q <= dmi_req_data_i[15];
              sb_increment_q <= dmi_req_data_i[16];
            end
          end
          7'h39: if (!sb_busy) sb_address_q <= dmi_req_data_i;
          7'h3c: if (!sb_busy && !sb_busyerror_q && sb_error_q == 0) sb_data_q <= dmi_req_data_i;
          default: begin end
        endcase
      end
      /* activation is the only writable state while the DM is inactive. */
      if (write_access && dmi_req_addr_i == 7'h10) begin
        /* revoke uncommitted actions before delayed deactivation. */
        if (!dmi_req_data_i[0]) begin
          deactivate_q <= 1;
          halt_q <= 0;
          resume_q <= 0;
          abstract_busy_q <= 0;
        end else if (!active_q && !deactivate_q) active_q <= 1;
        /* active control writes may request non-debug reset. */
        else if (active_q && !deactivate_q) begin
          ndmreset_q <= dmi_req_data_i[1];
          /* HARTSELLEN=0 always selects hart0; reserved selector fields are ignored. */
          if (!abstract_busy_q) begin
            halt_q <= dmi_req_data_i[31];
            if (dmi_req_data_i[31]) resume_q <= 0;
            /* latch only a currently halted hart resume request. */
            else if (dmi_req_data_i[30] && hart_halted_i && !unavailable) begin
              resume_q <= 1;
              resumeack_q <= 0;
            end
            if (dmi_req_data_i[28] && !hart_reset_i) havereset_q <= 0;
            if (dmi_req_data_i[2]) resethalt_q <= 0;
            else if (dmi_req_data_i[3]) resethalt_q <= 1;
          end
        end
      end
      /* deactivation acknowledges only after the old physical SBA owner drains. */
      if (deactivate_q && !sb_busy) begin
        active_q <= 0;
        deactivate_q <= 0;
        halt_q <= 0;
        resume_q <= 0;
        resumeack_q <= 0;
        resethalt_q <= 0;
        ndmreset_q <= 0;
        havereset_q <= 0;
        abstract_busy_q <= 0;
        abstract_write_q <= 0;
        abstract_addr_q <= 0;
        abstract_data_q <= 0;
        data_q <= 0;
        cmderr_q <= 0;
        sb_error_q <= 0;
        sb_access_q <= 2;
        sb_busyerror_q <= 0;
        sb_readaddr_q <= 0;
        sb_readdata_q <= 0;
        sb_increment_q <= 0;
        sb_address_q <= 0;
        sb_data_q <= 0;
      end
    end
  end
endmodule

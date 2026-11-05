/* check DM effects independently of the CPU and transport. */
module drg5_debug_module_tb;
  logic clk, reset = 1;
  /* run the independent system clock throughout every stall. */
  initial begin
    clk = 0;
    forever #5 clk = !clk;
  end
  logic hart_reset = 0, system_pending = 0, unavailable = 0, halted = 1, resumeack = 0;
  logic haltreq, resumereq, resethaltreq, ndmreset;
  logic reg_valid, reg_write, reg_ready = 0;
  logic [15:0] reg_addr;
  logic [31:0] reg_wdata, reg_rdata = 0;
  logic [2:0] reg_error = 0;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
  logic [6:0] req_addr = 0;
  logic [31:0] req_data = 0, rsp_data;
  logic [1:0] req_op = 0, rsp_op;
  logic sb_valid, sb_ready = 0, sb_write, sb_rsp_valid = 0, sb_rsp_ready;
  logic [31:0] sb_addr, sb_wdata, sb_rdata = 0;
  logic [1:0] sb_size;
  logic [3:0] sb_strobes;
  logic [2:0] sb_error = 0;
  logic [31:0] value;
  integer checks = 0, reg_effects, sb_effects, seed = 1;
  logic [31:0] random_q;

  /* bind every handshake to a separately controlled endpoint. */
  drg5_debug_module dut (
    .clk_i(clk), .power_reset_i(reset), .hart_reset_i(hart_reset), .system_reset_pending_i(system_pending),
    .hart_unavailable_i(unavailable), .hart_halted_i(halted), .hart_resumeack_i(resumeack),
    .haltreq_o(haltreq), .resumereq_o(resumereq), .resethaltreq_o(resethaltreq), .ndmreset_o(ndmreset),
    .debug_reg_valid_o(reg_valid), .debug_reg_write_o(reg_write), .debug_reg_addr_o(reg_addr),
    .debug_reg_wdata_o(reg_wdata), .debug_reg_ready_i(reg_ready), .debug_reg_rdata_i(reg_rdata),
    .debug_reg_error_i(reg_error), .dmi_req_valid_i(req_valid), .dmi_req_ready_o(req_ready),
    .dmi_req_addr_i(req_addr), .dmi_req_data_i(req_data), .dmi_req_op_i(req_op),
    .dmi_rsp_valid_o(rsp_valid), .dmi_rsp_ready_i(rsp_ready), .dmi_rsp_data_o(rsp_data),
    .dmi_rsp_op_o(rsp_op), .sb_req_valid_o(sb_valid), .sb_req_ready_i(sb_ready),
    .sb_req_write_o(sb_write), .sb_req_addr_o(sb_addr), .sb_req_wdata_o(sb_wdata),
    .sb_req_size_o(sb_size), .sb_req_wstrb_o(sb_strobes), .sb_rsp_valid_i(sb_rsp_valid),
    .sb_rsp_ready_o(sb_rsp_ready), .sb_rsp_rdata_i(sb_rdata), .sb_rsp_error_i(sb_error)
  );

  /* count endpoint effects only on the real accepting edge. */
  always @(posedge clk) begin
    /* start both endpoint effect ledgers from reset. */
    if (reset) begin
      reg_effects <= 0;
      sb_effects <= 0;
    /* count actual handshakes rather than requests or replies. */
    end else begin
      if (reg_valid && reg_ready && reg_error == 0) reg_effects <= reg_effects + 1;
      if (sb_valid && sb_ready) sb_effects <= sb_effects + 1;
    end
  end

  /* deterministic xorshift varies independent service delays. */
  function automatic integer delay_count();
    random_q ^= random_q << 13;
    random_q ^= random_q >> 17;
    random_q ^= random_q << 5;
    return 1 + int'(random_q % 7);
  endfunction

  /* ordinary detectors remain enabled in deliberate mutation runs. */
  task automatic check(input logic condition, input string message);
    checks++;
    assert (condition) else $fatal(1, "DM_CHECK %s", message);
  endtask

  /* hold a DMI response to prove it cannot execute the request again. */
  task automatic access(input logic [1:0] op, input logic [6:0] addr,
      input logic [31:0] data, output logic [31:0] result);
    @(negedge clk);
    req_valid = 1; req_op = op; req_addr = addr; req_data = data;
    @(posedge clk); #1;
    check(rsp_valid && rsp_op == (op == 3 ? 2'd2 : 2'd0), "DMI response");
    result = rsp_data;
    @(negedge clk); req_valid = 0;
    /* vary response backpressure without accepting a second request. */
    repeat (delay_count()) begin
      @(posedge clk); #1;
      check(rsp_valid && !req_ready && rsp_data == result, "held DMI response");
    end
    @(negedge clk); rsp_ready = 1;
    @(posedge clk); #1;
    @(negedge clk); rsp_ready = 0;
  endtask

  /* complete exactly one exposed SBA descriptor after separate acceptance/response stalls. */
  task automatic complete_bus(input logic write_expected, input logic [31:0] address_expected,
      input logic [1:0] size_expected, input logic [31:0] data_expected,
      input logic [3:0] strobes_expected, input logic [31:0] read_data, input logic [2:0] error);
    /* vary acceptance delay while checking every descriptor field. */
    repeat (delay_count()) begin
      @(posedge clk); #1;
      check(sb_valid && sb_write == write_expected && sb_addr == address_expected &&
          sb_size == size_expected && sb_wdata == data_expected && sb_strobes == strobes_expected,
          "immutable SBA offer");
    end
    @(negedge clk); sb_ready = 1;
    @(posedge clk); #1;
    check(!sb_valid && sb_rsp_ready, "SBA ownership transfer");
    @(negedge clk); sb_ready = 0;
    /* vary response delay independently from acceptance. */
    repeat (delay_count()) begin
      @(posedge clk); #1;
      check(sb_rsp_ready && !sb_valid, "held SBA response owner");
    end
    @(negedge clk); sb_rsp_valid = 1; sb_rdata = read_data; sb_error = error;
    @(posedge clk); #1;
    check(!sb_rsp_ready && !sb_valid, "SBA terminal release");
    @(negedge clk); sb_rsp_valid = 0; sb_error = 0;
  endtask

  /* directed collisions cover sticky errors, unsupported options and reset revocation. */
  initial begin
    if ($value$plusargs("seed=%d", seed)) begin end
    random_q = seed == 0 ? 32'h6d2b79f5 : 32'(seed);
    repeat (3) @(negedge clk);
    reset = 0;
    access(1, 7'h10, 0, value); check(value == 0, "inactive reset");
    access(2, 7'h10, 1, value);
    access(1, 7'h11, 0, value); check(value == 32'h000003a3, "DM capability and halt state");
    access(2, 7'h10, 32'h03ffffc1, value);
    access(1, 7'h10, 0, value); check(value == 1, "HARTSELLEN zero");
    access(1, 7'h38, 0, value); check(value == 32'h20040407, "SBA reset capabilities");
    /* absent addresses stay inert even when written with all ones. */
    for (int address = 0; address < 128; address++) begin
      /* probe every unimplemented seven-bit DMI address. */
      if (!(address inside {4, 16, 17, 22, 23, 56, 57, 60})) begin
        access(2, 7'(address), 32'hffffffff, value);
        access(1, 7'(address), 0, value);
        check(value == 0, "absent DMI register");
      end
    end
    access(3, 7'h10, 32'hffffffff, value);
    access(1, 7'h10, 0, value); check(value == 1, "reserved DMI op has no effect");
    access(2, 7'h10, 32'h80000001, value); check(haltreq, "halt request");
    access(2, 7'h10, 32'h40000001, value); check(resumereq && !haltreq, "resume request");
    /* a new halt defeats an already-selected but uncommitted resume. */
    @(negedge clk); req_valid = 1; req_addr = 7'h10; req_op = 2; req_data = 32'h80000001;
    #1; check(haltreq && !resumereq, "same-edge halt priority");
    @(posedge clk); #1;
    @(negedge clk); req_valid = 0; rsp_ready = 1;
    @(posedge clk); #1;
    @(negedge clk); rsp_ready = 0;
    access(2, 7'h10, 32'h40000001, value);
    @(negedge clk); resumeack = 1;
    @(posedge clk); #1;
    @(negedge clk); resumeack = 0;
    access(1, 7'h11, 0, value); check(value[17:16] == 3, "sticky resume acknowledgement");
    access(2, 7'h10, 3, value); check(ndmreset, "system reset request");
    access(2, 7'h10, 1, value); check(!ndmreset, "system reset release");
    access(2, 7'h10, 9, value); check(resethaltreq, "set reset halt");
    access(2, 7'h10, 5, value); check(!resethaltreq, "clear reset halt");
    @(negedge clk); hart_reset = 1;
    access(1, 7'h11, 0, value); check(value[19:18] == 3 && value[13:12] == 3 && value[24], "reset unavailable status");
    @(negedge clk); hart_reset = 0;
    access(2, 7'h10, 32'h10000001, value);
    access(1, 7'h11, 0, value); check(value[19:18] == 0, "acknowledge reset");
    /* a requested reset is unavailable before the hart has actually reset. */
    system_pending = 1;
    access(1, 7'h11, 0, value);
    check(value[24] && value[13:12] == 3 && value[19:18] == 0, "pending reset does not invent havereset");
    system_pending = 0;
    /* all six unsupported command controls are rejected before register side effects. */
    for (int variant = 0; variant < 6; variant++) begin
      access(2, 7'h17, variant == 0 ? 32'h01221001 : variant == 1 ? 32'h00821001 :
          variant == 2 ? 32'h002a1001 : variant == 3 ? 32'h00261001 :
          variant == 4 ? 32'h00321001 : 32'h00121001, value);
      access(1, 7'h16, 0, value); check(value[10:8] == 2 && !reg_valid, "unsupported command");
      access(2, 7'h16, 32'h00000700, value);
    end
    access(2, 7'h17, 32'h0071ffff, value);
    access(1, 7'h16, 0, value); check(value[10:8] == 0 && !reg_valid, "transfer-zero no-op");
    halted = 0;
    access(2, 7'h17, 32'h00221001, value);
    access(1, 7'h16, 0, value); check(value[10:8] == 4, "running abstract rejection");
    halted = 1;
    access(2, 7'h17, 32'h00221001, value); check(!reg_valid, "sticky command suppression");
    access(2, 7'h16, 32'h00000700, value);
    access(2, 7'h04, 32'hdeadbeef, value);
    access(2, 7'h17, 32'h00231001, value);
    check(reg_valid && reg_write && reg_addr == 16'h1001 && reg_wdata == 32'hdeadbeef, "abstract descriptor");
    access(2, 7'h10, 32'h80000009, value); check(!haltreq && !resethaltreq, "busy run-control ignored");
    access(2, 7'h17, 32'h00231002, value);
    @(negedge clk); reg_ready = 1;
    @(posedge clk); #1;
    @(negedge clk); reg_ready = 0;
    access(1, 7'h16, 0, value); check(value[10:8] == 1 && reg_effects == 1, "busy conflict preserves original effect");
    access(2, 7'h16, 32'h00000700, value);
    access(2, 7'h17, 32'h002207b0, value);
    @(negedge clk); reg_ready = 1; reg_rdata = 32'h40000403;
    @(posedge clk); #1;
    @(negedge clk); reg_ready = 0;
    access(1, 7'h04, 0, value); check(value == 32'h40000403, "abstract read result");
    access(2, 7'h17, 32'h002207b2, value);
    @(negedge clk); reg_ready = 1; reg_error = 3;
    @(posedge clk); #1;
    @(negedge clk); reg_ready = 0; reg_error = 0;
    access(1, 7'h16, 0, value); check(value[10:8] == 3, "absent register error");
    access(2, 7'h16, 32'h00000700, value);
    /* every lane and width has separate request and response stalls. */
    for (int width = 0; width < 3; width++) begin
      /* enumerate each naturally aligned byte lane. */
      for (int lane = 0; lane < 4; lane += 1 << width) begin
        access(2, 7'h38, 32'(width << 17), value);
        access(2, 7'h39, 32'h1000 + 32'(lane), value);
        access(2, 7'h3c, 32'h78563412, value);
        complete_bus(1, 32'h1000 + 32'(lane), 2'(width), 32'h78563412 << (8 * lane),
            (width == 0 ? 4'h1 : width == 1 ? 4'h3 : 4'hf) << lane, 0, 0);
        access(2, 7'h38, 32'(width << 17) | 32'h00110000, value);
        access(2, 7'h39, 32'h1000 + 32'(lane), value);
        complete_bus(0, 32'h1000 + 32'(lane), 2'(width), (32'h1000 + 32'(lane)) << (8 * lane), 0,
            32'h78563412, 0);
        access(1, 7'h3c, 0, value);
        check(value == ((32'h78563412 >> (8 * lane)) &
            (width == 0 ? 32'hff : width == 1 ? 32'hffff : 32'hffffffff)), "SBA narrow zero extension");
        access(1, 7'h39, 0, value);
        check(value == 32'h1000 + 32'(lane) + (32'd1 << width), "successful autoincrement");
      end
    end
    /* read-on-data returns the completed value before issuing the next read. */
    access(2, 7'h38, 32'h00158000, value);
    access(2, 7'h39, 32'h3000, value);
    complete_bus(0, 32'h3000, 2, 32'h3000, 0, 32'h11223344, 0);
    access(1, 7'h3c, 0, value);
    check(value == 32'h11223344 && sb_valid && sb_addr == 32'h3004, "read-on-data old result and next address");
    complete_bus(0, 32'h3004, 2, 0, 0, 32'h55667788, 0);
    access(2, 7'h38, 32'h00040000, value);
    access(1, 7'h3c, 0, value); check(value == 32'h55667788 && !sb_valid, "read-on-data final result");
    /* size errors precede alignment and unavailable state without bus exposure. */
    access(2, 7'h38, 32'h00160000, value);
    access(2, 7'h39, 3, value);
    access(1, 7'h38, 0, value); check(value[14:12] == 4 && !sb_valid, "unsupported SBA size");
    access(2, 7'h38, 32'h00147000, value);
    access(2, 7'h39, 3, value);
    access(1, 7'h38, 0, value); check(value[14:12] == 3 && !sb_valid, "misaligned SBA");
    access(2, 7'h38, 32'h00147000, value);
    unavailable = 1;
    access(2, 7'h39, 32'h1000, value);
    access(1, 7'h38, 0, value); check(value[14:12] == 2 && !sb_valid, "unavailable SBA");
    unavailable = 0;
    access(2, 7'h38, 32'h00157000, value);
    access(2, 7'h39, 32'h1000, value);
    access(2, 7'h39, 32'h2000, value);
    access(1, 7'h3c, 0, value);
    complete_bus(0, 32'h1000, 2, 32'h1000, 0, 32'habcd1234, 2);
    access(1, 7'h38, 0, value); check(value[22] && value[14:12] == 2, "SBA busy and target errors");
    access(1, 7'h39, 0, value); check(value == 32'h1000, "failed access does not increment");
    access(2, 7'h38, 32'h00547000, value);
    access(2, 7'h39, 32'h1000, value);
    /* DM reset drains the offered access and discards its late result. */
    access(2, 7'h10, 0, value);
    access(1, 7'h10, 0, value); check(value[0], "deactivation waits for exposed SBA");
    complete_bus(0, 32'h1000, 2, 32'h1000, 0, 32'hffffffff, 0);
    access(1, 7'h10, 0, value); check(value == 0, "drained deactivation");
    access(2, 7'h10, 1, value);
    access(1, 7'h3c, 0, value); check(value == 0, "old SBA response cannot refill reset DM");
    /* a same-edge deactivation revokes an abstract transfer before it commits. */
    access(2, 7'h17, 32'h00231003, value);
    @(negedge clk); req_valid = 1; req_addr = 7'h10; req_op = 2; req_data = 0; reg_ready = 1;
    #1; check(!reg_valid, "same-edge abstract revocation");
    @(posedge clk); #1;
    @(negedge clk); req_valid = 0; rsp_ready = 1; reg_ready = 0;
    @(posedge clk); #1;
    @(negedge clk); rsp_ready = 0;
    check(reg_effects == 2, "only committed abstract effects");
    check(sb_effects == 18, "exactly-once physical SBA effects");
    $display("DM_PASS seed=%0d checks=%0d register_effects=%0d bus_effects=%0d", seed, checks, reg_effects, sb_effects);
    $finish;
  end
endmodule

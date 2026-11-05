/* check physical memory effects independently of any CPU retirement record. */
module drg5_local_fabric_tb;
  logic clk, reset, isolated;
  logic [3:0] ia, ir, da, dr;
  logic iv, iy, irv, iry;
  logic [31:0] iaddr, itag, irtag, idata;
  logic [1:0] ip, irp, ifault, istatus;
  logic dv, dy, dw, drv, dry;
  logic [31:0] daddr, dwdata, dtag, drtag, drdata;
  logic [1:0] dsize, dstatus;
  logic [3:0] ds;
  logic [31:1] events;
  logic block_ready;
  logic [31:0] mip, pending, enabled, status;
  logic [63:0] mtime;
  logic status_write, output_valid, busy;
  logic [7:0] output_data;
  integer checks, transfers, status_effects, output_effects;
  logic [31:0] tag;

  /* instantiate the same fabric used by the compiled-firmware system. */
  drg5_local_fabric dut (
    .clk_i(clk), .reset_i(reset), .isolated_i(isolated),
    .i_accept_delay_i(ia), .i_response_delay_i(ir), .d_accept_delay_i(da), .d_response_delay_i(dr),
    .i_req_valid_i(iv), .i_req_ready_o(iy), .i_req_addr_i(iaddr), .i_req_tag_i(itag), .i_req_parcels_i(ip),
    .i_rsp_valid_o(irv), .i_rsp_ready_i(iry), .i_rsp_tag_o(irtag), .i_rsp_data_o(idata),
    .i_rsp_parcels_o(irp), .i_rsp_fault_o(ifault), .i_rsp_status_o(istatus),
    .d_req_valid_i(dv), .d_req_ready_o(dy), .d_req_addr_i(daddr), .d_req_wdata_i(dwdata),
    .d_req_tag_i(dtag), .d_req_write_i(dw), .d_req_size_i(dsize), .d_req_wstrb_i(ds),
    .d_rsp_valid_o(drv), .d_rsp_ready_i(dry), .d_rsp_tag_o(drtag), .d_rsp_rdata_o(drdata), .d_rsp_status_o(dstatus),
    .event_set_i(events), .block_ready_i(block_ready), .mip_levels_o(mip),
    .ext_pending_o(pending), .ext_enable_o(enabled), .mtime_o(mtime), .status_write_o(status_write),
    .output_valid_o(output_valid), .status_o(status), .output_data_o(output_data), .busy_o(busy)
  );

  /* sample effect pulses after each edge, independently of response consumption. */
  task automatic tick;
    clk = 0;
    #5;
    clk = 1;
    #5;
    if (status_write) status_effects = status_effects + 1;
    if (output_valid) output_effects = output_effects + 1;
    clk = 0;
    #1;
  endtask

  /* retain a single named assertion boundary for deterministic negative controls. */
  task automatic check(input logic condition, input string reason);
    checks = checks + 1;
    if (!condition) $fatal(1, "LOCAL_FABRIC_CHECK %s", reason);
  endtask

  /* compare admission clocks, synchronous snapshots and stable delayed responses. */
  task automatic data_access(input logic [31:0] address, input logic write,
      input logic [1:0] size, input logic [3:0] strobes, input logic [31:0] value,
      input logic [3:0] acceptance, input logic [3:0] response,
      input integer response_hold, input logic [31:0] expected, input logic [1:0] expected_status);
    integer waited, effective_response;
    tag = tag + 1;
    dv = 1; daddr = address; dw = write; dsize = size; ds = strobes; dwdata = value; dtag = tag;
    da = acceptance; dr = response; dry = 0;
    waited = 0;
    #1;
    /* change delay inputs after first presentation to test owner-local sampling. */
    while (!dy) begin
      check(waited < 20, "D acceptance deadline");
      tick();
      waited = waited + 1;
      da = 0; dr = 1;
      #1;
    end
    check(waited == int'(acceptance), "D acceptance latency");
    tick();
    dv = 0;
    effective_response = response == 0 ? 1 : int'(response);
    /* the earliest response edge is exactly the original sampled latency. */
    for (integer n = 1; n < effective_response; n = n + 1) begin
      check(!drv, "D response early");
      tick();
    end
    /* a stalled response retains its complete payload and cannot replay effects. */
    for (integer n = 0; n <= response_hold; n = n + 1) begin
      check(drv && drtag == tag && drdata == expected && dstatus == expected_status, "D response payload");
      check(!dy, "D admission while response owned");
      if (n != response_hold) tick();
    end
    dry = 1;
    tick();
    dry = 0;
    check(!drv, "D duplicate response");
    transfers = transfers + 1;
  endtask

  /* parcel faults and data masks remain distinct from whole-beat ownership. */
  task automatic instruction_access(input logic [31:0] address, input logic [1:0] parcels,
      input logic [3:0] acceptance, input logic [3:0] response, input integer response_hold,
      input logic [31:0] expected, input logic [1:0] expected_status);
    integer waited, effective_response;
    tag = tag + 1;
    iv = 1; iaddr = address; ip = parcels; itag = tag; ia = acceptance; ir = response; iry = 0;
    waited = 0;
    #1;
    /* ownership survives external changes to the following request's delay settings. */
    while (!iy) begin
      check(waited < 20, "I acceptance deadline");
      tick();
      waited = waited + 1;
      ia = 0; ir = 1;
      #1;
    end
    check(waited == int'(acceptance), "I acceptance latency");
    tick();
    iv = 0;
    effective_response = response == 0 ? 1 : int'(response);
    /* instruction RAM must not behave as a combinational zero-cycle response. */
    for (integer n = 1; n < effective_response; n = n + 1) begin
      check(!irv, "I response early");
      tick();
    end
    /* no response field may change when the consumer holds ready low. */
    for (integer n = 0; n <= response_hold; n = n + 1) begin
      check(irv && irtag == tag && idata == expected && istatus == expected_status && irp == parcels &&
          ifault == (expected_status == 0 ? 2'b0 : parcels), "I response payload");
      check(!iy, "I admission while response owned");
      if (n != response_hold) tick();
    end
    iry = 1;
    tick();
    iry = 0;
    check(!irv, "I duplicate response");
    transfers = transfers + 1;
  endtask

  /* qualification uses test-only memory poison; reset itself must leave RAM untouched. */
  initial begin
    clk = 0; reset = 1; isolated = 1; ia = 0; ir = 1; da = 0; dr = 1;
    iv = 0; iry = 0; iaddr = 0; itag = 0; ip = 0;
    dv = 0; dry = 0; daddr = 0; dwdata = 0; dtag = 0; dw = 0; dsize = 0; ds = 0;
    events = 0; block_ready = 0; checks = 0; transfers = 0; tag = 0; status_effects = 0; output_effects = 0;
    dut.rom[0] = 32'hfedcba98;
    dut.iram[0] = 32'h12345678;
    dut.dram[0] = 32'ha5a5a5a5;
    tick(); tick(); reset = 0;
    check(dut.dram[0] == 32'ha5a5a5a5, "reset changed RAM");
    instruction_access(0, 3, 0, 1, 4, 32'hfedcba98, 0);
    instruction_access(32'h10000, 1, 7, 12, 3, 32'h00005678, 0);
    instruction_access(32'h10000, 2, 15, 15, 2, 32'h12340000, 0);
    instruction_access(32'h40000004, 3, 3, 2, 3, 0, 1);
    instruction_access(32'h10002, 3, 2, 4, 2, 0, 1);
    data_access(0, 0, 2, 0, 0, 0, 1, 3, 32'hfedcba98, 0);
    data_access(0, 1, 2, 15, 0, 4, 4, 3, 0, 1);
    /* every memory port must zero unused byte and halfword response lanes. */
    data_access(0, 0, 0, 0, 0, 0, 1, 2, 32'h00000098, 0);
    data_access(1, 0, 0, 0, 0, 1, 2, 2, 32'h0000ba00, 0);
    data_access(2, 0, 0, 0, 0, 2, 3, 2, 32'h00dc0000, 0);
    data_access(3, 0, 0, 0, 0, 3, 4, 2, 32'hfe000000, 0);
    data_access(0, 0, 1, 0, 0, 4, 5, 2, 32'h0000ba98, 0);
    data_access(2, 0, 1, 0, 0, 5, 6, 2, 32'hfedc0000, 0);
    data_access(32'h10000, 0, 0, 0, 0, 0, 1, 2, 32'h00000078, 0);
    data_access(32'h10001, 0, 0, 0, 0, 1, 2, 2, 32'h00005600, 0);
    data_access(32'h10002, 0, 0, 0, 0, 2, 3, 2, 32'h00340000, 0);
    data_access(32'h10003, 0, 0, 0, 0, 3, 4, 2, 32'h12000000, 0);
    data_access(32'h10000, 0, 1, 0, 0, 4, 5, 2, 32'h00005678, 0);
    data_access(32'h10002, 0, 1, 0, 0, 5, 6, 2, 32'h12340000, 0);
    data_access(32'h20000000, 0, 0, 0, 0, 0, 1, 2, 32'h000000a5, 0);
    data_access(32'h20000001, 0, 0, 0, 0, 1, 2, 2, 32'h0000a500, 0);
    data_access(32'h20000002, 0, 0, 0, 0, 2, 3, 2, 32'h00a50000, 0);
    data_access(32'h20000003, 0, 0, 0, 0, 3, 4, 2, 32'ha5000000, 0);
    data_access(32'h20000000, 0, 1, 0, 0, 4, 5, 2, 32'h0000a5a5, 0);
    data_access(32'h20000002, 0, 1, 0, 0, 5, 6, 2, 32'ha5a50000, 0);
    data_access(32'h20000001, 1, 0, 2, 32'h00007b00, 7, 12, 4, 0, 0);
    data_access(32'h20000000, 0, 2, 0, 0, 15, 15, 2, 32'ha5a57ba5, 0);
    data_access(32'h20000002, 1, 1, 12, 32'hcdef0000, 0, 0, 1, 0, 0);
    data_access(32'h20000000, 0, 2, 0, 0, 2, 6, 0, 32'hcdef7ba5, 0);
    data_access(32'h20000001, 1, 1, 6, 32'hffff, 0, 1, 2, 0, 1);
    data_access(32'h20000000, 1, 2, 3, 0, 0, 1, 2, 0, 1);
    data_access(32'h40000000, 1, 2, 15, 32'h76543210, 7, 12, 5, 0, 0);
    check(status_effects == 1 && status == 32'h76543210, "status effect duplicated");
    data_access(32'h40000004, 1, 2, 15, 32'h41, 3, 4, 7, 0, 0);
    check(output_effects == 1 && output_data == 8'h41, "output effect duplicated");
    data_access(32'h40000004, 1, 0, 1, 32'h42, 0, 1, 3, 0, 1);
    data_access(32'h4000000c, 1, 2, 15, 32'h43, 0, 1, 2, 0, 1);
    check(status_effects == 1 && output_effects == 1, "rejected MMIO changed a device");
    data_access(32'h40000000, 0, 2, 0, 0, 1, 3, 1, 32'h76543210, 0);
    data_access(32'h40000004, 0, 2, 0, 0, 1, 3, 1, 32'h41, 0);
    data_access(32'h40001010, 1, 2, 15, 1, 2, 5, 4, 0, 0);
    check(mip == 8 && mtime > 0, "software interrupt missing");
    data_access(32'h40001010, 1, 2, 15, 0, 0, 1, 0, 0, 0);
    data_access(32'h40000008, 1, 2, 15, 1, 0, 1, 2, 0, 0);
    check(pending[1] && !mip[11], "masked external event lost");
    data_access(32'h40001018, 1, 2, 15, 2, 0, 1, 1, 0, 0);
    check(mip == 32'h800 && enabled == 2, "retained external event missing");
    data_access(32'h40001014, 1, 2, 15, 2, 0, 1, 1, 0, 0);
    check(!mip[11], "external acknowledgement failed");
    data_access(32'h4000101c, 1, 2, 15, 1, 0, 1, 2, 0, 1);

    /* a colliding D write owns its edge; the next I acceptance sees the new word. */
    dv = 1; daddr = 32'h10000; dw = 1; dsize = 2; ds = 15; dwdata = 32'h99887766; dtag = 100;
    iv = 1; iaddr = 32'h10000; ip = 3; itag = 101; ia = 0; ir = 1; da = 0; dr = 1;
    #1;
    check(dy && !iy, "IRAM write priority");
    tick(); dv = 0;
    check(iy && drv && drtag == 100, "I collision did not release");
    tick(); iv = 0;
    check(irv && idata == 32'h99887766 && irtag == 101, "I collision read stale word");
    dry = 1; iry = 1; tick(); dry = 0; iry = 0;

    /* a read already accepted retains old data when a later writer updates the same word. */
    iv = 1; itag = 102; tick(); iv = 0;
    check(irv && idata == 32'h99887766, "I snapshot absent");
    data_access(32'h10000, 1, 2, 15, 32'h11223344, 0, 1, 3, 0, 0);
    check(irv && idata == 32'h99887766, "held I response reread memory");
    iry = 1; tick(); iry = 0;

    /* positive isolation permits whole-system cancellation without clearing stored RAM bytes. */
    dv = 1; daddr = 32'h20000000; dw = 0; dsize = 2; ds = 0; dtag = 103; da = 7;
    tick();
    check(busy && !dy, "delayed D owner absent");
    reset = 1; dv = 0; tick(); reset = 0;
    check(!busy && !drv && !irv && status == 0 && pending == 0, "isolated reset failed");
    check(dut.dram[0] == 32'hcdef7ba5 && dut.iram[0] == 32'h11223344, "reset cleared RAM");
    /* negative modes must reach the intended ordinary checker. */
    if ($test$plusargs("mutate_effect")) check(output_effects == 2, "output effect duplicated");
    /* unsafe reset must fail before it can cancel ownership. */
    if ($test$plusargs("bad_reset")) begin
      isolated = 0; reset = 1; tick();
      $fatal(1, "unsafe reset detector missing");
    end
    $display("LOCAL_FABRIC_PASS checks=%0d transfers=%0d status_effects=%0d output_effects=%0d", checks, transfers, status_effects, output_effects);
    $finish;
  end
endmodule

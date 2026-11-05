/* exercise TAP protocol and asynchronous DMI ownership through independent clocks. */
module drg5_debug_transport_tb;
  logic clk = 0, reset = 1, tck = 0, tms = 1, tdi = 0, tdo;
  logic req_valid, req_ready = 0, rsp_valid = 0, rsp_ready;
  logic [6:0] req_addr;
  logic [31:0] req_data, rsp_data = 0;
  logic [1:0] req_op, rsp_op = 0;
  logic unused_bit_out;
  logic [40:0] scan_out;
  integer checks = 0, effects = 0, ratio = 0, seed = 1;
  logic [31:0] random_q;

  /* bind the crossing to an endpoint controlled independently from TCK. */
  drg5_debug_transport dut (
    .clk_i(clk), .power_reset_i(reset), .tck_i(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo),
    .dmi_req_valid_o(req_valid), .dmi_req_ready_i(req_ready), .dmi_req_addr_o(req_addr),
    .dmi_req_data_o(req_data), .dmi_req_op_o(req_op), .dmi_rsp_valid_i(rsp_valid),
    .dmi_rsp_ready_o(rsp_ready), .dmi_rsp_data_i(rsp_data), .dmi_rsp_op_i(rsp_op)
  );

  /* ordinary checks also classify mutation runs. */
  task automatic check(input logic condition, input string message);
    checks++;
    assert (condition) else $fatal(1, "DTM_CHECK %s", message);
  endtask

  /* advance only the system clock so TCK may remain stopped indefinitely. */
  task automatic system_tick;
    clk = 0; #2;
    clk = 1; #2;
    if (req_valid && req_ready) effects++;
    clk = 0; #2;
  endtask

  /* TDO must retain the falling-edge bit through the positive sampling edge. */
  task automatic tap_tick(input logic mode, data, output logic result);
    tms = mode; tdi = data; tck = 0; #3;
    result = tdo;
    repeat (ratio) system_tick();
    tck = 1; #3;
    check(tdo == result, "TDO changed on rising edge");
  endtask

  /* enter idle from any previous TAP state. */
  task automatic tap_reset;
    repeat (5) tap_tick(1, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
  endtask

  /* select a five-bit instruction and check mandatory IR capture bits. */
  task automatic select_ir(input logic [4:0] instruction);
    logic [4:0] captured;
    tap_tick(1, 0, unused_bit_out);
    tap_tick(1, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
    /* shift instruction bits least significant first. */
    for (int bit_index = 0; bit_index < 5; bit_index++) begin
      tap_tick(bit_index == 4, instruction[bit_index], captured[bit_index]);
    end
    tap_tick(1, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
    check(captured == 1, "IR capture low bits");
  endtask

  /* scan an actual register length without peeking into transport state. */
  task automatic scan_dr(input integer width, input logic [40:0] outgoing,
      output logic [40:0] incoming);
    incoming = 0;
    tap_tick(1, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
    /* shift only the selected register width. */
    for (int bit_index = 0; bit_index < width; bit_index++) begin
      tap_tick(bit_index == width - 1, outgoing[bit_index], incoming[bit_index]);
    end
    tap_tick(1, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
  endtask

  /* accept once and respond later while TCK is stopped. */
  task automatic serve(input logic [6:0] address_expected, input logic [31:0] data_expected,
      input logic [1:0] op_expected, input logic [31:0] result, input logic [1:0] error);
    repeat (5) system_tick();
    check(req_valid && req_addr == address_expected && req_data == data_expected && req_op == op_expected,
        "stable crossed descriptor");
    random_q ^= random_q << 13; random_q ^= random_q >> 17; random_q ^= random_q << 5;
    /* stall acceptance independently from the TAP clock. */
    repeat (1 + int'(random_q % 7)) begin
      system_tick();
      check(req_valid && req_addr == address_expected && req_data == data_expected && req_op == op_expected,
          "held DMI descriptor");
    end
    req_ready = 1;
    /* count pre-edge acceptance rather than the post-edge offer state. */
    effects++;
    system_tick();
    req_ready = 0;
    check(!req_valid && rsp_ready, "DMI acceptance ownership");
    repeat (1 + int'(random_q % 5)) system_tick();
    rsp_data = result; rsp_op = error; rsp_valid = 1;
    system_tick();
    rsp_valid = 0;
    check(!rsp_ready, "DMI response ownership release");
  endtask

  /* reset only sticky transport error state without touching the DM operation. */
  task automatic clear_status;
    select_ir(5'h10);
    scan_dr(32, 41'h000010000, scan_out);
    select_ir(5'h11);
  endtask

  /* directed scans cover CDC collisions, sticky status, hard reset and unknown IR. */
  initial begin
    if ($value$plusargs("seed=%d", seed)) begin end
    random_q = seed == 0 ? 32'h9e3779b9 : 32'(seed);
    system_tick(); tap_tick(1, 0, unused_bit_out);
    reset = 0;
    tap_reset();
    scan_dr(32, 0, scan_out); check(scan_out[31:0] == 1, "development IDCODE");
    select_ir(5'h10);
    scan_dr(32, 0, scan_out); check(scan_out[31:0] == 32'h5071, "DTM capability fields");
    /* unknown instructions have exactly one bit of delay. */
    for (int instruction = 0; instruction < 32; instruction++) begin
      /* probe every reserved and BYPASS instruction encoding. */
      if (!(instruction inside {1, 16, 17})) begin
        select_ir(5'(instruction));
        scan_dr(2, 1, scan_out);
        check(scan_out[1:0] == 2, "unknown IR BYPASS");
      end
    end
    select_ir(5'h11);
    scan_dr(41, {7'h04, 32'h12345678, 2'd2}, scan_out);
    serve(7'h04, 32'h12345678, 2, 32'hcafef00d, 0);
    /* two TCK edges synchronize completion; capture on the third must bypass its fresh data. */
    tap_tick(1, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
    tap_tick(0, 0, unused_bit_out);
    scan_out = 0;
    /* collect the response captured on the completion edge. */
    for (int bit_index = 0; bit_index < 41; bit_index++) begin
      tap_tick(bit_index == 40, 0, scan_out[bit_index]);
    end
    tap_tick(1, 0, unused_bit_out); tap_tick(0, 0, unused_bit_out);
    check(scan_out[1:0] == 0 && scan_out[33:2] == 32'hcafef00d && scan_out[40:34] == 7'h04,
        "completion coincident with Capture-DR");
    /* the same alignment must report a new DMI error, never false success. */
    scan_dr(41, {7'h7e, 32'b0, 2'd1}, scan_out);
    serve(7'h7e, 0, 1, 32'hbad0bad0, 2);
    scan_dr(41, {7'h04, 32'h99999999, 2'd2}, scan_out);
    check(scan_out[1:0] == 2, "error coincident with Capture-DR");
    repeat (5) system_tick(); check(!req_valid && effects == 2, "sticky error ignores next operation");
    clear_status();
    scan_dr(41, {7'h10, 32'h80000001, 2'd2}, scan_out);
    /* capture before service must set sticky busy and reject the scan's new operation. */
    scan_dr(41, {7'h04, 32'hffffffff, 2'd2}, scan_out);
    check(scan_out[1:0] == 3, "sticky busy capture");
    clear_status();
    serve(7'h10, 32'h80000001, 2, 32'hc0ffee00, 0);
    repeat (3) tap_tick(0, 0, unused_bit_out);
    scan_dr(41, 0, scan_out); check(scan_out[1:0] == 0, "dmireset preserves old transaction");
    check(effects == 3, "busy scan had no second effect");
    /* hard reset forgets the logical result but preserves physical drain ownership. */
    scan_dr(41, {7'h39, 32'h1000, 2'd2}, scan_out);
    select_ir(5'h10);
    scan_dr(32, 41'h000020000, scan_out);
    serve(7'h39, 32'h1000, 2, 32'hffffffff, 0);
    repeat (3) tap_tick(0, 0, unused_bit_out);
    select_ir(5'h11);
    scan_dr(41, 0, scan_out);
    check(scan_out[1:0] == 0 && scan_out[33:2] == 0, "hard reset discards old response");
    scan_dr(41, {7'h11, 32'b0, 2'd1}, scan_out);
    /* a TAP reset changes IR but cannot replay or discard the pending DM operation. */
    tap_reset();
    serve(7'h11, 0, 1, 32'h000003a3, 0);
    select_ir(5'h11);
    scan_dr(41, 0, scan_out); check(scan_out[1:0] == 0 && scan_out[33:2] == 32'h3a3, "TAP reset keeps owner");
    scan_dr(41, {7'h10, 32'hffffffff, 2'd3}, scan_out);
    scan_dr(41, 0, scan_out); check(scan_out[1:0] == 2, "reserved DMI op rejected");
    repeat (5) system_tick(); check(!req_valid && effects == 5, "exactly-once DMI effects");
    clear_status();
    /* additional independent clock ratios exercise request payload stability and response capture. */
    for (int iteration = 0; iteration < 30; iteration++) begin
      ratio = iteration % 4;
      scan_dr(41, {7'(iteration), 32'(iteration * 91), 2'd1}, scan_out);
      serve(7'(iteration), 32'(iteration * 91), 1, 32'(iteration) ^ 32'h89abcdef, 0);
      repeat (3) tap_tick(0, 0, unused_bit_out);
      scan_dr(41, 0, scan_out);
      check(scan_out[1:0] == 0 && scan_out[33:2] == (32'(iteration) ^ 32'h89abcdef), "varied clock ratio response");
    end
    check(effects == 35, "no CDC duplicates");
    $display("DTM_PASS seed=%0d checks=%0d effects=%0d", seed, checks, effects);
    $finish;
  end
endmodule

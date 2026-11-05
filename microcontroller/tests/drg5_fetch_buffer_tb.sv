/* check fetch framing independently of the external transaction manager. */
module drg5_fetch_buffer_tb;
  logic clk = 0;
  logic reset [0:1], restart [0:1], fill_valid [0:1], ready [0:1];
  logic [31:0] restart_pc [0:1], fill_addr [0:1], fill_data [0:1];
  logic [7:0] restart_generation [0:1], fill_generation [0:1];
  logic [1:0] fill_parcels [0:1], fill_fault [0:1];
  logic need_valid [0:1], valid [0:1], supported [0:1], fault [0:1];
  logic [31:0] need_addr [0:1], pc [0:1], raw [0:1], cause [0:1], mtval [0:1];
  logic [1:0] need_parcels [0:1], kind [0:1];
  logic [3:0] raw_valid [0:1];
  logic [2:0] length_bytes [0:1];
  logic [7:0] generation [0:1];
  int unsigned edges = 0, checks = 0, prefix_cases = 0;
  logic [31:0] observed_raw;
  bit mutate_raw;

  /* exercise the default 32-bit configuration and optional framing separately. */
  for (genvar c = 0; c < 2; c = c + 1) begin : configs
    drg5_fetch_buffer #(.C_FETCH(c != 0)) dut (
      .clk_i(clk), .reset_i(reset[c]), .restart_i(restart[c]),
      .restart_pc_i(restart_pc[c]), .restart_generation_i(restart_generation[c]),
      .fill_valid_i(fill_valid[c]), .fill_addr_i(fill_addr[c]),
      .fill_generation_i(fill_generation[c]), .fill_parcels_i(fill_parcels[c]),
      .fill_data_i(fill_data[c]), .fill_fault_i(fill_fault[c]),
      .need_valid_o(need_valid[c]), .need_addr_o(need_addr[c]), .need_parcels_o(need_parcels[c]),
      .insn_valid_o(valid[c]), .insn_ready_i(ready[c]), .insn_pc_o(pc[c]),
      .insn_raw_o(raw[c]), .insn_raw_valid_o(raw_valid[c]),
      .insn_length_kind_o(kind[c]), .insn_length_supported_o(supported[c]),
      .insn_length_bytes_o(length_bytes[c]), .insn_generation_o(generation[c]),
      .insn_fault_o(fault[c]), .insn_cause_o(cause[c]), .insn_mtval_o(mtval[c])
    );
  end

  /* use explicit edges so read-side checks cannot hide an extra clock. */
  task automatic tick;
    #5; clk = 1; #5; clk = 0;
    edges = edges + 1;
  endtask

  /* make every failed comparison identify this checker rather than a tool crash. */
  task automatic check(input bit condition, input string label_text);
    checks = checks + 1;
    /* terminate at the first independently observed mismatch. */
    if (!condition) $fatal(1, "FETCH_BUFFER_CHECK_FAILED %s edge=%0d", label_text, edges);
  endtask

  /* invalidation masks same-edge valid and discards all earlier buffered bytes. */
  task automatic new_stream(input bit c, input logic [31:0] start_pc, input logic [7:0] gen);
    restart_pc[c] = start_pc;
    restart_generation[c] = gen;
    restart[c] = 1;
    ready[c] = 0;
    fill_valid[c] = 0;
    #1;
    check(!valid[c] && !need_valid[c], "restart suppresses output and request");
    tick();
    restart[c] = 0;
    reset[c] = 0;
    #1;
  endtask

  /* compare the exact missing required parcel set before supplying a reply. */
  task automatic expect_need(input bit c, input logic [31:0] addr, input logic [1:0] mask);
    check(need_valid[c] && need_addr[c] == addr && need_parcels[c] == mask, "required parcel request");
  endtask

  /* inject only captured live outcomes; bus ownership is tested in the manager suite. */
  task automatic fill(input bit c, input logic [31:0] addr, input logic [1:0] mask,
                      input logic [31:0] data, input logic [1:0] errors, input logic [7:0] gen);
    fill_valid[c] = 1;
    fill_addr[c] = addr;
    fill_parcels[c] = mask;
    fill_data[c] = data;
    fill_fault[c] = errors;
    fill_generation[c] = gen;
    tick();
    fill_valid[c] = 0;
    #1;
  endtask

  /* compare all public packet fields with independent expected instruction bytes. */
  task automatic expect_packet(input bit c, input logic [31:0] expected_pc,
      input logic [31:0] expected_raw, input logic [3:0] expected_mask,
      input logic [1:0] expected_kind, input bit expected_supported,
      input logic [2:0] expected_bytes, input logic [7:0] expected_generation,
      input bit expected_fault, input logic [31:0] expected_cause, expected_mtval);
    check(valid[c] && !need_valid[c], "completed packet blocks requests");
    observed_raw = raw[c] ^ (mutate_raw ? 32'd1 : 32'd0);
    check(observed_raw == expected_raw, "packet raw");
    check(pc[c] == expected_pc && raw_valid[c] == expected_mask && kind[c] == expected_kind &&
          supported[c] == expected_supported && length_bytes[c] == expected_bytes &&
          generation[c] == expected_generation && fault[c] == expected_fault &&
          cause[c] == expected_cause && mtval[c] == expected_mtval, "packet metadata");
  endtask

  /* a transferred terminal packet parks until a new stream is explicitly selected. */
  task automatic consume(input bit c, input bit park);
    ready[c] = 1;
    tick();
    ready[c] = 0;
    #1;
    check(!valid[c], "one output transfer");
    /* terminal output never advances using an invented unsupported length. */
    if (park) begin
      check(!need_valid[c], "terminal packet parks fetch");
      tick();
      check(!valid[c] && !need_valid[c], "terminal park persists");
    end
  endtask

  /* exercise directed edge cases before exhaustively checking prefix framing. */
  initial begin
    mutate_raw = $test$plusargs("mutate_raw");
    /* establish every input before the first synchronous reset edge. */
    for (int c = 0; c < 2; c = c + 1) begin
      reset[c] = 1; restart[c] = 0; fill_valid[c] = 0; ready[c] = 0;
      restart_pc[c] = 0; restart_generation[c] = 0;
      fill_addr[c] = 0; fill_data[c] = 0; fill_generation[c] = 0;
      fill_parcels[c] = 0; fill_fault[c] = 0;
    end
    tick();
    new_stream(0, 0, 1);
    expect_need(0, 0, 3);
    fill(0, 0, 3, 32'h12340013, 0, 1);
    check(!valid[0], "assembly uses the following edge");
    tick();
    expect_packet(0, 0, 32'h12340013, 15, 2, 1, 4, 1, 0, 0, 0);
    /* backpressure, duplicate data and stale generations cannot mutate the packet. */
    for (int hold_cycle = 0; hold_cycle < 5; hold_cycle = hold_cycle + 1) begin
      fill(0, 0, 3, 32'hffffffff, 3, 8'(hold_cycle + 1));
      expect_packet(0, 0, 32'h12340013, 15, 2, 1, 4, 1, 0, 0, 0);
    end
    consume(0, 0);
    expect_need(0, 4, 3);
    /* a successful upper parcel remains observable after a non-C first fault. */
    fill(0, 4, 3, 32'hbeef0000, 1, 1);
    tick();
    expect_packet(0, 4, 32'hbeef0000, 12, 0, 0, 0, 1, 1, 1, 4);
    consume(0, 1);
    /* a first fault never waits for an absent later parcel. */
    new_stream(0, 8, 2);
    fill(0, 8, 1, 0, 1, 2);
    check(!need_valid[0], "first fault stops further requests");
    tick();
    expect_packet(0, 8, 0, 0, 0, 0, 0, 2, 1, 1, 8);
    /* a required second fault outranks every observed prefix category. */
    for (int prefix = 0; prefix < 3; prefix = prefix + 1) begin
      new_stream(0, 12, 3);
      fill(0, 12, 3, prefix == 0 ? 32'h00000001 :
                          prefix == 1 ? 32'h00000013 : 32'h0000001f, 2, 3);
      tick();
      expect_packet(0, 12, prefix == 0 ? 1 : prefix == 1 ? 19 : 31,
                    3, 2'(prefix + 1), prefix == 1, prefix == 1 ? 4 : 0, 3, 1, 1, 14);
      consume(0, 1);
    end
    /* both configurations reject a misaligned cursor locally without a request. */
    for (int c = 0; c < 2; c = c + 1) begin
      new_stream(1'(c), c == 0 ? 2 : 3, 4);
      check(!need_valid[c], "misaligned cursor never requests");
      tick();
      expect_packet(1'(c), c == 0 ? 2 : 3, 0, 0, 0, 0, 0, 4, 1, 0, c == 0 ? 2 : 3);
      consume(1'(c), 1);
    end
    /* straddling across address wrap rotates the already captured next word. */
    new_stream(1, 32'hfffffffe, 5);
    expect_need(1, 32'hfffffffc, 2);
    fill(1, 32'hfffffffc, 2, 32'h00130000, 0, 5);
    expect_need(1, 0, 1);
    fill(1, 0, 1, 32'h0000cafe, 0, 5);
    tick();
    expect_packet(1, 32'hfffffffe, 32'hcafe0013, 15, 2, 1, 4, 5, 0, 0, 0);
    consume(1, 0);
    expect_need(1, 0, 2);
    fill(1, 0, 2, 32'h00010000, 0, 5);
    tick();
    expect_packet(1, 2, 1, 3, 1, 1, 2, 5, 0, 0, 0);
    consume(1, 0);
    expect_need(1, 4, 1);
    /* a wrapped second-parcel fault preserves the first bytes and wrapped mtval. */
    new_stream(1, 32'hfffffffe, 6);
    fill(1, 32'hfffffffc, 2, 32'h001f0000, 0, 6);
    expect_need(1, 0, 1);
    fill(1, 0, 1, 0, 1, 6);
    tick();
    expect_packet(1, 32'hfffffffe, 31, 3, 3, 0, 0, 6, 1, 1, 0);
    consume(1, 1);
    /* first faults use the required upper halfword address, never its word base. */
    new_stream(1, 258, 7);
    fill(1, 256, 2, 0, 2, 7);
    tick();
    expect_packet(1, 258, 0, 0, 0, 0, 0, 7, 1, 1, 258);
    /* redirect and fill collision cannot insert bytes into the selected generation. */
    restart[1] = 1; restart_pc[1] = 512; restart_generation[1] = 8;
    ready[1] = 1;
    fill(1, 256, 2, 32'h00010000, 0, 7);
    check(!valid[1] && !need_valid[1], "redirect masks a held packet");
    restart[1] = 0; ready[1] = 0; #1;
    expect_need(1, 512, 1);
    fill(1, 512, 1, 1, 0, 7);
    expect_need(1, 512, 1);
    /* held reset discards matching fills as well as mismatched old generations. */
    reset[1] = 1;
    fill(1, 512, 1, 1, 0, 8);
    tick();
    check(!valid[1] && !need_valid[1], "held reset suppresses activity");
    reset[1] = 0; #1;
    expect_need(1, 512, 1);
    /* all halfword prefixes cover short, 32-bit and every longer-width marker. */
    for (int c = 0; c < 2; c = c + 1) begin
      /* every C prefix starts in each halfword position, including aligned long forms. */
      for (int position = 0; position < (c == 0 ? 1 : 2); position = position + 1) begin
      /* enumerate the complete first-parcel encoding space without random sampling. */
      for (int prefix = 0; prefix < 65536; prefix = prefix + 1) begin
        logic [31:0] start_pc, expected_raw;
        logic [1:0] expected_kind;
        bit upper_start, needs_second, expected_supported;
        upper_start = position != 0;
        start_pc = upper_start ? 258 : 256;
        expected_kind = (prefix % 4) != 3 ? 1 : ((prefix / 4) % 8) != 7 ? 2 : 3;
        needs_second = c == 0 || expected_kind != 1;
        expected_supported = expected_kind == 2 || (c != 0 && expected_kind == 1);
        expected_raw = needs_second ? {16'habcd, 16'(prefix)} : {16'b0, 16'(prefix)};
        new_stream(1'(c), start_pc, 9);
        expect_need(1'(c), 256, c == 0 ? 3 : upper_start ? 2 : 1);
        fill(1'(c), 256, c == 0 ? 3 : upper_start ? 2 : 1,
             c == 0 ? {16'habcd, 16'(prefix)} : upper_start ? {16'(prefix), 16'b0} :
             {16'b0, 16'(prefix)}, 0, 9);
        /* the framing-only configuration requests a second parcel only if required. */
        if (c != 0 && needs_second) begin
          expect_need(1'(c), upper_start ? 260 : 256, upper_start ? 1 : 2);
          fill(1'(c), upper_start ? 260 : 256, upper_start ? 1 : 2,
               upper_start ? 32'habcd : 32'habcd0000, 0, 9);
        end
        tick();
        expect_packet(1'(c), start_pc, expected_raw, needs_second ? 15 : 3,
                      expected_kind, expected_supported,
                      expected_supported ? expected_kind == 1 ? 2 : 4 : 0, 9, 0, 0, 0);
        prefix_cases = prefix_cases + 1;
      end
      end
    end
    $display("FETCH_BUFFER_PASS edges=%0d checks=%0d prefix_cases=%0d", edges, checks, prefix_cases);
    $finish;
  end
endmodule

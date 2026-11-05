/* check the RF ports against independent storage and edge-capture models. */
module drg5_regfile_tb;
  logic clk_i, reset_i, write_valid_i;
  logic [4:0] write_addr_i, read1_addr_i, read2_addr_i;
  logic [31:0] write_data_i;
  wire [31:0] data1 [0:3], data2 [0:3];
  wire defined1 [0:3], defined2 [0:3];
  logic [31:0] expected [0:31];
  logic [31:0] known;
  logic [31:0] random_q;
  int checks, edges;
  drg5_rf_ff ff(.clk_i, .reset_i, .write_valid_i, .write_addr_i, .write_data_i,
    .read1_addr_i, .read2_addr_i, .read1_data_o(data1[0]), .read2_data_o(data2[0]),
    .read1_defined_o(defined1[0]), .read2_defined_o(defined2[0]));
  drg5_rf_distributed distributed(.clk_i, .reset_i, .write_valid_i, .write_addr_i, .write_data_i,
    .read1_addr_i, .read2_addr_i, .read1_data_o(data1[1]), .read2_data_o(data2[1]),
    .read1_defined_o(defined1[1]), .read2_defined_o(defined2[1]));
  drg5_rf_bram bram(.clk_i, .reset_i, .write_valid_i, .write_addr_i, .write_data_i,
    .read1_addr_i, .read2_addr_i, .read1_data_o(data1[2]), .read2_data_o(data2[2]),
    .read1_defined_o(defined1[2]), .read2_defined_o(defined2[2]));

  drg5_regfile selected(.clk_i, .reset_i, .write_valid_i, .write_addr_i, .write_data_i,
    .read1_addr_i, .read2_addr_i, .read1_data_o(data1[3]), .read2_data_o(data2[3]),
    .read1_defined_o(defined1[3]), .read2_defined_o(defined2[3]));

  /* report a concrete failed property rather than accepting a process exit. */
  task automatic require(input bit condition, input string message);
    checks++;
    /* enforce this independently predicted condition. */
    if (!condition) $fatal(1, "RF_CHECK_FAILED %s edge=%0d", message, edges);
  endtask

  /* derive each read from the independent register contents and write intent. */
  task automatic predict(input logic [4:0] addr, output logic [31:0] value,
                         output logic valid);
    value = expected[addr];
    valid = known[addr] && !reset_i;
    /* x0 overrides storage and pending writes. */
    if (addr == 0) begin
      value = 0;
      valid = 1;
    end
    /* pending nonzero writes bypass storage before the committing edge. */
    else if (write_valid_i && !reset_i && addr == write_addr_i) begin
      value = write_data_i;
      valid = 1;
    end
  endtask

  /* asynchronous candidates must follow changed addresses without a clock. */
  task automatic check_async;
    logic [31:0] value1, value2, observed;
    logic valid1, valid2;
    predict(read1_addr_i, value1, valid1);
    predict(read2_addr_i, value2, valid2);
    /* visit every independently checked address or implementation. */
    for (int i = 0; i < 4; i++) begin
      /* check the synchronous candidate at its capture edge instead. */
      if (i == 2) continue;
      require(defined1[i] == valid1 && defined2[i] == valid2, "async definedness");
      observed = data1[i];
      /* inject only the selected detector-control observation. */
      if ($test$plusargs("mutate_x0") && read1_addr_i == 0) observed ^= 1;
      /* inject only the selected detector-control observation. */
      if ($test$plusargs("mutate_bypass") && write_valid_i && !reset_i &&
          write_addr_i != 0 && read1_addr_i == write_addr_i) observed ^= 1;
      /* compare data only when the architectural value is defined. */
      if (valid1) require(observed == value1, "async read1 value or bypass");
      /* compare data only when the architectural value is defined. */
      if (valid2) require(data2[i] == value2, "async read2 value or bypass");
    end
  endtask

  /* sample synchronous reads from pre-edge state and update storage once. */
  task automatic tick;
    logic [31:0] value1, value2;
    logic valid1, valid2;
    clk_i = 0;
    #2;
    check_async();
    predict(read1_addr_i, value1, valid1);
    predict(read2_addr_i, value2, valid2);
    /* apply reset before any write can commit. */
    if (reset_i) known = 32'b1;
    /* compare data only when the architectural value is defined. */
    else if (write_valid_i && write_addr_i != 0) begin
      expected[write_addr_i] = write_data_i;
      known[write_addr_i] = 1;
    end
    clk_i = 1;
    #2;
    edges++;
    require(defined1[2] == valid1 && defined2[2] == valid2, "BRAM captured definedness");
    /* compare data only when the architectural value is defined. */
    if (valid1) require(data1[2] == value1, "BRAM captured read1");
    /* compare data only when the architectural value is defined. */
    if (valid2) require(data2[2] == value2, "BRAM captured read2");
    check_async();
    clk_i = 0;
    #1;
  endtask

  /* exercise reset, all read pairs, collisions, canceled writes and random traffic. */
  initial begin
    logic [31:0] held1, held2;
    checks = 0;
    edges = 0;
    clk_i = 0;
    reset_i = 1;
    write_valid_i = 0;
    write_addr_i = 0;
    write_data_i = 0;
    read1_addr_i = 0;
    read2_addr_i = 0;
    known = 1;
    random_q = 32'h3a59c7e1;
    /* visit every independently checked address or implementation. */
    for (int i = 0; i < 32; i++) expected[i] = 0;
    tick();
    reset_i = 0;
    /* initialize every architectural register while testing dual-port bypass. */
    for (int i = 1; i < 32; i++) begin
      write_valid_i = 1;
      write_addr_i = 5'(i);
      write_data_i = 32'h91a50000 ^ (32'(i) * 32'h01020409);
      read1_addr_i = 5'(i);
      read2_addr_i = 5'(i);
      tick();
    end
    write_valid_i = 0;
    /* traverse every pair without clocking; the BRAM outputs must remain held. */
    held1 = data1[2];
    held2 = data2[2];
    /* visit every independently checked address or implementation. */
    for (int i = 0; i < 32; i++) begin
      /* visit every independently checked address or implementation. */
      for (int j = 0; j < 32; j++) begin
        read1_addr_i = 5'(i);
        read2_addr_i = 5'(j);
        #1;
        check_async();
        require(data1[2] == held1 && data2[2] == held2, "BRAM changed without an edge");
      end
    end
    /* a canceled pending write changes bypass but cannot change storage. */
    read1_addr_i = 7;
    read2_addr_i = 7;
    write_addr_i = 7;
    write_data_i = 32'habcdef01;
    write_valid_i = 1;
    #1;
    check_async();
    write_valid_i = 0;
    #1;
    check_async();
    require(data1[0] == expected[7] && data1[1] == expected[7], "canceled write committed");
    /* x0 ignores writes and stays defined through reset. */
    write_valid_i = 1;
    write_addr_i = 0;
    write_data_i = 32'hffffffff;
    read1_addr_i = 0;
    read2_addr_i = 0;
    tick();
    /* reset wins a pending write; raw stored data itself is not reset. */
    write_addr_i = 7;
    read1_addr_i = 7;
    read2_addr_i = 7;
    reset_i = 1;
    tick();
    require(data1[0] == expected[7] && data1[1] == expected[7] && data1[3] == expected[7], "reset changed stored data");
    reset_i = 0;
    write_valid_i = 0;
    tick();
    /* an undefined destination becomes temporarily defined through bypass only. */
    write_addr_i = 9;
    read1_addr_i = 9;
    read2_addr_i = 9;
    write_valid_i = 1;
    #1;
    check_async();
    write_valid_i = 0;
    #1;
    check_async();
    require(!defined1[0] && !defined1[1], "canceled write retained definedness");
    /* generate deterministic address changes and reset/write collisions. */
    for (int i = 0; i < 2000; i++) begin
      random_q = random_q ^ (random_q << 13);
      random_q = random_q ^ (random_q >> 17);
      random_q = random_q ^ (random_q << 5);
      reset_i = i % 97 == 0;
      write_valid_i = random_q[31];
      write_addr_i = random_q[4:0];
      read1_addr_i = i % 3 == 0 ? write_addr_i : random_q[12:8];
      read2_addr_i = i % 5 == 0 ? write_addr_i : random_q[20:16];
      write_data_i = random_q;
      tick();
    end
    $display("RF_PASS edges=%0d checks=%0d async_read_pairs=1024", edges, checks);
    $finish;
  end
endmodule

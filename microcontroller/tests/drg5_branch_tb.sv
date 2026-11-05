/* compare decoded transfers with independent widened arithmetic in both modes. */
module drg5_branch_tb;
  logic [31:0] pc_i, rs1_i, rs2_i, imm_i;
  logic [3:0] kind_i;
  logic [2:0] cond_i, length_i;
  logic valid_o [0:1], taken_o [0:1], misaligned_o [0:1];
  logic [31:0] target_o [0:1], next_pc_o [0:1], link_o [0:1];
  logic [31:0] random_state = 32'h12345678;
  int unsigned cases = 0, checks = 0;
  bit mutate_target;
  localparam logic [31:0] VALUES [0:11] = '{
    0, 1, 2, 3, 4, 32'h7fffffff, 32'h80000000, 32'h80000001,
    32'hfffffffc, 32'hfffffffe, 32'hffffffff, 32'h55aa55aa
  };

  /* optional short lengths exercise future decoded micro-ops, not a C decoder. */
  for (genvar c = 0; c < 2; c = c + 1) begin : configs
    drg5_branch #(.C_ENABLED(c != 0)) dut (
      .pc_i, .rs1_i, .rs2_i, .imm_i, .kind_i, .cond_i, .length_i,
      .valid_o(valid_o[c]), .taken_o(taken_o[c]), .misaligned_o(misaligned_o[c]),
      .target_o(target_o[c]), .next_pc_o(next_pc_o[c]), .link_o(link_o[c])
    );
  end

  /* count every checked field and fail with the responsible input values. */
  task automatic check(input bit condition, input string label_text);
    checks = checks + 1;
    /* parser errors and unrelated exits cannot satisfy this comparator signature. */
    if (!condition) $fatal(1, "BRANCH_CHECK_FAILED %s pc=%h a=%h b=%h imm=%h kind=%d cond=%d len=%d",
                          label_text, pc_i, rs1_i, rs2_i, imm_i, kind_i, cond_i, length_i);
  endtask

  /* a local generator makes traffic reproducible without simulator random state. */
  task automatic random_word(output logic [31:0] value);
    random_state = random_state ^ (random_state << 13);
    random_state = random_state ^ (random_state >> 17);
    random_state = random_state ^ (random_state << 5);
    value = random_state;
  endtask

  /* use signed 64-bit values and modulo arithmetic independently of DUT logic. */
  task automatic compare;
    longint signed a_signed, b_signed;
    longint unsigned target_wide, link_wide;
    logic [31:0] expected_target, expected_link, expected_next, observed_target;
    bit compare_value, condition_ok, expected_valid, expected_taken, expected_fault;
    a_signed = $signed({{32{rs1_i[31]}}, rs1_i});
    b_signed = $signed({{32{rs2_i[31]}}, rs2_i});
    compare_value = 0;
    condition_ok = 1;
    /* each legal condition uses its direct mathematical relation. */
    case (cond_i)
      0: compare_value = a_signed == b_signed;
      1: compare_value = a_signed != b_signed;
      4: compare_value = a_signed < b_signed;
      5: compare_value = a_signed >= b_signed;
      6: compare_value = {32'b0, rs1_i} < {32'b0, rs2_i};
      7: compare_value = {32'b0, rs1_i} >= {32'b0, rs2_i};
      default: condition_ok = 0;
    endcase
    #1;
    /* invalid fields and both alignment modes are checked for every stimulus. */
    for (int c = 0; c < 2; c = c + 1) begin
      expected_valid = (length_i == 4 || (c != 0 && length_i == 2)) &&
                       (kind_i == 5 || kind_i == 6 || (kind_i == 7 && condition_ok));
      expected_taken = 0; expected_target = 0; expected_link = 0;
      expected_next = 0; expected_fault = 0;
      /* retain diagnostic arithmetic on a valid misaligned transfer. */
      if (expected_valid) begin
        target_wide = (kind_i == 6 ? {32'b0, rs1_i} : {32'b0, pc_i}) + {32'b0, imm_i};
        link_wide = {32'b0, pc_i} + {61'b0, length_i};
        check(target_wide <= 64'h1fffffffe && link_wide <= 64'h100000006,
              "reference arithmetic range");
        expected_target = target_wide[31:0];
        /* JALR rounds down only after the modulo address addition. */
        if (kind_i == 6) expected_target = (expected_target / 2) * 2;
        expected_link = link_wide[31:0];
        expected_taken = kind_i == 7 ? compare_value : 1;
        expected_next = expected_taken ? expected_target : expected_link;
        expected_fault = expected_taken && (expected_target % (c != 0 ? 2 : 4)) != 0;
      end
      observed_target = target_o[c] ^ (mutate_target ? 32'd1 : 32'd0);
      check(observed_target == expected_target, "target");
      check(valid_o[c] == expected_valid, "valid");
      check(taken_o[c] == expected_taken, "taken");
      check(misaligned_o[c] == expected_fault, "alignment");
      check(link_o[c] == expected_link, "original-length link");
      check(next_pc_o[c] == expected_next, "next PC");
    end
    cases = cases + 1;
  endtask

  /* combine directed alias examples, boundary products and full-width random words. */
  initial begin
    mutate_target = $test$plusargs("mutate_target");
    pc_i = 32'h100; rs1_i = 32'h80000001; rs2_i = 0; imm_i = 2;
    kind_i = 6; cond_i = 3; length_i = 4;
    compare();
    /* rd=rs1 callers retain this old operand until the independently computed link commits. */
    check(target_o[1] == 32'h80000002 && link_o[1] == 32'h104,
          "JALR uses captured source rather than link");
    /* an odd untaken conditional target must not produce a target-alignment fault. */
    pc_i = 0; rs1_i = 0; rs2_i = 1; imm_i = 1; kind_i = 7; cond_i = 0;
    compare();
    check(!misaligned_o[0] && !taken_o[0] && next_pc_o[0] == 4, "untaken target ignored");
    /* exhaust signs, equality, wrap, negative offsets, condition codes and all lengths. */
    for (int a = 0; a < 12; a = a + 1) begin
      /* boundary pairs include both signed overflow directions. */
      for (int b = 0; b < 12; b = b + 1) begin
        /* each immediate also changes the independent instruction PC. */
        for (int offset = 0; offset < 12; offset = offset + 1) begin
          pc_i = VALUES[(offset + 5) % 12];
          rs1_i = VALUES[a]; rs2_i = VALUES[b]; imm_i = VALUES[offset];
          /* include every operation selector so unsupported kinds have benign outputs. */
          for (int operation = 0; operation < 16; operation = operation + 1) begin
            kind_i = 4'(operation);
            /* invalid condition values are active only for conditional transfers. */
            for (int condition = 0; condition < 8; condition = condition + 1) begin
              cond_i = 3'(condition);
              /* unsupported original widths must reject every kind. */
              for (int length = 0; length < 8; length = length + 1) begin
                length_i = 3'(length);
                compare();
              end
            end
          end
        end
      end
    end
    /* exercise arbitrary addresses and full-width signed operands after the boundaries. */
    for (int sample = 0; sample < 20000; sample = sample + 1) begin
      logic [31:0] selectors;
      random_word(pc_i); random_word(rs1_i); random_word(rs2_i); random_word(imm_i);
      random_word(selectors);
      kind_i = sample % 4 == 3 ? 4'(selectors % 127) : 4'(5 + sample % 3);
      cond_i = 3'((selectors / 17) % 8);
      length_i = sample % 3 == 2 ? 3'((selectors / 193) % 8) : sample % 3 == 0 ? 4 : 2;
      compare();
    end
    $display("BRANCH_PASS cases=%0d checks=%0d", cases, checks);
    $finish;
  end
endmodule

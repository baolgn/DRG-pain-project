/* verify isolated combinational blocks without claiming CPU conformance. */
module drg5_datapath_tb;
  /* compare the complete public decode record, including benign defaults. */
  typedef struct packed {
    logic legal;
    logic [3:0] kind;
    logic [3:0] alu_op;
    logic [2:0] imm_kind;
    logic rs1_used, rs2_used, rd_write;
    logic [4:0] rs1, rs2, rd;
    logic a_pc, b_imm;
    logic [2:0] branch_cond;
    logic [1:0] mem_size;
    logic load_signed;
  } decode_t;

  /* describe ISA encodings through independent masks and operation metadata. */
  typedef struct packed {
    logic [31:0] mask, match;
    logic [3:0] kind, alu_op;
    logic [2:0] imm_kind;
  } encoding_t;

  /* this independent mask table lists the forty RV32I instruction encodings. */
  localparam encoding_t ENCODINGS [0:39] = '{
    '{32'h0000007f, 32'h00000037, 3, 10, 4},
    '{32'h0000007f, 32'h00000017, 4, 0, 4},
    '{32'h0000007f, 32'h0000006f, 5, 0, 5},
    '{32'h0000707f, 32'h00000067, 6, 0, 1},
    '{32'h0000707f, 32'h00000063, 7, 1, 3},
    '{32'h0000707f, 32'h00001063, 7, 1, 3},
    '{32'h0000707f, 32'h00004063, 7, 1, 3},
    '{32'h0000707f, 32'h00005063, 7, 1, 3},
    '{32'h0000707f, 32'h00006063, 7, 1, 3},
    '{32'h0000707f, 32'h00007063, 7, 1, 3},
    '{32'h0000707f, 32'h00000003, 8, 0, 1},
    '{32'h0000707f, 32'h00001003, 8, 0, 1},
    '{32'h0000707f, 32'h00002003, 8, 0, 1},
    '{32'h0000707f, 32'h00004003, 8, 0, 1},
    '{32'h0000707f, 32'h00005003, 8, 0, 1},
    '{32'h0000707f, 32'h00000023, 9, 0, 2},
    '{32'h0000707f, 32'h00001023, 9, 0, 2},
    '{32'h0000707f, 32'h00002023, 9, 0, 2},
    '{32'h0000707f, 32'h00000013, 2, 0, 1},
    '{32'h0000707f, 32'h00002013, 2, 3, 1},
    '{32'h0000707f, 32'h00003013, 2, 4, 1},
    '{32'h0000707f, 32'h00004013, 2, 5, 1},
    '{32'h0000707f, 32'h00006013, 2, 8, 1},
    '{32'h0000707f, 32'h00007013, 2, 9, 1},
    '{32'hfe00707f, 32'h00001013, 2, 2, 6},
    '{32'hfe00707f, 32'h00005013, 2, 6, 6},
    '{32'hfe00707f, 32'h40005013, 2, 7, 6},
    '{32'hfe00707f, 32'h00000033, 1, 0, 0},
    '{32'hfe00707f, 32'h40000033, 1, 1, 0},
    '{32'hfe00707f, 32'h00001033, 1, 2, 0},
    '{32'hfe00707f, 32'h00002033, 1, 3, 0},
    '{32'hfe00707f, 32'h00003033, 1, 4, 0},
    '{32'hfe00707f, 32'h00004033, 1, 5, 0},
    '{32'hfe00707f, 32'h00005033, 1, 6, 0},
    '{32'hfe00707f, 32'h40005033, 1, 7, 0},
    '{32'hfe00707f, 32'h00006033, 1, 8, 0},
    '{32'hfe00707f, 32'h00007033, 1, 9, 0},
    '{32'h0000707f, 32'h0000000f, 10, 0, 0},
    '{32'hffffffff, 32'h00000073, 11, 0, 0},
    '{32'hffffffff, 32'h00100073, 12, 0, 0}
  };

  /* cover sign changes, carries, shift boundaries and alternating bit patterns. */
  localparam logic [31:0] BOUNDARIES [0:11] = '{
    0, 1, 2, 31, 32, 33, 32'h7fffffff, 32'h80000000,
    32'hffffffff, 32'hfffffffe, 32'h55555555, 32'haaaaaaaa
  };

  logic [31:0] instr_i = 0;
  logic legal_o, rs1_used_o, rs2_used_o, rd_write_o, a_pc_o, b_imm_o, load_signed_o;
  logic [3:0] kind_o, alu_op_o;
  logic [2:0] imm_kind_o, branch_cond_o;
  logic [4:0] rs1_o, rs2_o, rd_o;
  logic [1:0] mem_size_o;
  decode_t actual_decode;
  logic [2:0] immediate_kind = 0;
  logic [31:0] immediate_value;
  logic immediate_valid;
  logic [31:0] shift_value = 0, shift_amount = 0, shift_result;
  logic [1:0] shift_op = 0;
  logic shift_valid;
  logic [31:0] alu_a = 0, alu_b = 0, alu_result;
  logic [3:0] alu_op = 0;
  logic alu_valid, alu_eq, alu_lt_signed, alu_lt_unsigned;
  logic [31:0] seed = 1, random_state = 1;
  int unsigned decode_checks = 0, immediate_checks = 0, alu_checks = 0, shift_checks = 0;
  int unsigned legal_checks = 0, illegal_checks = 0;
  bit mutation_applied = 0;

  /* exercise each public block independently, including the ALU shifter instance. */
  drg5_decoder decoder (.*);
  drg5_immediate immediate_decoder (
    .instr_i(instr_i), .kind_i(immediate_kind), .value_o(immediate_value), .valid_o(immediate_valid)
  );
  drg5_shifter shifter (
    .value_i(shift_value), .amount_i(shift_amount), .op_i(shift_op),
    .value_o(shift_result), .valid_o(shift_valid)
  );
  drg5_alu alu (
    .a_i(alu_a), .b_i(alu_b), .op_i(alu_op), .result_o(alu_result), .valid_o(alu_valid),
    .eq_o(alu_eq), .lt_signed_o(alu_lt_signed), .lt_unsigned_o(alu_lt_unsigned)
  );
  assign actual_decode = {legal_o, kind_o, alu_op_o, imm_kind_o,
      rs1_used_o, rs2_used_o, rd_write_o, rs1_o, rs2_o, rd_o,
      a_pc_o, b_imm_o, branch_cond_o, mem_size_o, load_signed_o};

  /* identify the exact reproducible stimulus at the first mismatch. */
  function automatic void check(input bit condition, input string message);
    /* a failed comparator terminates instead of corrupting later evidence. */
    if (!condition) begin
      $fatal(1, {"seed=%0d decode=%0d immediate=%0d alu=%0d shift=%0d instr=%08x ",
                 "imm_kind=%0d alu_a=%08x alu_b=%08x alu_op=%0d ",
                 "shift_value=%08x shift_amount=%08x shift_op=%0d: %s"},
             seed, decode_checks, immediate_checks, alu_checks, shift_checks, instr_i,
             immediate_kind, alu_a, alu_b, alu_op, shift_value, shift_amount, shift_op, message);
    end
  endfunction

  /* this specified modulo-2^32 generator accepts zero as a normal seed. */
  function automatic logic [31:0] next_random();
    random_state = random_state * 32'd1664525 + 32'd1013904223;
    return random_state;
  endfunction

  /* recognize masked specification rows independently of the opcode-case RTL. */
  function automatic decode_t decode_reference(input logic [31:0] word);
    decode_t expected;
    bit has_destination;
    int unsigned hit_count;
    expected = '0;
    hit_count = 0;
    has_destination = 0;
    /* each legal word must match exactly one instruction family row. */
    for (int i = 0; i < 40; i++) begin
      /* reserved operand fields are excluded only where the ISA permits them. */
      if ((word & ENCODINGS[i].mask) == ENCODINGS[i].match) begin
        expected.legal = 1;
        expected.kind = ENCODINGS[i].kind;
        expected.alu_op = ENCODINGS[i].alu_op;
        expected.imm_kind = ENCODINGS[i].imm_kind;
        hit_count++;
      end
    end
    check(hit_count <= 1, "independent encoding table overlapped");
    /* operation classes determine use masks rather than register index values. */
    case (expected.kind)
      /* register arithmetic retains both source uses even for HINTs. */
      1: begin
        expected.rs1_used = 1;
        expected.rs2_used = 1;
        has_destination = 1;
      end
      /* immediate arithmetic and JALR use one source and one immediate. */
      2, 6: begin
        expected.rs1_used = 1;
        expected.b_imm = 1;
        has_destination = 1;
      end
      /* LUI takes only its upper immediate. */
      3: begin
        expected.b_imm = 1;
        has_destination = 1;
      end
      /* AUIPC and JAL use the instruction PC plus their immediate. */
      4, 5: begin
        expected.a_pc = 1;
        expected.b_imm = 1;
        has_destination = 1;
      end
      /* conditional branches compare both sources and retain their condition. */
      7: begin
        expected.rs1_used = 1;
        expected.rs2_used = 1;
        expected.branch_cond = word[14:12];
      end
      /* loads retain their memory operation even with an x0 destination. */
      8: begin
        expected.rs1_used = 1;
        expected.b_imm = 1;
        expected.mem_size = word[13:12];
        expected.load_signed = !word[14];
        has_destination = 1;
      end
      /* store data remains a source while its address uses an immediate. */
      9: begin
        expected.rs1_used = 1;
        expected.rs2_used = 1;
        expected.b_imm = 1;
        expected.mem_size = word[13:12];
      end
      /* fence, environment and illegal records retain zero execution metadata. */
      default: begin end
    endcase
    expected.rs1 = expected.rs1_used ? word[19:15] : 0;
    expected.rs2 = expected.rs2_used ? word[24:20] : 0;
    expected.rd_write = has_destination && word[11:7] != 0;
    expected.rd = expected.rd_write ? word[11:7] : 0;
    return expected;
  endfunction

  /* route each output bit separately rather than copying RTL concatenations. */
  function automatic logic [31:0] immediate_reference(input logic [31:7] word,
                                                      input logic [2:0] format);
    logic [31:0] value;
    int source_bit;
    value = 0;
    /* a negative source index denotes a fixed zero bit. */
    for (int bit_number = 0; bit_number < 32; bit_number++) begin
      source_bit = -1;
      /* each format is a mapping from destination positions to source positions. */
      case (format)
        1: source_bit = bit_number < 12 ? bit_number + 20 : 31;
        2: source_bit = bit_number < 5 ? bit_number + 7 :
                        (bit_number < 12 ? bit_number + 20 : 31);
        3: source_bit = bit_number == 0 ? -1 :
                        (bit_number < 5 ? bit_number + 7 :
                        (bit_number < 11 ? bit_number + 20 :
                        (bit_number == 11 ? 7 : 31)));
        4: source_bit = bit_number < 12 ? -1 : bit_number;
        5: source_bit = bit_number == 0 ? -1 :
                        (bit_number < 11 ? bit_number + 20 :
                        (bit_number == 11 ? 20 : (bit_number < 20 ? bit_number : 31)));
        6: source_bit = bit_number < 5 ? bit_number + 20 : -1;
        default: source_bit = -1;
      endcase
      /* fixed-zero fields do not read any instruction position. */
      if (source_bit >= 7) begin
        value[bit_number] = word[source_bit];
      end
    end
    return value;
  endfunction

  /* reconstruct shifts by source-bit indexing rather than shift operators. */
  function automatic logic [31:0] shift_reference(input logic [31:0] value,
                                                 input logic [4:0] amount,
                                                 input logic [1:0] operation);
    logic [31:0] result;
    int source_bit;
    result = 0;
    /* an invalid operation always produces the benign zero result. */
    if (operation < 3) begin
      /* each output bit independently selects a source or fill bit. */
      for (int bit_number = 0; bit_number < 32; bit_number++) begin
        source_bit = operation == 0 ? bit_number - int'(amount) : bit_number + int'(amount);
        /* in-range positions copy their original bit. */
        if (source_bit >= 0 && source_bit < 32) begin
          result[bit_number] = value[source_bit];
        end
        /* only an arithmetic right shift extends the original sign. */
        else if (operation == 2) begin
          result[bit_number] = value[31];
        end
      end
    end
    return result;
  endfunction

  /* signed comparison first separates signs, then compares magnitudes. */
  function automatic bit signed_less(input logic [31:0] a, input logic [31:0] b);
    return a[31] != b[31] ? a[31] : a < b;
  endfunction

  /* independently model wrapping arithmetic, comparisons and shifts. */
  function automatic logic [31:0] alu_reference(input logic [31:0] a,
                                               input logic [31:0] b,
                                               input logic [3:0] operation);
    logic [63:0] wide;
    wide = 0;
    /* subtraction is modeled through complement and carry in a wider domain. */
    case (operation)
      0: wide = {32'b0, a} + {32'b0, b};
      1: wide = {32'b0, a} + {32'b0, ~b} + 64'd1;
      2: wide = {32'b0, shift_reference(a, b[4:0], 0)};
      3: wide = 64'(signed_less(a, b));
      4: wide = 64'(a < b);
      5: wide = {32'b0, a ^ b};
      6: wide = {32'b0, shift_reference(a, b[4:0], 1)};
      7: wide = {32'b0, shift_reference(a, b[4:0], 2)};
      8: wide = {32'b0, a | b};
      9: wide = {32'b0, a & b};
      10: wide = {32'b0, b};
      default: wide = 0;
    endcase
    check(wide < 64'h0000000200000000, "widened arithmetic reference overflowed its bound");
    return 32'(wide);
  endfunction

  /* compare every decode output, including normalized illegal metadata. */
  task automatic test_decode(input logic [31:0] word);
    decode_t expected, observed;
    instr_i = word;
    expected = decode_reference(word);
    #1;
    observed = actual_decode;
    /* activate a plausible legal-instruction loss to qualify the comparator. */
    if ($test$plusargs("mutate_decode") && !mutation_applied && expected.legal) begin
      observed.legal = 0;
      mutation_applied = 1;
    end
    /* an illegal record must not enable a side effect even with legal still low. */
    if ($test$plusargs("mutate_illegal") && !mutation_applied && !expected.legal) begin
      observed.rd_write = 1;
      mutation_applied = 1;
    end
    decode_checks++;
    legal_checks += int'(expected.legal);
    illegal_checks += int'(!expected.legal);
    check(observed == expected, "decoder reference mismatch");
  endtask

  /* verify standalone immediate modes without depending on decode selection. */
  task automatic test_immediate(input logic [31:0] word, input logic [2:0] format);
    logic [31:0] expected, observed;
    instr_i = word;
    immediate_kind = format;
    expected = immediate_reference(word[31:7], format);
    #1;
    observed = immediate_value;
    /* a changed low bit must fail the independent immediate mapping. */
    if ($test$plusargs("mutate_immediate") && !mutation_applied && format != 7) begin
      observed ^= 1;
      mutation_applied = 1;
    end
    immediate_checks++;
    check(immediate_valid == (format != 7) && observed == expected,
          "immediate reference mismatch");
  endtask

  /* check all arithmetic outputs even when the operation itself is invalid. */
  task automatic test_alu(input logic [31:0] a, input logic [31:0] b,
                          input logic [3:0] operation);
    logic [31:0] expected, observed;
    bit observed_eq;
    alu_a = a;
    alu_b = b;
    alu_op = operation;
    expected = alu_reference(a, b, operation);
    #1;
    observed = alu_result;
    observed_eq = alu_eq;
    /* corrupt a valid arithmetic result rather than accepting a vacuous run. */
    if ($test$plusargs("mutate_alu") && !mutation_applied && operation <= 10) begin
      observed ^= 1;
      mutation_applied = 1;
    end
    /* comparisons remain checked during an explicitly unsupported ALU operation. */
    if ($test$plusargs("mutate_compare") && !mutation_applied && operation == 15) begin
      observed_eq = !observed_eq;
      mutation_applied = 1;
    end
    alu_checks++;
    check(alu_valid == (operation <= 10) && observed == expected,
          "ALU reference mismatch");
    check(observed_eq == (a == b) && alu_lt_signed == signed_less(a, b) &&
          alu_lt_unsigned == (a < b), "ALU comparison mismatch");
  endtask

  /* high amount bits must never alter the RV32 shift result. */
  task automatic test_shift(input logic [31:0] value, input logic [31:0] amount,
                            input logic [1:0] operation);
    logic [31:0] expected, observed;
    shift_value = value;
    shift_amount = amount;
    shift_op = operation;
    expected = shift_reference(value, amount[4:0], operation);
    #1;
    observed = shift_result;
    /* the shifter comparator must detect a changed computed bit. */
    if ($test$plusargs("mutate_shift") && !mutation_applied && operation < 3) begin
      observed ^= 1;
      mutation_applied = 1;
    end
    shift_checks++;
    check(shift_valid == (operation < 3) && observed == expected,
          "shifter reference mismatch");
  endtask

  /* combine exhaustive structural cases with explicit reproducible operands. */
  initial begin : regression
    logic [31:0] word, a, b;
    bit seed_supplied;
    seed_supplied = $value$plusargs("seed=%d", seed);
    random_state = seed;
    $display("datapath seed=%0d explicit=%0d generator=lcg32:1664525:1013904223",
             seed, seed_supplied);
    /* both source/destination extremes expose incorrect x0 and HINT filtering. */
    for (int registers = 0; registers < 2; registers++) begin
      /* enumerate every seven-bit opcode including unsupported instruction lengths. */
      for (int opcode = 0; opcode < 128; opcode++) begin
        /* every funct3 is considered even when the opcode treats it as immediate data. */
        for (int function3 = 0; function3 < 8; function3++) begin
          /* every funct7 exposes reserved arithmetic and shift encodings. */
          for (int function7 = 0; function7 < 128; function7++) begin
            word = (32'(function7) << 25) | (32'(function3) << 12) | 32'(opcode);
            /* nonzero register fields must not accidentally validate SYSTEM encodings. */
            if (registers != 0) begin
              word |= (32'd31 << 20) | (32'd31 << 15) | (32'd31 << 7);
            end
            test_decode(word);
          end
        end
      end
    end
    /* each canonical instruction and every register index receive direct checks. */
    for (int instruction = 0; instruction < 40; instruction++) begin
      test_decode(ENCODINGS[instruction].match);
      /* independently change each index without assuming it is an operand field. */
      for (int reg_index = 0; reg_index < 32; reg_index++) begin
        test_decode((ENCODINGS[instruction].match & ~32'h00000f80) | (32'(reg_index) << 7));
        test_decode((ENCODINGS[instruction].match & ~32'h000f8000) | (32'(reg_index) << 15));
        test_decode((ENCODINGS[instruction].match & ~32'h01f00000) | (32'(reg_index) << 20));
      end
    end
    /* exhaust all SYSTEM immediate values with the required zero register fields. */
    for (int immediate = 0; immediate < 4096; immediate++) begin
      test_decode((32'(immediate) << 20) | 32'h73);
    end
    /* all FENCE fm, predecessor and successor fields remain compatible. */
    for (int fields = 0; fields < 4096; fields++) begin
      test_decode((32'(fields) << 20) | 32'h000f8f8f);
    end
    /* exhaustive compact immediates test every source-bit combination and sign. */
    for (int payload = 0; payload < 4096; payload++) begin
      test_immediate(32'(payload) << 20, 1);
      word = ((32'(payload) & 32'hfe0) << 20) | ((32'(payload) & 31) << 7);
      test_immediate(word, 2);
      word = ((32'(payload) & 32'h800) << 20) | ((32'(payload) & 32'h400) >> 3) |
             ((32'(payload) & 32'h3f0) << 21) | ((32'(payload) & 15) << 8);
      test_immediate(word, 3);
    end
    /* walking source bits cover every mapping, fixed zero and sign replication. */
    for (int format = 0; format < 8; format++) begin
      test_immediate(0, 3'(format));
      test_immediate('1, 3'(format));
      /* both polarities make sign-extension and ignored-bit failures visible. */
      for (int bit_number = 0; bit_number < 32; bit_number++) begin
        test_immediate(32'b1 << bit_number, 3'(format));
        test_immediate(~(32'b1 << bit_number), 3'(format));
      end
    end
    /* every ALU operation sees all pairs of signed and unsigned boundary values. */
    for (int operation = 0; operation < 16; operation++) begin
      /* compare each first operand against every boundary second operand. */
      for (int lhs = 0; lhs < 12; lhs++) begin
        /* pairs include equality, overflow, underflow and opposite signs. */
        for (int rhs = 0; rhs < 12; rhs++) begin
          test_alu(BOUNDARIES[lhs], BOUNDARIES[rhs], 4'(operation));
        end
      end
    end
    /* enumerate every low-five-bit shift count, including all invalid operations. */
    for (int operation = 0; operation < 4; operation++) begin
      /* high bits are independently varied without changing the expected count. */
      for (int amount = 0; amount < 32; amount++) begin
        /* boundary values expose every fill-bit and direction rule. */
        for (int value = 0; value < 12; value++) begin
          test_shift(BOUNDARIES[value], 32'(amount), 2'(operation));
          test_shift(BOUNDARIES[value], 32'hffffffe0 | 32'(amount), 2'(operation));
          test_shift(BOUNDARIES[value], 32'h80000000 | 32'(amount), 2'(operation));
        end
      end
    end
    /* random bit patterns supplement structural cases without replacing them. */
    for (int sample = 0; sample < 20000; sample++) begin
      word = next_random();
      a = next_random();
      b = next_random();
      test_decode(word);
      test_immediate(word, 3'(sample % 8));
      test_alu(a, b, 4'(sample % 16));
      test_shift(a, b, 2'(sample % 4));
    end
    check(legal_checks != 0 && illegal_checks != 0, "decode coverage was vacuous");
    $display("PASS datapath seed=%0d decode=%0d legal=%0d illegal=%0d immediate=%0d alu=%0d shift=%0d",
             seed, decode_checks, legal_checks, illegal_checks, immediate_checks, alu_checks, shift_checks);
    $finish;
  end
endmodule

/* compare both forwarding modes against an independently ordered producer search. */
module drg5_forward_tb;
  logic [4:0] rs1_i, rs2_i;
  logic rs1_used_i, rs2_used_i;
  logic [31:0] rs1_rf_value_i, rs2_rf_value_i;
  logic [2:0] producer_valid_i, producer_write_i, producer_ready_i;
  logic [14:0] producer_rd_i;
  logic [95:0] producer_value_i;
  logic [31:0] rs1_value_o [0:1], rs2_value_o [0:1];
  logic hazard_o [0:1], rs1_match_o [0:1], rs2_match_o [0:1];
  logic [1:0] rs1_select_o [0:1], rs2_select_o [0:1];
  int unsigned samples = 0, checks = 0, blocked_cases = 0, both_matches = 0;
  int unsigned zero_cases = 0, unused_cases = 0, fallback_cases = 0;
  logic [31:0] random_state = 32'h17290305;
  bit mutate_stall, mutate_fallback;
  localparam logic [4:0] IDS [0:3] = '{0, 1, 17, 31};

  /* describe reference results without reading any selector output. */
  typedef struct packed {
    logic [31:0] value;
    logic [1:0] selected;
    logic matched, blocked;
  } expected_t;

  /* mode zero preserves conservative X/M interlocks while mode one permits ready values. */
  for (genvar mode = 0; mode < 2; mode++) begin : modes
    drg5_forward #(.FORWARDING(mode != 0)) dut (
      .rs1_i, .rs2_i, .rs1_used_i, .rs2_used_i, .rs1_rf_value_i, .rs2_rf_value_i,
      .producer_valid_i, .producer_write_i, .producer_ready_i, .producer_rd_i, .producer_value_i,
      .rs1_value_o(rs1_value_o[mode]), .rs2_value_o(rs2_value_o[mode]),
      .hazard_o(hazard_o[mode]), .rs1_select_o(rs1_select_o[mode]),
      .rs2_select_o(rs2_select_o[mode]), .rs1_match_o(rs1_match_o[mode]),
      .rs2_match_o(rs2_match_o[mode])
    );
  end

  /* retain the full failing input vector and the exact output comparator. */
  task automatic check(input bit condition, input string label_text, input int mode,
      input logic [31:0] expected_value, observed_value);
    checks++;
    /* later vectors cannot obscure a stalled or incorrectly selected source. */
    if (!condition) $fatal(1,
        "FORWARD_CHECK_FAILED %s sample=%0d mode=%0d ids=%0d,%0d used=%b%b rf=%h,%h valid=%b write=%b ready=%b rd=%h values=%h expected=%h observed=%h",
        label_text, samples, mode, rs1_i, rs2_i, rs1_used_i, rs2_used_i,
        rs1_rf_value_i, rs2_rf_value_i, producer_valid_i, producer_write_i,
        producer_ready_i, producer_rd_i, producer_value_i, expected_value, observed_value);
  endtask

  /* overwrite older candidates with younger matches before testing the chosen readiness. */
  function automatic expected_t predict(input logic [4:0] source, input bit used,
      input logic [31:0] rf_value, input bit mode);
    expected_t result;
    int chosen;
    result = '0;
    chosen = -1;
    /* unused operands and x0 ignore every producer, including malicious rd-zero metadata. */
    if (used && source != 0) begin
      result.value = rf_value;
      /* reverse traversal differs from the DUT's first-match search. */
      for (int producer = 2; producer >= 0; producer--) begin
        /* readiness does not qualify identity, so a blocked near match still replaces an older one. */
        if (producer_valid_i[producer] && producer_write_i[producer] &&
            producer_rd_i[5*producer +: 5] == source) chosen = producer;
      end
      /* only the winning producer can supply data or request an interlock. */
      if (chosen >= 0) begin
        result.matched = 1;
        result.selected = 2'(chosen + 1);
        result.blocked = !producer_ready_i[chosen] || (!mode && chosen != 2);
        result.value = result.blocked ? 32'b0 : producer_value_i[32*chosen +: 32];
      end
    end
    return result;
  endfunction

  /* make data choices reproducible without depending on simulator initialization. */
  task automatic random_word(output logic [31:0] value);
    random_state = random_state ^ (random_state << 13);
    random_state = random_state ^ (random_state >> 17);
    random_state = random_state ^ (random_state << 5);
    value = random_state;
  endtask

  /* check all seven outputs independently for each mode after combinational settling. */
  task automatic compare;
    expected_t first, second;
    logic [31:0] observed_first;
    bit wanted_hazard, observed_hazard, forbidden_fallback;
    #1;
    /* both configurations consume the same arbitrary producer descriptors. */
    for (int mode = 0; mode < 2; mode++) begin
      first = predict(rs1_i, rs1_used_i, rs1_rf_value_i, mode != 0);
      second = predict(rs2_i, rs2_used_i, rs2_rf_value_i, mode != 0);
      wanted_hazard = first.blocked || second.blocked;
      observed_hazard = hazard_o[mode] ^ (mutate_stall && wanted_hazard);
      forbidden_fallback = mode != 0 && first.selected == 1 && first.blocked &&
          producer_valid_i[1] && producer_write_i[1] && producer_ready_i[1] &&
          producer_rd_i[9:5] == rs1_i;
      observed_first = mutate_fallback && forbidden_fallback ? producer_value_i[63:32] : rs1_value_o[mode];
      check(observed_first == first.value, "source1 value", mode, first.value, observed_first);
      check(rs2_value_o[mode] == second.value, "source2 value", mode, second.value, rs2_value_o[mode]);
      check(rs1_select_o[mode] == first.selected, "source1 selection", mode, 32'(first.selected), 32'(rs1_select_o[mode]));
      check(rs2_select_o[mode] == second.selected, "source2 selection", mode, 32'(second.selected), 32'(rs2_select_o[mode]));
      check(rs1_match_o[mode] == first.matched, "source1 match", mode, 32'(first.matched), 32'(rs1_match_o[mode]));
      check(rs2_match_o[mode] == second.matched, "source2 match", mode, 32'(second.matched), 32'(rs2_match_o[mode]));
      check(observed_hazard == wanted_hazard, "hazard", mode, 32'(wanted_hazard), 32'(observed_hazard));
      blocked_cases += int'(wanted_hazard);
      both_matches += int'(first.matched && second.matched);
      zero_cases += int'((rs1_used_i && rs1_i == 0) || (rs2_used_i && rs2_i == 0));
      unused_cases += int'(!rs1_used_i || !rs2_used_i);
      fallback_cases += int'(forbidden_fallback);
    end
    samples++;
  endtask

  /* encode zero, either current source, or a guaranteed different nonzero destination. */
  function automatic logic [4:0] destination(input int choice);
    logic [4:0] other;
    other = 1;
    /* three consecutive nonzero candidates suffice to avoid two source indices. */
    while (other == rs1_i || other == rs2_i) other++;
    /* choices preserve identity relationships while the outer loops vary actual register numbers. */
    case (choice)
      0: return 0;
      1: return rs1_i;
      2: return rs2_i;
      default: return other;
    endcase
  endfunction

  /* combine exhaustive metadata relationships, all destination identities and arbitrary data. */
  initial begin
    mutate_stall = $test$plusargs("mutate_stall");
    mutate_fallback = $test$plusargs("mutate_fallback");
    rs1_rf_value_i = 32'h12345678;
    rs2_rf_value_i = 32'h87654321;
    producer_value_i = {32'hfedcba98, 32'h76543210, 32'h89abcdef};
    /* every valid/write/ready bit pattern and source-use mask meets every representative identity relation. */
    for (int flags = 0; flags < 512; flags++) begin
      producer_valid_i = 3'(flags);
      producer_write_i = 3'(flags >> 3);
      producer_ready_i = 3'(flags >> 6);
      /* source-use masks must suppress both matching and nonmatching metadata. */
      for (int used = 0; used < 4; used++) begin
        rs1_used_i = 1'(used);
        rs2_used_i = 1'(used >> 1);
        /* representative sources include zero, low/high indices and equal/unequal pairs. */
        for (int first = 0; first < 4; first++) begin
          rs1_i = IDS[first];
          /* two source ports can independently select different producer ages. */
          for (int second = 0; second < 4; second++) begin
            rs2_i = IDS[second];
            /* each producer can target zero, either source, or neither source. */
            for (int pattern = 0; pattern < 64; pattern++) begin
              producer_rd_i = {destination((pattern >> 4) & 3), destination((pattern >> 2) & 3), destination(pattern & 3)};
              compare();
            end
          end
        end
      end
    end
    producer_valid_i = 7;
    producer_write_i = 7;
    producer_ready_i = 7;
    rs1_used_i = 1;
    rs2_used_i = 1;
    /* exhaust all three producer destinations and every source-one identity with a complementary source two. */
    for (int source = 0; source < 32; source++) begin
      rs1_i = 5'(source);
      rs2_i = 5'(31 - source);
      /* destination enumeration includes repeated writers and rd-zero suppression. */
      for (int ids = 0; ids < 32768; ids++) begin
        producer_rd_i = 15'(ids);
        compare();
      end
    end
    /* every independent source pair also sees all relative producer identity patterns. */
    for (int sources = 0; sources < 1024; sources++) begin
      rs1_i = 5'(sources);
      rs2_i = 5'(sources >> 5);
      /* random control masks complement the exhaustive representative control sweep above. */
      for (int pattern = 0; pattern < 64; pattern++) begin
        logic [31:0] flags;
        random_word(flags);
        producer_valid_i = flags[2:0];
        producer_write_i = flags[5:3];
        producer_ready_i = flags[8:6];
        rs1_used_i = flags[9];
        rs2_used_i = flags[10];
        producer_rd_i = {destination((pattern >> 4) & 3), destination((pattern >> 2) & 3), destination(pattern & 3)};
        /* remaining random bits vary both independent RF values. */
        rs1_rf_value_i = flags;
        rs2_rf_value_i = ~flags;
        compare();
      end
    end
    /* full-width random values expose truncated or cross-connected data paths. */
    for (int sample = 0; sample < 20000; sample++) begin
      logic [31:0] flags;
      random_word(flags);
      rs1_i = flags[4:0]; rs2_i = flags[9:5];
      rs1_used_i = flags[10]; rs2_used_i = flags[11];
      producer_valid_i = flags[14:12]; producer_write_i = flags[17:15]; producer_ready_i = flags[20:18];
      producer_rd_i = {flags[31:27], flags[26:22], flags[21:17]};
      random_word(rs1_rf_value_i); random_word(rs2_rf_value_i);
      random_word(producer_value_i[31:0]); random_word(producer_value_i[63:32]); random_word(producer_value_i[95:64]);
      compare();
    end
    check(blocked_cases != 0 && both_matches != 0 && zero_cases != 0 && unused_cases != 0 && fallback_cases != 0,
          "nonvacuous semantic coverage", 0, 1, 1);
    $display("FORWARD_PASS samples=%0d modes=2 checks=%0d blocked=%0d both_matches=%0d zero=%0d unused=%0d forbidden_fallback=%0d",
             samples, checks, blocked_cases, both_matches, zero_cases, unused_cases, fallback_cases);
    $finish;
  end
endmodule

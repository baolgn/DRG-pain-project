/* exhaust the halfword space against independently generated semantic encodings. */
module drg5_decompress_tb;
  logic [15:0] instruction;
  logic [31:0] expanded;
  logic legal, hint;
  logic [1:0] classification;
  logic [33:0] expected [0:65535];
  logic [33:0] observed;
  int counts [0:3];
  string oracle_path;
  bit mutate_class, mutate_expansion, mutate_hint;
  int checks;

  /* the device only sees the original halfword. */
  drg5_decompress dut (
    .instr_i(instruction), .expanded_o(expanded), .legal_o(legal),
    .hint_o(hint), .class_o(classification)
  );

  /* report the first encoding and exact independently expected result. */
  task automatic check(input bit condition, input string label_text);
    checks++;
    /* detector calibration must fail the named comparator. */
    if (!condition) $fatal(1, "DECOMPRESS_CHECK_FAILED %s instr=%04h got=%09h expected=%09h",
                          label_text, instruction, observed, expected[instruction]);
  endtask

  /* every possible halfword is checked once in both ascending and descending order. */
  initial begin
    checks = 0;
    instruction = 0;
    mutate_class = $test$plusargs("mutate_class");
    mutate_expansion = $test$plusargs("mutate_expansion");
    mutate_hint = $test$plusargs("mutate_hint");
    /* the runner supplies the independently generated table, never DUT output. */
    if (!$value$plusargs("oracle=%s", oracle_path)) $fatal(1, "oracle path required");
    $readmemh(oracle_path, expected);
    /* initialize all four classification coverage bins. */
    for (int kind = 0; kind < 4; kind++) counts[kind] = 0;
    /* reversed traversal also exposes unwanted dependence on the prior encoding. */
    for (int pass = 0; pass < 2; pass++) begin
      /* all bit patterns include illegal, HINT and wide-prefix boundary cases. */
      for (int code = 0; code < 65536; code++) begin
        instruction = 16'(pass == 0 ? code : 65535 - code);
        #1;
        observed = {classification, expanded};
        /* corrupt one selected observation, leaving the device and oracle unchanged. */
        if (mutate_class && instruction == 0) observed[33:32] = 1;
        /* an immediate-bit error must fail even if legality stays correct. */
        if (mutate_expansion && instruction == 16'h0040) observed[20] = ~observed[20];
        check(observed[33:32] == expected[instruction][33:32], "classification");
        check(observed[31:0] == expected[instruction][31:0], "expansion");
        check(legal == (expected[instruction][33:32] == 1 || expected[instruction][33:32] == 2),
              "legal flag");
        check((hint ^ (mutate_hint && instruction == 16'h0005)) ==
              (expected[instruction][33:32] == 2), "HINT flag");
        /* first-pass bins count distinct halfwords rather than repeated visits. */
        if (pass == 0) counts[int'(classification)]++;
      end
    end
    check(counts[0] == 20329 && counts[1] == 28461 && counts[2] == 362 && counts[3] == 16384,
          "independent class cardinalities");
    $display("DECOMPRESS_PASS encodings=65536 passes=2 checks=%0d illegal=%0d ordinary=%0d hints=%0d wide=%0d",
             checks, counts[0], counts[1], counts[2], counts[3]);
    $finish;
  end
endmodule

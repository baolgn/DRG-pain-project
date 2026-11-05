/* compare LSU policy and byte arithmetic across all eight optional region profiles. */
module drg5_lsu_tb;
  logic [31:0] addr_i, store_value_i, rsp_data_i;
  logic [1:0] size_i;
  logic write_i, signed_i;
  logic allowed_o [0:7], misaligned_o [0:7];
  logic [31:0] cause_o [0:7], wdata_o [0:7], load_value_o [0:7];
  logic [3:0] wstrb_o [0:7];
  logic [31:0] random_state = 32'h1a2b3c4d;
  int unsigned samples = 0, checks = 0, allowed_reads = 0, allowed_writes = 0;
  int unsigned alignment_faults = 0, access_faults = 0;
  bit mutate_store, mutate_sign;
  localparam logic [31:0] ANCHORS [0:15] = '{
    0, 32'h2000, 32'h10000, 32'h20000, 32'h20000000, 32'h20008000,
    32'h40000000, 32'h40001000, 32'h40002000, 32'h50001000, 32'h50002000,
    32'h50003000, 32'hffffffff, 32'h80000000, 32'h60000000, 32'h1000
  };
  localparam logic [31:0] VALUES [0:15] = '{
    0, 1, 32'h7f, 32'h80, 32'hff, 32'h7fff, 32'h8000, 32'hffff,
    32'h7fffffff, 32'h80000000, 32'hffffffff, 32'h807f00ff,
    32'hff00807f, 32'h55aa55aa, 32'h00800000, 32'h007fffff
  };

  /* parameter bits independently enable test regions, IRAM stores and the timer page. */
  for (genvar profile = 0; profile < 8; profile = profile + 1) begin : profiles
    drg5_lsu #(.TEST_REGIONS((profile & 4) != 0), .IRAM_WRITE((profile & 2) != 0),
               .TIMER_ENABLED((profile & 1) != 0)) dut (
      .addr_i, .store_value_i, .rsp_data_i, .size_i, .write_i, .signed_i,
      .allowed_o(allowed_o[profile]), .misaligned_o(misaligned_o[profile]),
      .cause_o(cause_o[profile]), .wdata_o(wdata_o[profile]), .wstrb_o(wstrb_o[profile]),
      .load_value_o(load_value_o[profile])
    );
  end

  /* define byte permissions by page numbers independently of endpoint comparisons. */
  function automatic bit byte_permission(input logic [2:0] profile,
      input longint unsigned address);
    longint unsigned page;
    page = address / 4096;
    /* a byte beyond the physical 32-bit address space is never wrapped back to ROM. */
    if (address >= 64'h100000000) return 0;
    /* the first two pages provide read-only ROM. */
    if (page < 2) return !write_i;
    /* the sixteen instruction-RAM pages gate only their write direction. */
    if (page >= 16 && page < 32) return !write_i || profile[1];
    /* ordinary data RAM contains eight complete pages. */
    if (page >= 64'h20000 && page < 64'h20008) return 1;
    /* MMIO always requires a word operation. */
    if (page == 64'h40000) return size_i == 2;
    /* the separate timer page exists only in the selected profile. */
    if (page == 64'h40001) return profile[0] && size_i == 2;
    /* deliberate error and uncertainty responders accept all ordinary widths. */
    if (page == 64'h50001 || page == 64'h50002) return profile[2];
    return 0;
  endfunction

  /* name the exact semantic comparator rather than accepting any failing exit. */
  task automatic check(input bit condition, input string label_text, input int profile);
    checks = checks + 1;
    /* stop before a later vector can obscure the offending width or address. */
    if (!condition) $fatal(1,
        "LSU_CHECK_FAILED %s sample=%0d profile=%0d addr=%h size=%0d write=%0d signed=%0d store=%h rsp=%h",
        label_text, samples, profile, addr_i, size_i, write_i, signed_i, store_value_i, rsp_data_i);
  endtask

  /* generate full-width reproducible values without simulator startup randomness. */
  task automatic random_word(output logic [31:0] value);
    random_state = random_state ^ (random_state << 13);
    random_state = random_state ^ (random_state >> 17);
    random_state = random_state ^ (random_state << 5);
    value = random_state;
  endtask

  /* reconstruct each transfer using individual bytes and 64-bit arithmetic. */
  task automatic compare;
    int unsigned bytes, lane;
    bit expected_misaligned, expected_allowed;
    logic [31:0] expected_cause, expected_store, expected_load, observed_store, observed_load;
    logic [3:0] expected_strobes;
    longint unsigned unsigned_load, write_word, byte_value, modulus;
    bytes = size_i == 3 ? 0 : 1 << size_i;
    lane = addr_i % 4;
    expected_misaligned = bytes != 0 && ({32'b0, addr_i} % 64'(bytes)) != 0;
    #1;
    /* every input vector is checked against every optional-region combination. */
    for (int profile = 0; profile < 8; profile = profile + 1) begin
      expected_allowed = bytes != 0 && !expected_misaligned;
      /* inspect each actual byte, including endpoints near region and address-space edges. */
      for (int offset = 0; offset < 4; offset = offset + 1) begin
        /* unrequested neighboring bytes cannot affect a smaller access. */
        if (32'(offset) < bytes) expected_allowed = expected_allowed &&
            byte_permission(3'(profile), {32'b0, addr_i} + 64'(offset));
      end
      expected_cause = expected_allowed ? 0 : expected_misaligned ? (write_i ? 6 : 4) : (write_i ? 7 : 5);
      expected_store = 0; expected_strobes = 0; expected_load = 0;
      unsigned_load = 0; write_word = 0; modulus = 1;
      /* no arithmetic result is consumable from a rejected operation. */
      if (expected_allowed) begin
        /* positional base-256 arithmetic is separate from the RTL shift/extension network. */
        for (int offset = 0; offset < 4; offset = offset + 1) begin
          /* each enabled byte contributes exactly once to its destination position. */
          if (32'(offset) < bytes) begin
            byte_value = ({32'b0, store_value_i} >> (8*offset)) % 256;
            write_word = write_word + (byte_value << (8*(lane + 32'(offset))));
            byte_value = ({32'b0, rsp_data_i} >> (8*(lane + 32'(offset)))) % 256;
            unsigned_load = unsigned_load + (byte_value << (8*offset));
            expected_strobes[lane + 32'(offset)] = 1;
            modulus = modulus * 256;
          end
        end
        check(write_word < 64'h100000000 && unsigned_load < modulus, "reference byte arithmetic", profile);
        /* stores suppress the read result regardless of the signedness input. */
        if (write_i) expected_store = 32'(write_word);
        /* reads never enable write lanes and optionally extend a negative narrow field. */
        else begin
          expected_strobes = 0;
          expected_load = 32'(unsigned_load);
          /* subtracting the source modulus computes the sign-extended two's-complement value. */
          if (signed_i && unsigned_load >= modulus / 2) expected_load = 32'(unsigned_load - modulus);
        end
      end
      observed_store = wdata_o[profile] ^ (mutate_store && expected_allowed && write_i ? 32'd1 : 32'd0);
      observed_load = load_value_o[profile] ^
                     (mutate_sign && expected_allowed && !write_i && signed_i && size_i < 2 ? 32'h80000000 : 32'd0);
      check(allowed_o[profile] == expected_allowed, "region permission", profile);
      check(misaligned_o[profile] == expected_misaligned && cause_o[profile] == expected_cause,
            "alignment before permission", profile);
      check(observed_store == expected_store && wstrb_o[profile] == expected_strobes, "store lanes", profile);
      check(observed_load == expected_load, "load extension", profile);
      /* coverage counters distinguish successful transfers from both rejection classes. */
      if (expected_allowed && write_i) allowed_writes = allowed_writes + 1;
      /* a successful read is counted independently of its returned bit pattern. */
      else if (expected_allowed) allowed_reads = allowed_reads + 1;
      /* natural-alignment failures are distinct from access permission or width rejection. */
      else if (expected_misaligned) alignment_faults = alignment_faults + 1;
      /* every remaining rejected operation has the access-fault response. */
      else access_faults = access_faults + 1;
    end
    samples = samples + 1;
  endtask

  /* enumerate boundary neighborhoods, all widths/directions/signs and narrow sign edges. */
  initial begin
    mutate_store = $test$plusargs("mutate_store");
    mutate_sign = $test$plusargs("mutate_sign");
    /* each region transition is approached from both sides and every byte lane. */
    for (int anchor = 0; anchor < 16; anchor = anchor + 1) begin
      /* negative offsets also test the top-of-address-space wrap neighborhood. */
      for (int delta = -8; delta < 8; delta = delta + 1) begin
        addr_i = ANCHORS[anchor] + 32'(delta);
        /* invalid width three has an explicit access-fault expectation. */
        for (int width = 0; width < 4; width = width + 1) begin
          size_i = 2'(width);
          /* reads and writes apply different region permissions and result validity. */
          for (int direction = 0; direction < 2; direction = direction + 1) begin
            write_i = 1'(direction);
            /* signedness is exercised even when the operation must ignore it. */
            for (int sign = 0; sign < 2; sign = sign + 1) begin
              signed_i = 1'(sign);
              /* rotate source and response patterns so masking cannot accidentally agree. */
              for (int pattern = 0; pattern < 16; pattern = pattern + 1) begin
                rsp_data_i = VALUES[pattern];
                store_value_i = ~VALUES[(pattern + 5) % 16];
                compare();
              end
            end
          end
        end
      end
    end
    /* arbitrary values complement the structured page-boundary coverage. */
    for (int sample = 0; sample < 20000; sample = sample + 1) begin
      logic [31:0] selectors;
      random_word(addr_i); random_word(store_value_i); random_word(rsp_data_i); random_word(selectors);
      /* selected samples probe valid regions internally rather than almost always missing them. */
      if (sample % 5 != 0) addr_i = ANCHORS[sample % 16] + (addr_i % 2048);
      size_i = 2'(selectors % 127);
      write_i = 1'((selectors / 17) % 2);
      signed_i = 1'((selectors / 193) % 2);
      compare();
    end
    check(allowed_reads != 0 && allowed_writes != 0 && alignment_faults != 0 && access_faults != 0,
          "nonvacuous transfer and rejection coverage", 0);
    $display("LSU_PASS samples=%0d profiles=8 checks=%0d reads=%0d writes=%0d alignment=%0d access=%0d",
             samples, checks, allowed_reads, allowed_writes, alignment_faults, access_faults);
    $finish;
  end
endmodule

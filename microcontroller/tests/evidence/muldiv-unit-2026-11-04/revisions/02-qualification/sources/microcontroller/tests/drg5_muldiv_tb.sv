/* compare RV32M against widened host arithmetic and an independent lifecycle oracle. */
module drg5_muldiv_tb;
  logic clk_i = 0, cold_reset_i = 1, start_i = 0, ready_i = 0;
  logic [2:0] op_i = 0;
  logic [31:0] lhs_i = 0, rhs_i = 0;
  logic [63:0] uid_i = 0;
  logic busy_o, valid_o;
  logic [31:0] result_o;
  logic [63:0] uid_o;
  logic [31:0] random_state, seed;
  int unsigned cases = 0, checks = 0, edges = 0, resets = 0;
  int unsigned op_cases [0:7] = '{default:0};
  int unsigned latency_min [0:7] = '{default:1000};
  int unsigned latency_max [0:7] = '{default:0};
  int unsigned held_edges = 0, early_ready_cases = 0;
  int unsigned active_op = 0, active_elapsed = 0;
  logic [31:0] active_lhs = 0, active_rhs = 0, wanted = 0;
  logic [63:0] active_uid = 0;
  bit mutate_result, mutate_latency, mutate_uid, mutate_hold, misuse_start;
  localparam logic [31:0] BOUNDARY [0:15] = '{
    0, 1, 2, 3, 7, 32'hffff, 32'h10000, 32'h7fffffff,
    32'h80000000, 32'h80000001, 32'hfffffffd, 32'hfffffffe,
    32'hffffffff, 32'h55555555, 32'haaaaaaaa, 32'hffff0000
  };

  /* retain a compact public-interface trace before any assertion failure. */
  typedef struct packed {
    logic reset, start, ready, busy, valid;
    logic [2:0] op;
    logic [31:0] lhs, rhs, value;
    logic [63:0] in_uid, out_uid;
  } sample_t;
  sample_t history [0:63];

  /* the unit has no pipeline reset, cancellation, or debug control port. */
  drg5_muldiv dut (.*);

  /* every comparison reports a reproducible job and the preceding 64 sampled edges. */
  task automatic check(input bit condition, input string label_text);
    checks++;
    /* terminate on the first mismatch before any subsequent job can obscure it. */
    if (!condition) begin
      /* emit samples in temporal order, including idle and reset boundaries. */
      for (int offset = 63; offset >= 0; offset--) begin
        /* startup has fewer than 64 initialized samples. */
        if (edges > unsigned'(offset)) begin
          $display("MULDIV_TRACE edge=%0d state=%h", edges - unsigned'(offset),
                   history[(edges - unsigned'(offset)) % 64]);
        end
      end
      $fatal(1, "MULDIV_CHECK_FAILED %s seed=%0d case=%0d edge=%0d op=%0d lhs=%h rhs=%h elapsed=%0d expected=%h result=%h uid=%h observed_uid=%h busy=%b valid=%b",
             label_text, seed, cases, edges, active_op, active_lhs, active_rhs,
             active_elapsed, wanted, result_o, active_uid, uid_o, busy_o, valid_o);
    end
  endtask

  /* sample after nonblocking updates without depending on simulator scheduling order. */
  task automatic tick;
    #5;
    clk_i = 1;
    #1;
    edges++;
    history[edges % 64] = {cold_reset_i, start_i, ready_i, busy_o, valid_o,
                          op_i, lhs_i, rhs_i, result_o, uid_i, uid_o};
    #4;
    clk_i = 0;
  endtask

  /* the LCG accepts seed zero and is independent of Verilator's initialization RNG. */
  function automatic logic [31:0] random_word;
    random_state = random_state * 32'd1664525 + 32'd1013904223;
    return random_state;
  endfunction

  /* 64-bit division avoids host overflow at the RV32 signed minimum. */
  function automatic logic [31:0] reference_result(input logic [2:0] operation,
      input logic [31:0] lhs, rhs);
    logic [63:0] unsigned_product;
    logic signed [63:0] signed_lhs, signed_rhs, mixed_rhs;
    unsigned_product = {32'b0, lhs} * {32'b0, rhs};
    signed_lhs = {{32{lhs[31]}}, lhs};
    signed_rhs = {{32{rhs[31]}}, rhs};
    mixed_rhs = $signed({32'b0, rhs});
    /* full-width host operators differ from the DUT's partial products and restoring steps. */
    case (operation)
      0: return unsigned_product[31:0];
      /* signed widening defines the high product independently of correction terms. */
      1: begin
        return 32'((signed_lhs * signed_rhs) >>> 32);
      end
      /* only the lhs is sign-extended for mixed multiplication. */
      2: begin
        return 32'((signed_lhs * mixed_rhs) >>> 32);
      end
      3: return unsigned_product[63:32];
      /* signed quotient truncates toward zero. */
      4: begin
        /* zero division is specified by the ISA, never delegated to host behavior. */
        if (rhs == 0) return 32'hffffffff;
        return 32'(signed_lhs / signed_rhs);
      end
      5: return rhs == 0 ? 32'hffffffff : lhs / rhs;
      /* signed modulo retains the dividend's sign. */
      6: begin
        /* widened modulo produces the signed remainder, including RV32 overflow. */
        if (rhs == 0) return lhs;
        return 32'(signed_lhs % signed_rhs);
      end
      default: return rhs == 0 ? lhs : lhs % rhs;
    endcase
  endfunction

  /* vary irrelevant inputs to catch accidental recomputation from live operands. */
  task automatic scramble_inputs;
    lhs_i = random_word();
    rhs_i = random_word();
    op_i = 3'(random_word());
    uid_i = {random_word(), random_word()};
  endtask

  /* execute one job with explicit latency, identity, backpressure, and single-consumption checks. */
  task automatic execute(input logic [2:0] operation, input logic [31:0] lhs, rhs,
      input int unsigned hold_cycles, input bit early_ready);
    int unsigned latency;
    logic [31:0] observed_result;
    logic [63:0] observed_uid;
    bit observed_valid;
    latency = operation[2] ? 33 : 2;
    active_op = int'(operation);
    active_lhs = lhs;
    active_rhs = rhs;
    active_uid = {seed, 32'(cases + 1)};
    active_elapsed = 0;
    wanted = reference_result(operation, lhs, rhs);
    check(!busy_o && !valid_o, "idle before start");
    start_i = 1;
    ready_i = early_ready;
    op_i = operation;
    lhs_i = lhs;
    rhs_i = rhs;
    uid_i = active_uid;
    tick();
    check(busy_o && !valid_o && uid_o == active_uid, "atomic acceptance");
    start_i = 0;
    /* a legal caller may already request consumption while arithmetic is unfinished. */
    for (int unsigned elapsed = 1; elapsed <= latency; elapsed++) begin
      active_elapsed = elapsed;
      scramble_inputs();
      tick();
      observed_valid = valid_o ^ (mutate_latency && operation == 4 && elapsed == 1);
      check(busy_o, "owned until consumption");
      check(observed_valid == (elapsed == latency), "completion latency");
      observed_uid = uid_o ^ ((mutate_uid && elapsed == 1) ? 64'b1 : 64'b0);
      check(observed_uid == active_uid, "result identity");
    end
    ready_i = 0;
    observed_result = result_o ^ ((mutate_result && operation == 2) ? 32'b1 : 32'b0);
    check(observed_result == wanted, "arithmetic result");
    latency_min[operation] = latency < latency_min[operation] ? latency : latency_min[operation];
    latency_max[operation] = latency > latency_max[operation] ? latency : latency_max[operation];
    /* result backpressure cannot release ownership or alter either public result field. */
    for (int unsigned held = 0; held < hold_cycles; held++) begin
      scramble_inputs();
      tick();
      observed_result = result_o ^ ((mutate_hold && held == 0) ? 32'b1 : 32'b0);
      check(valid_o && busy_o && observed_result == wanted && uid_o == active_uid,
            "held result");
      held_edges++;
    end
    ready_i = 1;
    tick();
    check(!busy_o && !valid_o, "single consumption");
    tick();
    check(!busy_o && !valid_o, "no duplicate result");
    ready_i = 0;
    cases++;
    op_cases[operation]++;
    early_ready_cases += int'(early_ready);
  endtask

  /* cold reset must remove every unfinished or held identity before a fresh job. */
  task automatic reset_during(input logic [2:0] operation, input int unsigned elapsed);
    start_i = 1;
    ready_i = 0;
    op_i = operation;
    lhs_i = 32'h80000001;
    rhs_i = 32'hfffffffd;
    uid_i = 64'hffff1234ffff5678;
    tick();
    start_i = 0;
    /* include every arithmetic edge and the first held-result edge. */
    repeat (elapsed) begin
      tick();
    end
    cold_reset_i = 1;
    /* reset wins even over a simultaneous new command. */
    start_i = 1;
    tick();
    check(!busy_o && !valid_o && uid_o == 0 && result_o == 0, "cold reset ownership");
    cold_reset_i = 0;
    start_i = 0;
    tick();
    check(!busy_o && !valid_o, "no pre-reset result");
    resets++;
    execute(3'(elapsed % 8), 32'h87654321, 32'hffff0003, elapsed % 4, 1);
  endtask

  /* boundary cross-products precede random coverage so all special cases are deterministic. */
  initial begin
    /* seed zero is a distinct reproducible stream. */
    if (!$value$plusargs("seed=%d", seed)) begin
      seed = 1;
    end
    random_state = seed;
    mutate_result = $test$plusargs("mutate_result");
    mutate_latency = $test$plusargs("mutate_latency");
    mutate_uid = $test$plusargs("mutate_uid");
    mutate_hold = $test$plusargs("mutate_hold");
    misuse_start = $test$plusargs("misuse_start");
    tick();
    check(!busy_o && !valid_o && result_o == 0 && uid_o == 0, "initial reset");
    cold_reset_i = 0;
    /* this deliberate contract violation must activate the unit assertion. */
    if (misuse_start) begin
      start_i = 1;
      op_i = 4;
      tick();
      tick();
      $fatal(1, "missing busy-start assertion");
    end
    /* every signedness flavor sees every pair of critical 32-bit values. */
    for (int operation = 0; operation < 8; operation++) begin
      /* include both operand positions; MULHSU is deliberately asymmetric. */
      for (int lhs = 0; lhs < 16; lhs++) begin
        /* zero, signed extrema, limb boundaries, and dense patterns are independent. */
        for (int rhs = 0; rhs < 16; rhs++) begin
          execute(3'(operation), BOUNDARY[lhs], BOUNDARY[rhs], unsigned'(lhs + rhs) % 8,
                  (lhs + rhs) % 2 != 0);
        end
      end
    end
    /* random operands and result stalls use a retained seed rather than wall-clock entropy. */
    repeat (8192) begin
      /* each random pair exercises every opcode for equal coverage. */
      for (int operation = 0; operation < 8; operation++) begin
        logic [31:0] random_lhs, random_rhs;
        logic [3:0] flags;
        random_lhs = random_word();
        random_rhs = random_word();
        flags = 4'(random_word());
        execute(3'(operation), random_lhs, random_rhs, 32'(flags[2:0]), flags[3]);
      end
    end
    /* reset covers the multiplier's two stages, divider's 33 stages, and held results. */
    for (int operation = 0; operation < 8; operation++) begin
      /* varying ready never shortens computation, including a zero divisor. */
      for (int elapsed = 0; elapsed <= (operation < 4 ? 3 : 34); elapsed++) begin
        reset_during(3'(operation), unsigned'(elapsed));
      end
    end
    /* explicit long stalls exercise result lifetime beyond the arithmetic bound. */
    execute(2, 32'hffffffff, 32'hffffffff, 257, 1);
    execute(4, 32'h80000000, 0, 257, 1);
    /* completeness counters must not silently shrink after fixture changes. */
    for (int operation = 0; operation < 8; operation++) begin
      check(op_cases[operation] >= 8448, "opcode coverage");
      check(latency_min[operation] == (operation < 4 ? 2 : 33) &&
            latency_max[operation] == (operation < 4 ? 2 : 33), "latency coverage");
      $display("MULDIV_OPCODE op=%0d cases=%0d min=%0d max=%0d", operation,
               op_cases[operation], latency_min[operation], latency_max[operation]);
    end
    check(resets == 156 && held_edges > 100000 && early_ready_cases > 10000,
          "lifecycle coverage");
    $display("MULDIV_PASS seed=%0d cases=%0d checks=%0d edges=%0d resets=%0d held=%0d early_ready=%0d mul_latency=2 div_latency=33",
             seed, cases, checks, edges, resets, held_edges, early_ready_cases);
    $finish;
  end
endmodule

/* prove previews and one-edge transitions for every symbolic CSR input. */
module drg5_csr_formal #(
  parameter bit C_ENABLED = 0,
  parameter bit MUTATE_COUNTER = 0
) (
  input logic clk_i, reset_i, access_i,
  input logic [11:0] addr_i,
  input logic [1:0] op_i,
  input logic [31:0] source_i,
  input logic read_i, write_i, commit_i, trap_i,
  input logic [31:0] trap_pc_i, trap_cause_i, trap_tval_i,
  input logic mret_i, retire_i,
  input logic [31:0] mip_levels_i,
  input logic debug_mode_i, debug_ebreak_entry_i
);
  logic legal_o;
  logic [31:0] old_o, read_value_o, new_o;
  logic [31:0] mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o;
  logic [31:0] mie_o, mip_o, mcountinhibit_o;
  logic [63:0] mcycle_o, minstret_o;
  drg5_csr #(.C_ENABLED(C_ENABLED)) dut (.*);

  logic known, readonly_address, expected_legal, take_write, count_cycle, count_retirement;
  logic [31:0] expected_old, expected_new, candidate, expected_pending;
  logic [31:0] next_status, next_mie, next_vector, next_scratch, next_epc, next_cause, next_tval, next_inhibit;
  logic [63:0] next_cycle, next_retirement;
  logic [383:0] expected_state_q;
  logic past_valid = 0;
  logic unused_pending_bits;
  assign unused_pending_bits = ^(mip_levels_i & ~32'h888);

  /* use enumerated addresses and independent per-bit write semantics for preview. */
  always_comb begin
    expected_pending = 0;
    expected_pending[3] = mip_levels_i[3];
    expected_pending[7] = mip_levels_i[7];
    expected_pending[11] = mip_levels_i[11];
    known = (addr_i > 12'h322 && addr_i < 12'h340) ||
            (addr_i > 12'hb02 && addr_i < 12'hb20) ||
            (addr_i > 12'hb82 && addr_i < 12'hba0);
    readonly_address = 0;
    expected_old = 0;
    /* absent ranges remain absent rather than becoming writable zero storage. */
    case (addr_i)
      /* status exposes only the implemented machine fields. */
      12'h300: begin known = 1; expected_old = mstatus_o; end
      /* the prototype advertises I only. */
      12'h301: begin known = 1; expected_old = 32'h40000100; end
      /* interrupt enables are stored machine state. */
      12'h304: begin known = 1; expected_old = mie_o; end
      /* the vector contains a direct aligned base. */
      12'h305: begin known = 1; expected_old = mtvec_o; end
      12'h310: known = 1;
      /* inhibit bits control subsequent increments. */
      12'h320: begin known = 1; expected_old = mcountinhibit_o; end
      /* scratch exposes its full stored word. */
      12'h340: begin known = 1; expected_old = mscratch_o; end
      /* the saved PC obeys the fixed alignment. */
      12'h341: begin known = 1; expected_old = mepc_o; end
      /* cause exposes the selected legal state. */
      12'h342: begin known = 1; expected_old = mcause_o; end
      /* trap value exposes its full stored word. */
      12'h343: begin known = 1; expected_old = mtval_o; end
      /* pending state follows synchronized levels. */
      12'h344: begin known = 1; expected_old = expected_pending; end
      /* read the cycle counter's low half. */
      12'hb00: begin known = 1; expected_old = mcycle_o[31:0]; end
      /* read the cycle counter's high half. */
      12'hb80: begin known = 1; expected_old = mcycle_o[63:32]; end
      /* read the retirement counter's low half. */
      12'hb02: begin known = 1; expected_old = minstret_o[31:0]; end
      /* read the retirement counter's high half. */
      12'hb82: begin known = 1; expected_old = minstret_o[63:32]; end
      /* all identity addresses reject requested writes. */
      12'hf11, 12'hf12, 12'hf13, 12'hf14, 12'hf15: begin known = 1; readonly_address = 1; end
      /* retain the absent or constant-range classification. */
      default: begin end
    endcase
    expected_legal = access_i && known && !(readonly_address && write_i);
    candidate = expected_old;
    /* the three mutating operations are defined independently for each bit. */
    for (int b = 0; b < 32; b++) begin
      /* requested writes remain distinct from a source mask containing zero. */
      if (write_i) begin
        /* select replacement, set or clear for this bit. */
        case (op_i)
          1: candidate[b] = source_i[b];
          2: candidate[b] = source_i[b] ? 1'b1 : expected_old[b];
          3: candidate[b] = source_i[b] ? 1'b0 : expected_old[b];
          /* normalized READ retains the old bit. */
          default: begin end
        endcase
      end
    end
    expected_new = expected_old;
    /* fixed fields are reconstructed instead of trusting a requested whole word. */
    case (addr_i)
      12'h300: expected_new = {19'b0, 2'b11, 3'b0, candidate[7], 3'b0, candidate[3], 3'b0};
      12'h304: expected_new = {20'b0, candidate[11], 3'b0, candidate[7], 3'b0, candidate[3], 3'b0};
      12'h305: expected_new = {candidate[31:2], 2'b0};
      12'h320: expected_new = {29'b0, candidate[2], 1'b0, candidate[0]};
      12'h340, 12'h343, 12'hb00, 12'hb80, 12'hb02, 12'hb82: expected_new = candidate;
      12'h341: expected_new = C_ENABLED ? {candidate[31:1], 1'b0} : {candidate[31:2], 2'b0};
      /* every unlisted software cause preserves the old WLRL value. */
      12'h342: begin
        /* enumerate the complete permitted cause set. */
        case (candidate)
          0, 1, 2, 3, 4, 5, 6, 7, 11, 32'h80000003, 32'h80000007, 32'h8000000b: expected_new = candidate;
          /* unsupported software causes preserve state. */
          default: begin end
        endcase
      end
      /* other implemented registers are constants. */
      default: begin end
    endcase
  end

  /* derive next values independently for each public register and counter half. */
  always_comb begin
    take_write = commit_i && expected_legal && write_i && !trap_i && !mret_i;
    count_cycle = !debug_mode_i && !debug_ebreak_entry_i && !mcountinhibit_o[0];
    count_retirement = !debug_mode_i && !debug_ebreak_entry_i && !trap_i && retire_i && !mcountinhibit_o[2];
    next_status = mstatus_o;
    next_mie = take_write && addr_i == 12'h304 ? expected_new : mie_o;
    next_vector = take_write && addr_i == 12'h305 ? expected_new : mtvec_o;
    next_scratch = take_write && addr_i == 12'h340 ? expected_new : mscratch_o;
    next_epc = take_write && addr_i == 12'h341 ? expected_new : mepc_o;
    next_cause = take_write && addr_i == 12'h342 ? expected_new : mcause_o;
    next_tval = take_write && addr_i == 12'h343 ? expected_new : mtval_o;
    next_inhibit = take_write && addr_i == 12'h320 ? expected_new : mcountinhibit_o;
    next_cycle = mcycle_o;
    next_retirement = minstret_o;
    /* carry into the upper half is checked separately from the DUT's wide addition. */
    if (count_cycle) begin
      next_cycle[31:0] = mcycle_o[31:0] + 32'd1;
      next_cycle[63:32] = mcycle_o[63:32] + (mcycle_o[31:0] == 32'hffffffff ? 32'd1 : 32'b0);
    end
    /* retiring a counter-write instruction cannot add one after its explicit write. */
    if (count_retirement) begin
      next_retirement[31:0] = minstret_o[31:0] + 32'd1;
      next_retirement[63:32] = minstret_o[63:32] + (minstret_o[31:0] == 32'hffffffff ? 32'd1 : 32'b0);
    end
    /* trap state has precedence over every normal state update. */
    if (trap_i) begin
      next_status = 32'h1800; next_status[7] = mstatus_o[3];
      next_epc = C_ENABLED ? {trap_pc_i[31:1], 1'b0} : {trap_pc_i[31:2], 2'b0};
      next_cause = trap_cause_i; next_tval = trap_tval_i;
    end
    /* return updates only the interrupt stack. */
    else if (mret_i) begin
      next_status = 32'h1880; next_status[3] = mstatus_o[7];
    end
    /* an ordinary status write reaches only its two writable bits. */
    else if (take_write && addr_i == 12'h300) next_status = expected_new;
    /* each half-write restores the untouched half from the pre-edge counter. */
    if (take_write) begin
      /* update only the addressed counter half. */
      case (addr_i)
        12'hb00: next_cycle = {mcycle_o[63:32], expected_new};
        12'hb80: next_cycle = {expected_new, mcycle_o[31:0]};
        12'hb02: next_retirement = {minstret_o[63:32], expected_new};
        12'hb82: next_retirement = {expected_new, minstret_o[31:0]};
        /* other writes cannot alter counters. */
        default: begin end
      endcase
    end
    /* synchronous reset ignores every conflicting write, event and increment. */
    if (reset_i) begin
      next_status = 32'h1800; next_mie = 0; next_vector = 0; next_scratch = 0;
      next_epc = 0; next_cause = 0; next_tval = 0; next_inhibit = 5;
      next_cycle = 0; next_retirement = 0;
    end
  end

  /* initial reset and implemented caller trap causes are the only environment constraints. */
  always_ff @(posedge clk_i) begin
    past_valid <= 1;
    /* architectural storage is unspecified until one reset edge has occurred. */
    if (!past_valid) assume(reset_i);
    /* invalid caller trap metadata is rejected by the active simulation assertion. */
    assume(reset_i || !trap_i || trap_cause_i <= 7 || trap_cause_i == 11 ||
           trap_cause_i == 32'h80000003 || trap_cause_i == 32'h80000007 || trap_cause_i == 32'h8000000b);
    expected_state_q <= {next_status, next_mie, next_vector, next_scratch, next_epc,
                         next_cause, next_tval, next_inhibit, next_cycle, next_retirement};
    /* induction checks all legal previews and all next-state transitions after reset. */
    if (past_valid) begin
      assert(legal_o == expected_legal);
      assert(old_o == (expected_legal ? expected_old : 32'b0));
      assert(read_value_o == (expected_legal && read_i ? expected_old : 32'b0));
      assert(new_o == (expected_legal ? expected_new : 32'b0));
      assert(mip_o == expected_pending);
      assert({mstatus_o, mie_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o,
              mcountinhibit_o, mcycle_o, minstret_o} == (expected_state_q ^ (MUTATE_COUNTER ? 384'b1 : 384'b0)));
      assert((mstatus_o & ~32'h88) == 32'h1800 && (mie_o & ~32'h888) == 0 &&
             (mcountinhibit_o & ~32'h5) == 0 && mtvec_o[1:0] == 0 &&
             (mepc_o & (C_ENABLED ? 32'd1 : 32'd3)) == 0);
    end
  end
endmodule

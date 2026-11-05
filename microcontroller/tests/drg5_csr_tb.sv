/* check the CSR bank against independent address, field and clock-edge models. */
module drg5_csr_tb;
  logic clk_i = 0, reset_i = 0, access_i = 0;
  logic [11:0] addr_i = 0;
  logic [1:0] op_i = 0;
  logic [31:0] source_i = 0;
  logic read_i = 0, write_i = 0, commit_i = 0, trap_i = 0;
  logic [31:0] trap_pc_i = 0, trap_cause_i = 0, trap_tval_i = 0;
  logic mret_i = 0, retire_i = 0;
  logic [31:0] mip_levels_i = 0;
  logic debug_mode_i = 0, debug_ebreak_entry_i = 0;
  logic [2:0] legal_o;
  logic [31:0] old_o [0:2], read_value_o [0:2], new_o [0:2];
  logic [31:0] mstatus_o [0:2], mtvec_o [0:2], mscratch_o [0:2];
  logic [31:0] mepc_o [0:2], mcause_o [0:2], mtval_o [0:2];
  logic [31:0] mie_o [0:2], mip_o [0:2], mcountinhibit_o [0:2];
  logic [63:0] mcycle_o [0:2], minstret_o [0:2];

  /* alignment profiles and explicit identity overrides are separate configuration dimensions. */
  for (genvar profile = 0; profile < 3; profile++) begin : banks
    drg5_csr #(.C_ENABLED(profile != 0),
        .MISA_VALUE(profile == 2 ? 32'h40001104 : 32'h40000100),
        .MIMPID_VALUE(profile == 2 ? 32'h104 : 32'b0)) dut (
      .clk_i, .reset_i, .access_i, .addr_i, .op_i, .source_i,
      .read_i, .write_i, .commit_i, .trap_i, .trap_pc_i, .trap_cause_i, .trap_tval_i,
      .mret_i, .retire_i, .mip_levels_i, .debug_mode_i, .debug_ebreak_entry_i,
      .legal_o(legal_o[profile]), .old_o(old_o[profile]),
      .read_value_o(read_value_o[profile]), .new_o(new_o[profile]),
      .mstatus_o(mstatus_o[profile]), .mtvec_o(mtvec_o[profile]),
      .mscratch_o(mscratch_o[profile]), .mepc_o(mepc_o[profile]),
      .mcause_o(mcause_o[profile]), .mtval_o(mtval_o[profile]),
      .mie_o(mie_o[profile]), .mip_o(mip_o[profile]), .mcountinhibit_o(mcountinhibit_o[profile]),
      .mcycle_o(mcycle_o[profile]), .minstret_o(minstret_o[profile])
    );
  end

  /* a separate reference bank stores only architecturally writable fields. */
  typedef struct packed {
    logic [31:0] status, interrupt_enable, vector, scratch, epc, cause, tval, inhibit;
    logic [63:0] cycle_count, retirement_count;
  } state_t;
  /* separate permission and preview values from stored reference state. */
  typedef struct packed {
    logic legal;
    logic [31:0] old_value, read_value, new_value;
  } preview_t;
  state_t model [0:2];
  int unsigned cycles = 0, checks = 0, rng = 32'hc5a01234;
  int unsigned writes = 0, traps = 0, returns = 0, inhibited_edges = 0, frozen_edges = 0;
  bit mutation_applied = 0;

  /* print the complete input vector before stopping a failed comparison. */
  function automatic void check(input bit condition, input string reason, input int profile);
    checks++;
    /* failed observations never feed the next reference state. */
    if (!condition) $fatal(1, "cycle=%0d profile=%0d reset=%b access=%b addr=%03x op=%0d source=%08x read=%b write=%b commit=%b trap=%b pc=%08x cause=%08x tval=%08x mret=%b retire=%b pending=%08x debug=%b ebreak=%b: %s",
        cycles, profile, reset_i, access_i, addr_i, op_i, source_i, read_i, write_i, commit_i,
        trap_i, trap_pc_i, trap_cause_i, trap_tval_i, mret_i, retire_i, mip_levels_i,
        debug_mode_i, debug_ebreak_entry_i, reason);
  endfunction

  /* deterministic full-width samples supplement the exhaustive address/control sweep. */
  function automatic logic [31:0] random_word();
    rng = rng * 32'd1664525 + 32'd1013904223;
    return rng;
  endfunction

  /* a whitelist defines implemented addresses independently of the DUT's case statement. */
  function automatic int address_class(input int address);
    /* HPM placeholders are implemented constants in writable address space. */
    if ((address >= 803 && address <= 831) || (address >= 2819 && address <= 2847) ||
        (address >= 2947 && address <= 2975)) return 1;
    /* identification registers reject every requested write. */
    if (address >= 3857 && address <= 3861) return 2;
    /* machine state and counters use the manifest's exact decimal addresses. */
    case (address)
      768, 769, 772, 773, 784, 800, 832, 833, 834, 835, 836,
      2816, 2944, 2818, 2946: return 1;
      default: return 0;
    endcase
  endfunction

  /* reconstruct pending bits individually rather than sharing a DUT mask. */
  function automatic logic [31:0] pending_reference();
    logic [31:0] value;
    value = 0;
    value[3] = mip_levels_i[3]; value[7] = mip_levels_i[7]; value[11] = mip_levels_i[11];
    return value;
  endfunction

  /* model permission, old-value selection and field-specific write coercion. */
  function automatic preview_t preview(input state_t s, input int profile);
    preview_t p;
    logic [31:0] candidate;
    int category;
    p = '0;
    category = address_class(int'(addr_i));
    p.legal = access_i && category != 0 && !(category == 2 && write_i);
    /* forbidden and inactive queries have no visible result. */
    if (!p.legal) return p;
    /* constants default to zero, including all HPM placeholders and zero IDs. */
    case (int'(addr_i))
      768: p.old_value = s.status;
      769: p.old_value = profile == 2 ? 32'h40001104 : 32'h40000100;
      772: p.old_value = s.interrupt_enable;
      773: p.old_value = s.vector;
      800: p.old_value = s.inhibit;
      832: p.old_value = s.scratch;
      833: p.old_value = s.epc;
      834: p.old_value = s.cause;
      835: p.old_value = s.tval;
      836: p.old_value = pending_reference();
      2816: p.old_value = 32'(s.cycle_count);
      2944: p.old_value = 32'(s.cycle_count / 64'h100000000);
      2818: p.old_value = 32'(s.retirement_count);
      2946: p.old_value = 32'(s.retirement_count / 64'h100000000);
      3859: p.old_value = profile == 2 ? 32'h104 : 32'b0;
      default: p.old_value = 0;
    endcase
    p.read_value = read_i ? p.old_value : 32'b0;
    candidate = p.old_value;
    /* bit-level operations avoid sharing the implementation's word-level expressions. */
    for (int b = 0; b < 32; b++) begin
      /* a suppressed write never even proposes a field change. */
      if (write_i) begin
        /* normalized READ intentionally retains the previous value. */
        case (op_i)
          1: candidate[b] = source_i[b];
          2: candidate[b] = source_i[b] ? 1'b1 : p.old_value[b];
          3: candidate[b] = source_i[b] ? 1'b0 : p.old_value[b];
          default: candidate[b] = p.old_value[b];
        endcase
      end
    end
    p.new_value = p.old_value;
    /* each writable field is assembled explicitly from the candidate. */
    case (int'(addr_i))
      /* preserve fixed MPP while replacing MIE and MPIE. */
      768: begin p.new_value = 32'd6144; p.new_value[3] = candidate[3]; p.new_value[7] = candidate[7]; end
      /* retain only the three machine interrupt enables. */
      772: begin p.new_value = 0; p.new_value[3] = candidate[3]; p.new_value[7] = candidate[7]; p.new_value[11] = candidate[11]; end
      773: p.new_value = {candidate[31:2], 2'b00};
      /* retain only cycle and retirement inhibit bits. */
      800: begin p.new_value = 0; p.new_value[0] = candidate[0]; p.new_value[2] = candidate[2]; end
      832, 835, 2816, 2944, 2818, 2946: p.new_value = candidate;
      833: p.new_value = profile == 0 ? {candidate[31:2], 2'b00} : {candidate[31:1], 1'b0};
      /* the enumerated WLRL set includes software-writable cause zero in both alignments. */
      834: begin
        /* accept only the explicitly listed causes. */
        case (candidate)
          0, 1, 2, 3, 4, 5, 6, 7, 11, 32'h80000003, 32'h80000007, 32'h8000000b: p.new_value = candidate;
          default: p.new_value = p.old_value;
        endcase
      end
      default: p.new_value = p.old_value;
    endcase
    return p;
  endfunction

  /* advance reference state using whole-counter arithmetic and separate event priority. */
  function automatic state_t next_state(input state_t s, input bit legal, input logic [31:0] next_value, input int profile);
    state_t n;
    logic [64:0] sum;
    n = s;
    sum = 0;
    /* reset is independent of every supplied access and event field. */
    if (reset_i) begin
      n = '0; n.status = 6144; n.inhibit = 5;
      return n;
    end
    /* count only pre-edge enabled, non-debug cycles. */
    if (!debug_mode_i && !debug_ebreak_entry_i && !s.inhibit[0]) begin
      sum = {1'b0, s.cycle_count} + 65'd1;
      check(!sum[64] || sum[63:0] == 0, "reference cycle overflow boundary mismatch", profile);
      n.cycle_count = sum[63:0];
    end
    /* retirement is an explicit caller event and a trap cancels that event. */
    if (!debug_mode_i && !debug_ebreak_entry_i && !trap_i && retire_i && !s.inhibit[2]) begin
      sum = {1'b0, s.retirement_count} + 65'd1;
      check(!sum[64] || sum[63:0] == 0, "reference retirement overflow boundary mismatch", profile);
      n.retirement_count = sum[63:0];
    end
    /* no normal write survives a trap entry. */
    if (trap_i) begin
      n.status = 6144; n.status[7] = s.status[3];
      n.epc = profile == 0 ? {trap_pc_i[31:2], 2'b00} : {trap_pc_i[31:1], 1'b0};
      n.cause = trap_cause_i; n.tval = trap_tval_i;
    end
    /* MRET has priority over a simultaneous normal CSR commit. */
    else if (mret_i) begin
      n.status = 6272; n.status[3] = s.status[7];
    end
    /* legal explicit writes override an entire counter's implicit update. */
    else if (commit_i && legal && write_i) begin
      /* select storage independently from the DUT decode. */
      case (int'(addr_i))
        768: n.status = next_value;
        772: n.interrupt_enable = next_value;
        773: n.vector = next_value;
        800: n.inhibit = next_value;
        832: n.scratch = next_value;
        833: n.epc = next_value;
        834: n.cause = next_value;
        835: n.tval = next_value;
        2816: n.cycle_count = (s.cycle_count / 64'h100000000) * 64'h100000000 + 64'(next_value);
        2944: n.cycle_count = 64'(next_value) * 64'h100000000 + (s.cycle_count % 64'h100000000);
        2818: n.retirement_count = (s.retirement_count / 64'h100000000) * 64'h100000000 + 64'(next_value);
        2946: n.retirement_count = 64'(next_value) * 64'h100000000 + (s.retirement_count % 64'h100000000);
        /* constant registers ignore permitted writes. */
        default: begin end
      endcase
    end
    return n;
  endfunction

  /* compare each preview before the edge and complete public storage after it. */
  task automatic tick();
    preview_t p [0:2];
    state_t expected [0:2], actual;
    logic observed_legal;
    logic [31:0] observed_read;
    #2;
    /* all profiles share stimulus while maintaining separate alignment/identity expectations. */
    for (int profile = 0; profile < 3; profile++) begin
      p[profile] = preview(model[profile], profile);
      expected[profile] = next_state(model[profile], p[profile].legal, p[profile].new_value, profile);
      observed_legal = legal_o[profile]; observed_read = read_value_o[profile];
      /* corrupt permission observation through the ordinary preview comparator. */
      if ($test$plusargs("mutate_permission") && !mutation_applied && access_i && !p[profile].legal) begin
        observed_legal = 1; mutation_applied = 1;
      end
      /* corrupt a suppressed read without modifying the model or implementation. */
      if ($test$plusargs("mutate_suppression") && !mutation_applied && p[profile].legal && !read_i) begin
        observed_read ^= 1; mutation_applied = 1;
      end
      check(observed_legal == p[profile].legal, "permission mismatch", profile);
      check(old_o[profile] == p[profile].old_value && new_o[profile] == p[profile].new_value,
            "preview value mismatch", profile);
      check(observed_read == p[profile].read_value, "read suppression mismatch", profile);
      check(mip_o[profile] == pending_reference(), "pending-level mask mismatch", profile);
    end
    clk_i = 1; #2; cycles++;
    /* every writable bit is checked, even when it is never read through the selected address. */
    for (int profile = 0; profile < 3; profile++) begin
      actual = {mstatus_o[profile], mie_o[profile], mtvec_o[profile], mscratch_o[profile],
                mepc_o[profile], mcause_o[profile], mtval_o[profile], mcountinhibit_o[profile],
                mcycle_o[profile], minstret_o[profile]};
      /* a counter corruption must fail the normal state comparison. */
      if ($test$plusargs("mutate_counter") && !mutation_applied && !reset_i && !debug_mode_i &&
          !model[profile].inhibit[0]) begin
        actual.cycle_count ^= 1; mutation_applied = 1;
      end
      check(actual == expected[profile], "clock-edge state mismatch", profile);
      model[profile] = expected[profile];
    end
    /* coverage counts use stimulus events, not unverified implementation state. */
    if (commit_i && p[0].legal && write_i && !reset_i && !trap_i && !mret_i) writes++;
    if (trap_i && !reset_i) traps++;
    if (mret_i && !trap_i && !reset_i) returns++;
    if (model[0].inhibit == 5) inhibited_edges++;
    if (debug_mode_i || debug_ebreak_entry_i) frozen_edges++;
    clk_i = 0;
  endtask

  /* present one ordinary committed CSR write, retaining a separately controlled retire event. */
  task automatic write_csr(input logic [11:0] address, input logic [31:0] value);
    access_i = 1; addr_i = address; op_i = 1; source_i = value;
    read_i = 1; write_i = 1; commit_i = 1;
    tick();
  endtask

  /* enumerate all addresses and suppression/operation combinations, then force edge boundaries. */
  initial begin
    /* establish reset without relying on simulator initialization of architectural state. */
    for (int profile = 0; profile < 3; profile++) model[profile] = '0;
    reset_i = 1; #2; clk_i = 1; #2; clk_i = 0;
    /* reference reset values are explicit and independent of observed outputs. */
    for (int profile = 0; profile < 3; profile++) begin model[profile] = '0; model[profile].status = 6144; model[profile].inhibit = 5; end
    tick(); reset_i = 0;
    /* both read suppression and write suppression still require a known address. */
    for (int address = 0; address < 4096; address++) begin
      /* all normalized operations include register-value zero as well as set mask bits. */
      for (int operation = 0; operation < 4; operation++) begin
        /* the four read/write request combinations distinguish RO permissions from constant fields. */
        for (int controls = 0; controls < 4; controls++) begin
          access_i = 1; addr_i = 12'(address); op_i = 2'(operation);
          source_i = operation[0] ? 32'hffffffff : 32'b0;
          read_i = controls[0]; write_i = controls[1]; commit_i = 1;
          mip_levels_i = random_word(); tick();
        end
      end
    end
    /* walk every candidate bit through all operations on each stored noncounter register. */
    for (int register_number = 0; register_number < 8; register_number++) begin
      /* select stored register addresses independently of DUT state. */
      case (register_number)
        0: addr_i = 'h300;
        1: addr_i = 'h304;
        2: addr_i = 'h305;
        3: addr_i = 'h320;
        4: addr_i = 'h340;
        5: addr_i = 'h341;
        6: addr_i = 'h342;
        default: addr_i = 'h343;
      endcase
      /* all bit positions include reserved fields and writable fields. */
      for (int b = 0; b < 32; b++) begin
        /* WRITE, SET and CLEAR receive identical independently chosen candidates. */
        for (int operation = 1; operation < 4; operation++) begin
          source_i = 32'b1 << b; op_i = 2'(operation);
          access_i = 1; read_i = 1; write_i = 1; commit_i = 1; tick();
        end
      end
    end
    /* exercise every defined low cause and neighboring illegal interrupt/exception values. */
    for (int cause_number = 0; cause_number < 16; cause_number++) begin
      write_csr('h342, 32'(cause_number));
      write_csr('h342, 32'h80000000 + 32'(cause_number));
    end
    /* rollover and half writes exercise precedence over both counter increments. */
    retire_i = 1;
    write_csr('h320, 5); write_csr('hb80, 'hffffffff); write_csr('hb00, 'hffffffff);
    write_csr('hb82, 'hffffffff); write_csr('hb02, 'hffffffff);
    write_csr('h320, 0); access_i = 0; commit_i = 0; tick();
    write_csr('hb00, 'hffffffff); write_csr('hb80, 7);
    write_csr('hb02, 'hffffffff); write_csr('hb82, 9);
    access_i = 0; commit_i = 0; tick();
    /* enabling and disabling use the old inhibit bits on their own retirement edge. */
    write_csr('h320, 5); tick(); write_csr('h320, 0); tick();
    /* every combination of reset, trap, return, write, retirement and debug state has a defined order. */
    for (int collision = 0; collision < 128; collision++) begin
      write_csr('h300, 'h88); write_csr('h320, 0);
      reset_i = collision[0]; trap_i = collision[1]; mret_i = collision[2]; commit_i = collision[3];
      retire_i = collision[4]; debug_mode_i = collision[5]; debug_ebreak_entry_i = collision[6];
      access_i = 1; addr_i = 'h300; source_i = 'hffffffff;
      trap_pc_i = 'hffffffff; trap_cause_i = 11; trap_tval_i = 'h12345678; tick();
      reset_i = 0; trap_i = 0; mret_i = 0; debug_mode_i = 0; debug_ebreak_entry_i = 0;
    end
    /* counter-half writes compete with trap, return and debug freeze independently. */
    for (int address = 0; address < 4; address++) begin
      /* select all four halves without reusing the DUT decoder. */
      for (int collision = 0; collision < 16; collision++) begin
        write_csr('h320, 0);
        addr_i = address[0] ? (address[1] ? 12'hb82 : 12'hb80) : (address[1] ? 12'hb02 : 12'hb00);
        source_i = 'hffffffff; trap_i = collision[0]; mret_i = collision[1];
        debug_mode_i = collision[2]; debug_ebreak_entry_i = collision[3]; retire_i = 1;
        tick(); trap_i = 0; mret_i = 0; debug_mode_i = 0; debug_ebreak_entry_i = 0;
      end
    end
    /* full-width random data exercises arbitrary masks and invalid WLRL candidates. */
    for (int sample = 0; sample < 20000; sample++) begin
      source_i = random_word(); mip_levels_i = random_word(); trap_pc_i = random_word(); trap_tval_i = random_word();
      addr_i = 12'(random_word()); op_i = 2'(random_word());
      {reset_i, access_i, read_i, write_i, commit_i, trap_i, mret_i, retire_i, debug_mode_i, debug_ebreak_entry_i} = 10'(random_word());
      trap_cause_i = 32'(sample % 8); tick();
    end
    /* a malformed caller trap is a contract violation with its own active assertion detector. */
    if ($test$plusargs("invalid_trap")) begin
      reset_i = 0; trap_i = 1; trap_cause_i = 8; tick();
    end
    check(writes > 0 && traps > 0 && returns > 0 && frozen_edges > 0 && inhibited_edges > 0,
          "required event coverage missing", 0);
    check(!$test$plusargs("mutate_permission") && !$test$plusargs("mutate_suppression") &&
          !$test$plusargs("mutate_counter") && !$test$plusargs("invalid_trap"), "selected detector did not activate", 0);
    $display("PASS CSR profiles=3 addresses=4096 cycles=%0d checks=%0d writes=%0d traps=%0d returns=%0d frozen=%0d inhibited=%0d",
             cycles, checks, writes, traps, returns, frozen_edges, inhibited_edges);
    $finish;
  end
endmodule

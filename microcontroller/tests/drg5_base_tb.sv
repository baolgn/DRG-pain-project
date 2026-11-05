/* compare identical encoded RV32I programs under three scheduling configurations. */
module drg5_base_tb #(parameter bit DIAGNOSTIC = 0, parameter bit FORWARDING = 1);
  import drg5_control_pkg::*;
  /* disconnected debug outputs retain named endpoints in legacy configurations. */
  logic unused_debug_halted, unused_debug_resumeack, unused_debug_reg_ready;
  logic [31:0] unused_debug_dpc, unused_debug_dcsr, unused_debug_reg_rdata;
  logic [2:0] unused_debug_reg_error;
  /* preserve the explicitly IRQ-disabled compatibility profile. */
  logic unused_entry_pending, unused_idle, unused_irq_valid;
  logic [31:0] unused_irq_pc, unused_irq_cause;
  /* bounded identities and plans are independent of all DUT counters. */
  localparam integer CAPACITY = 2048;
  localparam integer PLAN_CAPACITY = 512;
  localparam logic [31:0] END_PC = 'h1f00;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
  logic [4:0] hold_i = 0;
  logic in_valid_i = 0, in_ready_o;
  packet_t in_packet_i = '0;
  logic flush_valid_i = 0, flush_ready_o, flush_aborted_o;
  logic [31:0] flush_pc_i = 0;
  logic redirect_valid_o;
  logic [31:0] redirect_pc_o;
  logic d_req_valid_o, d_req_ready_i = 0, d_req_write_o;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o;
  logic [1:0] d_req_size_o;
  logic [3:0] d_req_wstrb_o;
  logic d_rsp_valid_i = 0, d_rsp_ready_o;
  logic [31:0] d_rsp_tag_i = 0, d_rsp_rdata_i = 0;
  logic [1:0] d_rsp_status_i = 0;
  logic mem_launch_o, mem_busy_o, fatal_o;
  fatal_record_t fatal_record_o;
  logic [4:0] stage_valid_o, kill_valid_o;
  token_t stage_token_o [0:4];
  logic [3:0] transfer_o;
  logic [63:0] kill_uid_o [0:4];
  trace_t trace_o;
  logic [4:0] inspect_reg_i = 0;
  logic [31:0] inspect_value_o;
  logic inspect_defined_o;
  logic [31:0] mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o;
  /* this compatibility fixture leaves new interrupt levels disconnected. */
  logic [31:0] unused_mie, unused_mip, unused_mcountinhibit;
  logic [63:0] unused_mcycle, unused_minstret;


  /* the full public interface is observed without hierarchical implementation probes. */
  drg5_control #(.IRQ_ENABLED(0), .DIAGNOSTIC(DIAGNOSTIC), .FORWARDING(FORWARDING), .TEST_REGIONS(1)) dut (
    .debug_haltreq_i(1'b0), .debug_resumereq_i(1'b0), .debug_resethaltreq_i(1'b0),
    .debug_halted_o(unused_debug_halted), .debug_resumeack_o(unused_debug_resumeack), .debug_dpc_o(unused_debug_dpc), .debug_dcsr_o(unused_debug_dcsr), .debug_reg_valid_i(1'b0), .debug_reg_write_i(1'b0),
    .debug_reg_addr_i(16'b0), .debug_reg_wdata_i(32'b0), .debug_reg_ready_o(unused_debug_reg_ready),
    .debug_reg_rdata_o(unused_debug_reg_rdata), .debug_reg_error_o(unused_debug_reg_error),
    .mip_levels_i(32'b0), .fetch_busy_i(1'b0),
    .entry_pending_o(unused_entry_pending), .idle_o(unused_idle), .irq_valid_o(unused_irq_valid),
    .irq_pc_o(unused_irq_pc), .irq_cause_o(unused_irq_cause), .mie_o(unused_mie), .mip_o(unused_mip),
    .mcountinhibit_o(unused_mcountinhibit), .mcycle_o(unused_mcycle),
    .minstret_o(unused_minstret), .*
  );

  /* expected disposition records are produced before any DUT execution. */
  typedef struct packed {
    packet_t p;
    logic trap, redirect, serial, memory;
    logic [31:0] value, next_pc, response_data;
    logic [1:0] response_status;
    logic [3:0] lanes;
    logic [2:0] accept_extra, response_edges;
  } plan_t;
  plan_t plan [0:PLAN_CAPACITY-1];
  packet_t program_image [0:2047];
  packet_t originals [0:CAPACITY-1];
  bit live [0:CAPACITY-1], issued [0:CAPACITY-1], completed [0:CAPACITY-1];
  bit prepared [0:CAPACITY-1];
  logic [31:0] plan_regs [0:31], committed_regs [0:31];
  bit plan_defined [0:31], committed_defined [0:31];
  byte unsigned initial_ram [0:255], plan_ram [0:255], target_ram [0:255], effect_ram [0:255];
  int unsigned plan_reads, plan_writes, target_reads, target_writes, effect_reads, effect_writes;
  logic [31:0] plan_last, target_last, effect_last;
  int unsigned plan_count, cursor, memory_cursor, next_uid, order_ref, seed = 1, rng;
  int unsigned cases = 0, cycles = 0, checks = 0, retired = 0, traps = 0, offers = 0, replies = 0;
  int unsigned stalls = 0, bypass_x = 0, bypass_m = 0, bypass_w = 0, barrier_edges = 0;
  int unsigned completed_load_bypasses = 0, masked_ready = 0, serial_preparations = 0;
  bit [1:0] branch_bins [0:7];
  logic [39:0] encoding_rows = 0;
  int unsigned masking_bins [0:3];
  int focus_kind = -1;
  logic [31:0] focus_pc = 0;
  int unsigned nop_retired = 0;
  int unsigned case_cycle, build_pc, feed_pc;
  logic [31:0] epc_ref, cause_ref, tval_ref;
  bit recovery_ref = 1;
  bit owner = 0, accepted = 0, target_pending = 0, finished = 0, mutation_applied = 0;
  logic [10:0] owner_uid;
  int unsigned owner_plan, owner_edge, response_due, next_tag;
  logic [31:0] reply_data, reply_tag;
  logic [1:0] reply_status;
  int unsigned hold_left = 0;
  logic [31:0] hold_pc = 0;
  bit hold_started = 0, pause_active = 0;
  logic [31:0] pause_after_pc = 0;
  int unsigned held_w_captures = 0;

  /* fail immediately with enough context to reproduce the same instruction stream. */
  function automatic void check(input bit condition, input string message);
    checks++;
    /* no failing comparison may become an expected value for a later edge. */
    if (!condition) $fatal(1, "case=%0d seed=%0d diag=%0d forwarding=%0d cycle=%0d cursor=%0d: %s", cases, seed, DIAGNOSTIC, FORWARDING, cycles, cursor, message);
  endfunction

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

  /* compare independently widened signed values rather than copying the RTL predicate. */
  function automatic bit signed_less(input logic [31:0] a, input logic [31:0] b);
    logic signed [63:0] wide_a, wide_b;
    wide_a = $signed({{32{a[31]}}, a});
    wide_b = $signed({{32{b[31]}}, b});
    return wide_a < wide_b;
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

  /* produce deterministic schedule choices independently of runtime speculation. */
  function automatic logic [31:0] random_word();
    rng = rng * 32'd1664525 + 32'd1013904223;
    return rng;
  endfunction

  /* encode immediate arithmetic and load addresses directly from their fields. */
  function automatic logic [31:0] enc_i(input logic [6:0] opcode, input logic [4:0] rd,
      input logic [2:0] funct3, input logic [4:0] rs1, input logic [11:0] immediate);
    return {immediate, rs1, funct3, rd, opcode};
  endfunction

  /* encode the independent register-operation stimulus. */
  function automatic logic [31:0] enc_r(input logic [4:0] rd, input logic [2:0] funct3,
      input logic [4:0] rs1, input logic [4:0] rs2, input logic [6:0] funct7 = 0);
    return {funct7, rs2, rs1, funct3, rd, 7'h33};
  endfunction

  /* route a store immediate into its two encoded fields. */
  function automatic logic [31:0] enc_s(input logic [2:0] funct3, input logic [4:0] rs1,
      input logic [4:0] rs2, input logic [11:0] immediate = 0);
    return {immediate[11:5], rs2, rs1, funct3, immediate[4:0], 7'h23};
  endfunction

  /* construct branch offsets independently of the decoder's immediate extraction. */
  function automatic logic [31:0] enc_b(input logic [2:0] funct3, input logic [4:0] rs1,
      input logic [4:0] rs2, input logic [12:0] immediate);
    check(!immediate[0], "branch stimulus offset must be even");
    return {immediate[12], immediate[10:5], rs2, rs1, funct3,
            immediate[4:1], immediate[11], 7'h63};
  endfunction

  /* construct JAL offsets without consulting any DUT output. */
  function automatic logic [31:0] enc_j(input logic [4:0] rd, input logic [20:0] immediate);
    check(!immediate[0], "jump stimulus offset must be even");
    return {immediate[20], immediate[10:1], immediate[11], immediate[19:12], rd, 7'h6f};
  endfunction

  /* poison every supplied execution annotation while retaining encoded identity. */
  function automatic packet_t raw_packet(input logic [31:0] pc, input logic [31:0] word);
    packet_t p;
    p = '1;
    p.pc = pc;
    p.raw = word;
    p.raw_valid = 15;
    p.length = 4;
    p.expanded_valid = 0;
    p.expanded = 'h5a5aa5a5;
    p.op = OP_BASE;
    p.fault = 0;
    p.cause = 'hfeedface;
    p.mtval = 'hdeadbeef;
    return p;
  endfunction

  /* the verification adapter supplies access faults outside its immutable ROM image. */
  function automatic packet_t fetch_packet(input logic [31:0] pc);
    packet_t p;
    p = raw_packet(pc, 0);
    /* this adapter owns incoming instruction-alignment and access metadata. */
    if (pc[1:0] != 0 || pc >= 'h2000) begin
      p.fault = 1;
      p.cause = pc[1:0] != 0 ? 0 : 1;
      p.mtval = pc;
      p.raw_valid = 0;
    end
    /* a valid address selects immutable source bytes. */
    else begin
      p = program_image[pc >> 2];
    end
    return p;
  endfunction

  /* append an encoded word to the current immutable program. */
  task automatic emit(input logic [31:0] word);
    check(build_pc < END_PC, "program exceeded its instruction image");
    program_image[build_pc >> 2] = raw_packet(build_pc, word);
    build_pc += 4;
  endtask

  /* load constants using encoded instructions rather than synthetic results. */
  task automatic constant(input logic [4:0] rd, input logic [31:0] value);
    logic [31:0] upper;
    upper = (value + 'h800) & 'hfffff000;
    emit(upper | (32'(rd) << 7) | 'h37);
    emit(enc_i('h13, rd, 0, rd, value[11:0]));
  endtask

  /* end a finite program through a real unconditional control transfer. */
  task automatic end_program();
    emit(enc_j(0, 21'(END_PC - build_pc)));
  endtask

  /* calculate canonical lanes from the independent semantic address and width. */
  function automatic logic [3:0] lane_mask(input logic [1:0] offset, input logic [1:0] size);
    return 4'(((1 << (1 << size)) - 1) << offset);
  endfunction

  /* independently define the integration fixture's architectural region permissions. */
  function automatic logic [31:0] local_cause(input bit write_access,
      input logic [31:0] address, input logic [1:0] size);
    bit permitted;
    permitted = (address < 'h2000 && !write_access) ||
                (address >= 'h10000 && address < 'h20000 && !write_access) ||
                (address >= 'h20000000 && address < 'h20008000) ||
                (address >= 'h40000000 && address < 'h40001000 && size == 2) ||
                (address >= 'h50001000 && address < 'h50003000);
    /* natural alignment is checked before permissions. */
    if ((address & ((1 << size) - 1)) != 0) return write_access ? 6 : 4;
    /* every denied region has a precise access response before bus presentation. */
    if (!permitted) return write_access ? 7 : 5;
    return 0;
  endfunction

  /* model the planned target operation from semantic bytes before DUT execution. */
  task automatic plan_access(input bit write_access, input logic [31:0] address,
      input logic [1:0] size, input logic [31:0] source,
      output logic [1:0] status, output logic [31:0] data);
    int unsigned width, offset;
    logic [31:0] value;
    width = 1 << size;
    status = 0;
    data = 0;
    value = 0;
    /* the small mutable RAM is sufficient for the deterministic instruction programs. */
    if (address >= 'h20000000 && address + width <= 'h20000100) begin
      offset = address - 'h20000000;
      /* bytes are little-endian and stores consume the unshifted source value. */
      for (int unsigned b = 0; b < width; b++) begin
        /* accepted stores update the independent planned architectural memory. */
        if (write_access) plan_ram[offset + b] = source[8*b +: 8];
        /* accepted reads capture their value at the defined target service event. */
        else value[8*b +: 8] = plan_ram[offset + b];
      end
    end
    /* the side-effectful device has explicit direction and offset semantics. */
    else if (size == 2 && address >= 'h40000000 && address <= 'h40000010) begin
      /* every supported register has a deterministic acceptance-time action. */
      case (address[4:0])
        /* read tickets increment even when the load destination is x0. */
        0: begin
          status = write_access ? 1 : 0;
          /* rejected writes have no effect. */
          if (!write_access) begin value = plan_reads; plan_reads++; end
        end
        /* write tickets have one visible effect and reject reads. */
        4: begin
          status = write_access ? 0 : 1;
          /* accepted writes preserve their full word. */
          if (write_access) begin plan_writes++; plan_last = source; end
        end
        /* the read counter is read-only. */
        8: begin status = write_access ? 1 : 0; value = plan_reads; end
        /* the write counter is read-only. */
        12: begin status = write_access ? 1 : 0; value = plan_writes; end
        /* the last accepted store value is read-only. */
        16: begin status = write_access ? 1 : 0; value = plan_last; end
        default: status = 1;
      endcase
    end
    /* unmapped target registers and explicit test errors reject without effects. */
    else begin
      status = 1;
    end
    /* load replies carry only requested lanes; all other responses are zero. */
    if (!write_access && status == 0) data = value << (8 * address[1:0]);
  endtask

  /* interpret one immutable program before observing the pipeline. */
  task automatic build_plan();
    packet_t p;
    decode_t d;
    plan_t q;
    logic [31:0] pc, imm, a, b, target, shifted, random_value;
    bit taken;
    plan_count = 0;
    plan_reads = 0;
    plan_writes = 0;
    plan_last = 0;
    rng = seed ^ (32'(cases) * 'h9e3779b9);
    /* the reference begins with unspecified nonzero registers, just like the contract. */
    for (int r = 0; r < 32; r++) begin plan_regs[r] = 0; plan_defined[r] = r == 0; end
    /* planned memory starts from the same immutable fixture bytes as the actual target. */
    for (int byte_index = 0; byte_index < 256; byte_index++) plan_ram[byte_index] = initial_ram[byte_index];
    pc = 'h100;
    /* a bounded complete plan detects accidental infinite reference programs. */
    while (pc != END_PC && plan_count < PLAN_CAPACITY) begin
      p = fetch_packet(pc);
      d = decode_reference(p.raw);
      q = '0;
      q.p = p;
      q.p.rs1_used = 0; q.p.rs2_used = 0; q.p.rs1 = 0; q.p.rs2 = 0;
      q.p.rs1_value = 0; q.p.rs2_value = 0; q.p.rd = 0; q.p.rd_write = 0;
      q.p.result = 0; q.p.next_pc = 0;
      q.p.mem_addr = 0; q.p.mem_wdata = 0; q.p.mem_size = 0; q.p.mem_signed = 0;
      q.p.csr_addr = 0; q.p.csr_op = CSR_READ; q.p.csr_read = 0;
      q.p.csr_write = 0; q.p.csr_source = 0;
      /* incoming fetch faults take precedence over decoding and malformed metadata. */
      if (!p.fault) begin
        /* disabled instructions and malformed packet widths trap precisely. */
        if (!d.legal || p.length != 4 || p.raw_valid != 15 || p.expanded_valid) begin
          q.p.fault = 1; q.p.cause = 2; q.p.mtval = 0;
        end
        /* valid instruction operands are obtained only from independent reference state. */
        else begin
          check(!d.rs1_used || plan_defined[d.rs1], "program read undefined rs1");
          check(!d.rs2_used || plan_defined[d.rs2], "program read undefined rs2");
          q.p.rs1_used = d.rs1_used; q.p.rs2_used = d.rs2_used;
          q.p.rs1 = d.rs1; q.p.rs2 = d.rs2; q.p.rd = d.rd; q.p.rd_write = d.rd_write;
          q.p.rs1_value = d.rs1_used ? plan_regs[d.rs1] : 0;
          q.p.rs2_value = d.rs2_used ? plan_regs[d.rs2] : 0;
          q.p.next_pc = pc + 4; q.p.cause = 0; q.p.mtval = 0;
          imm = immediate_reference(p.raw[31:7], d.imm_kind);
          a = q.p.rs1_value; b = q.p.rs2_value;
          /* operation families have separate arithmetic, control and effect semantics. */
          case (d.kind)
            /* all arithmetic wraps at 32 bits. */
            1, 2, 3, 4: begin
              q.p.op = OP_RESULT;
              q.p.result = alu_reference(d.a_pc ? pc : a, d.b_imm ? imm : b, d.alu_op);
            end
            /* branch and jump targets are computed from pre-link operand values. */
            5, 6, 7: begin
              q.p.op = OP_CONTROL;
              taken = d.kind != 7;
              target = pc + imm;
              /* JALR clears bit zero before checking word alignment. */
              if (d.kind == 6) target = (a + imm) & 'hfffffffe;
              /* condition rows are independent of the RTL's branch implementation. */
              if (d.kind == 7) begin
                /* all six base predicates preserve signed versus unsigned comparisons. */
                case (d.branch_cond)
                  0: taken = a == b;
                  1: taken = a != b;
                  4: taken = signed_less(a, b);
                  5: taken = !signed_less(a, b);
                  6: taken = a < b;
                  7: taken = a >= b;
                  default: check(0, "illegal branch entered reference execution");
                endcase
              end
              q.redirect = taken;
              q.p.result = d.kind == 7 ? 0 : pc + 4;
              q.p.next_pc = taken ? target : pc + 4;
              /* only a taken control transfer raises source-target misalignment. */
              if (taken && target[1:0] != 0) begin
                q.p.fault = 1; q.p.cause = 0; q.p.mtval = target;
              end
            end
            /* stores and effectful loads share precise permission and ownership rules. */
            8, 9: begin
              q.p.op = d.kind == 9 ? OP_STORE : OP_LOAD;
              q.p.mem_size = d.mem_size; q.p.mem_signed = d.load_signed;
              q.p.mem_addr = a + imm;
              q.lanes = lane_mask(q.p.mem_addr[1:0], d.mem_size);
              /* store bytes are independently positioned and masked by semantic width. */
              for (int lane = 0; lane < 4; lane++) begin
                /* only requested store lanes carry source bytes. */
                if (d.kind == 9 && q.lanes[lane]) q.p.mem_wdata[8*lane +: 8] = b[8*(lane-int'(q.p.mem_addr[1:0])) +: 8];
              end
              q.p.cause = local_cause(d.kind == 9, q.p.mem_addr, d.mem_size);
              q.p.fault = q.p.cause != 0;
              /* local denials do not enter the physical effect plan. */
              if (q.p.fault) begin q.p.mtval = q.p.mem_addr; q.p.mem_wdata = 0; end
              /* permitted accesses have one target acceptance and one terminal reply. */
              else begin
                q.memory = 1;
                random_value = random_word(); q.accept_extra = 3'(random_value >> 16) % 4;
                random_value = random_word(); q.response_edges = 3'(1 + ((random_value >> 16) % 5));
                plan_access(d.kind == 9, q.p.mem_addr, d.mem_size, b, q.response_status, q.response_data);
                /* target rejections fault without consuming a load result. */
                if (q.response_status != 0) begin
                  q.p.fault = 1; q.p.cause = d.kind == 9 ? 7 : 5; q.p.mtval = q.p.mem_addr;
                end
                /* load extension occurs after lane selection. */
                else if (d.kind == 8) begin
                  shifted = q.response_data >> (8 * q.p.mem_addr[1:0]);
                  /* byte and halfword signs extend independently of the response's lane layout. */
                  case (d.mem_size)
                    0: q.p.result = d.load_signed ? {{24{shifted[7]}}, shifted[7:0]} : {24'b0, shifted[7:0]};
                    1: q.p.result = d.load_signed ? {{16{shifted[15]}}, shifted[15:0]} : {16'b0, shifted[15:0]};
                    default: q.p.result = shifted;
                  endcase
                end
              end
            end
            /* FENCE is a full barrier with no register or memory effect. */
            10: begin q.p.op = OP_FENCE; q.serial = 1; end
            /* ECALL raises the machine environment-call cause. */
            11: begin q.p.op = OP_ECALL; q.serial = 1; q.p.fault = 1; q.p.cause = 11; end
            /* EBREAK reports its own instruction address. */
            12: begin q.p.op = OP_EBREAK; q.serial = 1; q.p.fault = 1; q.p.cause = 3; q.p.mtval = pc; end
            default: check(0, "unknown legal reference kind");
          endcase
        end
      end
      q.trap = q.p.fault;
      q.next_pc = q.trap ? 0 : q.p.next_pc;
      q.value = q.p.result;
      plan[plan_count] = q;
      plan_count++;
      /* reference writes occur only for successful architectural dispositions. */
      if (!q.trap && q.p.rd_write) begin plan_regs[q.p.rd] = q.value; plan_defined[q.p.rd] = 1; end
      /* traps terminate this unit fixture's architectural stream at its vector. */
      if (q.trap) break;
      pc = q.next_pc;
    end
    check(plan_count > 0 && plan_count < PLAN_CAPACITY, "reference plan did not terminate");
  endtask
  /* map a surviving accepted identity onto the independently predicted architectural path. */
  function automatic int plan_index(input int unsigned uid);
    int position;
    position = int'(cursor);
    /* a wrong-path prefix makes later speculative records unmappable until redirect. */
    for (int unsigned id = 0; id < next_uid && id <= uid; id++) begin
      /* killed and already disposed identities do not consume architectural positions. */
      if (live[id]) begin
        /* immutable identity must agree with the next independently predicted instruction. */
        if (position >= int'(plan_count) || originals[id].pc != plan[position].p.pc ||
            originals[id].raw != plan[position].p.raw) return -1;
        /* return the position for this live allocation without consulting DUT results. */
        if (id == uid) return position;
        position++;
      end
    end
    return -1;
  endfunction

  /* classify readiness from immutable program intent and previously captured replies. */
  function automatic int readiness(input int stage, input int unsigned uid);
    int position;
    decode_t decoded;
    logic unused_decode_metadata;
    position = plan_index(uid);
    decoded = decode_reference(originals[uid].raw);
    unused_decode_metadata = ^decoded;
    /* nonarchitectural wrong-path arithmetic has unknown value readiness to this interpreter. */
    if (position < 0) begin
      /* a load is certainly unavailable before its registered completion. */
      if (decoded.kind == 8 && (stage == 2 || !completed[uid])) return 0;
      return -1;
    end
    /* a future architectural fault cannot supply a successful destination value. */
    if (plan[position].trap) return 0;
    /* W can bypass a held value only when forwarding is enabled. */
    if (stage == 4) return int'(FORWARDING || !hold_i[4]);
    /* conservative overlap deliberately waits for the actual W write. */
    if (!FORWARDING) return 0;
    /* ordinary ALU results and successful jump links are already available in X or M. */
    if (decoded.kind <= 6) return 1;
    /* loads require a prior registered successful reply in M. */
    if (stage == 3 && decoded.kind == 8) return int'(completed[uid]);
    return 0;
  endfunction

  /* target storage is changed from actual physical descriptors, without tag deduplication. */
  task automatic target_access(input bit write_access, input logic [31:0] address,
      input logic [1:0] size, input logic [3:0] lanes, input logic [31:0] data,
      output logic [1:0] status, output logic [31:0] response);
    int unsigned word_base;
    logic [3:0] read_lanes;
    read_lanes = lane_mask(address[1:0], size);
    status = 0;
    response = 0;
    /* byte strobes select actual target RAM effects independently of the instruction model. */
    if (address >= 'h20000000 && address < 'h20000100) begin
      word_base = (address - 'h20000000) & 'hfffffffc;
      /* a physical command never silently deduplicates repeated writes or reads. */
      for (int unsigned lane = 0; lane < 4; lane++) begin
        /* unused response lanes remain zero. */
        if (write_access ? lanes[lane] : read_lanes[lane]) begin
          /* stores update the actual target bytes at acceptance. */
          if (write_access) target_ram[word_base + lane] = data[8*lane +: 8];
          /* registered reads capture actual target bytes on the same service edge. */
          else response[8*lane +: 8] = target_ram[word_base + lane];
        end
      end
    end
    /* device registers are decoded from the actual physical address and direction. */
    else if (size == 2 && address == 'h40000000 && !write_access) begin
      response = target_reads;
      target_reads++;
    end
    /* write tickets expose their count and last accepted value. */
    else if (size == 2 && address == 'h40000004 && write_access) begin
      target_writes++;
      target_last = data;
    end
    /* read-only counters cannot be changed by a physical write. */
    else if (size == 2 && !write_access && address == 'h40000008) response = target_reads;
    /* the write-count register reports accepted physical writes. */
    else if (size == 2 && !write_access && address == 'h4000000c) response = target_writes;
    /* the last-write register reports the actual retained device value. */
    else if (size == 2 && !write_access && address == 'h40000010) response = target_last;
    /* every other target-level access rejects without architectural or device effects. */
    else status = 1;
  endtask

  /* update expected effects from the immutable planned intent rather than actual descriptors. */
  task automatic expected_effect(input plan_t q);
    int unsigned width, offset;
    logic unused_plan_metadata;
    unused_plan_metadata = ^{q.value, q.next_pc, q.response_data, q.trap, q.redirect,
                             q.serial, q.memory, q.lanes, q.accept_extra, q.response_edges};
    width = 1 << q.p.mem_size;
    /* a target rejection is guaranteed to have no physical effect. */
    if (q.response_status == 0) begin
      /* expected RAM writes consume semantic source bytes, independently of physical strobes. */
      if (q.p.op == OP_STORE && q.p.mem_addr >= 'h20000000 && q.p.mem_addr < 'h20000100) begin
        offset = q.p.mem_addr - 'h20000000;
        /* each semantic byte advances exactly once per validated acceptance. */
        for (int unsigned b = 0; b < width; b++) effect_ram[offset + b] = q.p.rs2_value[8*b +: 8];
      end
      /* read-ticket effects include loads to x0. */
      if (q.p.mem_addr == 'h40000000 && q.p.op == OP_LOAD) effect_reads++;
      /* write-ticket effects retain the source independently of lane positioning. */
      if (q.p.mem_addr == 'h40000004 && q.p.op == OP_STORE) begin
        effect_writes++; effect_last = q.p.rs2_value;
      end
    end
  endtask

  /* verify actual and independently predicted storage after every physical service. */
  task automatic check_effects();
    check(target_reads == effect_reads && target_writes == effect_writes && target_last == effect_last,
          "physical device effect mismatch");
    /* corruption in an unreturned RAM byte must still be detected. */
    for (int b = 0; b < 256; b++) check(target_ram[b] == effect_ram[b], "physical RAM effect mismatch");
  endtask

  /* preserve identity and independently count all live tokens on each registered snapshot. */
  task automatic check_stages();
    int unsigned count, seen;
    count = 0;
    /* every accepted live identity must occur in exactly one stage. */
    for (int unsigned uid = 0; uid < next_uid; uid++) begin
      seen = 0;
      /* stage inspection is an observation, never an allocation authority. */
      for (int s = 0; s < 5; s++) begin
        /* only asserted stage validity gives meaning to its token. */
        if (stage_valid_o[s] && stage_token_o[s].uid == 64'(uid)) seen++;
      end
      check(seen == int'(live[uid]), "live UID conservation mismatch");
      count += int'(live[uid]);
    end
    check(count == $countones(stage_valid_o), "pipeline owns an unallocated UID");
    /* complete immutable instruction identity survives every transfer and stall. */
    for (int s = 0; s < 5; s++) begin
      /* metadata is checked only while its stage owns an accepted token. */
      if (stage_valid_o[s]) begin
        check(stage_token_o[s].uid < 64'(next_uid), "stage UID outside allocation range");
        check({stage_token_o[s].p.pc, stage_token_o[s].p.raw, stage_token_o[s].p.raw_valid,
               stage_token_o[s].p.length, stage_token_o[s].p.expanded_valid, stage_token_o[s].p.expanded} ==
              {originals[stage_token_o[s].uid[10:0]].pc, originals[stage_token_o[s].uid[10:0]].raw,
               originals[stage_token_o[s].uid[10:0]].raw_valid, originals[stage_token_o[s].uid[10:0]].length,
               originals[stage_token_o[s].uid[10:0]].expanded_valid, originals[stage_token_o[s].uid[10:0]].expanded},
              "immutable instruction identity changed");
      end
    end
  endtask

  /* one edge checks admission, operands, effects and architectural disposition independently. */
  task automatic tick();
    logic [4:0] before_valid, expected_kills, observed_kills;
    token_t before_token [0:4];
    logic [3:0] moves;
    bit admission, response, acceptance, w_terminal, expect_redirect, any_barrier, older_barrier, expect_launch, older_done, expect_terminal;
    logic [31:0] accepted_addr, accepted_data;
    logic [3:0] accepted_lanes;
    logic [1:0] accepted_size;
    bit accepted_write;
    packet_t admitted_packet;
    trace_t observed;
    plan_t q;
    decode_t consumer, producer;
    int d_position, nearest, uid, memory_position, producer_readiness;
    bit ready, relevant, older_ready;
    logic unused_decode_metadata;
    logic [31:0] observed_source;
    d_req_ready_i = owner && !accepted && cycles >= owner_edge + int'(plan[owner_plan].accept_extra);
    d_rsp_valid_i = target_pending && cycles + 1 >= response_due;
    d_rsp_tag_i = reply_tag; d_rsp_status_i = reply_status; d_rsp_rdata_i = reply_data;
    /* a finite input pause leaves X and M empty while the selected producer reaches W. */
    if (pause_active && stage_valid_o[4] && stage_token_o[4].p.pc == hold_pc) pause_active = 0;
    in_valid_i = !finished && feed_pc != END_PC && !pause_active;
    in_packet_i = fetch_packet(feed_pc);
    hold_i = 0;
    /* a directed W stall exercises ready-value bypass without permitting retirement. */
    if (hold_left != 0 && stage_valid_o[4] && stage_token_o[4].p.pc == hold_pc) begin
      hold_i[4] = 1; hold_left--; hold_started = 1;
    end
    #2;
    check(fatal_o == 0 && fatal_record_o == '0, "unexpected fatal containment");
    check(d_rsp_ready_o, "healthy response channel not ready");
    check(!flush_aborted_o && flush_ready_o == !recovery_ref, "idle flush interface mismatch");
    before_valid = stage_valid_o;
    before_token = stage_token_o;
    moves = transfer_o;
    admission = in_valid_i && in_ready_o;
    admitted_packet = in_packet_i;
    acceptance = d_req_valid_o && d_req_ready_i;
    response = d_rsp_valid_i && d_rsp_ready_o;
    accepted_addr = d_req_addr_o; accepted_data = d_req_wdata_o;
    accepted_lanes = d_req_wstrb_o; accepted_size = d_req_size_o; accepted_write = d_req_write_o;
    check(d_req_valid_o == (owner && !accepted), "orphan or withdrawn first-valid offer");
    /* every physical presentation matches an independently planned intent. */
    if (owner && !accepted) begin
      q = plan[owner_plan];
      check(d_req_addr_o == q.p.mem_addr && d_req_wdata_o == q.p.mem_wdata &&
            d_req_size_o == q.p.mem_size && d_req_wstrb_o == (q.p.op == OP_STORE ? q.lanes : 0) &&
            d_req_write_o == (q.p.op == OP_STORE) && d_req_tag_o == next_tag,
            "persistent memory descriptor mismatch");
    end
    any_barrier = 0; older_barrier = 0;
    /* known base barriers exclude younger admission and movement through disposition. */
    for (int s = 0; s < 5; s++) begin
      /* raw decoding derives serialization without trusting the token's serial flag. */
      if (before_valid[s]) begin
        consumer = decode_reference(originals[before_token[s].uid[10:0]].raw);
        relevant = !originals[before_token[s].uid[10:0]].fault && originals[before_token[s].uid[10:0]].raw_valid == 15 &&
                   originals[before_token[s].uid[10:0]].length == 4 && !originals[before_token[s].uid[10:0]].expanded_valid &&
                   consumer.legal && consumer.kind >= 10;
        /* every known serial token excludes younger work independently of its stage flags. */
        if (relevant) begin
          any_barrier = 1;
          /* only a barrier older than M can prevent that memory operation draining. */
          if (s == 4) older_barrier = 1;
          /* younger stage transfers remain blocked while the barrier is live. */
          for (int younger = 0; younger < s && younger < 4; younger++)
            check(!moves[younger], "younger transfer crossed base barrier");
        end
      end
    end
    /* blocking new input is part of the advertised full-barrier policy. */
    if (any_barrier) begin check(!in_ready_o, "base barrier admitted younger input"); barrier_edges++; end
    expect_terminal = 0;
    /* W must dispose on its first eligible edge; a missing trace is not merely a timeout. */
    if (before_valid[4] && !hold_i[4]) begin
      memory_position = plan_index(int'(before_token[4].uid));
      check(memory_position >= 0, "wrong-path instruction reached ordered W");
      expect_terminal = !plan[memory_position].serial ||
                        (prepared[before_token[4].uid[10:0]] && !owner);
    end
    expect_launch = 0;
    older_done = !before_valid[4];
    /* W disposition readiness is reconstructed from mapped intent and prior preparation. */
    if (before_valid[4]) begin
      memory_position = plan_index(int'(before_token[4].uid));
      /* only successful older disposition allows a younger effect grant. */
      if (memory_position >= 0) older_done = !hold_i[4] && !plan[memory_position].trap &&
          !plan[memory_position].redirect && (!plan[memory_position].serial || prepared[before_token[4].uid[10:0]]);
    end
    /* first-valid permission follows the independently tracked M intent and bus ledger. */
    if (before_valid[3] && !owner && !recovery_ref && !hold_i[3] && !older_barrier && older_done) begin
      memory_position = plan_index(int'(before_token[3].uid));
      /* only an unissued planned physical operation can acquire the manager. */
      if (memory_position >= 0) expect_launch = plan[memory_position].memory && !issued[before_token[3].uid[10:0]];
    end
    check(mem_launch_o == expect_launch, "independent memory grant mismatch");
    d_position = -1;
    /* source dependency inspection uses immutable source and producer encodings. */
    if (before_valid[1]) begin
      uid = int'(before_token[1].uid);
      consumer = decode_reference(originals[uid].raw);
      d_position = plan_index(uid);
      /* both source ports independently choose the nearest older writer. */
      for (int port_number = 0; port_number < 2; port_number++) begin
        relevant = port_number == 0 ? consumer.rs1_used : consumer.rs2_used;
        nearest = -1; ready = 1; older_ready = 0;
        /* x0 has no producer and disabled/invalid inputs have no source dependency. */
        if (relevant && (port_number == 0 ? consumer.rs1 : consumer.rs2) != 0 &&
            !originals[uid].fault && originals[uid].length == 4 &&
            originals[uid].raw_valid == 15 && !originals[uid].expanded_valid) begin
          /* X then M then W implements age order, independent of their readiness. */
          for (int s = 2; s < 5; s++) begin
            /* producer identity comes from its original instruction, not decoded DUT annotations. */
            if (before_valid[s]) begin
              producer = decode_reference(originals[before_token[s].uid[10:0]].raw);
              /* destination intent exists even for an unready or faulting nearest producer. */
              if (producer.rd_write && !originals[before_token[s].uid[10:0]].fault &&
                  originals[before_token[s].uid[10:0]].length == 4 && originals[before_token[s].uid[10:0]].raw_valid == 15 &&
                  !originals[before_token[s].uid[10:0]].expanded_valid && producer.rd == (port_number == 0 ? consumer.rs1 : consumer.rs2)) begin
                producer_readiness = readiness(s, int'(before_token[s].uid));
                /* nearest identity is selected before readiness, including faults and pending loads. */
                if (nearest < 0) begin
                  nearest = s;
                  ready = producer_readiness != 0;
                end
                /* an older proven-ready value must remain masked by a nearer unready writer. */
                else if (producer_readiness == 1) older_ready = 1;
              end
            end
          end
          /* stale older values must never cross D when the nearest producer is unready. */
          if (!ready) begin
            check(!moves[1], "nearest unready producer did not stall operand capture");
            stalls++;
            /* the explicit masking bin distinguishes priority from ordinary dependencies. */
            if (older_ready) begin
              masked_ready++;
              /* directed programs attribute masking to the intended consumer class. */
              if (focus_kind >= 0 && originals[uid].pc == focus_pc) masking_bins[focus_kind]++;
            end
          end
          /* a successful dependency capture records which stage supplied the value. */
          if (moves[1] && nearest >= 0) begin
            /* these counters are timing observations, not architectural expectations. */
            case (nearest)
              2: bypass_x++;
              /* M can supply either an older result or a previously completed load. */
              3: begin
                bypass_m++;
                producer = decode_reference(originals[before_token[3].uid[10:0]].raw);
                /* completed-load forwarding never uses the current response bus. */
                if (producer.kind == 8) completed_load_bypasses++;
              end
              /* W capture distinguishes held-value forwarding from commit bypass. */
              4: begin
                bypass_w++;
                /* a held producer has not committed, so this observes the new W bypass policy. */
                if (hold_i[4]) held_w_captures++;
              end
              default: check(0, "invalid nearest producer stage");
            endcase
          end
        end
      end
    end
    unused_decode_metadata = ^{consumer, producer};
    clk_i = 1;
    #2;
    cycles++;
    recovery_ref = 0;
    observed = trace_o;
    /* suppressing a real NOP disposition must fail before any architectural value changes. */
    if ($test$plusargs("mutate_nop") && !mutation_applied && observed.valid && observed.packet.raw == 'h13) begin
      observed.valid = 0; mutation_applied = 1;
    end
    /* the result corruption control qualifies the architectural comparator. */
    if ($test$plusargs("mutate_result") && !mutation_applied && observed.valid && observed.rd_write) begin
      observed.value ^= 1; mutation_applied = 1;
    end
    check(observed.valid == expect_terminal, "terminal eligibility mismatch");
    w_terminal = observed.valid;
    expect_redirect = 0;
    expected_kills = 0;
    /* a terminal witness must name the oldest live W owner and exact independent plan record. */
    if (w_terminal) begin
      check(before_valid[4] && !hold_i[4] && observed.uid == before_token[4].uid &&
            observed.order == 64'(order_ref) && observed.uid < 64'(next_uid), "terminal ownership/order mismatch");
      uid = int'(observed.uid);
      check(live[uid] && cursor < plan_count && plan_index(uid) == int'(cursor), "lost or reordered architectural instruction");
      q = plan[cursor];
      consumer = decode_reference(q.p.raw);
      /* terminal coverage records only instructions whose full architectural result was checked. */
      for (int row = 0; row < 40; row++) begin
        /* raw metadata and prior faults prevent false legal-encoding coverage credit. */
        if (!originals[uid].fault && originals[uid].raw_valid == 15 && originals[uid].length == 4 &&
            !originals[uid].expanded_valid && (q.p.raw & ENCODINGS[row].mask) == ENCODINGS[row].match) encoding_rows[row] = 1;
      end
      /* both outcomes of every legal branch condition are explicit executed bins. */
      if (consumer.kind == 7 && !q.trap) branch_bins[consumer.branch_cond][q.redirect] = 1;
      check(!q.memory || completed[uid], "memory instruction disposed before captured reply");
      check(!q.serial || prepared[uid], "base barrier disposed before its preparation edge");
      check(observed.packet == q.p, "normalized terminal packet mismatch");
      check(observed.trap == q.trap && observed.next_pc == q.next_pc &&
            observed.rd_write == (!q.trap && q.p.rd_write) &&
            observed.rd == ((!q.trap && q.p.rd_write) ? q.p.rd : 0) &&
            observed.value == ((!q.trap && q.p.rd_write) ? q.value : 0) &&
            !observed.csr_read && !observed.csr_write && observed.csr_old == 0 && observed.csr_new == 0,
            "architectural disposition mismatch");
      expect_redirect = q.trap || q.redirect;
      /* only a qualified architectural control event authorizes killing younger identities. */
      if (expect_redirect) expected_kills = before_valid & 5'b01111;
      /* traps save their own PC and preserve every prior successful GPR effect. */
      if (q.trap) begin
        epc_ref = q.p.pc & 'hfffffffc; cause_ref = q.p.cause; tval_ref = q.p.mtval;
        traps++; finished = 1;
      end
      /* a successful normal instruction may change only its declared destination. */
      else begin
        retired++;
        /* a NOP still owns an architectural position and must retire exactly once. */
        if (q.p.raw == 'h13) nop_retired++;
        /* x0 writes are suppressed independently of instruction side effects. */
        if (q.p.rd_write) begin committed_regs[q.p.rd] = q.value; committed_defined[q.p.rd] = 1; end
      end
      $display("ARCH case=%0d index=%0d pc=%08x raw=%08x trap=%0d cause=%0d tval=%08x rdwrite=%0d rd=%0d value=%08x next=%08x",
               cases, cursor, q.p.pc, q.p.raw, q.trap, q.p.cause, q.p.mtval,
               !q.trap && q.p.rd_write, !q.trap && q.p.rd_write ? q.p.rd : 0,
               !q.trap && q.p.rd_write ? q.value : 0, q.next_pc);
      live[uid] = 0; cursor++; order_ref++;
    end
    check(redirect_valid_o == expect_redirect, "redirect event mismatch");
    /* control redirection is checked against the independent terminal result. */
    if (expect_redirect) begin check(redirect_pc_o == q.next_pc, "redirect target mismatch"); feed_pc = q.next_pc; end
    observed_kills = kill_valid_o;
    /* the kill negative control simulates a silent but reported instruction loss. */
    if ($test$plusargs("mutate_kill") && !mutation_applied && before_valid[0] && expected_kills == 0) begin
      observed_kills[0] = 1; mutation_applied = 1;
    end
    check(observed_kills == expected_kills, "unauthorized kill detector");
    /* kill witnesses must match exactly the independently authorized live stage set. */
    for (int s = 0; s < 5; s++) begin
      /* there is no unexplained cancellation of an accepted instruction. */
      if (expected_kills[s]) begin
        check(kill_uid_o[s] == before_token[s].uid && live[before_token[s].uid[10:0]], "kill identity mismatch");
        live[before_token[s].uid[10:0]] = 0;
      end
    end
    /* register the nonarchitectural preparation edge from conditions, not token flags. */
    if (before_valid[4] && !hold_i[4] && !w_terminal && !owner) begin
      uid = int'(before_token[4].uid);
      memory_position = plan_index(uid);
      /* a mapped serial operation must spend one eligible W edge preparing. */
      if (memory_position >= 0 && plan[memory_position].serial && !prepared[uid]) begin
        prepared[uid] = 1; serial_preparations++;
      end
    end
    /* validate captured operands against pre-executed state, including both bypass ports. */
    if (moves[1] && d_position >= 0) begin
      q = plan[d_position];
      observed_source = stage_token_o[2].p.rs1_value;
      /* a source-value corruption must be caught before its consumer can retire. */
      if ($test$plusargs("mutate_operand") && !mutation_applied && q.p.rs1_used) begin
        observed_source ^= 1; mutation_applied = 1;
      end
      check(stage_valid_o[2] && stage_token_o[2].uid == before_token[1].uid &&
            observed_source == q.p.rs1_value && stage_token_o[2].p.rs2_value == q.p.rs2_value &&
            stage_token_o[2].p.rs1_used == q.p.rs1_used && stage_token_o[2].p.rs2_used == q.p.rs2_used &&
            stage_token_o[2].p.rs1 == q.p.rs1 && stage_token_o[2].p.rs2 == q.p.rs2 &&
            stage_token_o[2].p.rd == q.p.rd && stage_token_o[2].p.rd_write == q.p.rd_write,
            "independent operand capture mismatch");
    end
    /* physical acceptance services actual descriptors and expected semantic intent separately. */
    if (acceptance) begin
      check(owner && !accepted, "duplicate physical acceptance");
      q = plan[owner_plan];
      target_access(accepted_write, accepted_addr, accepted_size, accepted_lanes, accepted_data, reply_status, reply_data);
      expected_effect(q);
      /* effect corruption is independent of all instruction and response comparators. */
      if ($test$plusargs("mutate_effect") && !mutation_applied) begin target_writes++; mutation_applied = 1; end
      check_effects();
      check(reply_status == q.response_status && reply_data == q.response_data, "target response differs from precomputed intent");
      accepted = 1; target_pending = 1; reply_tag = next_tag;
      response_due = cycles + int'(q.response_edges);
      $display("EFFECT case=%0d pc=%08x write=%0d address=%08x size=%0d lanes=%x wdata=%08x status=%0d rdata=%08x reads=%0d writes=%0d last=%08x",
               cases, q.p.pc, accepted_write, accepted_addr, accepted_size, accepted_lanes,
               accepted_data, reply_status, reply_data, target_reads, target_writes, target_last);
      $display("SERVICE case=%0d ordinal=%0d offer=%0d accepted=%0d reply_due=%0d", cases, owner_plan, owner_edge, cycles, response_due);
    end
    /* a registered reply completes exactly one physically accepted request. */
    if (response) begin
      check(owner && accepted && target_pending, "ownerless or duplicate response");
      completed[owner_uid] = 1;
      owner = 0; accepted = 0; target_pending = 0; replies++;
    end
    /* an emitted launch is a checked witness for an independently planned M instruction. */
    if (expect_launch) begin
      check(!owner && !response && before_valid[3] && !expect_redirect && !older_barrier,
            "unauthorized memory launch");
      uid = int'(before_token[3].uid);
      memory_position = plan_index(uid);
      check(memory_position >= 0 && plan[memory_position].memory && live[uid] && !issued[uid],
            "wrong-path or duplicate memory launch");
      /* no younger memory intent can jump over another live older instruction. */
      for (int unsigned older = 0; older < int'(before_token[3].uid); older++)
        check(!live[older], "memory launch preceded older architectural disposition");
      /* physical requests occur in the precomputed semantic effect order. */
      while (memory_cursor < plan_count && !plan[memory_cursor].memory) memory_cursor++;
      check(memory_cursor == int'(memory_position), "memory intent order mismatch");
      memory_cursor++;
      owner = 1; accepted = 0; owner_uid = 11'(uid); owner_plan = int'(memory_position);
      owner_edge = cycles; next_tag++; issued[uid] = 1; offers++;
      $display("SCHEDULE case=%0d ordinal=%0d accept_extra=%0d response_edges=%0d", cases, owner_plan,
               plan[owner_plan].accept_extra, plan[owner_plan].response_edges);
    end
    /* allocation follows only actual input handshakes, never trace or stage UID observations. */
    if (admission) begin
      check(next_uid < CAPACITY, "fixture UID capacity exhausted");
      originals[next_uid] = admitted_packet; live[next_uid] = 1;
      issued[next_uid] = 0; completed[next_uid] = 0; prepared[next_uid] = 0; next_uid++;
      check(!expect_redirect, "input admitted on redirect edge");
      feed_pc += 4;
      /* this one-off input pause changes timing only, never the immutable program. */
      if (pause_after_pc != 0 && admitted_packet.pc == pause_after_pc) begin pause_active = 1; pause_after_pc = 0; end
    end
    check(mem_busy_o == owner, "physical owner state mismatch");
    check(d_req_valid_o == (owner && !accepted), "orphan or missing registered offer");
    check_stages();
    /* inspect all committed storage, including writes that never appear in a terminal record. */
    for (int r = 0; r < 32; r++) begin
      inspect_reg_i = 5'(r); #1;
      check(inspect_defined_o == committed_defined[r], "architectural definedness mismatch");
      /* unspecified nonzero reset contents are not assigned invented values. */
      if (committed_defined[r]) check(inspect_value_o == committed_regs[r], "architectural GPR storage mismatch");
    end
    check(mstatus_o == 'h1800 && mtvec_o == 0 && mscratch_o == 0 &&
          mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref, "architectural trap storage mismatch");
    clk_i = 0;
  endtask
  /* initialize a new immutable program only after all prior accepted work was disposed. */
  task automatic begin_case();
    check(stage_valid_o == 0 && !owner && !target_pending, "previous case left live obligations");
    cases++;
    cold_reset_i = 1; in_valid_i = 0; d_req_ready_i = 0; d_rsp_valid_i = 0; hold_i = 0;
    #2; clk_i = 1; #2; clk_i = 0; cold_reset_i = 0;
    recovery_ref = 1;
    cursor = 0; memory_cursor = 0; next_uid = 0; order_ref = 0; next_tag = 0;
    owner = 0; accepted = 0; target_pending = 0; finished = 0;
    epc_ref = 0; cause_ref = 0; tval_ref = 0;
    target_reads = 0; target_writes = 0; target_last = 0;
    effect_reads = 0; effect_writes = 0; effect_last = 0;
    reply_data = 0; reply_status = 0; reply_tag = 0;
    hold_left = 0; hold_pc = 0; hold_started = 0; focus_kind = -1; focus_pc = 0; pause_active = 0; pause_after_pc = 0;
    build_pc = 'h100; feed_pc = 'h100;
    /* unused ROM positions contain a legal NOP, allowing harmless speculative prefixes. */
    for (int i = 0; i < 2048; i++) program_image[i] = raw_packet(32'(i * 4), 'h13);
    /* reset removes definedness rather than inventing nonzero-register values. */
    for (int r = 0; r < 32; r++) begin committed_regs[r] = 0; committed_defined[r] = r == 0; end
    /* every scenario uses a reproducible byte pattern and one pointer at RAM offset zero. */
    for (int b = 0; b < 256; b++) initial_ram[b] = 8'((b * 73) ^ 'h81);
    initial_ram[0] = 'h40; initial_ram[1] = 0; initial_ram[2] = 0; initial_ram[3] = 'h20;
  endtask

  /* run a preplanned finite program and positively drain all accepted instructions and effects. */
  task automatic execute_case();
    build_plan();
    /* actual and expected-effect memories share initialization but not mutable storage. */
    for (int b = 0; b < 256; b++) begin target_ram[b] = initial_ram[b]; effect_ram[b] = initial_ram[b]; end
    case_cycle = cycles;
    /* the finite bound assumes the fixture's recorded bounded target schedule and W hold. */
    while (!(cursor == plan_count && stage_valid_o == 0 && !owner)) begin
      check(cycles - case_cycle < 10000, "bounded architectural progress failed");
      tick();
    end
    check(!target_pending && feed_pc == (finished ? 0 : END_PC), "final stream or response did not drain");
    check_effects();
    check(target_reads == plan_reads && target_writes == plan_writes && target_last == plan_last,
          "final device state differs from independent whole-program execution");
    /* full storage equality detects silent corruption outside returned data. */
    for (int b = 0; b < 256; b++) check(target_ram[b] == plan_ram[b], "final RAM differs from whole-program execution");
    /* all specified final GPR values must match the independently executed image. */
    for (int r = 0; r < 32; r++) begin
      check(committed_defined[r] == plan_defined[r], "final reference definedness disagreement");
      /* undefined reset data remains outside the comparison domain. */
      if (plan_defined[r]) check(committed_regs[r] == plan_regs[r], "final program register mismatch");
      $display("FINAL case=%0d reg=%0d defined=%0d value=%08x", cases, r, plan_defined[r], plan_defined[r] ? plan_regs[r] : 0);
    end
    $display("CASE case=%0d instructions=%0d cycles=%0d hold_observed=%0d", cases, plan_count, cycles-case_cycle, hold_started);
  endtask

  /* construct arithmetic chains that exercise all base operations and source dependencies. */
  task automatic arithmetic_case();
    begin_case();
    emit('h13);
    constant(1, 'hfffffffe); constant(2, 33); constant(3, 'h80000000); constant(4, 'h7fffffff);
    /* register operations cover sign boundaries and low-five-bit shift masking. */
    for (int op = 0; op < 8; op++) emit(enc_r(5'(8 + op), 3'(op), 1, 2));
    emit(enc_r(16, 0, 3, 4, 'h20)); emit(enc_r(17, 5, 3, 2, 'h20));
    /* immediate operations include a negative SLTIU immediate and arithmetic shifts. */
    for (int op = 0; op < 8; op++) begin
      /* shift rows have the explicit base shift-function encoding. */
      if (op == 1 || op == 5) emit(enc_i('h13, 5'(18 + op), 3'(op), 3, 31));
      /* other rows sign-extend their negative twelve-bit immediate. */
      else emit(enc_i('h13, 5'(18 + op), 3'(op), 4, 'hfff));
    end
    emit(enc_i('h13, 26, 5, 3, 'h41f));
    emit('h00001297); emit(enc_i('h13, 5, 0, 5, 1));
    /* a long nearest-writer chain cannot accidentally pass with stale RF data. */
    for (int i = 0; i < 12; i++) emit(enc_i('h13, 5, 0, 5, 7));
    emit(enc_r(0, 0, 1, 2)); emit(enc_i('h13, 0, 0, 5, 17));
    end_program(); execute_case();
  endtask

  /* cover little-endian widths, extension, full barriers and effectful x0 loads. */
  task automatic memory_case();
    begin_case();
    constant(1, 'h20000000); constant(2, 'h89abcdef);
    emit(enc_s(2, 1, 2, 16)); emit(enc_s(1, 1, 2, 22)); emit(enc_s(0, 1, 2, 25));
    emit(enc_i(3, 3, 0, 1, 16)); emit(enc_i(3, 4, 4, 1, 16));
    emit(enc_i(3, 5, 1, 1, 18)); emit(enc_i(3, 6, 5, 1, 18)); emit(enc_i(3, 7, 2, 1, 16));
    constant(8, 'h40000000);
    emit(enc_i(3, 0, 2, 8, 0)); emit(enc_i(3, 9, 2, 8, 0));
    emit('hffff8f8f); emit(enc_s(2, 8, 7, 4)); emit('h0000000f);
    emit(enc_i(3, 10, 2, 8, 8)); emit(enc_i(3, 11, 2, 8, 12)); emit(enc_i(3, 12, 2, 8, 16));
    end_program(); execute_case();
  endtask

  /* execute all branch predicates with both outcomes and one backward finite loop. */
  task automatic control_cases();
    logic [2:0] condition;
    /* each independent stream selects its branch outcome through initialized operands. */
    for (int test_number = 0; test_number < 12; test_number++) begin
      begin_case();
      condition = test_number / 2 < 2 ? 3'(test_number / 2) : 3'(test_number / 2 + 2);
      constant(1, test_number[0] ? (condition >= 6 ? 'h7fffffff : 'h80000000) : 7);
      constant(2, test_number[0] ? (condition >= 6 ? 'h80000000 : 'h7fffffff) : 7);
      emit(enc_b(condition, 1, 2, 8)); emit(enc_i('h13, 3, 0, 0, 1));
      emit(enc_j(4, 8)); emit(enc_s(2, 0, 0, 0));
      constant(5, build_pc + 16 + 1);
      emit(enc_i('h67, 5, 0, 5, 0)); emit(enc_s(2, 0, 0, 0));
      end_program(); execute_case();
    end
    begin_case();
    emit(enc_i('h13, 1, 0, 0, 0)); emit(enc_j(0, 12));
    emit(enc_i('h13, 1, 0, 0, 1)); emit(enc_j(0, 4));
    emit(enc_b(0, 1, 0, 13'h1ff8));
    end_program(); execute_case();
  endtask

  /* each pending load masks an older ready destination for a different consumer class. */
  task automatic dependency_case(input int kind, input bit rejection);
    begin_case();
    focus_kind = kind;
    constant(1, rejection ? 'h50001000 : 'h20000000);
    constant(2, 'h20000000);
    emit(enc_i('h13, 5, 0, 0, 7));
    emit(enc_i(3, 5, 2, 1, 0));
    focus_pc = build_pc;
    /* ALU, branch, address and store-data dependencies use the same nearest loaded writer. */
    case (kind)
      0: emit(enc_i('h13, 6, 0, 5, 1));
      1: emit(enc_b(1, 5, 0, 8));
      2: emit(enc_i(3, 6, 2, 5, 0));
      3: emit(enc_s(2, 2, 5, 32));
      default: check(0, "unknown dependency scenario");
    endcase
    emit(enc_i('h13, 7, 0, 0, 1)); end_program(); execute_case();
  endtask

  /* hold a real ALU producer in W with empty intermediate stages and two dependent source ports. */
  task automatic held_w_case();
    begin_case();
    constant(1, 123);
    hold_pc = 'h104; pause_after_pc = 'h104; hold_left = 12;
    emit(enc_r(2, 0, 1, 1)); emit(enc_i('h13, 3, 0, 2, 1));
    end_program(); execute_case();
    check(hold_started, "directed W hold did not occur");
  endtask

  /* every unsupported family and supplied fetch fault has an explicit precise outcome. */
  task automatic fault_cases();
    logic [31:0] word;
    /* disabled extensions, privilege instructions and reserved base forms trap as illegal. */
    for (int fault_case = 0; fault_case < 18; fault_case++) begin
      begin_case();
      word = 'hffffffff;
      /* raw words are fixed stimuli rather than derived from the DUT decoder. */
      case (fault_case)
        0: word = 'h02000033;
        1: word = 'h30001073;
        2: word = 'h30200073;
        3: word = 'h10500073;
        4: word = 'h0000100f;
        5: word = 'h00000001;
        6: word = 'h0000001f;
        7: word = 'h02001013;
        8: word = 'h40001033;
        9: word = 'h00003003;
        10: word = 'h00003023;
        11: word = 'h00000073;
        12: word = 'h00100073;
        default: word = 'h00000013;
      endcase
      emit(word);
      /* metadata-invalid words cannot inherit their poisoned execution annotations. */
      if (fault_case == 13) program_image['h100 >> 2].raw_valid = 3;
      /* a supplied access fault wins over both illegal raw bits and poisoned operands. */
      if (fault_case == 14) begin
        program_image['h100 >> 2].fault = 1;
        program_image['h100 >> 2].cause = 1;
        program_image['h100 >> 2].mtval = 'h102;
        program_image['h100 >> 2].raw = 'hffffffff;
      end
      /* expanded and shortened input records cannot claim the raw32 base entry point. */
      if (fault_case == 15) program_image['h100 >> 2].expanded_valid = 1;
      /* the base entry never accepts an original sixteen-bit instruction. */
      if (fault_case == 16) program_image['h100 >> 2].length = 2;
      /* an incoming alignment fault wins over an otherwise ordinary encoding. */
      if (fault_case == 17) begin
        program_image['h100 >> 2].fault = 1; program_image['h100 >> 2].cause = 0;
        program_image['h100 >> 2].mtval = 'h102;
      end
      end_program(); execute_case();
    end
    /* exercise alignment, local permissions and target direction failures with real encodings. */
    for (int fault_case = 0; fault_case < 8; fault_case++) begin
      begin_case();
      constant(1, fault_case < 2 ? 'h20000001 : (fault_case < 4 ? 'h40001000 : 'h40000000));
      /* even cases are effectful loads to x0 and odd cases are stores. */
      if (!fault_case[0]) emit(enc_i(3, 0, 2, 1, fault_case >= 4 ? 4 : 0));
      /* reserved or wrong-direction device writes reject without counting an effect. */
      else emit(enc_s(2, 1, 0, fault_case >= 6 ? 24 : 0));
      end_program(); execute_case();
    end
    begin_case(); emit(enc_j(1, 2)); end_program(); execute_case();
    begin_case(); emit(enc_j(1, 21'('h2000 - build_pc))); execute_case();
    begin_case(); constant(1, 'h103); emit(enc_i('h67, 1, 0, 1, 0)); end_program(); execute_case();
  endtask

  /* establish physical reset before making any observation of initially unspecified stages. */
  initial begin
    /* zero remains a valid schedule seed and differs from Verilator's random seed convention. */
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    cold_reset_i = 1; #2; clk_i = 1; #2; clk_i = 0; cold_reset_i = 0;
    /* coverage arrays are initialized explicitly, independent of simulator power-up policy. */
    for (int condition = 0; condition < 8; condition++) branch_bins[condition] = 0;
    /* each dependency category starts without an assumed coverage witness. */
    for (int kind = 0; kind < 4; kind++) masking_bins[kind] = 0;
    arithmetic_case(); memory_case(); control_cases(); held_w_case();
    /* successful and rejected nearest loads exercise identical consumer categories. */
    for (int kind = 0; kind < 4; kind++) begin
      dependency_case(kind, 0); dependency_case(kind, 1);
    end
    fault_cases();
    check(nop_retired > 0, "NOP retirement coverage missing");
    check(encoding_rows == 40'hffffffffff, "not every base encoding row executed");
    /* reserved predicate slots are excluded from the six valid conditions. */
    for (int condition = 0; condition < 8; condition++) begin
      /* valid branch rows require both independently checked outcomes. */
      if (condition != 2 && condition != 3) check(branch_bins[condition] == 3, "branch outcome coverage missing");
    end
    check(offers == replies && offers > 0 && traps > 0 && serial_preparations > 0,
          "mandatory memory/trap/barrier coverage missing");
    /* overlapping modes must actually exercise dependency stalls. */
    if (!DIAGNOSTIC) check(stalls > 0, "dependency stall coverage missing");
    /* forwarded execution must use more than the eventual architectural RF write. */
    if (!DIAGNOSTIC && FORWARDING) check(bypass_x > 0 && bypass_m > 0 && completed_load_bypasses > 0 && held_w_captures > 0,
          "forwarding stage coverage missing");
    /* the central nearest-unready masking claim needs a witness for every consumer class. */
    if (!DIAGNOSTIC && FORWARDING) begin
      /* ALU, branch, address and store-data consumers are measured separately. */
      for (int kind = 0; kind < 4; kind++) check(masking_bins[kind] > 0, "nearest-writer masking class missing");
    end
    check(!$test$plusargs("mutate_result") && !$test$plusargs("mutate_operand") &&
          !$test$plusargs("mutate_effect") && !$test$plusargs("mutate_kill") && !$test$plusargs("mutate_nop"), "selected negative control did not activate");
    $display("PASS base diagnostic=%0d forwarding=%0d seed=%0d cases=%0d cycles=%0d checks=%0d retired=%0d traps=%0d offers=%0d replies=%0d stalls=%0d x=%0d m=%0d w=%0d held_w=%0d load_m=%0d masked=%0d masked_alu=%0d masked_branch=%0d masked_address=%0d masked_store=%0d nop=%0d barrier_edges=%0d preparation=%0d",
             DIAGNOSTIC, FORWARDING, seed, cases, cycles, checks, retired, traps, offers, replies,
             stalls, bypass_x, bypass_m, bypass_w, held_w_captures, completed_load_bypasses, masked_ready, masking_bins[0], masking_bins[1], masking_bins[2], masking_bins[3], nop_retired, barrier_edges, serial_preparations);
    $finish;
  end
endmodule

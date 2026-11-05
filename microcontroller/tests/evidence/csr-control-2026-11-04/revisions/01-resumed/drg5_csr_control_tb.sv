/* verify encoded CSR effects, trap state and event ordering at architectural retirement. */
module drg5_csr_control_tb #(parameter bit C_ENABLED = 0);
  import drg5_control_pkg::*;
  /* finite allocation ledgers are independent of DUT identity counters. */
  localparam integer CAPACITY = 128;
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



  /* synchronized pending levels are observed as CSRs without adding interrupt delivery. */
  logic [31:0] mip_levels_i = 0;
  logic [31:0] mie_o, mip_o, mcountinhibit_o;
  logic [63:0] mcycle_o, minstret_o;
  /* exercise overlapping execution with the production forwarding policy enabled. */
  drg5_control #(.DIAGNOSTIC(0), .FORWARDING(1), .C_ENABLED(C_ENABLED),
      .TEST_REGIONS(1), .D_MAX_WAIT_CYCLES(256)) dut (.*);

  /* instruction intent and eventual CSR values are separate reference records. */
  typedef struct packed {
    packet_t p;
    logic serial, redirect;
  } expected_t;
  packet_t originals [0:CAPACITY-1];
  expected_t expected [0:CAPACITY-1], offered;
  bit live [0:CAPACITY-1], issued [0:CAPACITY-1], completed [0:CAPACITY-1];
  bit failed [0:CAPACITY-1], prepared [0:CAPACITY-1];
  logic [31:0] memory_value [0:CAPACITY-1], preparation_value [0:CAPACITY-1];
  logic [31:0] regs_ref [0:31];
  bit defined_ref [0:31];
  logic [31:0] status_ref = 'h1800, vector_ref = 0, scratch_ref = 0, epc_ref = 0;
  logic [31:0] cause_ref = 0, tval_ref = 0, enable_ref = 0, inhibit_ref = 5;
  logic [63:0] cycle_ref = 0, instret_ref = 0;
  logic [31:0] arch_pc = 0, flush_target = 0;
  logic [63:0] next_uid = 0, next_order = 0;
  bit recovery_ref = 1, flush_pending = 0, fatal_ref = 0;
  bit owner = 0, accepted = 0, orphan = 0, respond = 0, inject_orphan = 0;
  logic [6:0] owner_uid = 0;
  logic [31:0] owner_addr = 0, owner_data = 0, owner_tag = 0, last_tag = 0;
  bit owner_write = 0;
  logic [1:0] planned_status = 0;
  logic [31:0] reply_data = 0;
  int unsigned target_reads = 0, target_writes = 0, reference_reads = 0, reference_writes = 0;
  logic [31:0] target_last = 0, reference_last = 0;
  int unsigned cases = 0, cycles = 0, checks = 0, retirements = 0, traps = 0;
  int unsigned csr_reads = 0, csr_writes = 0, read_suppressed = 0, write_suppressed = 0;
  int unsigned preparations = 0, returns = 0, launches = 0, responses = 0;
  int unsigned flushes = 0, aborts = 0, resets = 0, fatal_events = 0;
  int unsigned cycle_rollovers = 0, instret_rollovers = 0, held_dynamic_reads = 0;
  logic [5:0] csr_forms = 0;
  bit mutation_applied = 0;

  /* stop before a failing observation can become expected state on a subsequent edge. */
  function automatic void check(input bit condition, input string message);
    checks++;
    /* each failure identifies a reproducible scenario and independently expected PC. */
    if (!condition) $fatal(1, "case=%0d C=%0d cycle=%0d pc=%08x: %s", cases, C_ENABLED, cycles, arch_pc, message);
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
    decode_t decoded_ref;
    bit has_destination;
    int unsigned hit_count;
    decoded_ref = '0;
    hit_count = 0;
    has_destination = 0;
    /* each legal word must match exactly one instruction family row. */
    for (int i = 0; i < 40; i++) begin
      /* reserved operand fields are excluded only where the ISA permits them. */
      if ((word & ENCODINGS[i].mask) == ENCODINGS[i].match) begin
        decoded_ref.legal = 1;
        decoded_ref.kind = ENCODINGS[i].kind;
        decoded_ref.alu_op = ENCODINGS[i].alu_op;
        decoded_ref.imm_kind = ENCODINGS[i].imm_kind;
        hit_count++;
      end
    end
    check(hit_count <= 1, "independent encoding table overlapped");
    /* operation classes determine use masks rather than register index values. */
    case (decoded_ref.kind)
      /* register arithmetic retains both source uses even for HINTs. */
      1: begin
        decoded_ref.rs1_used = 1;
        decoded_ref.rs2_used = 1;
        has_destination = 1;
      end
      /* immediate arithmetic and JALR use one source and one immediate. */
      2, 6: begin
        decoded_ref.rs1_used = 1;
        decoded_ref.b_imm = 1;
        has_destination = 1;
      end
      /* LUI takes only its upper immediate. */
      3: begin
        decoded_ref.b_imm = 1;
        has_destination = 1;
      end
      /* AUIPC and JAL use the instruction PC plus their immediate. */
      4, 5: begin
        decoded_ref.a_pc = 1;
        decoded_ref.b_imm = 1;
        has_destination = 1;
      end
      /* conditional branches compare both sources and retain their condition. */
      7: begin
        decoded_ref.rs1_used = 1;
        decoded_ref.rs2_used = 1;
        decoded_ref.branch_cond = word[14:12];
      end
      /* loads retain their memory operation even with an x0 destination. */
      8: begin
        decoded_ref.rs1_used = 1;
        decoded_ref.b_imm = 1;
        decoded_ref.mem_size = word[13:12];
        decoded_ref.load_signed = !word[14];
        has_destination = 1;
      end
      /* store data remains a source while its address uses an immediate. */
      9: begin
        decoded_ref.rs1_used = 1;
        decoded_ref.rs2_used = 1;
        decoded_ref.b_imm = 1;
        decoded_ref.mem_size = word[13:12];
      end
      /* fence, environment and illegal records retain zero execution metadata. */
      default: begin end
    endcase
    decoded_ref.rs1 = decoded_ref.rs1_used ? word[19:15] : 0;
    decoded_ref.rs2 = decoded_ref.rs2_used ? word[24:20] : 0;
    decoded_ref.rd_write = has_destination && word[11:7] != 0;
    decoded_ref.rd = decoded_ref.rd_write ? word[11:7] : 0;
    return decoded_ref;
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
    p.op = OP_MACHINE;
    p.fault = 0;
    p.cause = 'hfeedface;
    p.mtval = 'hdeadbeef;
    return p;
  endfunction

  /* classify exactly the manifest inventory independently of bank implementation signals. */
  function automatic bit known_csr(input logic [11:0] address);
    /* implemented zero HPM windows are resources; adjacent addresses remain absent. */
    if ((address >= 'h323 && address <= 'h33f) || (address >= 'hb03 && address <= 'hb1f) ||
        (address >= 'hb83 && address <= 'hb9f)) return 1;
    /* each scalar address belongs to the fixed incomplete-prototype profile. */
    case (address)
      'h300, 'h301, 'h304, 'h305, 'h310, 'h320, 'h340, 'h341, 'h342, 'h343, 'h344,
      'hb00, 'hb80, 'hb02, 'hb82, 'hf11, 'hf12, 'hf13, 'hf14, 'hf15: return 1;
      default: return 0;
    endcase
  endfunction

  /* architectural read-only address permission is distinct from writable constant fields. */
  function automatic bit legal_csr(input logic [11:0] address, input bit write_requested);
    return known_csr(address) && !(write_requested && address[11:10] == 3);
  endfunction

  /* read exclusively the independently maintained pre-edge machine state. */
  function automatic logic [31:0] csr_value(input logic [11:0] address);
    /* constant identity and HPM values are zero except the fixed base-only misa value. */
    case (address)
      'h300: return status_ref;
      'h301: return 'h40000100;
      'h304: return enable_ref;
      'h305: return vector_ref;
      'h320: return inhibit_ref;
      'h340: return scratch_ref;
      'h341: return epc_ref;
      'h342: return cause_ref;
      'h343: return tval_ref;
      'h344: return mip_levels_i & 'h888;
      'hb00: return 32'(cycle_ref);
      'hb80: return 32'(cycle_ref >> 32);
      'hb02: return 32'(instret_ref);
      'hb82: return 32'(instret_ref >> 32);
      default: return 0;
    endcase
  endfunction

  /* legalize requested values by masks and the enumerated software-writable cause set. */
  function automatic logic [31:0] csr_post(input logic [11:0] address,
      input csr_op_t operation, input logic [31:0] source);
    logic [31:0] value, mask, fixed_bits;
    value = csr_value(address);
    mask = 0;
    fixed_bits = value;
    /* operation values come from decoded instruction intent, never bank preview outputs. */
    case (operation)
      CSR_WRITE: value = source;
      CSR_SET: value |= source;
      CSR_CLEAR: value &= ~source;
      default: begin end
    endcase
    /* generic fixed/writable-bit merging covers WARL and WPRI fields. */
    case (address)
      'h300: begin mask = 'h88; fixed_bits = 'h1800; end
      'h304: begin mask = 'h888; fixed_bits = 0; end
      'h305: begin mask = 'hfffffffc; fixed_bits = 0; end
      'h320: begin mask = 5; fixed_bits = 0; end
      'h341: begin mask = C_ENABLED ? 'hfffffffe : 'hfffffffc; fixed_bits = 0; end
      'h340, 'h343, 'hb00, 'hb80, 'hb02, 'hb82: begin mask = '1; fixed_bits = 0; end
      /* WLRL writes outside the legal cause set retain the previous value. */
      'h342: begin
        /* explicit set membership avoids accepting reserved cause ranges. */
        case (value)
          0, 1, 2, 3, 4, 5, 6, 7, 11, 'h80000003, 'h80000007, 'h8000000b: mask = '1;
          default: mask = 0;
        endcase
      end
      default: begin end
    endcase
    return (value & mask) | (fixed_bits & ~mask);
  endfunction

  /* decode expected packet intent from original bits and independently supplied operand values. */
  function automatic expected_t intent(input packet_t original,
      input logic [31:0] source1 = 0, input logic [31:0] source2 = 0);
    expected_t q;
    decode_t d;
    logic [31:0] immediate;
    bit csr_instruction, mret_instruction;
    logic [2:0] unused_branch_condition;
    q = '0;
    q.p = original;
    q.p.rs1_used = 0; q.p.rs2_used = 0; q.p.rs1 = 0; q.p.rs2 = 0;
    q.p.rs1_value = 0; q.p.rs2_value = 0; q.p.rd = 0; q.p.rd_write = 0;
    q.p.result = 0; q.p.next_pc = 0; q.p.mem_addr = 0; q.p.mem_wdata = 0;
    q.p.mem_size = 0; q.p.mem_signed = 0; q.p.csr_addr = 0; q.p.csr_op = CSR_READ;
    q.p.csr_read = 0; q.p.csr_write = 0; q.p.csr_source = 0;
    d = decode_reference(original.raw);
    unused_branch_condition = d.branch_cond;
    csr_instruction = original.raw[6:0] == 'h73 &&
                      (original.raw[14:12] inside {1, 2, 3, 5, 6, 7});
    mret_instruction = original.raw == 'h30200073;
    /* an earlier fetch fault does not execute any SYSTEM or operand semantics. */
    if (!original.fault) begin
      /* only complete raw32 machine-entry packets can execute this profile. */
      if (original.length != 4 || original.raw_valid != 15 || original.expanded_valid ||
          !(d.legal || csr_instruction || mret_instruction)) begin
        q.p.fault = 1; q.p.cause = 2; q.p.mtval = 0;
      end
      /* all legal instructions begin with a sequential continuation and no old fault annotation. */
      else begin
        q.p.next_pc = original.pc + 4; q.p.cause = 0; q.p.mtval = 0;
        /* six CSR forms derive suppression from encoded indices, independently of values. */
        if (csr_instruction) begin
          q.p.op = OP_CSR; q.serial = 1;
          q.p.rs1_used = !original.raw[14];
          q.p.rs1 = original.raw[14] ? 0 : original.raw[19:15];
          q.p.rs1_value = original.raw[14] || original.raw[19:15] == 0 ? 0 : source1;
          q.p.rd = original.raw[11:7]; q.p.rd_write = original.raw[11:7] != 0;
          q.p.csr_addr = original.raw[31:20]; q.p.csr_op = csr_op_t'(original.raw[13:12]);
          q.p.csr_read = original.raw[13:12] != 1 || original.raw[11:7] != 0;
          q.p.csr_write = original.raw[13:12] == 1 || original.raw[19:15] != 0;
          q.p.csr_source = original.raw[14] ? 32'(original.raw[19:15]) : q.p.rs1_value;
        end
        /* MRET reads machine state only on its ordered terminal edge. */
        else if (mret_instruction) begin
          q.p.op = OP_MRET; q.serial = 1; q.redirect = 1;
        end
        /* selected base instructions supply initialization and memory collision stimulus. */
        else begin
          q.p.rs1_used = d.rs1_used; q.p.rs2_used = d.rs2_used;
          q.p.rs1 = d.rs1; q.p.rs2 = d.rs2; q.p.rd = d.rd; q.p.rd_write = d.rd_write;
          q.p.rs1_value = d.rs1_used && d.rs1 != 0 ? source1 : 0;
          q.p.rs2_value = d.rs2_used && d.rs2 != 0 ? source2 : 0;
          immediate = immediate_reference(original.raw[31:7], d.imm_kind);
          /* the integration corpus uses only these already-qualified base operation families. */
          case (d.kind)
            /* full arithmetic semantics remain independent from DUT results. */
            1, 2, 3, 4: begin
              q.p.op = OP_RESULT;
              q.p.result = alu_reference(d.a_pc ? original.pc : q.p.rs1_value,
                                        d.b_imm ? immediate : q.p.rs2_value, d.alu_op);
            end
            /* collision accesses are naturally aligned MMIO words with explicit effect plans. */
            8, 9: begin
              q.p.op = d.kind == 9 ? OP_STORE : OP_LOAD;
              q.p.mem_addr = q.p.rs1_value + immediate;
              q.p.mem_size = d.mem_size; q.p.mem_signed = d.load_signed;
              check(d.mem_size == 2 && q.p.mem_addr[1:0] == 0, "CSR fixture memory intent must be aligned word");
              q.p.mem_wdata = d.kind == 9 ? q.p.rs2_value : 0;
            end
            /* environment instructions are ordered barriers with their own exception semantics. */
            10: begin q.p.op = OP_FENCE; q.serial = 1; end
            11: begin q.p.op = OP_ECALL; q.serial = 1; end
            12: begin q.p.op = OP_EBREAK; q.serial = 1; end
            default: check(0, "unsupported fixture instruction family");
          endcase
        end
      end
    end
    return q;
  endfunction

  /* recompute only W-time effects from current independent state and registered responses. */
  function automatic expected_t disposition(input logic [6:0] uid);
    expected_t q;
    q = expected[uid];
    /* an earlier fetch or decode fault remains authoritative. */
    if (!q.p.fault) begin
      /* instruction-specific late faults are independently resolved at the architectural boundary. */
      case (q.p.op)
        /* unknown and read-only write attempts have no normal CSR or destination effect. */
        OP_CSR: begin
          q.p.fault = !legal_csr(q.p.csr_addr, q.p.csr_write);
          q.p.cause = q.p.fault ? 2 : 0; q.p.mtval = 0;
        end
        /* returned data is available only after a successful owned response. */
        OP_LOAD: begin
          q.p.fault = failed[uid]; q.p.cause = failed[uid] ? 5 : 0;
          q.p.mtval = failed[uid] ? q.p.mem_addr : 0;
          q.p.result = failed[uid] ? 0 : memory_value[uid];
        end
        /* store rejections do not invent a completed write effect. */
        OP_STORE: begin
          q.p.fault = failed[uid]; q.p.cause = failed[uid] ? 7 : 0;
          q.p.mtval = failed[uid] ? q.p.mem_addr : 0;
        end
        /* faulting environment instructions never increment instret. */
        OP_ECALL: begin q.p.fault = 1; q.p.cause = 11; q.p.mtval = 0; end
        OP_EBREAK: begin q.p.fault = 1; q.p.cause = 3; q.p.mtval = q.p.pc; end
        default: begin end
      endcase
    end
    return q;
  endfunction

  /* expected GPR data for CSR reads is sampled from this edge's independent pre-state. */
  function automatic logic [31:0] terminal_value(input op_t op, input logic [31:0] result,
      input bit read_requested, input logic [11:0] address);
    /* non-CSR results were computed from semantic instruction intent or target service. */
    if (op != OP_CSR) return result;
    return read_requested ? csr_value(address) : 0;
  endfunction

  /* update autonomous counters before explicit ordered actions, preserving pre-edge write operands. */
  task automatic bank_edge(input bit reset_active, input bit terminal, input expected_t q);
    logic [63:0] old_cycle, old_instret;
    logic [31:0] post_value;
    logic unused_control;
    unused_control = ^{q.serial, q.redirect};
    old_cycle = cycle_ref; old_instret = instret_ref;
    post_value = csr_post(q.p.csr_addr, q.p.csr_op, q.p.csr_source);
    /* reset cancels every normal write, trap, return and automatic count. */
    if (reset_active) begin
      status_ref = 'h1800; enable_ref = 0; vector_ref = 0; scratch_ref = 0;
      epc_ref = 0; cause_ref = 0; tval_ref = 0; inhibit_ref = 5;
      cycle_ref = 0; instret_ref = 0;
    end
    /* containment and pipeline stalls leave the nonreset cycle counter running. */
    else begin
      /* the old inhibit bits govern this edge, including an inhibit-register write. */
      if (!inhibit_ref[0]) cycle_ref++;
      if (!inhibit_ref[2] && terminal && !q.p.fault) instret_ref++;
      /* explicit terminal state changes are atomic and younger work cannot interpose. */
      if (terminal) begin
        /* trap entry stacks MIE into MPIE and overwrites only trap-owned registers. */
        if (q.p.fault) begin
          status_ref = 'h1800 | ((status_ref & 8) << 4);
          epc_ref = q.p.pc & (C_ENABLED ? 'hfffffffe : 'hfffffffc);
          cause_ref = q.p.cause; tval_ref = q.p.mtval;
        end
        /* return restores MIE, sets MPIE and leaves saved PC/cause/value intact. */
        else if (q.p.op == OP_MRET) status_ref = 'h1880 | ((status_ref & 'h80) >> 4);
        /* successful writes can be legal no-ops on constant fields. */
        else if (q.p.op == OP_CSR && q.p.csr_write) begin
          /* counter-half writes preserve the other pre-edge half and override the full increment. */
          case (q.p.csr_addr)
            'h300: status_ref = post_value;
            'h304: enable_ref = post_value;
            'h305: vector_ref = post_value;
            'h320: inhibit_ref = post_value;
            'h340: scratch_ref = post_value;
            'h341: epc_ref = post_value;
            'h342: cause_ref = post_value;
            'h343: tval_ref = post_value;
            'hb00: cycle_ref = (old_cycle & 64'hffffffff00000000) | 64'(post_value);
            'hb80: cycle_ref = (old_cycle & 64'hffffffff) | (64'(post_value) << 32);
            'hb02: instret_ref = (old_instret & 64'hffffffff00000000) | 64'(post_value);
            'hb82: instret_ref = (old_instret & 64'hffffffff) | (64'(post_value) << 32);
            default: begin end
          endcase
        end
      end
      /* record genuine automatic rollover separately from intentional counter writes. */
      if (old_cycle == '1 && cycle_ref == 0) cycle_rollovers++;
      if (old_instret == '1 && instret_ref == 0) instret_rollovers++;
    end
  endtask
  /* compare complete terminal records before updating any architectural reference state. */
  task automatic terminal(input trace_t actual, input expected_t q, input logic [6:0] uid);
    trace_t wanted, observed;
    logic [31:0] value;
    logic unused_control;
    unused_control = ^{q.serial, q.redirect};
    wanted = '0; observed = actual;
    wanted.valid = 1; wanted.uid = 64'(uid); wanted.order = next_order;
    wanted.packet = q.p; wanted.trap = q.p.fault;
    wanted.next_pc = q.p.fault ? vector_ref : (q.p.op == OP_MRET ? epc_ref : q.p.next_pc);
    value = terminal_value(q.p.op, q.p.result, q.p.csr_read, q.p.csr_addr);
    /* a successful nonzero destination owns exactly one GPR write. */
    if (!q.p.fault && q.p.rd_write) begin
      wanted.rd_write = 1; wanted.rd = q.p.rd; wanted.value = value;
    end
    /* suppressed CSR accesses have zero validity and zero corresponding observation data. */
    if (!q.p.fault && q.p.op == OP_CSR) begin
      wanted.csr_read = q.p.csr_read; wanted.csr_write = q.p.csr_write;
      wanted.csr_old = q.p.csr_read ? csr_value(q.p.csr_addr) : 0;
      wanted.csr_new = q.p.csr_write ? csr_post(q.p.csr_addr, q.p.csr_op, q.p.csr_source) : 0;
      /* a requested write remains an event even when it changes no stored bit. */
      if ($test$plusargs("mutate_write") && !mutation_applied && wanted.csr_write) begin
        observed.csr_write = 0; mutation_applied = 1;
      end
      /* hidden read suppression cannot be inferred merely from a discarded destination. */
      if ($test$plusargs("mutate_read") && !mutation_applied && !wanted.csr_read) begin
        observed.csr_read = 1; mutation_applied = 1;
      end
      /* use an earlier preparation sample to calibrate the retirement-time dynamic-read check. */
      if ($test$plusargs("mutate_stale") && !mutation_applied && q.p.csr_read && q.p.csr_addr == 'hb00 &&
          preparation_value[uid] != value) begin
        observed.value = preparation_value[uid]; observed.csr_old = preparation_value[uid]; mutation_applied = 1;
      end
    end
    /* altered trap targets cannot hide behind a correct saved-PC update. */
    if ($test$plusargs("mutate_return") && !mutation_applied && q.p.op == OP_MRET && !q.p.fault) begin
      observed.next_pc ^= 2; mutation_applied = 1;
    end
    check((q.p.op != OP_LOAD && q.p.op != OP_STORE) || completed[uid],
          "memory terminal preceded its registered response");
    check(live[uid] && q.p.pc == arch_pc, "lost or reordered CSR instruction");
    check(observed == wanted, "independent CSR terminal mismatch");
    /* all older live owners must have already reached a terminal disposition. */
    for (int id = 0; id < int'(uid); id++) check(!live[id], "CSR terminal passed older live owner");
    live[uid] = 0; next_order++; arch_pc = wanted.next_pc;
    /* precise faults count as attempts, never as normal retirements. */
    if (q.p.fault) traps++;
    /* only successful dispositions modify GPRs or explicit CSR-access counts. */
    else begin
      retirements++;
      /* x0 never acquires defined storage or a write event. */
      if (q.p.rd_write) begin regs_ref[q.p.rd] = value; defined_ref[q.p.rd] = 1; end
      /* the six actual instruction forms each require an executed witness. */
      if (q.p.op == OP_CSR) begin
        csr_reads += int'(q.p.csr_read); csr_writes += int'(q.p.csr_write);
        read_suppressed += int'(!q.p.csr_read); write_suppressed += int'(!q.p.csr_write);
        csr_forms[q.p.raw[14] ? int'(q.p.raw[13:12])+2 : int'(q.p.raw[13:12])-1] = 1;
        /* changed samples demonstrate that preparation did not latch the returned dynamic value. */
        if (q.p.csr_read && (q.p.csr_addr == 'hb00 || q.p.csr_addr == 'h344) &&
            preparation_value[uid] != value) held_dynamic_reads++;
      end
      /* MRET is a real retired instruction and leaves trap history intact. */
      if (q.p.op == OP_MRET) returns++;
    end
  endtask

  /* observe one edge with independent reset, flush, terminal and request-ownership arbitration. */
  task automatic tick();
    logic [4:0] before_valid, wanted_kill, observed_kill;
    token_t before_token [0:4];
    logic [3:0] moves;
    logic [6:0] w_id, m_id;
    bit reset_active, fatal_active, accepted_input, flush_accept, active_flush, protect_m, protect_w;
    bit w_done, wanted_redirect, wanted_abort, flush_complete, launch_expected;
    bit accept_request, accept_response, owner_before, ready_expected;
    bit barrier_present, older_barrier;
    logic [31:0] redirect_target, active_target, observed_scratch, prep_snapshot;
    logic [31:0] accepted_data;
    bit accepted_write;
    logic [63:0] observed_cycle;
    expected_t w;
    packet_t d_expected;
    fatal_record_t fatal_wanted;
    int count;
    clk_i = 0;
    d_rsp_valid_i = inject_orphan || (owner && accepted && respond);
    d_rsp_tag_i = inject_orphan ? 'h12345678 : owner_tag;
    d_rsp_rdata_i = planned_status == 0 && !owner_write && !inject_orphan ? reply_data : 0;
    d_rsp_status_i = inject_orphan ? 0 : planned_status;
    #2;
    reset_active = cold_reset_i || hart_reset_i;
    fatal_active = fatal_ref || (inject_orphan && !cold_reset_i);
    check(!inject_orphan || !owner, "orphan-response fixture overlapped a real owner");
    before_valid = stage_valid_o; before_token = stage_token_o; moves = transfer_o;
    owner_before = owner;
    ready_expected = !flush_pending && !reset_active && !recovery_ref && !fatal_active;
    check(flush_ready_o == ready_expected, "independent flush readiness mismatch");
    check(d_rsp_ready_o == !cold_reset_i, "response readiness mismatch");
    flush_accept = flush_valid_i && ready_expected;
    active_flush = flush_pending || flush_accept;
    active_target = flush_pending ? flush_target : flush_pc_i;
    w_id = 7'(before_token[4].uid); m_id = 7'(before_token[3].uid);
    w = disposition(w_id);
    protect_m = before_valid[3] && issued[m_id];
    protect_w = before_valid[4] && (issued[w_id] || w.p.fault);
    w_done = before_valid[4] && !hold_i[4] && !reset_active && !fatal_active &&
             (!w.serial || (prepared[w_id] && !owner_before)) && (!active_flush || protect_w);
    wanted_kill = 0;
    /* reset cancels instruction ownership while physical ownership survives hart reset. */
    if (reset_active) wanted_kill = before_valid;
    /* fatal containment freezes live owners until reset, without inventing a terminal. */
    else if (!fatal_active) begin
      /* a precise fault or return precedes an external flush and all younger work. */
      if (w_done && (w.p.fault || w.redirect)) wanted_kill = before_valid & 5'b01111;
      /* issued memory survives flush through its W disposition, even after its reply. */
      else if (active_flush) begin
        wanted_kill = before_valid;
        wanted_kill[3] = before_valid[3] && !protect_m;
        wanted_kill[4] = before_valid[4] && !protect_w;
      end
    end
    flush_complete = !reset_active && !fatal_active && active_flush && !protect_m &&
                     (!protect_w || w_done) && !owner_before;
    wanted_redirect = flush_complete || (w_done && (w.p.fault || w.redirect));
    redirect_target = active_target;
    /* only an independent W disposition can select the trap vector or mepc. */
    if (w_done && (w.p.fault || w.redirect)) redirect_target = w.p.fault ? vector_ref :
        (w.p.op == OP_MRET ? epc_ref : w.p.next_pc);
    wanted_abort = reset_active ? flush_pending : (w_done && w.p.fault && active_flush);
    barrier_present = 0; older_barrier = before_valid[4] && expected[w_id].serial;
    /* each allocated expected serial instruction blocks younger input and movement. */
    for (int stage = 0; stage < 5; stage++) begin
      /* intent comes from original instruction bits, not the DUT serial flags. */
      if (before_valid[stage] && expected[7'(before_token[stage].uid)].serial) begin
        barrier_present = 1;
        /* existing older memory must remain able to drain ahead of the barrier. */
        for (int younger = 0; younger < stage && younger < 4; younger++)
          check(!moves[younger], "younger transfer crossed machine barrier");
      end
    end
    /* a held dynamic CSR cannot feed an admitted younger consumer. */
    if (barrier_present) check(!in_ready_o, "machine barrier admitted younger input");
    launch_expected = before_valid[3] && !hold_i[3] && !wanted_kill[3] && !active_flush &&
        !reset_active && !fatal_active && !older_barrier && !expected[m_id].p.fault && !issued[m_id] &&
        (expected[m_id].p.op == OP_LOAD || expected[m_id].p.op == OP_STORE) &&
        !owner_before && !recovery_ref && (!before_valid[4] || (w_done && !w.p.fault && !w.redirect));
    check(mem_launch_o == launch_expected, "independent CSR memory grant mismatch");
    check(mem_busy_o == owner && d_req_valid_o == (owner && !accepted), "CSR physical owner mismatch");
    /* first-valid descriptors remain intact through flush, stalls and hart reset. */
    if (owner) check(d_req_tag_o == owner_tag && d_req_addr_o == owner_addr &&
        d_req_wdata_o == owner_data && d_req_write_o == owner_write && d_req_size_o == 2 &&
        d_req_wstrb_o == (owner_write ? 15 : 0), "CSR owned descriptor changed");
    accepted_input = in_valid_i && in_ready_o;
    accept_request = d_req_valid_o && d_req_ready_i;
    accepted_data = d_req_wdata_o; accepted_write = d_req_write_o;
    prep_snapshot = csr_value(w.p.csr_addr);
    accept_response = !inject_orphan && d_rsp_valid_i && d_rsp_ready_o;
    check(fatal_o == fatal_ref, "public fatal changed before its sampled edge");
    clk_i = 1; #2; cycles++;
    observed_kill = kill_valid_o;
    /* a spurious reported cancellation must fail the ordinary independent kill comparator. */
    if ($test$plusargs("mutate_kill") && !mutation_applied && before_valid[4] && hold_i[4] &&
        !reset_active && !fatal_active && !active_flush) begin
      observed_kill[4] = !observed_kill[4]; mutation_applied = 1;
    end
    check(observed_kill == wanted_kill, "unjustified CSR squash");
    check(trace_o.valid == w_done, "CSR terminal eligibility mismatch");
    check(redirect_valid_o == wanted_redirect && (!wanted_redirect || redirect_pc_o == redirect_target),
          "CSR redirect arbitration mismatch");
    check(flush_aborted_o == wanted_abort, "CSR flush abort mismatch");
    /* every justified kill consumes exactly its independently allocated identity. */
    for (int stage = 0; stage < 5; stage++) begin
      /* invalid stages never supply arbitrary identity values. */
      if (wanted_kill[stage]) begin
        check(kill_uid_o[stage] == before_token[stage].uid && live[7'(kill_uid_o[stage])], "CSR kill identity mismatch");
        live[7'(kill_uid_o[stage])] = 0;
      end
    end
    /* acceptance updates physical and independent device ledgers separately. */
    if (accept_request) begin
      check(owner && !accepted, "duplicate CSR target acceptance");
      accepted = 1; reply_data = 0;
      /* a rejection has no target side effect. */
      if (planned_status == 0) begin
        /* actual target direction and data determine the device's physical action. */
        if (accepted_write) begin target_writes++; target_last = accepted_data; end
        else begin reply_data = target_reads; target_reads++; end
        /* independent instruction intent determines expected effects. */
        if (expected[owner_uid].p.op == OP_STORE) begin
          reference_writes++; reference_last = expected[owner_uid].p.rs2_value;
        end
        /* a ticket read has an effect even when rd is zero. */
        else begin
          check(reply_data == reference_reads, "CSR target returned wrong ticket"); reference_reads++;
        end
      end
    end
    /* completion releases the bus but leaves the issued instruction protected through W. */
    if (accept_response) begin
      check(owner && accepted, "ownerless CSR target response");
      /* reset or prior orphaning discards architectural completion without replaying effects. */
      if (!reset_active && !orphan) begin
        completed[owner_uid] = 1; failed[owner_uid] = planned_status == 1;
        memory_value[owner_uid] = reply_data;
      end
      owner = 0; accepted = 0; orphan = 0; responses++;
    end
    /* bank comparison uses old inhibit and old CSR state before any reference update. */
    if (w_done) terminal(trace_o, w, w_id);
    bank_edge(reset_active, w_done, w);
    /* cold reset is the only event that clears a recorded protocol fatal. */
    if (cold_reset_i) fatal_ref = 0;
    /* the intentional ownerless response freezes architecture on its sampling edge. */
    else if (inject_orphan && !fatal_ref) begin fatal_ref = 1; fatal_events++; end
    fatal_wanted = '0;
    /* this fixture's sole fatal injection has no owned descriptor. */
    if (fatal_ref) begin fatal_wanted.valid = 1; fatal_wanted.reason = 1; end
    check(fatal_o == fatal_ref && fatal_record_o == fatal_wanted, "CSR fatal state mismatch");
    /* reset clears architectural definedness and pending flushes, but preserves hart-reset identities. */
    if (reset_active) begin
      check(!cold_reset_i || !owner_before, "CSR fixture abandoned a live physical owner");
      recovery_ref = 1; flush_pending = 0; arch_pc = 0;
      /* x0 remains the only defined reset GPR. */
      for (int r = 0; r < 32; r++) begin regs_ref[r] = 0; defined_ref[r] = r == 0; end
      /* only qualified cold reset restarts allocation/order/tag counters. */
      if (cold_reset_i) begin next_uid = 0; next_order = 0; last_tag = 0; end
      /* a hart reset cannot withdraw a previously presented device request. */
      if (hart_reset_i && owner) orphan = 1;
      resets++;
    end
    /* normal edge bookkeeping cannot reintroduce a previously killed instruction. */
    else begin
      /* recovery release waits until no physical obligation exists. */
      if (recovery_ref && !owner_before && !fatal_active) recovery_ref = 0;
      /* a newly accepted external flush owns one stable continuation. */
      if (flush_accept) begin flush_pending = 1; flush_target = flush_pc_i; flushes++; end
      /* successful protected memory can retire to its own PC while external flush publishes another. */
      if (flush_complete && !(w_done && (w.p.fault || w.redirect))) arch_pc = active_target;
      /* completion or a winning fault/reset consumes the accepted flush exactly once. */
      if (flush_complete || wanted_abort) flush_pending = 0;
      /* preparation records a reference sample but does not commit any instruction effect. */
      if (before_valid[4] && w.serial && !prepared[w_id] && !hold_i[4] && !wanted_kill[4] &&
          !owner_before && !fatal_active) begin
        prepared[w_id] = 1; preparations++;
        preparation_value[w_id] = w.p.op == OP_CSR ? prep_snapshot : 0;
      end
      /* only an input handshake creates a new reference-owned token. */
      if (accepted_input) begin
        check(next_uid < 64'(CAPACITY), "CSR fixture UID capacity exhausted");
        originals[7'(next_uid)] = in_packet_i; expected[7'(next_uid)] = offered;
        live[7'(next_uid)] = 1; issued[7'(next_uid)] = 0; completed[7'(next_uid)] = 0;
        failed[7'(next_uid)] = 0; prepared[7'(next_uid)] = 0;
        memory_value[7'(next_uid)] = 0; preparation_value[7'(next_uid)] = 0; next_uid++;
      end
    end
    aborts += int'(wanted_abort);
    /* reserve physical first-valid ownership independently of the DUT busy flag. */
    if (launch_expected) begin
      check(!owner, "CSR memory launch overlapped old owner");
      owner = 1; accepted = 0; owner_uid = m_id; owner_addr = expected[m_id].p.mem_addr;
      owner_data = expected[m_id].p.mem_wdata; owner_write = expected[m_id].p.op == OP_STORE;
      last_tag++; owner_tag = last_tag; issued[m_id] = 1; launches++;
    end
    check(mem_busy_o == owner && d_req_valid_o == (owner && !accepted), "registered CSR bus owner mismatch");
    check(target_reads == reference_reads && target_writes == reference_writes && target_last == reference_last,
          "CSR physical effect mismatch");
    /* every live UID has exactly one stage, including zero-effect CSR and NOP instructions. */
    for (int id = 0; id < CAPACITY; id++) begin
      count = 0;
      /* multiplicity prevents duplicate identities from concealing a missing instruction. */
      for (int stage = 0; stage < 5; stage++) count += int'(stage_valid_o[stage] && stage_token_o[stage].uid == 64'(id));
      check(count == int'(live[id]), "CSR accepted identity lost or duplicated");
    end
    /* every movement witness preserves its original instruction identity. */
    for (int stage = 0; stage < 5; stage++) begin
      /* invalid tokens are unspecified and cannot create a reference owner. */
      if (stage_valid_o[stage]) begin
        check(stage_token_o[stage].uid < next_uid, "unallocated CSR stage identity");
        check({stage_token_o[stage].p.pc, stage_token_o[stage].p.raw, stage_token_o[stage].p.raw_valid,
               stage_token_o[stage].p.length, stage_token_o[stage].p.expanded_valid, stage_token_o[stage].p.expanded} ==
              {originals[7'(stage_token_o[stage].uid)].pc, originals[7'(stage_token_o[stage].uid)].raw,
               originals[7'(stage_token_o[stage].uid)].raw_valid, originals[7'(stage_token_o[stage].uid)].length,
               originals[7'(stage_token_o[stage].uid)].expanded_valid, originals[7'(stage_token_o[stage].uid)].expanded},
              "immutable CSR instruction identity changed");
      end
    end
    /* compare the complete D-captured operand and intent record before X execution. */
    if (moves[1]) begin
      d_expected = expected[7'(before_token[1].uid)].p;
      d_expected.result = 0;
      /* effective address and store lanes are formed later in X. */
      if (d_expected.op == OP_LOAD || d_expected.op == OP_STORE) begin d_expected.mem_addr = 0; d_expected.mem_wdata = 0; end
      check(stage_valid_o[2] && stage_token_o[2].uid == before_token[1].uid && stage_token_o[2].p == d_expected,
            "independent CSR D capture mismatch");
    end
    observed_scratch = mscratch_o; observed_cycle = mcycle_o;
    /* a hidden CSR update must fail direct storage comparison even without a read instruction. */
    if ($test$plusargs("mutate_storage") && !mutation_applied && scratch_ref != 0) begin observed_scratch ^= 1; mutation_applied = 1; end
    /* automatic counter changes are checked without copying any CSR read trace. */
    if ($test$plusargs("mutate_counter") && !mutation_applied && !inhibit_ref[0]) begin observed_cycle ^= 1; mutation_applied = 1; end
    check(mstatus_o == status_ref && mtvec_o == vector_ref && observed_scratch == scratch_ref &&
          mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref && mie_o == enable_ref &&
          mip_o == (mip_levels_i & 'h888) && mcountinhibit_o == inhibit_ref, "independent CSR storage mismatch");
    check(observed_cycle == cycle_ref && minstret_o == instret_ref, "independent counter edge mismatch");
    /* committed GPR storage is inspected in full after every checked edge. */
    for (int r = 0; r < 32; r++) begin
      inspect_reg_i = 5'(r); #1;
      check(inspect_defined_o == defined_ref[r], "CSR GPR definedness mismatch");
      /* unspecified nonzero reset contents are not replaced with invented zeros. */
      if (defined_ref[r]) check(inspect_value_o == regs_ref[r], "CSR GPR storage mismatch");
    end
    clk_i = 0;
  endtask
  /* start a scenario only after every earlier pipeline, flush and target obligation is gone. */
  task automatic begin_case();
    check(stage_valid_o == 0 && !owner && !flush_pending && !fatal_ref, "CSR scenario abandoned live state");
    cases++; in_valid_i = 0; flush_valid_i = 0; hold_i = 0;
    respond = 0; d_req_ready_i = 0; inject_orphan = 0; planned_status = 0; mip_levels_i = 0;
    cold_reset_i = 1; tick(); cold_reset_i = 0; tick();
    arch_pc = 'h100;
    target_reads = 0; target_writes = 0; reference_reads = 0; reference_writes = 0;
    target_last = 0; reference_last = 0;
  endtask

  /* wait for a chosen observation point only to place an event, not to determine expected results. */
  task automatic reach(input logic [2:0] stage, input logic [31:0] pc);
    int clocks;
    clocks = 0;
    /* finite progress is required under the fixture's explicit holds and bounded target service. */
    while (!(stage_valid_o[stage] && stage_token_o[stage].p.pc == pc) && clocks < 100) begin
      tick(); clocks++;
    end
    check(clocks < 100, "CSR instruction failed to reach event boundary");
  endtask

  /* submit raw bits plus independent semantic operand intent until actual allocation. */
  task automatic send(input packet_t p, input logic [31:0] source1 = 0, input logic [31:0] source2 = 0);
    logic [63:0] initial_uid;
    int clocks;
    initial_uid = next_uid;
    in_packet_i = p; offered = intent(p, source1, source2); in_valid_i = 1;
    clocks = 0;
    /* input acceptance cannot be inferred from changing internal stage state. */
    while (next_uid == initial_uid && clocks < 100) begin tick(); clocks++; end
    in_valid_i = 0;
    check(next_uid == initial_uid + 1, "CSR input failed to accept once");
  endtask

  /* run to a positively empty owner ledger instead of resetting unfinished work away. */
  task automatic drain();
    int clocks;
    clocks = 0;
    /* callers explicitly release any deliberate hold or target stall first. */
    while ((stage_valid_o != 0 || owner || flush_pending) && clocks < 150) begin tick(); clocks++; end
    check(clocks < 150 && !owner && !flush_pending && stage_valid_o == 0, "CSR drainage bound expired");
    /* quiet edges also check for repeated architectural and device effects. */
    repeat (2) tick();
  endtask

  /* encode an exact Zicsr instruction without using any production decode constant. */
  function automatic logic [31:0] encode_csr(input logic [11:0] address,
      input logic [2:0] form, input logic [4:0] rd, input logic [4:0] source);
    return {address, source, form, rd, 7'h73};
  endfunction

  /* commit constants through real LUI/ADDI encodings, including the dependency between them. */
  task automatic constant(input logic [4:0] rd, input logic [31:0] value);
    logic [31:0] pc, upper;
    pc = arch_pc;
    upper = (value + 'h800) & 'hfffff000;
    send(raw_packet(pc, upper | (32'(rd) << 7) | 'h37));
    send(raw_packet(pc + 4, enc_i('h13, rd, 0, rd, value[11:0])), upper);
    drain();
    check(regs_ref[rd] == value, "encoded constant setup disagreed with intent");
  endtask

  /* this convenience wrapper still executes a raw CSRRW with an independently known register value. */
  task automatic write_csr(input logic [11:0] address, input logic [31:0] value);
    constant(31, value);
    send(raw_packet(arch_pc, encode_csr(address, 1, 0, 31)), value);
    drain();
  endtask

  /* read with CSRRS rs1=x0 and verify its returned value through the ordinary terminal comparator. */
  task automatic read_csr(input logic [11:0] address, input logic [4:0] rd = 5);
    send(raw_packet(arch_pc, encode_csr(address, 2, rd, 0)));
    drain();
  endtask

  /* exhaust encoded read/write suppression distinctions across all six forms. */
  task automatic suppression_cases();
    logic [2:0] form;
    logic [4:0] source, rd;
    logic [31:0] value;
    /* register and immediate forms use the same independent semantic partition. */
    for (int form_index = 0; form_index < 6; form_index++) begin
      form = form_index < 3 ? 3'(form_index + 1) : 3'(form_index + 2);
      /* discarded and nonzero destinations differ only in architecturally defined read suppression. */
      for (int destination = 0; destination < 2; destination++) begin
        rd = destination == 0 ? 0 : 2;
        /* distinguish x0, a nonzero register holding zero, and a nonzero data value. */
        for (int source_kind = 0; source_kind < 3; source_kind++) begin
          begin_case();
          write_csr('h340, 'h87654321);
          value = source_kind == 2 ? 'h80200181 : 0;
          constant(1, value);
          source = source_kind == 0 ? 0 : (form[2] && source_kind == 2 ? 31 : 1);
          send(raw_packet(arch_pc, encode_csr('h340, form, rd, source)), value);
          drain(); read_csr('h340, 3);
        end
      end
    end
  endtask

  /* verify address permissions from encoded accesses, including zero-valued requested writes. */
  task automatic permission_cases();
    logic [2:0] form;
    logic [4:0] source;
    logic [11:0] address;
    /* read-only identity and absent resources have different suppressed-write responses. */
    for (int resource_kind = 0; resource_kind < 3; resource_kind++) begin
      address = resource_kind == 0 ? 'hf11 : (resource_kind == 1 ? 'hf13 : 'h306);
      /* every instruction form independently exercises its encoded permission intent. */
      for (int form_index = 0; form_index < 6; form_index++) begin
        form = form_index < 3 ? 3'(form_index + 1) : 3'(form_index + 2);
        /* x0 suppresses SET/CLEAR writes, but a nonzero zero-valued source still requests one. */
        for (int source_kind = 0; source_kind < 2; source_kind++) begin
          begin_case(); constant(1, 0); source = 5'(source_kind);
          send(raw_packet(arch_pc, encode_csr(address, form, source_kind == 0 ? 0 : 2, source)), 0);
          drain();
        end
      end
    end
  endtask

  /* touch every scalar inventory entry and every HPM-window boundary through real CSR encodings. */
  task automatic inventory_cases();
    logic [11:0] address;
    /* a fixed independent table includes implemented constants and nearby absent groups. */
    for (int index = 0; index < 40; index++) begin
      /* this list is intentionally unrelated to production address-selection logic. */
      case (index)
        0: address = 'h300; 1: address = 'h301; 2: address = 'h304; 3: address = 'h305;
        4: address = 'h310; 5: address = 'h320; 6: address = 'h323; 7: address = 'h33f;
        8: address = 'h340; 9: address = 'h341; 10: address = 'h342; 11: address = 'h343;
        12: address = 'h344; 13: address = 'hb00; 14: address = 'hb80; 15: address = 'hb02;
        16: address = 'hb82; 17: address = 'hb03; 18: address = 'hb1f; 19: address = 'hb83;
        20: address = 'hb9f; 21: address = 'hf11; 22: address = 'hf12; 23: address = 'hf13;
        24: address = 'hf14; 25: address = 'hf15; 26: address = 'h000; 27: address = 'h306;
        28: address = 'h30a; 29: address = 'h31a; 30: address = 'h302; 31: address = 'h303;
        32: address = 'hc00; 33: address = 'hc01; 34: address = 'hc02; 35: address = 'h723;
        36: address = 'h73f; 37: address = 'h7b0; 38: address = 'h3a0; default: address = 'h180;
      endcase
      begin_case(); mip_levels_i = 'hffffffff;
      /* implemented writable registers are exercised with all reserved bits requested. */
      if (known_csr(address) && address[11:10] != 3) write_csr(address, 'hffffffff);
      read_csr(address);
    end
    /* legal cause writes followed by reserved values exercise WLRL preservation. */
    begin_case(); write_csr('h342, 'h80000007); write_csr('h342, 8); read_csr('h342);
    write_csr('h342, 11); write_csr('h342, 'h8000000c); read_csr('h342);
  endtask

  /* execute nested synchronous traps and a real encoded return with alignment-specific mepc. */
  task automatic trap_return_case();
    begin_case(); write_csr('h305, 'h403); write_csr('h300, 'h88);
    send(raw_packet(arch_pc, 'h00000073)); drain();
    read_csr('h300); read_csr('h341); read_csr('h342); read_csr('h343);
    write_csr('h305, 'h503); send(raw_packet(arch_pc, 'h00100073)); drain();
    read_csr('h300); read_csr('h341); read_csr('h342); read_csr('h343);
    write_csr('h341, 'h203); read_csr('h341); write_csr('h300, 'h80);
    send(raw_packet(arch_pc, 'h30200073)); drain();
    check(arch_pc == (C_ENABLED ? 'h202 : 'h200), "MRET return mask mismatch");
    send(raw_packet(arch_pc, enc_i('h13, 7, 0, 0, 9))); drain();
    check(status_ref == 'h1888, "MRET status restore missing");
  endtask

  /* autonomous counter values must be sampled on disposition rather than preparation or held W. */
  task automatic held_read(input logic [11:0] address);
    logic [31:0] pc;
    pc = arch_pc;
    send(raw_packet(pc, encode_csr(address, 2, 8, 0)));
    reach(4, pc); tick(); hold_i[4] = 1;
    /* multiple held clocks force a dynamic counter to change before the eventual read. */
    repeat (5) tick();
    /* pending levels are a changing observation source without any controller IRQ delivery. */
    if (address == 'h344) mip_levels_i = 'hffffffff;
    hold_i[4] = 0; drain();
  endtask

  /* validate full-width rollover, half-write priority, inhibit timing and trapping nonretirement. */
  task automatic counter_case();
    begin_case();
    write_csr('hb80, 'hffffffff); write_csr('hb00, 'hfffffffe);
    write_csr('hb82, 'hffffffff); write_csr('hb02, 'hfffffffe);
    send(raw_packet(arch_pc, encode_csr('h320, 5, 0, 0))); drain();
    send(raw_packet(arch_pc, 'h13)); drain(); send(raw_packet(arch_pc, 'h13)); drain();
    held_read('hb00); mip_levels_i = 8; held_read('h344);
    write_csr('hb00, 'hffffffff); read_csr('hb80); write_csr('hb80, 'h12345678);
    write_csr('hb02, 'hffffffff); read_csr('hb82); write_csr('hb82, 'h87654321);
    send(raw_packet(arch_pc, 'h00000073)); drain();
    send(raw_packet(arch_pc, encode_csr('h320, 5, 0, 5))); drain();
    read_csr('hb00); read_csr('hb80); read_csr('hb02); read_csr('hb82);
    check(cycle_rollovers > 0 && instret_rollovers > 0, "counter rollover coverage missing");
  endtask

  /* illegal widths and SYSTEM encodings cannot inherit poisoned intent or override fetch faults. */
  task automatic invalid_cases();
    packet_t p;
    /* exact MRET is the only newly enabled privileged instruction. */
    for (int variant = 0; variant < 9; variant++) begin
      begin_case();
      p = raw_packet(arch_pc, encode_csr('h340, 1, 1, 0));
      /* independently select each malformed or unsupported input class. */
      case (variant)
        0: p.length = 2;
        1: p.raw_valid = 3;
        2: p.expanded_valid = 1;
        3: p.raw = 'h00004073;
        4: p.raw = 'h10500073;
        5: p.raw = 'h10200073;
        6: p.raw = 'h7b200073;
        /* a prior fault prevents a CSR write even when its raw encoding is otherwise legal. */
        7: begin p.fault = 1; p.cause = 1; p.mtval = 'h102; end
        /* a prior fault prevents MRET from restoring status or selecting its return target. */
        8: begin p.raw = 'h30200073; p.fault = 1; p.cause = 1; p.mtval = 'h102; end
        default: check(0, "invalid malformed-input variant");
      endcase
      send(p); drain();
    end
  endtask
  /* a legal held CSR is cancellable, while an already known CSR fault survives a pending flush. */
  task automatic held_flush_case(input bit faulting);
    logic [31:0] pc;
    begin_case(); write_csr('h305, 'h400); write_csr('h340, 'h12345678);
    constant(1, 'h87654321); pc = arch_pc;
    send(raw_packet(pc, encode_csr(faulting ? 'h306 : 'h340, 1, 2, 1)), 'h87654321);
    hold_i[4] = 1; reach(4, pc);
    flush_pc_i = 'h600; flush_valid_i = 1; tick(); flush_valid_i = 0;
    /* a fault remains protected while a normal uncommitted CSR has been killed. */
    repeat (3) tick();
    hold_i = 0; drain();
    check(scratch_ref == 'h12345678, "flushed CSR changed scratch state");
    check(arch_pc == (faulting ? 'h400 : 'h600), "held CSR flush winner mismatch");
  endtask

  /* an older issued target operation survives while a younger CSR is flushed without effects. */
  task automatic memory_flush_case(input bit write_access, input bit already_accepted, input bit rejection);
    logic [31:0] pc;
    begin_case(); write_csr('h305, 'h400); write_csr('h340, 'h13579bdf);
    constant(1, 'h40000000); constant(2, 'h2468ace0); pc = arch_pc;
    planned_status = rejection ? 1 : 0;
    send(raw_packet(pc, write_access ? enc_s(2, 1, 2, 4) : enc_i(3, 0, 2, 1, 0)), 'h40000000, 'h2468ace0);
    reach(3, pc); tick();
    check(owner && d_req_valid_o, "memory/CSR scenario missed first offer");
    /* offered and accepted obligations exercise different physical boundary phases. */
    if (already_accepted) begin d_req_ready_i = 1; tick(); d_req_ready_i = 0; end
    send(raw_packet(pc + 4, encode_csr('h340, 1, 3, 2)), 'h2468ace0);
    flush_pc_i = 'h600; flush_valid_i = 1; tick(); flush_valid_i = 0;
    /* no already-presented request may be withdrawn while external flush is pending. */
    repeat (2) tick();
    d_req_ready_i = 1;
    /* service the outstanding offer once, then deliver its single registered response. */
    if (!accepted) tick();
    respond = 1; drain(); respond = 0; d_req_ready_i = 0;
    check(scratch_ref == 'h13579bdf, "younger flushed CSR escaped older memory ordering");
    check(arch_pc == (rejection ? 'h400 : 'h600), "memory/CSR flush priority mismatch");
  endtask

  /* a CSR source waits for the nearest older load and disappears when that load faults. */
  task automatic older_load_case(input bit rejection);
    logic [31:0] pc;
    begin_case(); write_csr('h340, 'h11111111); constant(1, 'h40000000); constant(2, 'hffffffff);
    pc = arch_pc; planned_status = rejection ? 1 : 0;
    send(raw_packet(pc, enc_i(3, 2, 2, 1, 0)), 'h40000000);
    send(raw_packet(pc + 4, encode_csr('h340, 1, 3, 2)), 0);
    /* the pending ticket read must not be bypassed by the old all-ones register value. */
    repeat (6) tick();
    d_req_ready_i = 1; tick(); respond = 1; drain(); respond = 0; d_req_ready_i = 0;
    check(scratch_ref == (rejection ? 'h11111111 : 0), "CSR source used stale older GPR value");
  endtask

  /* reset and protocol containment veto a prepared CSR on its otherwise eligible terminal edge. */
  task automatic reset_fatal_case(input bit make_fatal, input bit return_instruction);
    logic [31:0] pc;
    begin_case(); write_csr('h340, 'ha5a55a5a); write_csr('h341, 'h200); write_csr('h300, 'h80);
    send(raw_packet(arch_pc, encode_csr('h320, 5, 0, 0))); drain();
    constant(1, 'h12345678); pc = arch_pc;
    send(raw_packet(pc, return_instruction ? 32'h30200073 : encode_csr('h340, 1, 2, 1)), 'h12345678);
    reach(4, pc); tick(); hold_i[4] = 1;
    /* held preparation cannot perform a CSR update or MRET status change. */
    repeat (3) tick();
    hold_i[4] = 0;
    /* an ownerless response invokes same-edge fatal containment before the W commit. */
    if (make_fatal) begin
      inject_orphan = 1; tick(); inject_orphan = 0;
      /* cycle counting continues while architectural work is frozen by fatal containment. */
      repeat (3) tick();
      check(scratch_ref == 'ha5a55a5a, "fatal CSR changed architectural state");
    end
    hart_reset_i = 1; tick(); hart_reset_i = 0;
    /* fatal exposure survives hart reset and only coordinated cold reset may clear it. */
    if (make_fatal) begin cold_reset_i = 1; tick(); cold_reset_i = 0; end
    tick(); drain();
    check(status_ref == 'h1800 && scratch_ref == 0 && cycle_ref == 0 && instret_ref == 0,
          "reset failed to dominate CSR/return/counter updates");
  endtask
  /* initialize reference-owned state and establish a real isolated reset before inspection. */
  initial begin
    /* no test depends on simulator zero initialization of token arrays. */
    for (int id = 0; id < CAPACITY; id++) begin
      originals[id] = '0; expected[id] = '0; live[id] = 0; issued[id] = 0;
      completed[id] = 0; failed[id] = 0; prepared[id] = 0;
      memory_value[id] = 0; preparation_value[id] = 0;
    end
    /* unspecified hardware GPR contents remain outside the reference's defined domain. */
    for (int r = 0; r < 32; r++) begin regs_ref[r] = 0; defined_ref[r] = r == 0; end
    cold_reset_i = 1; #2; clk_i = 1; #2; clk_i = 0; cold_reset_i = 0;
    suppression_cases(); permission_cases(); inventory_cases(); trap_return_case(); counter_case(); invalid_cases();
    /* aliased source and destination retain the old register operand before returning the old CSR. */
    for (int form = 1; form <= 3; form++) begin
      begin_case(); write_csr('h340, 'h12345678); constant(1, 'h87654321);
      send(raw_packet(arch_pc, encode_csr('h340, 3'(form), 1, 1)), 'h87654321); drain();
      read_csr('h340);
    end
    held_flush_case(0); held_flush_case(1);
    /* offered and accepted reads/stores test both successful and precise rejected dispositions. */
    for (int variant = 0; variant < 8; variant++) memory_flush_case(variant[0], variant[1], variant[2]);
    older_load_case(0); older_load_case(1);
    reset_fatal_case(0, 0); reset_fatal_case(0, 1); reset_fatal_case(1, 0);
    check(csr_forms == 6'b111111 && read_suppressed > 0 && write_suppressed > 0 && preparations > 0,
          "CSR instruction/suppression coverage missing");
    check(returns > 0 && traps > 0 && launches == responses && launches > 0 &&
          held_dynamic_reads >= 2 && fatal_events > 0 && cycle_rollovers > 0 && instret_rollovers > 0,
          "CSR event/counter coverage missing");
    check(!$test$plusargs("mutate_write") && !$test$plusargs("mutate_read") && !$test$plusargs("mutate_stale") &&
          !$test$plusargs("mutate_return") && !$test$plusargs("mutate_kill") &&
          !$test$plusargs("mutate_storage") && !$test$plusargs("mutate_counter"), "CSR negative control did not activate");
    $display("PASS csr-control C=%0d cases=%0d cycles=%0d checks=%0d retired=%0d traps=%0d reads=%0d writes=%0d read_suppressed=%0d write_suppressed=%0d prepared=%0d returns=%0d offers=%0d replies=%0d flushes=%0d aborts=%0d resets=%0d fatal=%0d cycle_rollovers=%0d instret_rollovers=%0d dynamic_reads=%0d",
             C_ENABLED, cases, cycles, checks, retirements, traps, csr_reads, csr_writes, read_suppressed,
             write_suppressed, preparations, returns, launches, responses, flushes, aborts, resets,
             fatal_events, cycle_rollovers, instret_rollovers, held_dynamic_reads);
    $finish;
  end
endmodule

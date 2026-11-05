/* verify decoded memory operations, precise effects and surviving transaction ownership. */
module drg5_memory_tb #(parameter bit PROFILE = 0, parameter integer MAX_WAIT = 128, parameter integer SCENARIO = 0);
  import drg5_control_pkg::*;
  /* disconnected debug outputs retain named endpoints in legacy configurations. */
  logic unused_debug_halted, unused_debug_resumeack, unused_debug_reg_ready;
  logic [31:0] unused_debug_dpc, unused_debug_dcsr, unused_debug_reg_rdata;
  logic [2:0] unused_debug_reg_error;
  /* preserve the explicitly IRQ-disabled compatibility profile. */
  logic unused_entry_pending, unused_idle, unused_irq_valid;
  logic [31:0] unused_irq_pc, unused_irq_cause;
  /* all stimulus and ownership records are bounded independently of DUT counters. */
  localparam integer CAPACITY = 128;
  localparam bit C_ENABLED = 0;
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

  /* expected packets come from explicit stimulus intent rather than observed decode. */
  typedef struct packed {
    packet_t p;
    logic redirects;
  } expected_t;
  expected_t offered_expectation;
  expected_t expected [0:CAPACITY-1];
  packet_t original [0:CAPACITY-1];
  bit live [0:CAPACITY-1], issued [0:CAPACITY-1], completed [0:CAPACITY-1];
  bit failed [0:CAPACITY-1];
  logic [31:0] load_value [0:CAPACITY-1];
  logic [31:0] regs_ref [0:31];
  bit defined_ref [0:31];
  logic [31:0] arch_pc = 0, status_ref = 'h1800, vector_ref = 0, epc_ref = 0;
  logic [31:0] cause_ref = 0, tval_ref = 0;
  logic [63:0] next_uid = 0, next_order = 0;
  bit recovery_ref = 1, flush_pending = 0;
  logic [31:0] flush_target = 0;
  bit owner = 0, owner_accepted = 0, orphan = 0;
  logic [6:0] owner_uid = 0;
  logic [31:0] owner_addr = 0, owner_tag = 0, last_tag = 0;
  int unsigned cycles = 0, cases = 0, checks = 0, terminals = 0, traps = 0;
  int unsigned killed = 0, flushes = 0, flush_redirects = 0, aborts = 0, resets = 0;
  int unsigned launches = 0, responses = 0, dual_bypasses = 0;
  int unsigned dependency_stalls = 0, nearest_stalls = 0, memory_flush_cases = 0, invalid_cases = 0;
  int unsigned decoded_cases = 0, rejection_cases = 0, fatal_cases = 0, reset_cases = 0;
  int unsigned schedule_seed = 1, random_state = 1, accept_delay = 0, response_delay = 0;
  int unsigned offer_cycle = 0, response_due = 0;
  int unsigned maximum_accept_delay = 0, maximum_response_delay = 0;
  bit hold_accept = 0, hold_response = 0, target_pending = 0, recover_owner = 0;
  bit fatal_ref = 0, inject_response = 0, inject_wrong_tag = 0, corrupt_reply = 0;
  bit uncertain_effect = 0, zero_latency = 0;
  logic [31:0] target_uncertain = 0, reference_uncertain = 0;
  logic [1:0] force_status = 0, target_status = 0;
  logic [31:0] target_data = 0, target_tag = 0, owner_wdata = 0;
  logic [1:0] owner_size = 0;
  logic [3:0] owner_lanes = 0;
  bit owner_write = 0;
  fatal_record_t fatal_record_ref;
  byte unsigned target_ram [0:98303], reference_ram [0:98303];
  logic [31:0] target_timer [0:4], reference_timer [0:4];
  logic [63:0] target_reads = 0, reference_reads = 0, target_writes = 0, reference_writes = 0;
  logic [63:0] target_effects = 0, reference_effects = 0;
  logic [31:0] target_last_write = 0, reference_last_write = 0;
  bit target_external = 0, reference_external = 0;
  bit mutation_applied = 0;

  /* overlapping occupancy is essential to the issued-load and younger-jump cases. */
  drg5_control #(.IRQ_ENABLED(0), .FORWARDING(SCENARIO == 2), .DIAGNOSTIC(SCENARIO == 2), .TEST_REGIONS(SCENARIO != 2), .IRAM_WRITE(PROFILE),
      .TIMER_ENABLED(PROFILE), .D_MAX_WAIT_CYCLES(MAX_WAIT)) dut (
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

  /* stop at the first mismatch before another edge can corrupt the ownership ledger. */
  function automatic void check(input bit condition, input string message);
    checks++;
    /* each failure names the exact scenario and independently selected PC. */
    if (!condition) $fatal(1, "case=%0d profile=%0d scenario=%0d seed=%0d cycle=%0d pc=%08x: %s", cases, PROFILE, SCENARIO, schedule_seed, cycles, arch_pc, message);
  endfunction

  /* ordinary operations are synthetic packet stimulus rather than decoded ISA instructions. */
  function automatic packet_t packet(input logic [31:0] pc, input op_t op = OP_RESULT,
      input logic [4:0] rd = 0, input logic [31:0] value = 0);
    packet_t p;
    p = '0;
    p.pc = pc;
    p.raw = 'h13;
    p.raw_valid = 15;
    p.length = 4;
    p.op = op;
    p.rd = rd;
    p.rd_write = rd != 0;
    p.result = value;
    p.next_pc = pc + 4;
    p.mem_size = 2;
    return p;
  endfunction

  /* produce a true JAL encoding while poisoning annotations that D must replace. */
  function automatic packet_t jal(input logic [31:0] pc, input logic [31:0] offset,
      input logic [4:0] rd = 2);
    packet_t p;
    p = packet(pc, OP_CONTROL, 31, 'hdeadbeef);
    p.raw = ((offset & 'h100000) << 11) | ((offset & 'h7fe) << 20) |
            ((offset & 'h800) << 9) | (offset & 'hff000) | (32'(rd) << 7) | 'h6f;
    p.rs1_used = 1;
    p.rs2_used = 1;
    p.rs1 = 31;
    p.rs2 = 31;
    p.rs1_value = 'hbad0bad0;
    p.rs2_value = 'hbad1bad1;
    p.next_pc = 'hbad2bad2;
    return p;
  endfunction

  /* construct the expected JAL effect from its declared offset, not decoded DUT fields. */
  function automatic expected_t jal_expected(input packet_t p, input logic [31:0] offset,
      input logic [4:0] rd = 2);
    expected_t q;
    q = '0;
    q.p = p;
    q.p.rs1_used = 0;
    q.p.rs2_used = 0;
    q.p.rs1 = 0;
    q.p.rs2 = 0;
    q.p.rs1_value = 0;
    q.p.rs2_value = 0;
    q.p.rd = rd;
    q.p.rd_write = rd != 0;
    q.p.result = p.pc + 4;
    q.p.next_pc = p.pc + offset;
    q.redirects = 1;
    q.p.fault = q.p.next_pc[0] || (!C_ENABLED && q.p.next_pc[1]);
    q.p.cause = 0;
    q.p.mtval = q.p.fault ? q.p.next_pc : 0;
    return q;
  endfunction

  /* this fixture uses BEQ of the same independently supplied register on both ports. */
  function automatic packet_t equal_branch(input logic [31:0] pc, input logic [4:0] source);
    packet_t p;
    p = jal(pc, 8);
    p.raw = (32'(source) << 20) | (32'(source) << 15) | 'h463;
    return p;
  endfunction

  /* equal source operands make the declared BEQ target independently certain. */
  function automatic expected_t branch_expected(input packet_t p, input logic [4:0] source,
      input logic [31:0] value);
    expected_t q;
    q = jal_expected(p, 8, 0);
    q.p.rs1_used = 1;
    q.p.rs2_used = 1;
    q.p.rs1 = source;
    q.p.rs2 = source;
    q.p.rs1_value = value;
    q.p.rs2_value = value;
    q.p.result = 0;
    return q;
  endfunction

  /* CSR inputs remain explicit synthetic operations with real W storage semantics. */
  function automatic packet_t csr_write(input logic [31:0] pc, input logic [11:0] address,
      input logic [31:0] value, input logic read_old = 0, input logic [4:0] rd = 0);
    packet_t p;
    p = packet(pc, OP_CSR, rd);
    p.csr_addr = address;
    p.csr_op = CSR_WRITE;
    p.csr_read = read_old;
    p.csr_write = 1;
    p.csr_source = value;
    return p;
  endfunction

  /* select reference CSR values without reading exposed DUT storage. */
  function automatic logic [31:0] csr_value(input logic [11:0] address);
    /* the fixture deliberately limits its synthetic CSR operation subset. */
    case (address)
      'h300: return status_ref;
      'h305: return vector_ref;
      'h341: return epc_ref;
      /* unsupported fixture addresses are test construction errors. */
      default: begin
        check(0, "fixture used an unmodeled CSR");
        return 0;
      end
    endcase
  endfunction

  /* advance a replayable schedule generator without depending on DUT readiness or data. */
  function automatic logic [31:0] next_random();
    random_state = 32'd1664525 * random_state + 32'd1013904223;
    return random_state;
  endfunction

  /* map only the two real RAM regions; denied addresses must never alias an array index. */
  function automatic integer ram_index(input logic [31:0] address);
    check((address >= 'h20000000 && address <= 'h20007fff) ||
          (address >= 'h10000 && address <= 'h1ffff), "target RAM address was outside its region");
    return address >= 'h20000000 ? int'(address - 'h20000000) : int'(address - 'h10000) + 32768;
  endfunction

  /* both models start from the same immutable input image, never from a DUT result. */
  function automatic logic [7:0] image_byte(input logic [31:0] address);
    logic [20:0] unused_high_image_address;
    /* this recorded image pattern deliberately repeats above its low eleven address bits. */
    unused_high_image_address = address[31:11];
    return 8'(address ^ (address >> 3) ^ 'ha5);
  endfunction

  /* validate every requested byte independently of the LSU's widened-endpoint implementation. */
  function automatic bit region_permitted(input logic [31:0] address,
      input logic [1:0] size, input bit write);
    logic [31:0] at;
    bit okay;
    okay = size != 3;
    /* natural alignment and valid widths are required before any target sees a command. */
    if (size != 3 && (address % (1 << size)) != 0) okay = 0;
    /* a full footprint must remain in one independently permitted byte region. */
    for (int byte_number = 0; byte_number < (1 << size); byte_number++) begin
      at = address + 32'(byte_number);
      okay &= at >= address &&
          ((!write && at < 'h2000) ||
           ((PROFILE || !write) && at >= 'h10000 && at < 'h20000) ||
           (at >= 'h20000000 && at < 'h20008000) ||
           (size == 2 && at >= 'h40000000 && at < 'h40001000) ||
           (PROFILE && size == 2 && at >= 'h40001000 && at < 'h40002000) ||
           (SCENARIO != 2 && at >= 'h50001000 && at < 'h50003000));
    end
    return okay;
  endfunction

  /* construct real I/S-format memory encodings separately from their declared intent. */
  function automatic packet_t memory_instruction(input logic [31:0] pc, input bit write,
      input logic [2:0] funct3, input logic [11:0] immediate,
      input logic [4:0] base = 1, input logic [4:0] data_or_destination = 3);
    packet_t p;
    p = packet(pc, OP_MEMORY, 31, 'hdeadbeef);
    p.raw = (32'(base) << 15) | (32'(funct3) << 12);
    /* the source bytes and destination field occupy different bits in I and S formats. */
    if (write) p.raw |= (32'(immediate[11:5]) << 25) | (32'(data_or_destination) << 20) |
                        (32'(immediate[4:0]) << 7) | 'h23;
    /* load immediates are contiguous and have a true destination register field. */
    else p.raw |= (32'(immediate) << 20) | (32'(data_or_destination) << 7) | 3;
    p.rs1_used = 0;
    p.rs2_used = 0;
    p.rs1 = 31;
    p.rs2 = 31;
    p.rs1_value = 'hbad0bad0;
    p.rs2_value = 'hbad1bad1;
    p.mem_addr = 'hbad2bad2;
    p.mem_wdata = 'hbad3bad3;
    p.next_pc = 'hbad4bad4;
    return p;
  endfunction

  /* specify normalized memory intent using known operands and displacement, not observed decoding. */
  function automatic expected_t memory_expected(input packet_t original_packet, input bit write,
      input logic [1:0] size, input bit signed_load, input logic [31:0] base_value,
      input logic [31:0] displacement, input logic [31:0] store_value = 0,
      input logic [4:0] base = 1, input logic [4:0] data_or_destination = 3);
    expected_t q;
    q = '0;
    q.p = original_packet;
    q.p.op = write ? OP_STORE : OP_LOAD;
    q.p.rs1_used = 1;
    q.p.rs2_used = write;
    q.p.rs1 = base;
    q.p.rs2 = write ? data_or_destination : 0;
    q.p.rs1_value = base_value;
    q.p.rs2_value = write ? store_value : 0;
    q.p.rd = write ? 0 : data_or_destination;
    q.p.rd_write = !write && data_or_destination != 0;
    q.p.result = 0;
    q.p.next_pc = original_packet.pc + 4;
    q.p.mem_addr = base_value + displacement;
    q.p.mem_size = size;
    q.p.mem_signed = !write && signed_load;
    q.p.mem_wdata = 0;
    q.p.fault = !region_permitted(q.p.mem_addr, size, write);
    q.p.cause = q.p.fault ? ((q.p.mem_addr % (1 << size)) != 0 ? (write ? 6 : 4) :
                           (write ? 7 : 5)) : 0;
    q.p.mtval = q.p.fault ? q.p.mem_addr : 0;
    /* emit store lanes byte by byte; every unselected byte stays zero. */
    if (write && !q.p.fault) begin
      /* each low source byte goes to its actual addressed lane. */
      for (int byte_number = 0; byte_number < (1 << size); byte_number++) begin
        q.p.mem_wdata[8*(int'(q.p.mem_addr[1:0])+byte_number) +: 8] = store_value[8*byte_number +: 8];
      end
    end
    return q;
  endfunction

  /* derive the external lane mask from independently accepted memory intent. */
  function automatic logic [3:0] lane_mask(input logic [1:0] offset, input logic [1:0] size);
    logic [3:0] mask;
    mask = 0;
    /* every naturally aligned requested byte sets exactly one addressed word lane. */
    for (int byte_number = 0; byte_number < (1 << size); byte_number++) begin
      mask[int'(offset) + byte_number] = 1;
    end
    return mask;
  endfunction

  /* the actual bus target services each physical acceptance once and never deduplicates tags. */
  task automatic target_service(input logic [31:0] address, input logic [31:0] data,
      input logic [1:0] size, input logic [3:0] strobes, input bit write);
    logic [31:0] word, byte_address;
    bit perform;
    word = 0;
    target_status = force_status;
    /* predefined target-error registers reject without any effect. */
    if (address >= 'h50001000 && address < 'h50002000) target_status = 1;
    /* the uncertainty register supports only offset zero and complete word commands. */
    if (address >= 'h50002000 && address < 'h50003000 &&
        (address != 'h50002000 || size != 2)) target_status = 1;
    /* device permissions belong to the responder after the window-level guard. */
    if (address >= 'h40000000 && address < 'h40001000) begin
      /* exact register direction and offset are independently decoded by this physical target. */
      case (address - 'h40000000)
        0, 8, 12, 16: target_status = write ? 1 : force_status;
        4: target_status = write ? force_status : 1;
        20: target_status = force_status;
        default: target_status = 1;
      endcase
    end
    /* the enabled timer window is a plain bus-register fixture, not a timer implementation. */
    if (address >= 'h40001000 && address < 'h40002000 && address > 'h40001010) target_status = 1;
    perform = target_status == 0 || (target_status == 2 && uncertain_effect);
    /* only this explicit service point can mutate real target storage. */
    if (perform) begin
      /* the MMIO device has observable read and write actions even when software discards data. */
      if (address >= 'h40000000 && address < 'h40001000) begin
        /* access direction already passed the physical target's independent permissions. */
        case (address - 'h40000000)
          /* reading a ticket increments the physical read counter exactly once. */
          0: begin
            word = 32'(target_reads);
            target_reads++;
            target_effects++;
          end
          /* writing a ticket preserves its payload and increments the physical write count. */
          4: begin
            target_writes++;
            target_last_write = data;
            target_effects++;
          end
          8: word = 32'(target_reads);
          12: word = 32'(target_writes);
          16: word = target_last_write;
          /* external pending is a held bit with explicit write-one-to-clear behavior. */
          20: begin
            word = {31'b0, target_external};
            /* writing bit zero acknowledges this fixture's held external state. */
            if (write && data[0]) target_external = 0;
          end
          default: check(0, "physical device serviced a rejected offset");
        endcase
      end
      /* the optional timer aperture verifies forwarding of complete word transactions. */
      else if (address >= 'h40001000 && address <= 'h40001010) begin
        word = target_timer[(address - 'h40001000) / 4];
        /* this target register has an ordinary single accepted write effect. */
        if (write) target_timer[(address - 'h40001000) / 4] = data;
      end
      /* explicit uncertainty scripts choose whether a real accepted write changes this register. */
      else if (address >= 'h50002000 && address < 'h50003000) begin
        word = target_uncertain;
        /* this scripted effect is visible even though the CPU cannot know its outcome. */
        if (write) begin
          target_uncertain = data;
          target_effects++;
        end
      end
      /* RAM and ROM expose only requested byte lanes in a registered read result. */
      else if (address < 'h2000 || (address >= 'h10000 && address < 'h20000) ||
               (address >= 'h20000000 && address < 'h20008000)) begin
        /* process each physical word lane independently of the expected instruction. */
        for (int lane = 0; lane < 4; lane++) begin
          byte_address = (address & 32'hfffffffc) + 32'(lane);
          /* every asserted store strobe is a real external write, even if a mutant duplicates it. */
          if (write && strobes[lane]) target_ram[ram_index(byte_address)] = data[8*lane +: 8];
          /* unrequested load bytes never enter the response payload. */
          if (!write && lane >= int'(address[1:0]) && lane < int'(address[1:0]) + (1 << size)) begin
            word[8*lane +: 8] = byte_address < 'h2000 ? image_byte(byte_address) : target_ram[ram_index(byte_address)];
          end
        end
      end
    end
    target_data = target_status == 0 && !write ? word : 0;
  endtask

  /* reference memory effects follow validated immutable intents rather than actual bus data. */
  task automatic reference_service(input logic [6:0] id);
    packet_t p;
    logic [31:0] value, address;
    logic [1:0] status;
    bit permitted_effect;
    logic [362:0] unused_architectural_fields;
    p = expected[id].p;
    /* target effects do not consume instruction identity, result intent or unrelated CSR metadata. */
    unused_architectural_fields = {p.pc, p.raw, p.raw_valid, p.length, p.expanded_valid, p.expanded,
        p.rs1_used, p.rs2_used, p.rs1, p.rs2, p.rd, p.rs1_value, p.rd_write, p.result,
        p.next_pc, p.mem_wdata, p.csr_addr, p.csr_op, p.csr_read, p.csr_write, p.csr_source,
        p.fault, p.cause, p.mtval};
    address = p.mem_addr;
    value = 0;
    status = force_status;
    /* classify no-effect device rejects from the expected requested register and direction. */
    if ((address >= 'h50001000 && address < 'h50002000) ||
        (address >= 'h50002000 && address < 'h50003000 && (address != 'h50002000 || p.mem_size != 2)) ||
        (address >= 'h40000000 && address < 'h40001000 &&
         ((p.op == OP_STORE && !(address inside {'h40000004, 'h40000014})) ||
          (p.op == OP_LOAD && !(address inside {'h40000000, 'h40000008, 'h4000000c, 'h40000010, 'h40000014})))) ||
        (address >= 'h40001014 && address < 'h40002000)) status = 1;
    check(status == target_status, "physical response status differs from independent target intent");
    permitted_effect = status == 0 || (status == 2 && uncertain_effect);
    /* the reference and physical target never share mutable storage or returned data. */
    if (permitted_effect) begin
      /* expected device values and effect totals derive solely from preceding expected commands. */
      if (address >= 'h40000000 && address < 'h40001000) begin
        /* each expected device operation has its own explicit state transition. */
        case (address)
          /* expected ticket reads advance only the independent effect history. */
          'h40000000: begin
            value = 32'(reference_reads);
            reference_reads++;
            reference_effects++;
          end
          /* expected ticket writes use the immutable captured source value. */
          'h40000004: begin
            reference_writes++;
            reference_last_write = p.rs2_value;
            reference_effects++;
          end
          'h40000008: value = 32'(reference_reads);
          'h4000000c: value = 32'(reference_writes);
          'h40000010: value = reference_last_write;
          /* the reference held bit has no implicit timer or external stimulus. */
          'h40000014: begin
            value = {31'b0, reference_external};
            /* this fixture has no asynchronous source events while the LSU is qualified. */
            if (p.op == OP_STORE && p.rs2_value[0]) reference_external = 0;
          end
          default: check(0, "reference serviced an invalid device offset");
        endcase
      end
      /* timer-profile checks use a separately maintained plain-register target bank. */
      else if (address >= 'h40001000 && address <= 'h40001010) begin
        value = reference_timer[(address - 'h40001000) / 4];
        /* immutable store intent supplies the expected write value. */
        if (p.op == OP_STORE) reference_timer[(address - 'h40001000) / 4] = p.rs2_value;
      end
      /* a scripted uncertain target effect is counted independently and must never be replayed. */
      else if (address >= 'h50002000 && address < 'h50003000) begin
        value = reference_uncertain;
        /* the expected write value comes from the captured raw instruction's source operand. */
        if (p.op == OP_STORE) begin
          reference_uncertain = p.rs2_value;
          reference_effects++;
        end
      end
      /* assemble little-endian values from addressed bytes before extending them. */
      else if (address < 'h2000 || (address >= 'h10000 && address < 'h20000) ||
               (address >= 'h20000000 && address < 'h20008000)) begin
        /* expected stores write source bytes, independently of physical lane strobes. */
        for (int byte_number = 0; byte_number < (1 << p.mem_size); byte_number++) begin
          /* the target's mutable RAM is never read by this architectural prediction. */
          if (p.op == OP_STORE) reference_ram[ram_index(address + 32'(byte_number))] = p.rs2_value[8*byte_number +: 8];
          /* ROM bytes are the shared immutable input image only. */
          else value[8*byte_number +: 8] = address < 'h2000 ? image_byte(address + 32'(byte_number)) :
              reference_ram[ram_index(address + 32'(byte_number))];
        end
        /* signed extension fills only bits above the requested byte width. */
        if (p.mem_signed && p.mem_size < 2 && value[(8 << p.mem_size)-1]) begin
          /* each high result bit repeats the independently assembled sign bit. */
          for (int bit_number = (8 << p.mem_size); bit_number < 32; bit_number++) value[bit_number] = 1;
        end
      end
    end
    load_value[id] = value;
    failed[id] = status == 1;
    /* a deliberate extra physical effect must be exposed even for an x0 destination. */
    if ($test$plusargs("mutate_effect") && !mutation_applied && address == 'h40000000 && status == 0) begin
      target_reads++;
      mutation_applied = 1;
    end
    check(target_reads == reference_reads && target_writes == reference_writes &&
          target_last_write == reference_last_write && target_effects == reference_effects &&
          target_external == reference_external && target_uncertain == reference_uncertain, "physical device effect differs from independent intent");
  endtask

  /* a completed data response updates only the immutable original load's expectation. */
  function automatic expected_t disposition(input logic [6:0] id);
    expected_t q;
    q = expected[id];
    /* no synthetic early load result is accepted before its planned response. */
    if ((q.p.op == OP_LOAD || q.p.op == OP_STORE) && completed[id]) begin
      q.p.fault = failed[id];
      q.p.cause = failed[id] ? (q.p.op == OP_LOAD ? 5 : 7) : 0;
      q.p.mtval = failed[id] ? q.p.mem_addr : 0;
      /* access faults preserve the original packet's result field. */
      if (!failed[id] && q.p.op == OP_LOAD) q.p.result = load_value[id];
    end
    return q;
  endfunction

  /* compare and commit one independently eligible architectural terminal. */
  task automatic terminal(input trace_t actual, input packet_t p);
    logic [6:0] id;
    logic [31:0] old_csr, new_csr, write_value, continuation;
    logic do_write;
    packet_t expected_packet;
    id = 7'(actual.uid);
    check(actual.valid && actual.uid < 64'(CAPACITY) && live[id], "terminal lacked an independently accepted owner");
    check(actual.uid == next_terminal_uid() && actual.order == next_order, "terminal bypassed, duplicated or lost an owner");
    check(p.pc == arch_pc && original[id].pc == arch_pc, "architectural instruction sequence diverged");
    expected_packet = p;
    expected_packet.cause = p.fault ? p.cause : 0;
    expected_packet.mtval = p.fault ? p.mtval : 0;
    check(actual.packet == expected_packet && actual.trap == p.fault,
          "terminal packet or fault differed from independent intent");
    old_csr = p.op == OP_CSR ? csr_value(p.csr_addr) : 0;
    new_csr = p.csr_source;
    /* the tested WARL masks are defined independently of DUT readback. */
    if (p.csr_addr == 'h300) new_csr = 'h1800 | (new_csr & 'h88);
    /* mtvec remains word aligned in both active configurations. */
    if (p.csr_addr == 'h305) new_csr &= 32'hfffffffc;
    /* mepc reflects IALIGN, preserving bit one only when C is enabled. */
    if (p.csr_addr == 'h341) new_csr &= C_ENABLED ? 32'hfffffffe : 32'hfffffffc;
    write_value = p.op == OP_CSR ? (p.csr_read ? old_csr : 0) : p.result;
    do_write = !p.fault && p.rd_write && p.rd != 0 &&
               p.op inside {OP_RESULT, OP_LOAD, OP_CSR, OP_CONTROL};
    check(actual.rd_write == do_write && actual.rd == (do_write ? p.rd : 0) &&
          actual.value == (do_write ? write_value : 0), "unexpected architectural GPR effect");
    check(actual.csr_write == (!p.fault && p.op == OP_CSR && p.csr_write),
          "unexpected architectural CSR effect");
    check(actual.csr_read == (!p.fault && p.op == OP_CSR && p.csr_read),
          "unexpected architectural CSR read");
    check(actual.csr_old == (actual.csr_read ? old_csr : 0) &&
          actual.csr_new == (actual.csr_write ? new_csr : 0), "CSR old/new trace value mismatch");
    continuation = p.op == OP_MRET ? epc_ref : p.next_pc;
    check(actual.next_pc == (p.fault ? vector_ref : continuation), "wrong terminal continuation");
    /* trap disposition changes only trap state and consumes its original instruction. */
    if (p.fault) begin
      epc_ref = p.pc & (C_ENABLED ? 32'hfffffffe : 32'hfffffffc);
      cause_ref = p.cause;
      tval_ref = p.mtval;
      status_ref = 'h1800 | (status_ref[3] ? 'h80 : 0);
      arch_pc = vector_ref;
      traps++;
    end
    /* all normal register and CSR effects happen on this one checked W edge. */
    else begin
      arch_pc = continuation;
      /* x0 cannot become a stored link or CSR destination. */
      if (do_write) begin
        regs_ref[p.rd] = write_value;
        defined_ref[p.rd] = 1;
      end
      /* explicit synthetic CSR writes update the independent bank atomically. */
      if (actual.csr_write) begin
        /* the fixture covers all CSR fields it can write. */
        case (p.csr_addr)
          'h300: status_ref = new_csr;
          'h305: vector_ref = new_csr;
          'h341: epc_ref = new_csr;
          default: check(0, "unmodeled CSR update");
        endcase
      end
      /* MRET restores the independently stored previous interrupt enable. */
      if (p.op == OP_MRET) status_ref = 'h1880 | (status_ref[7] ? 8 : 0);
    end
    live[id] = 0;
    terminals++;
    next_order++;
  endtask

  /* the oldest surviving accepted UID is independent of pipeline stage placement. */
  function automatic logic [63:0] next_terminal_uid();
    /* holes represent independently justified squash or reset dispositions. */
    for (int id = 0; id < CAPACITY; id++) begin
      /* a live older owner cannot be skipped even if it has no architectural write. */
      if (live[id]) return 64'(id);
    end
    return '1;
  endfunction

  /* one edge predicts all control events before sampling registered DUT witnesses. */
  task automatic tick();
    logic [4:0] before_valid, wanted_kill, observed_kill;
    token_t before_token [0:4];
    logic [3:0] before_transfer;
    logic reset_active, accepted_input, flush_accept, active_flush, protect_m, protect_w;
    logic w_done, wanted_redirect, wanted_abort, observed_abort, flush_complete, launch_expected;
    logic accept_request, accept_response, owner_before, ready_expected;
    logic complete_reply, bad_reply, deadline, fatal_active, payload_bad, observed_valid;
    logic [31:0] response_mask, observed_wdata, sample_addr, sample_wdata;
    logic [1:0] sample_size;
    logic [3:0] sample_lanes;
    bit sample_write;
    fatal_record_t next_fatal_record;
    logic [31:0] redirect_target, active_target;
    expected_t w;
    packet_t x_packet;
    trace_t observed_trace;
    logic [6:0] w_id, m_id;
    int count, matching_writers;
    bit source_match;
    clk_i = 0;
    d_req_ready_i = !cold_reset_i && !hold_accept && owner && !owner_accepted && cycles >= offer_cycle + accept_delay;
    d_rsp_valid_i = inject_response || (target_pending && !hold_response && cycles >= response_due);
    d_rsp_tag_i = inject_response ? (inject_wrong_tag ? owner_tag + 1 : owner_tag) : target_tag;
    d_rsp_rdata_i = inject_response ? 0 : target_data;
    d_rsp_status_i = inject_response ? 0 : target_status;
    /* malformed payload injection changes only the physical response, never expected memory state. */
    if (corrupt_reply && d_rsp_valid_i) d_rsp_rdata_i ^= 32'h80000000;
    #2;
    reset_active = cold_reset_i || hart_reset_i;
    before_valid = stage_valid_o;
    before_token = stage_token_o;
    before_transfer = transfer_o;
    check(d_rsp_ready_o == !cold_reset_i, "response readiness differs from qualified reset contract");
    check(fatal_o == fatal_ref, "public fatal status was not registered and sticky");
    sample_addr = d_req_addr_o;
    sample_wdata = d_req_wdata_o;
    sample_size = d_req_size_o;
    sample_lanes = d_req_wstrb_o;
    sample_write = d_req_write_o;
    owner_before = owner;
    accept_request = d_req_valid_o && d_req_ready_i;
    accept_response = d_rsp_valid_i && !cold_reset_i;
    complete_reply = accept_response && owner && !recover_owner && d_rsp_tag_i == owner_tag &&
                     (owner_accepted || accept_request);
    response_mask = 0;
    /* build canonical response bytes independently of the target's own payload construction. */
    for (int lane = 0; lane < 4; lane++) begin
      /* requested lanes alone may carry successful load data. */
      if (owner_lanes[lane]) response_mask[8*lane +: 8] = '1;
    end
    payload_bad = (d_rsp_status_i != 0 || owner_write) ? d_rsp_rdata_i != 0 :
                  (d_rsp_rdata_i & ~response_mask) != 0;
    bad_reply = accept_response && (!complete_reply || d_rsp_status_i[1] || payload_bad);
    deadline = !cold_reset_i && owner && !recover_owner && !complete_reply &&
               cycles + 1 - offer_cycle >= 32'(MAX_WAIT);
    fatal_active = fatal_ref || bad_reply || deadline;
    next_fatal_record = fatal_record_ref;
    /* first containment captures immutable exposure, including same-edge physical events. */
    if (!cold_reset_i && !fatal_ref && (bad_reply || deadline)) begin
      next_fatal_record = '0;
      next_fatal_record.valid = 1;
      next_fatal_record.reason = bad_reply ?
          (complete_reply && d_rsp_status_i == 2 && !payload_bad ? 2 : 1) : 3;
      /* an orphan response cannot invent an original instruction or descriptor. */
      if (owner) begin
        next_fatal_record.owned = 1;
        next_fatal_record.accepted = owner_accepted || accept_request || recover_owner;
        next_fatal_record.responded = complete_reply || recover_owner;
        next_fatal_record.uid = 64'(owner_uid);
        next_fatal_record.pc = original[owner_uid].pc;
        next_fatal_record.addr = owner_addr;
        next_fatal_record.wdata = owner_wdata;
        next_fatal_record.tag = owner_tag;
        next_fatal_record.size = owner_size;
        next_fatal_record.wstrb = owner_write ? owner_lanes : 0;
        next_fatal_record.write = owner_write;
      end
    end
    ready_expected = !flush_pending && !reset_active && !recovery_ref && !fatal_active;
    check(flush_ready_o == ready_expected, "flush readiness disagreed with independent ownership");
    flush_accept = flush_valid_i && ready_expected;
    active_flush = flush_pending || flush_accept;
    active_target = flush_pending ? flush_target : flush_pc_i;
    w_id = 7'(before_token[4].uid);
    m_id = 7'(before_token[3].uid);
    w = disposition(w_id);
    protect_m = before_valid[3] && issued[m_id];
    protect_w = before_valid[4] && (issued[w_id] || w.p.fault);
    w_done = before_valid[4] && !hold_i[4] && !reset_active && !fatal_active && (!active_flush || protect_w);
    wanted_kill = 0;
    /* reset revokes instruction ownership while a physical data owner remains separately live. */
    if (reset_active) wanted_kill = before_valid;
    /* precise W control wins over any requested external flush. */
    else if (w_done && (w.p.fault || w.redirects)) wanted_kill = before_valid & 5'b01111;
    /* a flush preserves the issued token until its W disposition, even after bus response. */
    else if (active_flush && !fatal_active) begin
      wanted_kill = before_valid;
      wanted_kill[3] = before_valid[3] && !protect_m;
      wanted_kill[4] = before_valid[4] && !protect_w;
    end
    flush_complete = !reset_active && !fatal_active && active_flush && !protect_m &&
                     (!protect_w || w_done) && !owner_before;
    wanted_redirect = flush_complete || (w_done && (w.p.fault || w.redirects));
    redirect_target = active_target;
    /* a trap or normal return/control terminal supplies its own independently known target. */
    if (w_done && (w.p.fault || w.redirects)) redirect_target = w.p.fault ? vector_ref :
        (w.p.op == OP_MRET ? epc_ref : w.p.next_pc);
    wanted_abort = reset_active ? flush_pending : (w_done && w.p.fault && active_flush);
    launch_expected = before_valid[3] && !hold_i[3] && !wanted_kill[3] && !active_flush &&
        !reset_active && !fatal_active && !expected[m_id].p.fault && !issued[m_id] &&
        expected[m_id].p.op inside {OP_LOAD, OP_STORE} && !owner_before && !recovery_ref &&
        (!before_valid[4] || (w_done && !w.p.fault && !w.redirects));
    check(mem_launch_o == launch_expected, "unexpected or missing first-valid memory grant");
    observed_valid = d_req_valid_o;
    /* an ownerless valid signal must be detected even while target ready is low. */
    if ($test$plusargs("mutate_orphan") && !mutation_applied && !reset_active && !recovery_ref && !owner) begin
      observed_valid = 1;
      mutation_applied = 1;
    end
    check(mem_busy_o == owner && observed_valid == (owner && !owner_accepted && !recover_owner),
          "physical request owner disappeared or appeared without permission");
    /* first-valid request ownership makes the complete external descriptor immutable. */
    observed_wdata = d_req_wdata_o;
    /* corrupt one observed store lane without altering the independently expected intent. */
    if ($test$plusargs("mutate_lane") && !mutation_applied && owner && owner_write) begin
      observed_wdata ^= 1;
      mutation_applied = 1;
    end
    /* physical exposure remains immutable after reset and containment as well as normal stalls. */
    if (owner) check(d_req_tag_o == owner_tag && d_req_addr_o == owner_addr &&
        observed_wdata == owner_wdata && d_req_write_o == owner_write && d_req_size_o == owner_size &&
        d_req_wstrb_o == (owner_write ? owner_lanes : 0), "owned request descriptor changed");
    accepted_input = in_valid_i && in_ready_o;
    accept_request = d_req_valid_o && d_req_ready_i;
    accept_response = d_rsp_valid_i && d_rsp_ready_o;
    /* decoded memory sources must wait for every nearer unready writer. */
    matching_writers = 0;
    /* only a successfully decoded memory instruction participates in this source dependency check. */
    if (before_valid[1] && original[7'(before_token[1].uid)].op == OP_MEMORY &&
        expected[7'(before_token[1].uid)].p.op inside {OP_LOAD, OP_STORE}) begin
      /* use immutable expected source indices instead of the DUT's normalized fields. */
      for (int stage = 2; stage < 5; stage++) begin
        source_match = before_valid[stage] && expected[7'(before_token[stage].uid)].p.rd_write &&
            expected[7'(before_token[stage].uid)].p.rd != 0 &&
            ((expected[7'(before_token[1].uid)].p.rs1_used &&
              expected[7'(before_token[1].uid)].p.rs1 == expected[7'(before_token[stage].uid)].p.rd) ||
             (expected[7'(before_token[1].uid)].p.rs2_used &&
              expected[7'(before_token[1].uid)].p.rs2 == expected[7'(before_token[stage].uid)].p.rd));
        /* only a successful W value is eligible for same-edge source capture. */
        if (source_match && !wanted_kill[1]) begin
          matching_writers++;
          /* X/M and held/faulting W producers must interlock the actual D transfer. */
          if (stage != 4 || !w_done || w.p.fault) begin
            check(!before_transfer[1], "memory source bypassed an unresolved older writer");
            dependency_stalls++;
          end
          /* exact D capture checks below independently verify the forwarded value. */
          else if (before_transfer[1]) dual_bypasses++;
        end
      end
      /* a nearer matching destination must hide a farther producer's available value. */
      if (matching_writers > 1) nearest_stalls++;
    end
    clk_i = 1;
    #2;
    cycles++;
    observed_kill = kill_valid_o;
    /* a hidden extra killed instruction must fail the exact independently justified mask. */
    if ($test$plusargs("mutate_kill") && !mutation_applied && !reset_active && before_valid[4] && hold_i[4] &&
        !active_flush) begin
      observed_kill[4] = !observed_kill[4];
      mutation_applied = 1;
    end
    check(observed_kill == wanted_kill, "unjustified or missing memory squash");
    check(trace_o.valid == w_done, "unexpected or missing event terminal");
    check(redirect_valid_o == wanted_redirect && (!wanted_redirect || redirect_pc_o == redirect_target),
          "incorrect event redirect arbitration");
    observed_abort = flush_aborted_o;
    /* a missing flush-abort pulse cannot hide behind a correct trap redirect. */
    if ($test$plusargs("mutate_abort") && !mutation_applied && wanted_abort) begin
      mutation_applied = 1;
      observed_abort = !observed_abort;
    end
    check(observed_abort == wanted_abort, "missing or spurious flush abort");
    /* consume only independently justified instruction kills. */
    for (int stage = 0; stage < 5; stage++) begin
      /* every reported kill must name the exact pre-edge stage owner. */
      if (wanted_kill[stage]) begin
        check(kill_uid_o[stage] == before_token[stage].uid &&
              live[7'(kill_uid_o[stage])], "kill changed or repeated an accepted identity");
        live[7'(kill_uid_o[stage])] = 0;
        killed++;
      end
    end
    /* every physical acceptance services the actual target before reference comparison. */
    if (accept_request) begin
      check(owner && !owner_accepted && !recover_owner, "duplicate or ownerless target acceptance");
      target_service(sample_addr, sample_wdata, sample_size, sample_lanes, sample_write);
      reference_service(owner_uid);
      owner_accepted = 1;
      target_pending = 1;
      $display("ACCEPT profile=%0d scenario=%0d seed=%0d cycle=%0d uid=%0d tag=%0d address=%08x data=%08x lanes=%x status=%0d read_count=%0d write_count=%0d",
               PROFILE, SCENARIO, schedule_seed, cycles, owner_uid, owner_tag, sample_addr,
               sample_wdata, sample_lanes, target_status, target_reads, target_writes);
      target_tag = owner_tag;
      response_due = cycles + response_delay - 1;
    end
    /* preserve actual response edges separately from selected delay parameters and script overrides. */
    if (accept_response) $display("RESPONSE profile=%0d scenario=%0d seed=%0d cycle=%0d tag=%0d status=%0d data=%08x matching=%0d contained=%0d",
        PROFILE, SCENARIO, schedule_seed, cycles, d_rsp_tag_i, d_rsp_status_i, d_rsp_rdata_i,
        complete_reply, fatal_active);
    /* only the physical target's own response handshake consumes its pending payload. */
    if (accept_response && !inject_response) begin
      check(target_pending, "target emitted an unowned response");
      target_pending = 0;
    end
    /* matching replies resolve physical ownership even after architectural containment/reset. */
    if (complete_reply) begin
      /* the explicit minimum-deadline mode is a separate combinational target compatibility case. */
      if (zero_latency) target_pending = 0;
      /* normal architectural delivery additionally requires the surviving instruction owner. */
      if (!reset_active && !orphan && !fatal_active) completed[owner_uid] = 1;
      /* late or uncertain completions remain contained until a qualified cold fence. */
      if (fatal_active) begin
        recover_owner = 1;
        owner_accepted = 1;
      end
      /* a successful or proven-rejected ordinary response releases the physical request. */
      else begin
        owner = 0;
        owner_accepted = 0;
      end
      orphan = 0;
      responses++;
    end
    fatal_ref = fatal_active;
    fatal_record_ref = next_fatal_record;
    /* apply reset to architectural state while preserving hart-reset identity counters. */
    if (reset_active) begin
      check(!cold_reset_i || isolated_i, "fixture attempted an unqualified cold fence");
      recovery_ref = 1;
      flush_pending = 0;
      status_ref = 'h1800;
      vector_ref = 0;
      epc_ref = 0;
      cause_ref = 0;
      tval_ref = 0;
      arch_pc = 0;
      /* only the architecturally hardwired zero register has a defined reset value. */
      for (int reg_index = 0; reg_index < 32; reg_index++) begin
        defined_ref[reg_index] = reg_index == 0;
        regs_ref[reg_index] = 0;
      end
      /* cold reset restarts observation identities; hart reset never does. */
      if (cold_reset_i) begin
        next_uid = 0;
        next_order = 0;
        last_tag = 0;
        owner = 0;
        owner_accepted = 0;
        recover_owner = 0;
        target_pending = 0;
        orphan = 0;
        fatal_ref = 0;
        fatal_record_ref = '0;
        target_reads = 0;
        reference_reads = 0;
        target_writes = 0;
        reference_writes = 0;
        target_last_write = 0;
        reference_last_write = 0;
        target_external = 0;
        reference_external = 0;
      end
      /* a surviving request remains owed even after its instruction was reset-aborted. */
      if (hart_reset_i && owner) orphan = 1;
      resets++;
    end
    /* normal clocking resolves pending control events in their independent order. */
    else begin
      /* recovery lasts through at least the edge observing no physical obligation. */
      if (recovery_ref && !owner_before && !fatal_active) recovery_ref = 0;
      /* accept one external flush descriptor before any later fault can supersede it. */
      if (flush_accept) begin
        flush_pending = 1;
        flush_target = flush_pc_i;
        flushes++;
      end
      /* terminal comparison commits state before an independent external flush changes PC. */
      if (w_done) begin
        observed_trace = trace_o;
        /* a corrupt load writeback must fail against independently serviced reference memory. */
        if ($test$plusargs("mutate_load") && !mutation_applied && w.p.op == OP_LOAD && trace_o.rd_write) begin
          observed_trace.value ^= 1;
          mutation_applied = 1;
        end
        terminal(observed_trace, w.p);
      end
      /* a surviving external flush can complete on the successful protected load's W edge. */
      if (flush_complete && !(w_done && (w.p.fault || w.redirects))) begin
        arch_pc = active_target;
        flush_redirects++;
      end
      /* neither a completed nor an aborted flush may reappear on a later edge. */
      if (flush_complete || wanted_abort) flush_pending = 0;
      /* allocate exact independent identities only for accepted external packets. */
      if (accepted_input) begin
        check(next_uid < 64'(CAPACITY), "input owner ledger exhausted");
        original[7'(next_uid)] = in_packet_i;
        expected[7'(next_uid)] = offered_expectation;
        live[7'(next_uid)] = 1;
        issued[7'(next_uid)] = 0;
        completed[7'(next_uid)] = 0;
        failed[7'(next_uid)] = 0;
        load_value[7'(next_uid)] = 0;
        next_uid++;
      end
    end
    aborts += int'(wanted_abort);
    /* reserve the first-valid physical owner only for the independently permitted memory intent. */
    if (launch_expected) begin
      check(!owner, "new memory grant overlapped an existing owner");
      owner = 1;
      owner_accepted = 0;
      owner_uid = m_id;
      owner_addr = expected[m_id].p.mem_addr;
      owner_wdata = expected[m_id].p.mem_wdata;
      owner_size = expected[m_id].p.mem_size;
      owner_write = expected[m_id].p.op == OP_STORE;
      owner_lanes = lane_mask(owner_addr[1:0], owner_size);
      offer_cycle = cycles;
      accept_delay = next_random() % 4;
      response_delay = 1 + next_random() % 5;
      maximum_accept_delay = accept_delay > maximum_accept_delay ? accept_delay : maximum_accept_delay;
      maximum_response_delay = response_delay > maximum_response_delay ? response_delay : maximum_response_delay;
      last_tag++;
      owner_tag = last_tag;
      issued[m_id] = 1;
      launches++;
      $display("SCHEDULE profile=%0d scenario=%0d seed=%0d cycle=%0d uid=%0d pc=%08x tag=%0d address=%08x write=%0d size=%0d accept_extra=%0d response_edges=%0d",
               PROFILE, SCENARIO, schedule_seed, cycles, owner_uid, original[owner_uid].pc,
               owner_tag, owner_addr, owner_write, owner_size, accept_delay, response_delay);
    end
    check(mem_busy_o == owner && d_req_valid_o == (owner && !owner_accepted && !recover_owner),
          "first-valid external request did not match independent grant");
    next_fatal_record = fatal_record_o;
    /* an incorrect deadline snapshot must fail independently of visible retirement suppression. */
    if ($test$plusargs("mutate_deadline") && !mutation_applied && fatal_record_ref.valid && fatal_record_ref.reason == 3) begin
      next_fatal_record.reason ^= 1;
      mutation_applied = 1;
    end
    check(next_fatal_record == fatal_record_ref, "fatal exposure snapshot mismatch");
    check(fatal_o == fatal_ref, "public fatal status was not registered and sticky");
    /* every live input has one physical pipeline slot, even when it has no visible effect. */
    for (int id = 0; id < CAPACITY; id++) begin
      count = 0;
      /* multiplicity prevents one duplicate from concealing a different lost instruction. */
      for (int stage = 0; stage < 5; stage++) begin
        count += int'(stage_valid_o[stage] && stage_token_o[stage].uid == 64'(id));
      end
      check(count == int'(live[id]), "accepted event instruction lost or duplicated");
    end
    /* all movement witnesses must preserve the unique accepted source owner. */
    for (int stage = 0; stage < 4; stage++) begin
      /* a transfer installs its old source in exactly the next stage. */
      if (before_transfer[stage]) check(before_valid[stage] && stage_valid_o[stage+1] &&
          stage_token_o[stage+1].uid == before_token[stage].uid, "event transfer changed identity");
    end
    /* D captures real RF operands before X; supplied poison cannot become source authority. */
    if (before_transfer[1] && stage_valid_o[2] &&
        original[7'(stage_token_o[2].uid)].op inside {OP_CONTROL, OP_MEMORY}) begin
      x_packet = expected[7'(stage_token_o[2].uid)].p;
      x_packet.result = 0;
      x_packet.next_pc = 0;
      /* memory effective address and lanes are formed only after D captures actual RF operands. */
      if (original[7'(stage_token_o[2].uid)].op == OP_MEMORY && x_packet.op inside {OP_LOAD, OP_STORE}) begin
        x_packet.mem_addr = 0;
        x_packet.mem_wdata = 0;
        x_packet.fault = 0;
        x_packet.cause = 0;
        x_packet.mtval = 0;
      end
      /* a taken-target alignment failure belongs to X, not D capture. */
      if (x_packet.fault && x_packet.cause == 0) begin
        x_packet.fault = 0;
        x_packet.mtval = 0;
      end
      check(stage_token_o[2].p == x_packet, "control D capture ignored independent operand intent");
    end
    /* device effect totals remain independent of observed GPR or trace values. */
    check(target_reads == reference_reads && target_writes == reference_writes &&
          target_last_write == reference_last_write && target_effects == reference_effects,
          "physical device effect differs from independent intent");
    /* a protected held W fault must remain bit-for-bit stable until it can trap. */
    if (before_valid[4] && hold_i[4] && !wanted_kill[4]) check(stage_valid_o[4] &&
        stage_token_o[4] == before_token[4], "held protected W token changed");
    check(mstatus_o == status_ref && mtvec_o == vector_ref && mscratch_o == 0 &&
          mepc_o == epc_ref && mcause_o == cause_ref && mtval_o == tval_ref,
          "event CSR state differs from independent committed bank");
    /* inspect the full GPR bank to detect speculative or killed link writes. */
    for (int reg_index = 0; reg_index < 32; reg_index++) begin
      inspect_reg_i = 5'(reg_index);
      #1;
      check(inspect_defined_o == defined_ref[reg_index], "early or killed GPR definedness change");
      /* reset leaves nonzero stored bits unspecified until a real commit defines them. */
      if (defined_ref[reg_index]) check(inspect_value_o == regs_ref[reg_index], "event GPR storage mismatch");
    end
    clk_i = 0;
  endtask

  /* start a scenario only after every old instruction and physical obligation is resolved. */
  task automatic begin_case();
    check(!owner && stage_valid_o == 0 && !flush_pending, "new case abandoned an owner or flush");
    in_valid_i = 0;
    flush_valid_i = 0;
    hold_i = 0;
    hold_accept = 0;
    hold_response = 0;
    inject_response = 0;
    inject_wrong_tag = 0;
    corrupt_reply = 0;
    force_status = 0;
    uncertain_effect = 0;
    zero_latency = 0;
    cold_reset_i = 1;
    tick();
    cold_reset_i = 0;
    tick();
    arch_pc = 'h100;
    cases++;
  endtask

  /* hold one packet and its independently constructed intent until input acceptance. */
  task automatic send(input packet_t p, input expected_t q);
    logic [63:0] initial_uid;
    integer clocks;
    initial_uid = next_uid;
    in_packet_i = p;
    offered_expectation = q;
    in_valid_i = 1;
    clocks = 0;
    /* bounded input readiness is required while this fixture has not held an older stage. */
    while (next_uid == initial_uid && clocks < 50) begin
      tick();
      clocks++;
    end
    in_valid_i = 0;
    check(next_uid == initial_uid + 1, "event packet input acceptance did not progress");
  endtask

  /* ordinary precomputed operations retain their original complete packet as expectation. */
  task automatic send_plain(input packet_t p);
    expected_t q;
    q.p = p;
    q.redirects = p.op == OP_MRET;
    send(p, q);
  endtask

  /* wait for a named stage only to place an event, never to determine expected effects. */
  task automatic reach(input logic [2:0] stage, input logic [31:0] pc);
    integer clocks;
    clocks = 0;
    /* a missing or duplicated instruction must also violate this independent finite bound. */
    while (!(stage_valid_o[stage] && stage_token_o[stage].p.pc == pc) && clocks < 50) begin
      tick();
      clocks++;
    end
    check(clocks < 50, "target instruction did not reach requested event boundary");
  endtask

  /* consume every normal terminal and completed external flush without using reset as cleanup. */
  task automatic drain();
    integer clocks;
    clocks = 0;
    /* response permission and holds are explicitly controlled by each scenario. */
    while ((stage_valid_o != 0 || owner || flush_pending) && clocks < MAX_WAIT + 80) begin
      tick();
      clocks++;
    end
    check(clocks < MAX_WAIT + 80 && !owner && !flush_pending && stage_valid_o == 0, "event drainage bound expired");
    /* two quiet edges reject repeated redirect, terminal, abort or request activity. */
    repeat (2) tick();
    compare_storage();
  endtask

  /* accept one explicit flush request and retain its target through all protected work. */
  task automatic request_flush(input logic [31:0] target = 'h300);
    int unsigned before_count;
    before_count = flushes;
    flush_pc_i = target;
    flush_valid_i = 1;
    tick();
    flush_valid_i = 0;
    check(flushes == before_count + 1, "directed external flush was not accepted");
  endtask

  /* compare actual storage with a separately updated reference, including unrequested neighbors. */
  task automatic compare_storage();
    /* a wrong strobe must not hide outside the bytes returned by a later load. */
    for (int index = 0; index < 98304; index++) begin
      check(target_ram[index] == reference_ram[index], "RAM contents differ from independent memory effects");
    end
    /* optional aperture registers verify profile forwarding without claiming timer behavior. */
    for (int index = 0; index < 5; index++) begin
      check(target_timer[index] == reference_timer[index], "timer aperture storage mismatch");
    end
    check(target_uncertain == reference_uncertain, "uncertain scripted effect changed or replayed");
  endtask

  /* one directed operation initializes every real source before using the raw instruction. */
  task automatic operation_case(input logic [31:0] base_value, displacement, store_value,
      input bit write, input logic [1:0] size, input bit signed_load = 0,
      input logic [4:0] destination = 3, input bit same_source = 0, input bit zero_base = 0);
    packet_t p;
    expected_t q;
    logic [31:0] pc;
    logic [2:0] funct3;
    logic [4:0] base_register, data_register;
    int unsigned old_launches;
    begin_case();
    pc = 'h100;
    base_register = zero_base ? 0 : 1;
    data_register = same_source ? base_register : 2;
    /* x0 is already defined and must never be initialized by a diagnostic write. */
    if (!zero_base) begin
      send_plain(packet(pc, OP_RESULT, base_register, base_value));
      pc += 4;
    end
    /* a store with equal source indices consumes the actual base value as its data. */
    if (write && !same_source) begin
      send_plain(packet(pc, OP_RESULT, data_register, store_value));
      pc += 4;
    end
    funct3 = {1'b0, size} | (!write && !signed_load && size != 2 ? 3'b100 : 0);
    p = memory_instruction(pc, write, funct3, 12'(displacement), base_register,
                           write ? data_register : destination);
    q = memory_expected(p, write, size, signed_load || size == 2, base_value, displacement,
                        same_source ? base_value : store_value, base_register,
                        write ? data_register : destination);
    old_launches = launches;
    send(p, q);
    drain();
    check(launches == old_launches + int'(!q.p.fault), "local denial or permitted memory launch count mismatch");
    decoded_cases++;
    rejection_cases += int'(q.p.fault || cause_ref inside {5, 7});
  endtask

  /* malformed encodings and metadata cannot inherit any supplied memory intent. */
  task automatic invalid_memory_case(input integer variant);
    packet_t p;
    expected_t q;
    int unsigned before_launches;
    begin_case();
    p = memory_instruction('h100, variant == 1, 2, 0);
    /* isolate invalid funct3, raw metadata, expansion misuse and earlier fetch fault precedence. */
    case (variant)
      0: p = memory_instruction('h100, 0, 3, 0);
      1: p = memory_instruction('h100, 1, 3, 0);
      2: p.raw_valid = 7;
      3: p.length = 2;
      4: p.expanded_valid = 1;
      /* a supplied fault wins even when the encoded memory operation itself is valid. */
      default: begin
        p.fault = 1;
        p.cause = 1;
        p.mtval = 'h102;
      end
    endcase
    q = '0;
    q.p = p;
    q.p.rs1_used = 0;
    q.p.rs2_used = 0;
    q.p.rs1 = 0;
    q.p.rs2 = 0;
    q.p.rs1_value = 0;
    q.p.rs2_value = 0;
    q.p.rd = 0;
    q.p.rd_write = 0;
    q.p.result = 0;
    q.p.next_pc = 0;
    q.p.fault = 1;
    q.p.cause = p.fault ? p.cause : 2;
    q.p.mtval = p.fault ? p.mtval : 0;
    before_launches = launches;
    send(p, q);
    drain();
    check(launches == before_launches && cause_ref == (variant == 5 ? 1 : 2),
          "invalid memory encoding or earlier fault created an effect");
    invalid_cases++;
  endtask

  /* prepare a decoded memory instruction and stop exactly at its first registered offer. */
  task automatic prepare_owner(input bit write = 0, input logic [31:0] address = 'h20000000,
      input logic [1:0] size = 2, input logic [4:0] destination = 3);
    packet_t p;
    logic [31:0] pc;
    integer clocks;
    hold_accept = 1;
    hold_response = 1;
    pc = 'h100;
    send_plain(packet(pc, OP_RESULT, 1, address));
    pc += 4;
    /* this store source is deliberately rich in high and low byte patterns. */
    if (write) begin
      send_plain(packet(pc, OP_RESULT, 2, 'h89abcdef));
      pc += 4;
    end
    p = memory_instruction(pc, write, {1'b0, size}, 0, 1, write ? 5'd2 : destination);
    send(p, memory_expected(p, write, size, 1, address, 0, 'h89abcdef, 1,
                            write ? 5'd2 : destination));
    clocks = 0;
    /* the checked first-valid grant is the only authority for creating this owner. */
    while (!owner && clocks < 30) begin
      tick();
      clocks++;
    end
    check(owner && !owner_accepted && clocks < 30, "decoded memory did not produce its initial offer");
  endtask

  /* force a target acceptance without allowing its registered response to complete yet. */
  task automatic reach_accepted();
    integer clocks;
    hold_accept = 0;
    clocks = 0;
    /* ordinary schedules must accept well before the finite deadline. */
    while (!owner_accepted && clocks < 10) begin
      tick();
      clocks++;
    end
    check(owner_accepted && target_pending, "target acceptance did not create a response obligation");
  endtask

  /* wait for the independent model's fatal edge and require the same sticky public state. */
  task automatic wait_fatal();
    integer clocks;
    clocks = 0;
    /* no protocol failure can be mistaken for an unbounded architectural wait. */
    while (!fatal_ref && clocks < MAX_WAIT + 20) begin
      tick();
      clocks++;
    end
    check(fatal_ref && fatal_o && clocks < MAX_WAIT + 20, "expected memory containment did not occur");
  endtask

  /* drain a surviving physical obligation, then reset-abort frozen instructions and positively fence recovery. */
  task automatic finish_fatal();
    integer clocks;
    fatal_record_t snapshot;
    snapshot = fatal_record_ref;
    inject_response = 0;
    inject_wrong_tag = 0;
    corrupt_reply = 0;
    hold_accept = 0;
    hold_response = 0;
    clocks = 0;
    /* late ordinary acceptance and response must never re-enable a contained instruction. */
    while (owner && !recover_owner && clocks < 30) begin
      tick();
      clocks++;
    end
    check(!owner || recover_owner, "contained physical owner did not drain to recovery");
    check(!target_pending, "contained target still owed an untracked response");
    hart_reset_i = 1;
    tick();
    hart_reset_i = 0;
    tick();
    check(fatal_record_ref == snapshot && fatal_record_o == snapshot,
          "hart reset changed the first containment snapshot");
    compare_storage();
    cold_reset_i = 1;
    tick();
    cold_reset_i = 0;
    tick();
    check(!fatal_o && fatal_record_o == '0 && !owner && stage_valid_o == 0,
          "qualified cold fence failed to recover the contained manager");
    fatal_cases++;
  endtask

  /* exercise the smallest advertised deadline separately from the registered RAM fixture. */
  task automatic minimum_deadline_cases();
    int unsigned before_terminals;
    check(MAX_WAIT == 1, "minimum-deadline scenario used the wrong parameter");
    begin_case();
    prepare_owner(0, 'h40000000, 2, 0);
    before_terminals = terminals;
    accept_delay = 0;
    hold_accept = 0;
    zero_latency = 1;
    inject_response = 1;
    tick();
    inject_response = 0;
    check(!fatal_o && !owner && !target_pending && reference_reads == 1,
          "final-edge same-cycle acceptance/response lost to the minimum deadline");
    drain();
    check(terminals == before_terminals + 1, "minimum-deadline x0 load did not terminate once");
    /* no response on the first allowed edge must capture an unaccepted exposed owner. */
    begin_case();
    prepare_owner();
    tick();
    check(fatal_record_ref.reason == 3 && !fatal_record_ref.accepted &&
          cycles == offer_cycle + 1, "minimum OFFER timeout occurred on the wrong edge");
    finish_fatal();
    /* accepting on the last edge does not extend the deadline without a matching reply. */
    begin_case();
    prepare_owner();
    accept_delay = 0;
    hold_accept = 0;
    tick();
    check(fatal_record_ref.reason == 3 && fatal_record_ref.accepted &&
          !fatal_record_ref.responded && cycles == offer_cycle + 1,
          "minimum accepted timeout snapshot omitted its same-edge exposure");
    finish_fatal();
  endtask

  /* run replayable memory cases without assuming reset values for nonzero GPRs. */
  initial begin : regression
    packet_t p;
    expected_t q;
    logic [31:0] pc, value, address, first_offer_edge;
    int unsigned before_launches, before_terminals, before_bypasses;
    logic [63:0] before_effects;
    check($value$plusargs("seed=%d", schedule_seed) || schedule_seed == 1, "schedule seed parse failed");
    random_state = schedule_seed;
    fatal_record_ref = '0;
    /* initialize only the observer ledgers and immutable test input image. */
    for (int id = 0; id < CAPACITY; id++) begin
      original[id] = '0;
      expected[id] = '0;
      live[id] = 0;
      issued[id] = 0;
      completed[id] = 0;
      failed[id] = 0;
      load_value[id] = 0;
    end
    /* target and reference storage start equal but remain separate mutable arrays. */
    for (int index = 0; index < 98304; index++) begin
      target_ram[index] = image_byte(32'(index));
      reference_ram[index] = image_byte(32'(index));
    end
    /* exact byte boundaries expose both positive and negative sign-extension cases. */
    for (int byte_number = 0; byte_number < 4; byte_number++) begin
      target_ram[byte_number] = 8'(32'h80ff7f01 >> (8 * byte_number));
      reference_ram[byte_number] = 8'(32'h80ff7f01 >> (8 * byte_number));
    end
    /* enabled-profile timer apertures use deterministic plain register values only. */
    for (int index = 0; index < 5; index++) begin
      target_timer[index] = 'h55667788 + 32'(index);
      reference_timer[index] = 'h55667788 + 32'(index);
    end
    /* establish qualified reset before any checked observation of potentially unspecified DUT state. */
    cold_reset_i = 1;
    #2;
    clk_i = 1;
    #2;
    clk_i = 0;
    cold_reset_i = 0;
    cycles++;
    resets++;
    /* minimum timing compatibility is deliberately separate from registered target-read tests. */
    if (SCENARIO == 1) minimum_deadline_cases();
    /* the default occupancy and guard parameters execute real decoded memory independently. */
    else if (SCENARIO == 2) begin
      check(!PROFILE && MAX_WAIT == 128, "default diagnostic scenario used nondefault parameters");
      /* exercise every default-mode transfer width and its actual load/store path. */
      for (int width = 0; width < 3; width++) begin
        operation_case('h20000000, 0, 'h80ff7f01, 1, 2'(width));
        operation_case('h20000000, 0, 0, 0, 2'(width), 1);
        /* narrow unsigned reads use the same default occupancy mode. */
        if (width != 2) operation_case('h20000000, 0, 0, 0, 2'(width), 0);
      end
      operation_case('h20000001, 0, 0, 0, 2, 1);
      operation_case('h10000, 0, 'h12345678, 1, 2);
      operation_case('h40001000, 0, 0, 0, 2, 1);
      operation_case('h50001000, 0, 0, 0, 2, 1);
      operation_case('h40000000, 0, 0, 0, 2, 1, 0);
      operation_case('hfffffff0, 32, 0, 0, 2, 1);
    end
    /* the default deadline profile runs decoded memory, side effects and containment cases. */
    else begin
      /* decoding failures and earlier fetch faults must suppress all memory actions. */
      for (int variant = 0; variant < 6; variant++) invalid_memory_case(variant);
      /* every byte and halfword lane is read with both sign-extension choices. */
      for (int width = 0; width < 3; width++) begin
        /* natural alignment determines the valid lane positions for each transfer width. */
        for (int lane = 0; lane < 4; lane += (1 << width)) begin
          operation_case('h20000000 + 32'(lane), 0, 0, 0, 2'(width), 1);
          /* unsigned narrow loads must never replicate the selected sign bit. */
          if (width != 2) operation_case('h20000000 + 32'(lane), 0, 0, 0, 2'(width), 0);
          operation_case('h20000000 + 32'(lane), 0, 'h89abcdef, 1, 2'(width));
          operation_case('h20000000 + 32'(lane), 0, 0, 0, 2'(width), 0);
        end
      end
      /* source/destination overlap and modulo address arithmetic use real captured registers. */
      operation_case('h20000000, 0, 0, 0, 2, 1, 1);
      operation_case('h20000000, 4, 0, 1, 2, 0, 3, 1);
      operation_case('h20000010, -32'd16, 0, 0, 2, 1);
      operation_case('hfffffff0, 32, 0, 0, 2, 1);
      operation_case(0, 4, 0, 0, 2, 1, 0, 0, 1);
      /* natural alignment wins before region access faults and never creates a bus owner. */
      for (int write = 0; write < 2; write++) begin
        operation_case('h20000001, 0, 'h12345678, 1'(write), 1);
        operation_case('h70000001, 0, 'h12345678, 1'(write), 2);
        operation_case('h20008000, 0, 'h12345678, 1'(write), 2);
        operation_case('h50000000, 0, 'h12345678, 1'(write), 2);
        operation_case('h40000000, 0, 'h12345678, 1'(write), 0);
        operation_case('h40001000, 0, 'h12345678, 1'(write), 2);
        operation_case('h10000, 0, 'h12345678, 1'(write), 2);
      end
      operation_case('h1fff, 0, 0, 0, 0);
      operation_case('h1fff, 0, 'h55, 1, 0);
      operation_case('h20007fff, 0, 'h55, 1, 0);
      operation_case('h2000, 0, 0, 0, 0, 0, 0);
      operation_case('h50001000, 0, 0, 0, 2, 1, 0);
      operation_case('h50001000, 0, 'h12345678, 1, 2);
      operation_case('h40000004, 0, 0, 0, 2);
      operation_case('h40000000, 0, 'h12345678, 1, 2);
      operation_case('h40000024, 0, 0, 0, 2);
      operation_case('h50002001, 0, 0, 0, 0);
      operation_case('h50002004, 0, 'h12345678, 1, 2);
      /* one device stream proves x0 reads still create effects and writes retain their payload. */
      begin_case();
      send_plain(packet('h100, OP_RESULT, 1, 'h40000000));
      pc = 'h104;
      /* the first ticket is discarded through x0; the second returns the previous increment. */
      for (int destination = 0; destination < 2; destination++) begin
        p = memory_instruction(pc, 0, 2, 0, 1, destination == 0 ? 0 : 3);
        send(p, memory_expected(p, 0, 2, 1, 'h40000000, 0, 0, 1, destination == 0 ? 0 : 3));
        pc += 4;
      end
      p = memory_instruction(pc, 0, 2, 8, 1, 4);
      send(p, memory_expected(p, 0, 2, 1, 'h40000000, 8, 0, 1, 4));
      pc += 4;
      send_plain(packet(pc, OP_RESULT, 2, 'hdeadbeef));
      pc += 4;
      p = memory_instruction(pc, 1, 2, 4, 1, 2);
      send(p, memory_expected(p, 1, 2, 0, 'h40000000, 4, 'hdeadbeef, 1, 2));
      pc += 4;
      p = memory_instruction(pc, 0, 2, 12, 1, 5);
      send(p, memory_expected(p, 0, 2, 1, 'h40000000, 12, 0, 1, 5));
      pc += 4;
      p = memory_instruction(pc, 0, 2, 16, 1, 6);
      send(p, memory_expected(p, 0, 2, 1, 'h40000000, 16, 0, 1, 6));
      drain();
      check(regs_ref[3] == 1 && regs_ref[4] == 2 && regs_ref[5] == 1 &&
            regs_ref[6] == 'hdeadbeef && target_reads == 2 && target_writes == 1,
            "MMIO exact-once stream lost an x0 effect or payload");
      /* a nearer base-register writer must hide an older stale unmapped value. */
      begin_case();
      send_plain(packet('h100, OP_RESULT, 1, 'h70000000));
      send_plain(packet('h104, OP_RESULT, 1, 'h20000000));
      p = memory_instruction('h108, 0, 2, 0);
      send(p, memory_expected(p, 0, 2, 1, 'h20000000, 0));
      drain();
      check(nearest_stalls != 0, "nearest memory base writer was not exercised");
      /* a load updates its own base register, then supplies the next load and store sources. */
      begin_case();
      before_bypasses = dual_bypasses;
      send_plain(packet('h100, OP_RESULT, 1, 'h20000080));
      send_plain(packet('h104, OP_RESULT, 2, 'h20000040));
      p = memory_instruction('h108, 1, 2, 0, 1, 2);
      send(p, memory_expected(p, 1, 2, 0, 'h20000080, 0, 'h20000040, 1, 2));
      p = memory_instruction('h10c, 0, 2, 0, 1, 1);
      send(p, memory_expected(p, 0, 2, 1, 'h20000080, 0, 0, 1, 1));
      value = {24'b0, reference_ram['h41]};
      /* the independently stored byte defines both the expected load and following store operand. */
      if (value[7]) value |= 'hffffff00;
      p = memory_instruction('h110, 0, 0, 1, 1, 3);
      send(p, memory_expected(p, 0, 0, 1, 'h20000040, 1, 0, 1, 3));
      p = memory_instruction('h114, 1, 0, 3, 1, 3);
      send(p, memory_expected(p, 1, 0, 0, 'h20000040, 3, value, 1, 3));
      drain();
      check(dual_bypasses >= before_bypasses + 2 && dependency_stalls != 0,
            "load-to-memory source dependencies did not exercise W forwarding");
      /* a normal held older result blocks effects, then permits exactly one eventual command. */
      begin_case();
      send_plain(packet('h100, OP_RESULT, 1, 'h40000000));
      drain();
      hold_i[4] = 1;
      send_plain(packet('h104, OP_RESULT, 4, 'h44));
      p = memory_instruction('h108, 0, 2, 0, 1, 0);
      send(p, memory_expected(p, 0, 2, 1, 'h40000000, 0, 0, 1, 0));
      reach(3, 'h108);
      before_launches = launches;
      /* withheld W completion denies launch without losing the waiting memory token. */
      repeat (3) tick();
      check(launches == before_launches && target_reads == 0, "held normal W allowed an early memory effect");
      hold_i[4] = 0;
      drain();
      check(launches == before_launches + 1 && target_reads == 1 && regs_ref[4] == 'h44,
            "normal W release lost or duplicated the younger command");
      /* a real decoded read or store remains protected through external flush in OFFER and WAIT. */
      for (int write = 0; write < 2; write++) begin
        /* phase zero flushes before physical acceptance; phase one flushes its accepted owner. */
        for (int accepted_phase = 0; accepted_phase < 2; accepted_phase++) begin
          begin_case();
          prepare_owner(1'(write), write != 0 ? 'h40000004 : 'h40000000, 2, 0);
          /* the accepted phase already has exactly one target effect before the flush request. */
          if (accepted_phase != 0) reach_accepted();
          send_plain(packet(original[owner_uid].pc + 4, OP_RESULT, 5, 'hbad0bad0));
          request_flush();
          hold_accept = 0;
          hold_response = 0;
          drain();
          check(arch_pc == 'h300 && !defined_ref[5] &&
                (write != 0 ? target_writes == 1 && target_last_write == 'h89abcdef : target_reads == 1),
                "flush lost its protected decoded command or retained a younger result");
          memory_flush_cases++;
        end
      end
      /* held older W instructions deny younger memory effects until their own disposition. */
      for (int older_fault = 0; older_fault < 2; older_fault++) begin
        begin_case();
        send_plain(packet('h100, OP_RESULT, 1, 'h40000000));
        drain();
        hold_i[4] = 1;
        p = jal('h104, 'h1fc);
        q = jal_expected(p, 'h1fc);
        /* a supplied earlier fetch fault is a distinct precise instruction event. */
        if (older_fault != 0) begin
          p = packet('h104);
          p.fault = 1;
          p.cause = 1;
          p.mtval = 'h104;
          q.p = p;
          q.redirects = 0;
        end
        send(p, q);
        p = memory_instruction('h108, 0, 2, 0, 1, 0);
        send(p, memory_expected(p, 0, 2, 1, 'h40000000, 0, 0, 1, 0));
        reach(3, 'h108);
        before_launches = launches;
        /* holding W cannot authorize speculative MMIO reads whose result will be discarded. */
        repeat (3) tick();
        hold_i[4] = 0;
        drain();
        check(launches == before_launches && target_reads == 0,
              "younger MMIO read escaped an older held control or fault");
      end
      /* hart reset preserves an offered or accepted device obligation while aborting its instruction. */
      for (int phase = 0; phase < 3; phase++) begin
        begin_case();
        prepare_owner(0, 'h40000000, 2, 0);
        /* the accepted variant has already produced its single physical read effect. */
        if (phase == 1) reach_accepted();
        /* the collision variant accepts the still-offered request on the reset edge itself. */
        if (phase == 2) begin
          hold_accept = 0;
          accept_delay = 0;
        end
        before_terminals = terminals;
        hart_reset_i = 1;
        tick();
        hart_reset_i = 0;
        hold_accept = 0;
        hold_response = 0;
        drain();
        check(terminals == before_terminals && reference_reads == 1 && !defined_ref[3],
              "hart reset replayed an x0 device read or retired its orphan instruction");
        reset_cases++;
      end
      /* an exact last-edge response wins over deadline detection. */
      begin_case();
      prepare_owner();
      first_offer_edge = offer_cycle;
      reach_accepted();
      /* the registered target keeps its completed data private until the last allowed edge. */
      while (cycles < first_offer_edge + 32'(MAX_WAIT) - 1) tick();
      hold_response = 0;
      tick();
      check(!fatal_ref && cycles == first_offer_edge + 32'(MAX_WAIT), "deadline-edge response lost priority");
      drain();
      /* both exposed and accepted effectful reads/stores retain their first-valid deadline. */
      for (int write = 0; write < 2; write++) begin
        /* the target may perform its one effect before timeout or only during late acceptance. */
        for (int accepted_phase = 0; accepted_phase < 2; accepted_phase++) begin
          begin_case();
          before_effects = target_effects;
          prepare_owner(1'(write), write != 0 ? 'h40000004 : 'h40000000, 2, 0);
          /* acceptance alone cannot restart the first-valid deadline. */
          if (accepted_phase != 0) reach_accepted();
          wait_fatal();
          check(fatal_record_ref.reason == 3 && cycles == offer_cycle + 32'(MAX_WAIT) &&
                fatal_record_ref.accepted == (accepted_phase != 0) && !fatal_record_ref.responded,
                "deadline did not preserve exact first-valid exposure");
          finish_fatal();
          check(target_effects == before_effects + 1, "timed-out device command was lost or replayed");
        end
      end
      /* uncertainty may mean either zero or one actual effect, and neither case authorizes replay. */
      for (int write = 0; write < 2; write++) begin
        /* the independently declared script chooses the physical outcome hidden from the CPU. */
        for (int perform = 0; perform < 2; perform++) begin
          begin_case();
          before_effects = target_effects;
          force_status = 2;
          uncertain_effect = perform != 0;
          prepare_owner(1'(write), write != 0 ? 'h40000004 : 'h40000000, 2, 0);
          reach_accepted();
          hold_response = 0;
          wait_fatal();
          check(fatal_record_ref.reason == 2 && target_effects == before_effects + 64'(perform),
                "uncertain MMIO outcome differed from its explicit effect script");
          finish_fatal();
          check(target_effects == before_effects + 64'(perform), "uncertain device operation was replayed");
        end
      end
      /* early, wrong-tag, malformed and uncertain responses all have distinct explicit dispositions. */
      for (int error = 0; error < 7; error++) begin
        begin_case();
        force_status = error == 4 ? 1 : error == 5 ? 2 : error == 6 ? 3 : 0;
        uncertain_effect = error == 5;
        prepare_owner(error == 3 || error >= 5, error >= 5 ? 'h50002000 : 'h20000000, error == 2 ? 0 : 2);
        /* premature matching replies deliberately leave ready low at the first offer. */
        if (error != 0) reach_accepted();
        /* injected identity errors must not consume the real target's future response. */
        if (error < 2) begin
          inject_response = 1;
          inject_wrong_tag = error == 1;
        end
        /* matching malformed payloads still physically respond but cannot reach W. */
        else begin
          corrupt_reply = error inside {2, 3, 4};
          hold_response = 0;
        end
        wait_fatal();
        check(fatal_record_ref.reason == (error == 5 ? 2 : 1) &&
              fatal_record_ref.responded == (error >= 2), "response-error classification or snapshot is wrong");
        finish_fatal();
      end
      /* an orphan reply has no instruction descriptor to invent or overwrite. */
      begin_case();
      inject_response = 1;
      inject_wrong_tag = 1;
      tick();
      check(fatal_record_ref.valid && !fatal_record_ref.owned && fatal_record_ref.reason == 1,
            "orphan response acquired a fictitious owner");
      finish_fatal();
      /* a duplicate reply after a completed command is independently rejected as an orphan. */
      begin_case();
      prepare_owner();
      hold_accept = 0;
      hold_response = 0;
      drain();
      inject_response = 1;
      tick();
      check(fatal_record_ref.valid && !fatal_record_ref.owned, "duplicate response acquired a released owner");
      finish_fatal();
      /* seeded aligned writes and reads vary operand bytes independently of bus-delay choices. */
      for (int sample = 0; sample < 24; sample++) begin
        value = next_random();
        address = 'h20000040 + (next_random() & 'h3c);
        operation_case(address, 0, value, 1, 2);
        operation_case(address, 0, 0, 0, 2, 1);
      end
    end
    check(SCENARIO != 0 || (memory_flush_cases == 4 && invalid_cases == 6 && nearest_stalls != 0),
          "required memory integration coverage was not exercised");
    check(!owner && !target_pending && !fatal_ref && !flush_pending && stage_valid_o == 0,
          "memory qualification left an instruction, target or manager obligation unresolved");
    compare_storage();
    $display("PASS memory profile=%0d scenario=%0d deadline=%0d seed=%0d cases=%0d cycles=%0d checks=%0d terminals=%0d traps=%0d kills=%0d offers=%0d replies=%0d decoded=%0d rejects=%0d fatal_cases=%0d resets=%0d effects=%0d max_accept_delay=%0d max_response_delay=%0d flushes=%0d flush_redirects=%0d aborts=%0d bypasses=%0d reset_cases=%0d dependency_stalls=%0d nearest_stalls=%0d memory_flush=%0d invalid=%0d",
             PROFILE, SCENARIO, MAX_WAIT, schedule_seed, cases, cycles, checks, terminals, traps, killed,
             launches, responses, decoded_cases, rejection_cases, fatal_cases, resets, target_effects,
             maximum_accept_delay, maximum_response_delay, flushes, flush_redirects, aborts, dual_bypasses, reset_cases, dependency_stalls, nearest_stalls, memory_flush_cases, invalid_cases);
    $finish;
  end
endmodule

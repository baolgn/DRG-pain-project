/* verify fetch ownership and framing against an independent synchronous RAM. */
module drg5_fetch_tb #(
  parameter bit C_FETCH = 0,
  parameter integer MAX_WAIT_CYCLES = 64,
  parameter integer TAG_BITS = 32,
  parameter integer SCENARIO = 0
);
  localparam integer GEN_BITS = 2;
  localparam integer RAM_PARCELS = 38917;
  /* allow one old-owner drain, two new beats and fixed turnaround/assembly edges. */
  localparam integer OUTPUT_PROGRESS_BOUND = 3 * MAX_WAIT_CYCLES + 4;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0, permit_i = 0;
  logic redirect_valid_i = 0;
  logic [31:0] redirect_pc_i = 0;
  logic i_req_valid_o, i_req_ready_i = 0;
  logic [31:0] i_req_addr_o, i_req_tag_o;
  logic [1:0] i_req_parcels_o;
  logic i_rsp_valid_i, i_rsp_ready_o;
  logic [31:0] i_rsp_tag_i, i_rsp_data_i;
  logic [1:0] i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i;
  logic insn_valid_o, insn_ready_i = 0;
  logic [31:0] insn_pc_o, insn_raw_o, insn_cause_o, insn_mtval_o;
  logic [3:0] insn_raw_valid_o;
  logic [1:0] insn_length_kind_o;
  logic insn_length_supported_o, insn_fault_o;
  logic [2:0] insn_length_bytes_o;
  logic [GEN_BITS-1:0] insn_generation_o, generation_o;
  logic busy_o, discard_o, fatal_o, launch_o, accept_o, complete_o, drop_o;
  logic [2:0] fatal_reason_o;

  /* retain complete expected instruction records independently of DUT outputs. */
  typedef struct packed {
    logic [31:0] pc, raw;
    logic [3:0] raw_valid;
    logic [1:0] kind;
    logic supported;
    logic [2:0] bytes;
    logic [GEN_BITS-1:0] generation;
    logic fault;
    logic [31:0] cause, mtval;
  } instruction_t;

  /* independently name the next missing required parcels. */
  typedef struct packed {
    logic valid;
    logic [31:0] address;
    logic [1:0] mask;
  } demand_t;

  logic [15:0] ram [0:RAM_PARCELS-1];
  integer seen_serial [0:RAM_PARCELS-1];
  bit seen_fault [0:RAM_PARCELS-1];
  logic [31:0] denied_address [0:1];
  integer denied_serial [0:1];
  integer stream_serial = 1;
  logic [31:0] expected_pc = 0;
  logic [GEN_BITS-1:0] expected_generation = 0;
  bit parked = 0, fatal_ref = 0, reset_was_high = 1;
  logic [2:0] reason_ref = 0;
  bit owner = 0, accepted = 0, stale = 0, recovered = 0;
  logic [31:0] owner_addr = 0, owner_tag = 0, next_tag = 0;
  logic [1:0] owner_mask = 0;
  integer owner_serial = 0;
  int unsigned owner_cycle = 0, cycles = 0, offers = 0, accepts = 0;
  int unsigned replies = 0, delivered = 0, dropped = 0, instructions = 0;
  int unsigned normal_releases = 0;
  int unsigned fault_packets = 0, unsupported_packets = 0, isolated_owners = 0;
  int unsigned ram_reads;
  int unsigned zero_completions = 0, held_output_cycles = 0;
  int unsigned max_output_wait = 0, straddle_cycles = 0;
  bit tag_exhausted = 0, mutation_applied = 0;
  bit output_held = 0;
  instruction_t held_packet;
  integer acceptance_delay = 0, response_delay = 0, response_mode = 0;
  bit block_accept = 0, zero_latency = 0;
  bit fault_address_valid = 0;
  logic [31:0] fault_address = 0;
  bit rejection_address_valid = 0;
  logic [31:0] rejection_address = 0;
  logic [1:0] owner_fault_plan = 0;

  /* registered target state is outside the hart reset domain. */
  logic ram_owned, ram_valid;
  logic [31:0] ram_tag, ram_data;
  logic [1:0] ram_mask, ram_fault, ram_status;
  integer ram_countdown;
  logic inject_valid = 0;
  logic [31:0] inject_tag = 0, inject_data = 0;
  logic [1:0] inject_mask = 0, inject_fault = 0, inject_status = 0;

  /* keep all external observations visible without hierarchical DUT access. */
  drg5_fetch #(.C_FETCH(C_FETCH), .GEN_BITS(GEN_BITS), .TAG_BITS(TAG_BITS),
      .MAX_WAIT_CYCLES(MAX_WAIT_CYCLES), .TEST_REGIONS(1)) dut (.*);

  /* stop immediately with a replayable clock and independently counted stream. */
  function automatic void check(input bit condition, input string message);
    /* failures must not leave a corrupted ownership ledger running. */
    if (!condition) begin
      $fatal(1, "cycle=%0d C=%0d scenario=%0d serial=%0d pc=%08x: %s",
             cycles, C_FETCH, SCENARIO, stream_serial, expected_pc, message);
    end
  endfunction

  /* permission uses explicit fixture intervals and individual safe halfwords. */
  function automatic bit executable(input logic [31:0] address);
    return !address[0] && (address < 32'h2000 ||
        (address >= 32'h10000 && address < 32'h20000) ||
        (address >= 32'h50000000 && address < 32'h50001000) ||
        address == 32'h60000000 || address == 32'h60000006 || address == 32'hfffffffe);
  endfunction

  /* map declared regions to distinct backing storage rather than address aliases. */
  function automatic integer memory_index(input logic [31:0] address);
    check(executable(address), "reference attempted forbidden memory read");
    /* ROM and IRAM have separate physical storage. */
    if (address < 32'h2000) return int'(address / 2);
    /* the larger instruction RAM follows ROM in the fixture array. */
    else if (address >= 32'h10000 && address < 32'h20000)
      return 4096 + int'((address - 32'h10000) / 2);
    /* the error-injection region remains side-effect-free instruction storage. */
    else if (address >= 32'h50000000 && address < 32'h50001000)
      return 36864 + int'((address - 32'h50000000) / 2);
    /* isolated boundary parcels never imply permission for their neighbors. */
    else if (address == 32'h60000000) return 38912;
    /* the upper isolated parcel occupies a different backing location. */
    else if (address == 32'h60000006) return 38915;
    /* the final fixture parcel exercises address wrap. */
    else return 38916;
  endfunction

  /* expected data comes directly from immutable initialized memory. */
  function automatic logic [15:0] memory_half(input logic [31:0] address);
    return ram[memory_index(address)];
  endfunction

  /* target faults are planned stimulus, never copied from an instruction record. */
  function automatic logic [1:0] planned_faults(input logic [31:0] address,
                                              input logic [1:0] mask,
                                              input integer mode);
    logic [1:0] faults;
    faults = 0;
    /* whole-beat rejection requires every requested fault bit. */
    if (mode == 1 || (rejection_address_valid && address == rejection_address)) begin
      faults = mask;
    end
    /* individual failures affect only their named requested parcel. */
    else if (fault_address_valid) begin
      faults[0] = mask[0] && address == fault_address;
      faults[1] = mask[1] && address + 2 == fault_address;
    end
    return faults;
  endfunction

  /* synchronous and compatibility targets share initial bytes, not captured results. */
  function automatic logic [31:0] planned_data(input logic [31:0] address,
                                             input logic [1:0] mask,
                                             input logic [1:0] faults);
    logic [31:0] data;
    data = 0;
    /* denied and absent parcels never perform a physical read. */
    for (int parcel = 0; parcel < 2; parcel++) begin
      /* each enabled read has an independently checked safe address. */
      if (mask[parcel] && !faults[parcel]) begin
        data[16*parcel +: 16] = memory_half(address + 32'(2 * parcel));
      end
    end
    return data;
  endfunction

  /* select registered RAM replies or explicit adversarial and compatibility fixtures. */
  always_comb begin
    i_rsp_valid_i = ram_valid;
    i_rsp_tag_i = ram_tag;
    i_rsp_parcels_i = ram_mask;
    i_rsp_data_i = ram_data;
    i_rsp_fault_i = ram_fault;
    i_rsp_status_i = ram_status;
    /* adversarial replies are explicit test stimulus, separate from normal RAM. */
    if (inject_valid) begin
      i_rsp_valid_i = 1;
      i_rsp_tag_i = inject_tag;
      i_rsp_parcels_i = inject_mask;
      i_rsp_data_i = inject_data;
      i_rsp_fault_i = inject_fault;
      i_rsp_status_i = inject_status;
    end
    /* zero latency is a separate compatibility fixture, not a RAM timing claim. */
    else if (zero_latency && i_req_valid_o && i_req_ready_i) begin
      i_rsp_valid_i = 1;
      i_rsp_tag_i = i_req_tag_o;
      i_rsp_parcels_i = i_req_parcels_o;
      i_rsp_fault_i = planned_faults(i_req_addr_o, i_req_parcels_o, response_mode);
      i_rsp_data_i = planned_data(i_req_addr_o, i_req_parcels_o, i_rsp_fault_i);
      i_rsp_status_i = 2'(response_mode);
    end
  end

  /* read the actual RAM only on acceptance and expose registered data afterward. */
  always_ff @(posedge clk_i) begin
    /* positive isolation fences the responder along with the manager. */
    if (cold_reset_i && isolated_i) begin
      ram_owned <= 0;
      ram_valid <= 0;
      ram_countdown <= 0;
      ram_data <= 0;
      ram_fault <= 0;
      ram_status <= 0;
      ram_tag <= 0;
      ram_mask <= 0;
      /* retain cumulative read coverage across subsequent isolated resets. */
      if (cycles == 0) ram_reads <= 0;
    end
    /* hart reset and redirect deliberately do not reset this target. */
    else begin
      /* one acceptance captures a real registered memory read. */
      if (i_req_valid_o && i_req_ready_i && !zero_latency) begin
        check(!ram_owned, "RAM accepted a second live transaction");
        ram_owned <= 1;
        ram_valid <= response_delay == 0;
        ram_countdown <= response_delay;
        ram_tag <= response_mode == 4 ? i_req_tag_o + 1 : i_req_tag_o;
        ram_mask <= response_mode == 5 ? ~i_req_parcels_o : i_req_parcels_o;
        ram_fault <= planned_faults(i_req_addr_o, i_req_parcels_o, response_mode);
        ram_data <= planned_data(i_req_addr_o, i_req_parcels_o,
                                planned_faults(i_req_addr_o, i_req_parcels_o, response_mode));
        ram_status <= response_mode <= 3 ? 2'(response_mode) : 0;
        /* this planned rejection is canonical regardless of the current global mode. */
        if (rejection_address_valid && i_req_addr_o == rejection_address) begin
          ram_status <= 1;
        end
        /* a deliberately malformed successful reply must trigger containment. */
        if (response_mode == 6) begin
          ram_fault <= i_req_parcels_o;
          ram_data <= 32'h1;
        end
        /* status01 must reject nonzero data even with a complete fault mask. */
        if (response_mode == 7) begin
          ram_status <= 1;
          ram_fault <= i_req_parcels_o;
          ram_data <= 1;
        end
        /* status01 must also reject an incomplete requested fault mask. */
        if (response_mode == 8) begin
          ram_status <= 1;
          ram_fault <= 0;
          ram_data <= 0;
        end
        ram_reads <= ram_reads + $countones(i_req_parcels_o &
                     ~planned_faults(i_req_addr_o, i_req_parcels_o, response_mode));
      end
      /* response latency is independent of acceptance waiting time. */
      else if (ram_owned && !ram_valid) begin
        ram_countdown <= ram_countdown - 1;
        /* once ready, response-valid stays asserted until an actual capture. */
        if (ram_countdown == 1) begin
          ram_valid <= 1;
        end
      end
      /* clear exactly one response, never replay its read after a redirect. */
      if (ram_valid && i_rsp_ready_o && !inject_valid) begin
        ram_owned <= 0;
        ram_valid <= 0;
      end
    end
  end

  /* distinguish delivered data from local permission failures in the active stream. */
  function automatic bit parcel_seen(input logic [31:0] address);
    /* local denial becomes terminal only after an independently permitted fill edge. */
    if (!executable(address)) return
        (denied_serial[0] == stream_serial && denied_address[0] == address) ||
        (denied_serial[1] == stream_serial && denied_address[1] == address);
    return seen_serial[memory_index(address)] == stream_serial;
  endfunction

  /* a denied parcel is a local fault and never a target read. */
  function automatic bit parcel_fault(input logic [31:0] address);
    /* denied addresses never enter the RAM indexing function. */
    if (!executable(address)) return 1;
    return seen_fault[memory_index(address)];
  endfunction

  /* form exact expected PC, framing, partial bytes and access-fault attribution. */
  function automatic instruction_t expected_packet();
    instruction_t p;
    bit first_fault, second_fault, need_second;
    logic [15:0] first;
    p = '0;
    p.pc = expected_pc;
    p.generation = expected_generation;
    first_fault = parcel_fault(expected_pc);
    second_fault = parcel_fault(expected_pc + 2);
    first = executable(expected_pc) ? memory_half(expected_pc) : 0;
    /* defensive start alignment takes priority before all memory activity. */
    if (expected_pc[0] || (!C_FETCH && expected_pc[1])) begin
      p.fault = 1;
      p.mtval = expected_pc;
    end
    /* a first-parcel failure leaves the instruction length unknown. */
    else if (first_fault) begin
      p.fault = 1;
      p.cause = 1;
      p.mtval = expected_pc;
      /* required non-C upper bytes are retained only when independently delivered. */
      if (!C_FETCH && parcel_seen(expected_pc + 2) && !second_fault) begin
        p.raw[31:16] = memory_half(expected_pc + 2);
        p.raw_valid = 12;
      end
    end
    /* successful first bytes select framing independently of any decoder. */
    else begin
      p.raw[15:0] = first;
      p.raw_valid = 3;
      p.kind = first % 4 != 3 ? 1 : ((first / 4) % 8 != 7 ? 2 : 3);
      p.supported = p.kind == 2 || (C_FETCH && p.kind == 1);
      p.bytes = p.kind == 2 ? 4 : (C_FETCH && p.kind == 1 ? 2 : 0);
      need_second = !C_FETCH || p.kind != 1;
      /* required second-parcel failure preserves the known low instruction bytes. */
      if (need_second && second_fault) begin
        p.fault = 1;
        p.cause = 1;
        p.mtval = expected_pc + 2;
      end
      /* full original bits remain visible even for an unsupported length. */
      else if (need_second) begin
        p.raw[31:16] = memory_half(expected_pc + 2);
        p.raw_valid = 15;
      end
    end
    return p;
  endfunction

  /* readiness depends on independently delivered required bytes, never DUT valid. */
  function automatic bit packet_ready();
    logic [15:0] first;
    /* alignment faults need no memory result. */
    if (expected_pc[0] || (!C_FETCH && expected_pc[1])) return 1;
    /* a missing first parcel cannot establish bytes or length. */
    if (!parcel_seen(expected_pc)) return 0;
    /* the oldest required fault terminates without waiting for absent later bytes. */
    if (parcel_fault(expected_pc)) return 1;
    first = memory_half(expected_pc);
    return C_FETCH && first % 4 != 3 ? 1 : parcel_seen(expected_pc + 2);
  endfunction

  /* derive demand from the independent parcel ledger, never from a DUT need signal. */
  function automatic demand_t next_demand();
    demand_t d;
    d = '0;
    /* alignment faults, parked attempts and complete instructions need no new parcel. */
    if (!parked && !expected_pc[0] && (C_FETCH || !expected_pc[1])) begin
      /* the initial demand is one halfword for C framing or both halves for non-C. */
      if (!parcel_seen(expected_pc)) begin
        d.valid = 1;
        d.address = expected_pc & 32'hfffffffc;
        d.mask = C_FETCH ? (expected_pc[1] ? 2 : 1) :
                 { !parcel_seen(expected_pc + 2), !parcel_seen(expected_pc) };
      end
      /* a known wider prefix requires only its missing second halfword. */
      else if (!parcel_fault(expected_pc) &&
               (!C_FETCH || memory_half(expected_pc) % 4 == 3) &&
               !parcel_seen(expected_pc + 2)) begin
        d.valid = 1;
        d.address = (expected_pc + 2) & 32'hfffffffc;
        d.mask = expected_pc[1] ? 1 : 2;
      end
    end
    return d;
  endfunction

  /* snapshot public instruction outputs without using them to advance the oracle. */
  function automatic instruction_t actual_packet();
    return {insn_pc_o, insn_raw_o, insn_raw_valid_o, insn_length_kind_o,
            insn_length_supported_o, insn_length_bytes_o, insn_generation_o,
            insn_fault_o, insn_cause_o, insn_mtval_o};
  endfunction

  /* validate every first presentation against the independent current demand. */
  task automatic check_offer(input logic [31:0] address, input logic [1:0] mask);
    logic [31:0] need_pc;
    logic [1:0] expected_mask;
    check(!parked && !expected_pc[0] && (C_FETCH || !expected_pc[1]),
          "offer without an aligned live instruction");
    need_pc = expected_pc;
    expected_mask = 0;
    /* non-C initially needs both halves, unless a local deny already supplied one. */
    if (!parcel_seen(expected_pc)) begin
      /* compressed framing must request exactly its initial halfword. */
      if (C_FETCH) expected_mask = expected_pc[1] ? 2 : 1;
      /* every missing permitted half belongs to the current aligned word. */
      else begin
        expected_mask[0] = !parcel_seen(expected_pc);
        expected_mask[1] = !parcel_seen(expected_pc + 2);
      end
    end
    /* a complete first parcel can require only the instruction's second half. */
    else begin
      check(!parcel_fault(expected_pc) && (!C_FETCH || memory_half(expected_pc) % 4 == 3) &&
            !parcel_seen(expected_pc + 2), "offer after the instruction was already complete");
      need_pc = expected_pc + 2;
      expected_mask = need_pc[1] ? 2 : 1;
    end
    check(address == (need_pc & 32'hfffffffc) && mask == expected_mask && mask != 0,
          "request did not match independent required parcels");
    /* safe data reads must never be widened into peripheral or denied neighbors. */
    for (int parcel = 0; parcel < 2; parcel++) begin
      /* observe first valid even when the target refuses acceptance. */
      if (mask[parcel]) begin
        check(executable(address + 32'(2 * parcel)), "forbidden instruction bus offer");
      end
    end
  endtask

  /* account one edge before checking newly registered owners and output packets. */
  task automatic tick();
    bit request_accept, response_capture, matching, malformed, event_fatal;
    bit launch_before, output_take, cold, invalidation, old_owner, observed_drop;
    bit old_fatal, expected_timeout;
    bit expected_launch, expected_local_deny, can_start;
    logic [2:0] event_reason;
    logic [31:0] old_address, old_tag, observed_address;
    logic [1:0] old_mask, response_fault;
    logic [1:0] allowed_mask, denied_mask;
    integer old_serial;
    instruction_t packet, observed;
    demand_t demand;
    clk_i = 0;
    /* ready is fixed before the edge and cannot change when the ledger updates. */
    i_req_ready_i = owner && !accepted && !ram_owned && !block_accept &&
                    cycles - owner_cycle >= 32'(acceptance_delay);
    #2;
    cold = cold_reset_i && isolated_i;
    invalidation = hart_reset_i || redirect_valid_i;
    old_owner = owner;
    old_address = owner_addr;
    old_mask = owner_mask;
    old_tag = owner_tag;
    old_serial = owner_serial;
    old_fatal = fatal_ref;
    launch_before = launch_o;
    request_accept = i_req_valid_o && i_req_ready_i;
    response_capture = i_rsp_valid_i && i_rsp_ready_o;
    matching = response_capture && owner && (accepted || request_accept) && !recovered &&
               i_rsp_tag_i == owner_tag && i_rsp_parcels_i == owner_mask;
    malformed = response_capture && (!matching || i_rsp_status_i[1] ||
        (i_rsp_status_i == 0 && ((i_rsp_fault_i & ~owner_mask) != 0 ||
         ((!owner_mask[0] || i_rsp_fault_i[0]) && i_rsp_data_i[15:0] != 0) ||
         ((!owner_mask[1] || i_rsp_fault_i[1]) && i_rsp_data_i[31:16] != 0))) ||
        (i_rsp_status_i == 1 && (i_rsp_data_i != 0 || i_rsp_fault_i != owner_mask)));
    expected_timeout = owner && !recovered && !matching &&
                       cycles - owner_cycle >= 32'(MAX_WAIT_CYCLES - 1) && !cold;
    demand = next_demand();
    allowed_mask = {executable(demand.address + 2), executable(demand.address)};
    denied_mask = demand.mask & ~allowed_mask;
    can_start = !owner && permit_i && !reset_was_high && !fatal_ref && !malformed &&
                !cold_reset_i && !invalidation;
    expected_local_deny = can_start && demand.valid && denied_mask != 0;
    expected_launch = can_start && demand.valid && denied_mask == 0 && !tag_exhausted;
    event_reason = cold_reset_i && !isolated_i ? 4 : malformed ? 1 : expected_timeout ? 2 :
        (can_start && demand.valid && denied_mask == 0 && tag_exhausted ? 3 : 0);
    event_fatal = event_reason != 0;
    check(fatal_o == (fatal_ref || event_fatal) &&
          (!(fatal_ref || event_fatal) || fatal_reason_o == (fatal_ref ? reason_ref : event_reason)),
          "wrong fetch containment state or first failure reason");
    check(i_rsp_ready_o == !cold, "response sink was not reserved");
    check(accept_o == request_accept && complete_o == matching, "wrong acceptance or completion witness");
    check(launch_before == expected_launch, "launch disagreed with independent parcel demand and grant");
    check(!launch_before || (!old_owner && !reset_was_high && permit_i &&
          !cold_reset_i && !invalidation && !fatal_ref && !event_fatal),
          "new offer escaped reset, redirect, permission or occupied-owner veto");
    /* an owned offer must remain immutable through every reset and redirect. */
    if (owner && !accepted && !cold) begin
      check(i_req_valid_o && i_req_addr_o == owner_addr && i_req_tag_o == owner_tag &&
            i_req_parcels_o == owner_mask, "owned instruction offer changed or disappeared");
    end
    check(!request_accept || (owner && !accepted), "duplicate or ownerless instruction acceptance");
    /* successful output has an independent sequential PC and exact byte provenance. */
    output_take = insn_valid_o && insn_ready_i;
    /* compare every presented packet, including cycles with ready low. */
    if (insn_valid_o) begin
      check(!fatal_ref && !event_fatal && !cold && !invalidation && !parked && packet_ready(),
            "instruction appeared without complete live required parcels");
      packet = expected_packet();
      observed = actual_packet();
      /* a plausible skipped instruction must fail PC comparison. */
      if ($test$plusargs("mutate_pc") && !mutation_applied) begin
        observed.pc ^= 4;
        mutation_applied = 1;
      end
      /* data corruption is detected against initialized bytes, not the response record. */
      if ($test$plusargs("mutate_raw") && !mutation_applied && packet.raw_valid != 0) begin
        observed.raw ^= 1;
        mutation_applied = 1;
      end
      check(observed == packet, "instruction reference mismatch");
      /* backpressure must not alter the packet until an explicit invalidation. */
      if (output_held) begin
        check(actual_packet() == held_packet, "held instruction packet changed");
        held_output_cycles++;
      end
      held_packet = actual_packet();
    end
    output_held = insn_valid_o && !insn_ready_i;
    /* externally selected control events suppress output transfer on this edge. */
    if (cold || invalidation || event_fatal || fatal_ref) begin
      check(!insn_valid_o, "reset, redirect or fatal event exposed an instruction");
      output_held = 0;
    end
    /* compare stale disposition before any ledger update can erase its cause. */
    observed_drop = drop_o;
    /* a missing discard must fail even when no wrong-path packet is emitted yet. */
    if ($test$plusargs("mutate_drop") && !mutation_applied && matching && (stale || invalidation)) begin
      observed_drop = 0;
      mutation_applied = 1;
    end
    check(observed_drop == (matching && (fatal_ref || event_fatal || stale || invalidation)),
          "missing or spurious stale-response discard");
    /* physical acceptance changes protocol state without creating another owner. */
    if (request_accept) begin
      accepted = 1;
      accepts++;
      owner_fault_plan = planned_faults(owner_addr, owner_mask, response_mode);
      /* the separate compatibility fixture may complete at this same edge. */
      if (zero_latency) zero_completions++;
    end
    /* matching replies deliver from the independent read plan or remain contained. */
    if (matching) begin
      replies++;
      response_fault = owner_fault_plan;
      /* fatal and stale streams never update the active parcel ledger. */
      if (!(fatal_ref || event_fatal || stale || invalidation)) begin
        check(i_rsp_fault_i == response_fault &&
              i_rsp_data_i == planned_data(owner_addr, owner_mask, response_fault),
              "RAM reply disagreed with independently initialized bytes");
        /* record exactly which independently requested parcels reached this stream. */
        for (int parcel = 0; parcel < 2; parcel++) begin
          /* no generation alias can turn an old delivery into current data. */
          if (owner_mask[parcel]) begin
            check(old_serial == stream_serial, "stale owner reached the new stream");
            seen_serial[memory_index(owner_addr + 32'(2 * parcel))] = stream_serial;
            seen_fault[memory_index(owner_addr + 32'(2 * parcel))] = response_fault[parcel];
          end
        end
        delivered++;
      end
      /* rejected delivery still accounts its matching external completion. */
      else begin
        dropped++;
      end
      /* a fatal owner remains quarantined even after a late matching success. */
      if (fatal_ref || event_fatal) begin
        recovered = 1;
      end
      /* ordinary delivery or discard completes this transaction lifetime. */
      else begin
        owner = 0;
        accepted = 0;
        stale = 0;
        normal_releases++;
      end
    end
    /* a qualified cold reset is the only modeled positive containment fence. */
    if (cold) begin
      isolated_owners += int'(owner);
      owner = 0;
      accepted = 0;
      stale = 0;
      recovered = 0;
      fatal_ref = 0;
      reason_ref = 0;
      expected_generation = 0;
      expected_pc = 0;
      stream_serial++;
      parked = 0;
      next_tag = 0;
      tag_exhausted = 0;
    end
    /* architectural events preserve transaction identities across stream changes. */
    else begin
      /* every asserted hart reset and every redirect starts a distinct stream. */
      if (invalidation) begin
        stream_serial++;
        expected_generation++;
        expected_pc = hart_reset_i ? 0 : redirect_pc_i;
        parked = 0;
        /* sticky invalidation survives numerical generation wrap. */
        if (old_owner) stale = 1;
      end
      /* successful instruction transfer is the only sequential advance. */
      else if (output_take) begin
        instructions++;
        fault_packets += int'(packet.fault);
        unsupported_packets += int'(!packet.fault && !packet.supported);
        parked = packet.fault || !packet.supported;
        /* unsupported widths and faults do not invent a following PC. */
        if (!parked) expected_pc += {29'b0, packet.bytes};
      end
      /* sticky failure keeps its first reason until isolated cold reset. */
      if (event_fatal) begin
        fatal_ref = 1;
        stale = 1;
        /* later malformed replies must not overwrite timeout or reset diagnosis. */
        if (!old_fatal) reason_ref = event_reason;
      end
      /* denied parcels acquire terminal status only on their permitted local-fill edge. */
      if (expected_local_deny) begin
        /* each denied halfword gets a current-stream record without reading RAM. */
        for (int parcel = 0; parcel < 2; parcel++) begin
          /* no permission event can silently complete an unrequested neighbor. */
          if (denied_mask[parcel]) begin
            denied_address[parcel] = demand.address + 32'(2 * parcel);
            denied_serial[parcel] = stream_serial;
          end
        end
      end
    end
    clk_i = 1;
    #2;
    cycles++;
    /* first presentation creates an independently validated immutable obligation. */
    if (!owner && i_req_valid_o && !cold) begin
      check(launch_before && !old_owner && !fatal_ref, "ownerless or recycled instruction offer");
      observed_address = i_req_addr_o;
      /* even an unaccepted peripheral offer must fail the bus monitor. */
      if ($test$plusargs("mutate_forbidden_offer") && !mutation_applied) begin
        observed_address = 32'h40000000;
        mutation_applied = 1;
      end
      /* check permissions before matching the expected address for a named detector. */
      for (int parcel = 0; parcel < 2; parcel++) begin
        /* every requested halfword must be safe before first valid. */
        if (i_req_parcels_o[parcel]) begin
          check(executable(observed_address + 32'(2 * parcel)), "forbidden instruction bus offer");
        end
      end
      check_offer(observed_address, i_req_parcels_o);
      check(i_req_tag_o == next_tag && !tag_exhausted, "instruction tag reused or skipped");
      owner = 1;
      accepted = 0;
      recovered = 0;
      stale = 0;
      owner_addr = i_req_addr_o;
      owner_mask = i_req_parcels_o;
      owner_tag = next_tag;
      owner_serial = stream_serial;
      owner_cycle = cycles;
      tag_exhausted = next_tag == (32'hffffffff >> (32 - TAG_BITS));
      next_tag++;
      offers++;
    end
    /* a launch pulse without first presentation would lose an allocated obligation. */
    else begin
      check(!launch_before, "launch witness lacked a new first-valid owner");
    end
    check(i_req_valid_o == (owner && !accepted && !cold), "missing or ownerless request-valid");
    check(busy_o == owner, "fetch manager ownership disappeared or duplicated");
    check(generation_o == expected_generation, "fetch generation did not follow independent control events");
    /* active discarded owners retain revocation across any generation-counter alias. */
    if (owner && (stale || fatal_ref)) begin
      check(discard_o, "discard permission revived after invalidation");
    end
    /* old descriptors remain independently available through response and containment. */
    if (old_owner && owner) begin
      check(owner_addr == old_address && owner_tag == old_tag && owner_mask == old_mask,
            "existing instruction owner was overwritten");
    end
    reset_was_high = cold_reset_i || hart_reset_i;
    clk_i = 0;
  endtask

  /* establish a fresh isolated epoch and retain cumulative coverage counters. */
  task automatic cold_start();
    permit_i = 0;
    insn_ready_i = 0;
    cold_reset_i = 1;
    isolated_i = 1;
    hart_reset_i = 0;
    redirect_valid_i = 0;
    inject_valid = 0;
    zero_latency = 0;
    block_accept = 0;
    response_mode = 0;
    fault_address_valid = 0;
    rejection_address_valid = 0;
    tick();
    cold_reset_i = 0;
    tick();
  endtask

  /* redirects are one-edge invalidations; the expected PC never comes from output. */
  task automatic redirect(input logic [31:0] pc);
    redirect_pc_i = pc;
    redirect_valid_i = 1;
    tick();
    redirect_valid_i = 0;
  endtask

  /* availability assumes permit stays high, healthy bounded service and no new redirect. */
  task automatic wait_output();
    int count;
    count = 0;
    /* a missing instruction cannot pass merely because no comparison occurred. */
    while (!insn_valid_o && !fatal_o && count < OUTPUT_PROGRESS_BOUND) begin
      tick();
      count++;
    end
    check(insn_valid_o && !fatal_o, "bounded fetch progress failed");
    /* consumer readiness is unnecessary for output availability and is tested separately. */
    if (32'(count) > max_output_wait) max_output_wait = 32'(count);
    tick();
  endtask

  /* select a single instruction and leave the manager drained afterward. */
  task automatic fetch_one(input logic [31:0] pc);
    insn_ready_i = 0;
    permit_i = 1;
    redirect(pc);
    wait_output();
    permit_i = 0;
    /* preserve output while independently stalling the instruction consumer. */
    repeat (3) begin
      tick();
    end
    insn_ready_i = 1;
    tick();
    insn_ready_i = 0;
    check(!owner && !ram_owned, "single-instruction test left an unaccounted request");
  endtask

  /* stop at first presentation without requiring physical acceptance. */
  task automatic wait_offer();
    int count;
    count = 0;
    /* the first-valid obligation must appear under a permitted aligned demand. */
    while (!i_req_valid_o && !fatal_o && count < 40) begin
      tick();
      count++;
    end
    check(i_req_valid_o && owner && !fatal_o, "expected fetch offer never appeared");
  endtask

  /* wait for a registered target reply without consuming it before the caller's event. */
  task automatic wait_ram_response();
    int count;
    count = 0;
    /* target service is finite in every ordinary test phase. */
    while (!ram_valid && !fatal_o && count < 40) begin
      tick();
      count++;
    end
    check(ram_valid, "registered RAM response failed to appear");
  endtask

  /* an independent watchdog catches accidental unbounded driver loops. */
  initial begin : watchdog
    #2000000;
    $fatal(1, "fetch regression watchdog expired");
  end

  /* exercise ordinary framing before adversarial protocol and lifetime collisions. */
  initial begin : regression
    int unsigned before_count;
    /* no local permission result exists before a granted fill edge. */
    for (int parcel = 0; parcel < 2; parcel++) begin
      denied_address[parcel] = 0;
      denied_serial[parcel] = 0;
    end
    /* default storage is a stream of four-byte ADDI x0,x0,0 instructions. */
    for (int index = 0; index < RAM_PARCELS; index++) begin
      ram[index] = index % 2 == 0 ? 16'h0013 : 16'h0000;
      seen_serial[index] = 0;
      seen_fault[index] = 0;
    end
    ram[memory_index('h100)] = 'h0001;
    ram[memory_index('h102)] = 'h0013;
    ram[memory_index('h104)] = 'hbeef;
    ram[memory_index('h106)] = 'h0001;
    ram[memory_index('h108)] = 'h001f;
    ram[memory_index('h10a)] = 'habcd;
    ram[memory_index('h10e)] = 'h001f;
    ram[memory_index('h110)] = 'ha5a5;
    ram[memory_index('h302)] = 'h0013;
    ram[memory_index('h60000000)] = 'h0001;
    ram[memory_index('h60000006)] = 'h0013;
    ram[memory_index('hfffffffe)] = 'h0013;
    cold_start();
    /* deadline tests distinguish last-edge success from an irrecoverably late reply. */
    if (SCENARIO == 1) begin
      acceptance_delay = 0;
      response_delay = 2;
      fetch_one(0);
      permit_i = 1;
      redirect('h102);
      wait_offer();
      before_count = owner_cycle;
      /* both straddling replies arrive on their respective last permitted edges. */
      while (!insn_valid_o && cycles - before_count < 20) begin
        tick();
      end
      check(insn_valid_o && cycles - before_count <= 10,
            "straddling instruction exceeded the ten-clock assembly bound");
      straddle_cycles = cycles - before_count;
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      cold_start();
      response_delay = 3;
      permit_i = 1;
      /* this response arrives one edge beyond the documented four-clock limit. */
      repeat (10) begin
        tick();
      end
      check(fatal_ref && reason_ref == 2 && owner && recovered,
            "late response escaped timeout containment");
      cold_start();
      block_accept = 1;
      permit_i = 1;
      wait_offer();
      /* first-valid age includes time before acceptance. */
      repeat (6) begin
        tick();
      end
      check(fatal_ref && reason_ref == 2 && i_req_valid_o, "unaccepted offer evaded deadline");
      block_accept = 0;
      response_delay = 0;
      /* even a later success drains into the retained recovery owner. */
      repeat (6) begin
        tick();
      end
      check(owner && recovered && fatal_ref, "late acceptance released timeout ownership");
      cold_start();
    end
    /* a small tag space exercises the last legal tag and no-wrap containment. */
    else if (SCENARIO == 2) begin
      /* eight requests consume tags zero through seven exactly once. */
      for (int request = 0; request < 8; request++) begin
        fetch_one(32'(request * 4));
      end
      permit_i = 1;
      redirect('h60000000);
      check(!fatal_o, "tag exhaustion bypassed an older local permission denial");
      tick();
      tick();
      check(fatal_ref && reason_ref == 3 && offers == 8 && accepts == 8 && replies == 8,
            "small-tag exhaustion was early, late or reused a tag");
      cold_start();
      fetch_one(0);
    end
    /* stress configuration deliberately separates acceptance, response and output stalls. */
    else begin
      /* all combinations use real registered RAM, never a combinational shortcut. */
      for (int acceptance = 0; acceptance < 3; acceptance++) begin
        /* include response latency longer than request acceptance delay. */
        for (int response_wait = 0; response_wait < 3; response_wait++) begin
          acceptance_delay = acceptance * 2;
          response_delay = response_wait * 2;
          fetch_one('h200 + 32'(4 * (acceptance * 3 + response_wait)));
        end
      end
      acceptance_delay = 0;
      response_delay = 0;
      fetch_one('h100);
      fetch_one('h102);
      fetch_one('h108);
      fetch_one('h10e);
      fetch_one('h60000000);
      fetch_one('h60000006);
      fetch_one('hfffffffe);
      fetch_one('h40000000);
      fetch_one(1);
      permit_i = 0;
      redirect('h40000000);
      /* local permission failures must wait for permission to perform their fill. */
      repeat (4) begin
        tick();
        check(!insn_valid_o && !owner, "ungranted local denial produced an instruction");
      end
      permit_i = 1;
      wait_output();
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      /* first and second target faults retain exactly the independently available bytes. */
      fault_address_valid = 1;
      fault_address = 'h300;
      fetch_one('h300);
      fault_address = 'h302;
      fetch_one('h300);
      fault_address_valid = 0;
      rejection_address_valid = 1;
      rejection_address = 'h304;
      fetch_one(C_FETCH ? 'h302 : 'h304);
      rejection_address_valid = 0;
      /* replace a fully assembled stalled packet without consuming its old instruction. */
      permit_i = 1;
      insn_ready_i = 0;
      redirect('h400);
      wait_output();
      before_count = instructions;
      redirect('h440);
      wait_output();
      check(instructions == before_count, "redirect consumed an old held output");
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      /* repeated offered-state redirects wrap generation while preserving sticky discard. */
      block_accept = 1;
      permit_i = 1;
      fault_address_valid = 1;
      fault_address = 'h500;
      redirect('h500);
      wait_offer();
      /* nine invalidations cross the two-bit generation boundary twice. */
      for (int restart = 0; restart < 9; restart++) begin
        redirect('h600 + 32'(restart * 4));
      end
      block_accept = 0;
      wait_output();
      fault_address_valid = 0;
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      /* redirect on the matching reply edge must invalidate insertion. */
      permit_i = 1;
      response_delay = 3;
      redirect('h700);
      wait_ram_response();
      redirect('h780);
      wait_output();
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      /* acceptance during hart reset remains a physical event with a discarded owner. */
      response_delay = 0;
      block_accept = 1;
      permit_i = 1;
      redirect('h800);
      wait_offer();
      hart_reset_i = 1;
      /* repeated reset levels preserve the offer while generation wraps. */
      repeat (3) begin
        tick();
      end
      block_accept = 0;
      tick();
      hart_reset_i = 0;
      tick();
      wait_output();
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      /* the separate zero-latency target collides acceptance, response and redirect. */
      zero_latency = 1;
      block_accept = 1;
      permit_i = 1;
      redirect('h900);
      wait_offer();
      block_accept = 0;
      redirect('h980);
      wait_output();
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      zero_latency = 0;
      /* a reset on the registered matching reply edge discards the old read. */
      permit_i = 1;
      response_delay = 2;
      redirect('h9c0);
      wait_ram_response();
      hart_reset_i = 1;
      tick();
      hart_reset_i = 0;
      tick();
      wait_output();
      permit_i = 0;
      insn_ready_i = 1;
      tick();
      insn_ready_i = 0;
      response_delay = 0;
      /* stale precise rejection is discarded, but stale uncertain outcomes still contain. */
      for (int mode = 1; mode <= 8; mode++) begin
        cold_start();
        response_mode = mode;
        block_accept = 1;
        permit_i = 1;
        redirect('ha00);
        wait_offer();
        redirect('hb00);
        permit_i = 0;
        block_accept = 0;
        /* allow the old response to drain before selecting normal service for the new stream. */
        repeat (5) begin
          tick();
        end
        /* only canonical status01 is an ordinary architectural discard. */
        if (mode == 1) begin
          response_mode = 0;
          permit_i = 1;
          wait_output();
          check(!insn_fault_o, "stale rejection poisoned the new stream");
        end
        /* every other injected response class is a containment event. */
        else begin
          check(fatal_ref && reason_ref == 1 && owner, "stale protocol failure escaped containment");
        end
      end
      cold_start();
      /* a reply before acceptance cannot release the persistent offered owner. */
      block_accept = 1;
      permit_i = 1;
      redirect('hc00);
      wait_offer();
      inject_valid = 1;
      inject_tag = owner_tag;
      inject_mask = owner_mask;
      inject_data = planned_data(owner_addr, owner_mask, 0);
      tick();
      inject_valid = 0;
      check(fatal_ref && i_req_valid_o && !accepted, "premature response released offered owner");
      block_accept = 0;
      /* the real later completion must remain recovery-only. */
      repeat (5) begin
        tick();
      end
      check(owner && recovered && fatal_ref, "late matching reply revived fatal stream");
      cold_start();
      /* an orphan reply cannot fabricate a transaction or an architectural result. */
      inject_valid = 1;
      inject_tag = 'hbad;
      inject_mask = 1;
      inject_data = 0;
      tick();
      inject_valid = 0;
      check(fatal_ref && !owner, "orphan response escaped containment");
      cold_start();
      fetch_one('hd00);
      /* a second reply for an ordinary released tag is a protocol failure. */
      inject_valid = 1;
      inject_tag = owner_tag;
      inject_mask = owner_mask;
      inject_data = planned_data(owner_addr, owner_mask, 0);
      tick();
      inject_valid = 0;
      check(fatal_ref && !owner, "duplicate completed response escaped containment");
      cold_start();
      /* unsafe cold reset is a failure signal, never a transaction cancellation. */
      block_accept = 1;
      permit_i = 1;
      wait_offer();
      isolated_i = 0;
      cold_reset_i = 1;
      tick();
      cold_reset_i = 0;
      check(fatal_ref && reason_ref == 4 && owner && i_req_valid_o,
            "unqualified cold reset erased an offered transaction");
      cold_start();
      check(instructions >= 25 && fault_packets >= 5 && unsupported_packets >= 1 &&
            held_output_cycles >= 20 && dropped >= 5 && zero_completions != 0 && ram_reads != 0,
            "fetch directed coverage was incomplete");
    end
    check(!owner && !ram_owned && !ram_valid && !fatal_ref, "finalization left an uncontained owner");
    check(offers == normal_releases + isolated_owners, "request conservation failed at finalization");
    $display("PASS fetch C=%0d scenario=%0d cycles=%0d instructions=%0d faults=%0d unsupported=%0d offers=%0d accepts=%0d replies=%0d deliveries=%0d drops=%0d contained=%0d RAM_reads=%0d zero=%0d wait_max=%0d wait_bound=%0d straddle_cycles=%0d",
             C_FETCH, SCENARIO, cycles, instructions, fault_packets, unsupported_packets,
             offers, accepts, replies, delivered, dropped, isolated_owners, ram_reads, zero_completions,
             max_output_wait, OUTPUT_PROGRESS_BOUND, straddle_cycles);
    $finish;
  end
endmodule

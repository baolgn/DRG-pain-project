/* retain complete records through reserved, capture, assembly, FIFO and DMA ownership. */
module drg5_acquisition_records #(
  parameter integer DEPTH = 256,
  parameter logic [63:0] COUNTER_LIMIT = 64'hffffffffffffffff
) (
  input logic clk_i, system_reset_i, inhibit_i,
  input logic bind_i,
  input logic [63:0] bind_epoch_i, bind_first_tick_i,
  output logic [3:0] bind_result_o,
  output logic [63:0] epoch_o, first_tick_o,
  output logic bound_o,
  input logic reserve_i,
  output logic reserve_ready_o,
  output logic [3:0] reserve_result_o,
  output logic reserved_o,
  output logic [63:0] reservation_id_o,
  input logic release_i,
  input logic [63:0] release_id_i,
  output logic [3:0] release_result_o,
  input logic admit_i,
  input logic [63:0] admit_id_i, admit_epoch_i, admit_slot_i, admit_tick_i,
  input logic admit_triggered_i,
  output logic [3:0] admit_result_o,
  input logic complete_valid_i,
  output logic complete_ready_o,
  input logic [63:0] complete_id_i,
  input logic [383:0] complete_record_i,
  output logic [3:0] complete_result_o,
  input logic cancel_i,
  input logic [63:0] cancel_epoch_i, cancel_slot_i,
  output logic [3:0] cancel_result_o,
  output logic dma_valid_o,
  input logic dma_ready_i,
  output logic [383:0] dma_record_o,
  output logic [63:0] dma_epoch_o, dma_slot_o,
  output logic dma_owned_o, dma_sent_o,
  input logic dma_done_i,
  input logic [63:0] dma_done_epoch_i, dma_done_slot_i,
  output logic [3:0] dma_done_result_o,
  output logic [8:0] owned_o, reserved_count_o, capture_count_o, missing_count_o,
  output logic [8:0] assembler_count_o, fifo_count_o, dma_count_o,
  output logic [63:0] allocated_o, unused_released_o, retired_o, admitted_o,
  output logic capture_idle_o,
  output logic [31:0] sticky_faults_o,
  output logic fault_o
);
  localparam integer PTR_W = $clog2(DEPTH);
  localparam logic [3:0] EMPTY = 0, ACCEPTED = 1, STALE = 2, BUSY = 3,
    INVALID = 4, TOO_LATE = 5, EXHAUSTED = 6, INHIBITED = 7;
  localparam logic [2:0] FREE = 0, RESERVED = 1, CAPTURE = 2, MISSING = 3,
    MISSING_TRIGGERED = 4, ASSEMBLER = 5, QUEUED = 6, DMA = 7;
  logic [2:0] state_q [0:DEPTH-1], state_d [0:DEPTH-1];
  logic [383:0] record_q [0:DEPTH-1];
  logic [63:0] slot_q [0:DEPTH-1];
  logic [PTR_W-1:0] head_q, head_d, tail_q, tail_d, reserve_index_q, reserve_index_d;
  logic [PTR_W-1:0] capture_index_q, capture_index_d, assembler_index_q, assembler_index_d;
  logic reserved_q, reserved_d, capture_q, capture_d, assembler_q, assembler_d;
  logic dma_q, dma_d, sent_q, sent_d, bound_q, bound_d;
  logic [63:0] epoch_q, epoch_d, first_tick_q, first_tick_d, head_slot_q, head_slot_d;
  logic [63:0] reservation_q, reservation_d, capture_token_q, capture_token_d;
  logic [63:0] allocated_q, allocated_d, released_q, released_d, retired_q, retired_d;
  logic [63:0] admitted_q, admitted_d, dma_slot_q, dma_slot_d;
  logic [383:0] assembler_record_q, assembler_record_d, dma_record_q, dma_record_d;
  logic [31:0] sticky_q, sticky_d, faults;
  logic [79:0] expected_tick;
  logic [65:0] accounted;
  logic [PTR_W-1:0] cancel_index, missing_index, scan_index;
  logic cancel_exists, completion_matches, missing_found;

  /* missing records contain no received bytes; only MISSING and optional TRIGGERED are set. */
  function automatic [383:0] placeholder(input logic triggered);
    logic [383:0] value;
    /* byte 44 begins the flags word in the frozen little-endian record. */
    begin
      value = '0;
      value[373] = 1'b1;
      value[368] = triggered;
      placeholder = value;
    end
  endfunction

  /* state counts include every reserved ring location, not just completed FIFO entries. */
  always_comb begin
    reserved_count_o = 0; capture_count_o = 0; missing_count_o = 0;
    assembler_count_o = 0; fifo_count_o = 0; dma_count_o = 0;
    missing_found = 0; missing_index = 0; scan_index = 0;
    /* scan from the ordered head so pending placeholders also make ordered progress. */
    for (integer offset = 0; offset < DEPTH; offset = offset + 1) begin
      scan_index = PTR_W'(head_q + PTR_W'(offset));
      case (state_q[scan_index])
        RESERVED: reserved_count_o = reserved_count_o + 1'b1;
        CAPTURE: capture_count_o = capture_count_o + 1'b1;
        MISSING, MISSING_TRIGGERED: missing_count_o = missing_count_o + 1'b1;
        ASSEMBLER: assembler_count_o = assembler_count_o + 1'b1;
        QUEUED: fifo_count_o = fifo_count_o + 1'b1;
        DMA: dma_count_o = dma_count_o + 1'b1;
        default: ;
      endcase
      /* retain only the oldest pending placeholder in this selection. */
      if (!missing_found && (state_q[scan_index] == MISSING || state_q[scan_index] == MISSING_TRIGGERED)) begin
        missing_found = 1; missing_index = scan_index;
      end
    end
    owned_o = reserved_count_o + capture_count_o + missing_count_o + assembler_count_o + fifo_count_o + dma_count_o;
  end

  assign epoch_o = epoch_q;
  assign first_tick_o = first_tick_q;
  assign bound_o = bound_q;
  assign reserved_o = reserved_q;
  assign reservation_id_o = reservation_q;
  assign allocated_o = allocated_q;
  assign unused_released_o = released_q;
  assign retired_o = retired_q;
  assign admitted_o = admitted_q;
  assign capture_idle_o = !capture_q;
  assign dma_valid_o = dma_q && !sent_q && !system_reset_i;
  assign dma_owned_o = dma_q;
  assign dma_sent_o = sent_q;
  assign dma_record_o = dma_record_q;
  assign dma_epoch_o = epoch_q;
  assign dma_slot_o = dma_slot_q;
  assign sticky_faults_o = sticky_q;
  assign expected_tick = {16'b0, first_tick_q} + {16'b0, admit_slot_i} * 80'd1600;
  assign accounted = {2'b0, released_q} + {2'b0, retired_q} + {57'b0, owned_o};
  assign cancel_index = PTR_W'(head_q + PTR_W'(cancel_slot_i - head_slot_q));
  assign cancel_exists = bound_q && cancel_epoch_i == epoch_q &&
    cancel_slot_i >= head_slot_q && cancel_slot_i < admitted_q;
  assign completion_matches = capture_q && complete_id_i == capture_token_q;
  assign reserve_ready_o = !system_reset_i && !bind_i && !inhibit_i && !reserved_q &&
    owned_o < 9'(DEPTH) && allocated_q < COUNTER_LIMIT && state_q[tail_q] == FREE;

  /* commands inspect pre-edge ownership; no operation borrows a same-edge returned credit. */
  always_comb begin
    bind_result_o = EMPTY; reserve_result_o = EMPTY; release_result_o = EMPTY;
    admit_result_o = EMPTY; cancel_result_o = EMPTY; complete_result_o = EMPTY;
    dma_done_result_o = EMPTY; complete_ready_o = !system_reset_i;
    /* binding keeps one optional anonymous reserve but cannot replace admitted owners. */
    if (bind_i) begin
      if (system_reset_i) bind_result_o = INHIBITED;
      else if (bind_epoch_i == 0 || bind_first_tick_i == 0) bind_result_o = INVALID;
      else if (bound_q && bind_epoch_i <= epoch_q) bind_result_o = STALE;
      else if (owned_o != reserved_count_o) bind_result_o = BUSY;
      else bind_result_o = ACCEPTED;
    end
    /* an unused reservation allocates a unique, nonwrapping lifetime token. */
    if (reserve_i) begin
      if (system_reset_i) reserve_result_o = INHIBITED;
      else if (bind_i) reserve_result_o = BUSY;
      else if (inhibit_i) reserve_result_o = INHIBITED;
      else if (reserved_q || owned_o >= 9'(DEPTH) || state_q[tail_q] != FREE) reserve_result_o = BUSY;
      else if (allocated_q == COUNTER_LIMIT) reserve_result_o = EXHAUSTED;
      else reserve_result_o = ACCEPTED;
    end
    /* only the current unused tail reservation may return capacity without a record. */
    if (release_i) begin
      if (system_reset_i) release_result_o = INHIBITED;
      else if (bind_i) release_result_o = BUSY;
      else if (!reserved_q || release_id_i != reservation_q) release_result_o = STALE;
      else release_result_o = ACCEPTED;
    end
    /* identity and widened grid arithmetic bind each admitted slot exactly once. */
    if (admit_i) begin
      if (system_reset_i) admit_result_o = INHIBITED;
      else if (bind_i || release_result_o == ACCEPTED) admit_result_o = BUSY;
      else if (!reserved_q || admit_id_i != reservation_q) admit_result_o = STALE;
      else if (!bound_q || admit_epoch_i != epoch_q || admit_slot_i != admitted_q) admit_result_o = STALE;
      else if (admit_slot_i == 64'hffffffffffffffff || expected_tick[79:64] != 0 ||
               admit_tick_i != expected_tick[63:0]) admit_result_o = INVALID;
      else if (admit_triggered_i && capture_q) admit_result_o = BUSY;
      else admit_result_o = ACCEPTED;
    end
    /* cancellation can replace only the unresolved synthetic conversion result. */
    if (cancel_i) begin
      if (system_reset_i) cancel_result_o = INHIBITED;
      else if (!cancel_exists) cancel_result_o = STALE;
      else if (state_q[cancel_index] != CAPTURE) cancel_result_o = TOO_LATE;
      else cancel_result_o = ACCEPTED;
    end
    /* a stale response is consumed as an error; an owned response waits for assembly. */
    if (complete_valid_i) begin
      if (system_reset_i) complete_result_o = INHIBITED;
      else if (!completion_matches) complete_result_o = STALE;
      else if (cancel_result_o == ACCEPTED) complete_result_o = TOO_LATE;
      /* the existing assembler remains immutable until its next-edge write. */
      else if (assembler_q) begin
        complete_result_o = BUSY; complete_ready_o = 0;
      end else complete_result_o = ACCEPTED;
    end
    /* DMA retirement requires an earlier accepted request with the same whole identity. */
    if (dma_done_i) begin
      if (system_reset_i) dma_done_result_o = INHIBITED;
      else if (!dma_q || dma_done_epoch_i != epoch_q || dma_done_slot_i != dma_slot_q)
        dma_done_result_o = STALE;
      else if (!sent_q) dma_done_result_o = TOO_LATE;
      else dma_done_result_o = ACCEPTED;
    end
  end

  /* each accepted transaction changes one owner; automatic movement never returns a credit. */
  always_comb begin
    /* preserve every ring owner unless its documented transition fires. */
    for (integer index = 0; index < DEPTH; index = index + 1) begin
      state_d[index] = state_q[index];
    end
    head_d = head_q; tail_d = tail_q; reserve_index_d = reserve_index_q;
    capture_index_d = capture_index_q; assembler_index_d = assembler_index_q;
    reserved_d = reserved_q; capture_d = capture_q; assembler_d = assembler_q;
    dma_d = dma_q; sent_d = sent_q; bound_d = bound_q;
    epoch_d = epoch_q; first_tick_d = first_tick_q; head_slot_d = head_slot_q;
    reservation_d = reservation_q; capture_token_d = capture_token_q;
    allocated_d = allocated_q; released_d = released_q; retired_d = retired_q;
    admitted_d = admitted_q; dma_slot_d = dma_slot_q;
    assembler_record_d = assembler_record_q; dma_record_d = dma_record_q;
    faults = 0; sticky_d = sticky_q;

    /* assembly writes its complete record into the already owned ring location. */
    if (assembler_q) begin
      state_d[assembler_index_q] = QUEUED; assembler_d = 0;
    end
    /* completion has priority over selecting a pending placeholder. */
    if (complete_valid_i && complete_ready_o && complete_result_o == ACCEPTED) begin
      assembler_d = 1; assembler_index_d = capture_index_q;
      assembler_record_d = complete_record_i;
      state_d[capture_index_q] = ASSEMBLER; capture_d = 0;
    /* only an empty pre-edge assembler accepts an automatically generated placeholder. */
    end else if (!assembler_q && missing_found) begin
      assembler_d = 1; assembler_index_d = missing_index;
      assembler_record_d = placeholder(state_q[missing_index] == MISSING_TRIGGERED);
      state_d[missing_index] = ASSEMBLER;
    end
    /* a cancellation retains the admitted slot rather than freeing its reserved storage. */
    if (cancel_result_o == ACCEPTED) begin
      state_d[cancel_index] = MISSING_TRIGGERED; capture_d = 0;
    end
    /* only the ordered head may become the single DMA-owned complete-record offer. */
    if (!dma_q && state_q[head_q] == QUEUED) begin
      dma_d = 1; sent_d = 0; dma_record_d = record_q[head_q]; dma_slot_d = slot_q[head_q];
      state_d[head_q] = DMA;
    end
    /* request acceptance retains the data until positive completion. */
    if (dma_valid_o && dma_ready_i) sent_d = 1;
    /* positive completion retires exactly one entry and advances the ordered head. */
    if (dma_done_result_o == ACCEPTED) begin
      state_d[head_q] = FREE; head_d = head_q + 1'b1; head_slot_d = head_slot_q + 1'b1;
      dma_d = 0; sent_d = 0; retired_d = retired_q + 1'b1;
    end
    /* binding uses the already parked ring and never revokes an anonymous reservation. */
    if (bind_result_o == ACCEPTED) begin
      bound_d = 1; epoch_d = bind_epoch_i; first_tick_d = bind_first_tick_i;
      admitted_d = 0; head_slot_d = 0;
    end
    /* reservation consumes pre-edge free capacity before a scheduler can admit the slot. */
    if (reserve_result_o == ACCEPTED) begin
      state_d[tail_q] = RESERVED; reserve_index_d = tail_q; tail_d = tail_q + 1'b1;
      reserved_d = 1; allocated_d = allocated_q + 1'b1; reservation_d = allocated_q + 1'b1;
    end
    /* an unused tail can roll back without changing admitted slot order. */
    if (release_result_o == ACCEPTED) begin
      state_d[reserve_index_q] = FREE; tail_d = reserve_index_q; reserved_d = 0;
      released_d = released_q + 1'b1;
    end
    /* result and placeholder share the same reservation and slot identity. */
    if (admit_result_o == ACCEPTED) begin
      reserved_d = 0; admitted_d = admitted_q + 1'b1;
      /* one triggered conversion may remain unresolved while later placeholders wait. */
      if (admit_triggered_i) begin
        state_d[reserve_index_q] = CAPTURE; capture_d = 1;
        capture_index_d = reserve_index_q; capture_token_d = reservation_q;
      /* a suppressed conversion still owns a complete future placeholder. */
      end else begin
        state_d[reserve_index_q] = MISSING;
      end
    end

    /* rejected identities and malformed transactions remain observable outside data queues. */
    if (bind_result_o == STALE || reserve_result_o == STALE || release_result_o == STALE ||
        admit_result_o == STALE || cancel_result_o == STALE || dma_done_result_o == STALE ||
        (complete_valid_i && complete_ready_o && complete_result_o == STALE)) faults[0] = 1;
    if (bind_result_o == INVALID || admit_result_o == INVALID) faults[1] = 1;
    if (cancel_result_o == TOO_LATE || dma_done_result_o == TOO_LATE ||
        (complete_valid_i && complete_ready_o && complete_result_o == TOO_LATE)) faults[2] = 1;
    if (reserve_result_o == EXHAUSTED) faults[3] = 1;
    /* cross-check capacity and singleton staging against the retained ring ledger. */
    if (reserved_count_o != {8'b0, reserved_q} || capture_count_o != {8'b0, capture_q} ||
        assembler_count_o != {8'b0, assembler_q} || dma_count_o != {8'b0, dma_q} ||
        owned_o > 9'(DEPTH) || accounted != {2'b0, allocated_q} ||
        (reserved_q && state_q[reserve_index_q] != RESERVED) ||
        (capture_q && state_q[capture_index_q] != CAPTURE) ||
        (assembler_q && state_q[assembler_index_q] != ASSEMBLER) ||
        (dma_q && (state_q[head_q] != DMA || dma_slot_q != head_slot_q))) faults[4] = 1;
    sticky_d = sticky_q | faults;
  end

  /* payload RAM has no destructive reset; valid ownership alone authorizes every read. */
  always_ff @(posedge clk_i) begin
    /* a reset edge cannot write an old assembler or fabricate a new slot tag. */
    if (!system_reset_i) begin
      if (assembler_q) record_q[assembler_index_q] <= assembler_record_q;
      if (admit_result_o == ACCEPTED) slot_q[reserve_index_q] <= admit_slot_i;
    end
  end

  /* only externally contained whole-domain reset destroys the local ownership history. */
  always_ff @(posedge clk_i) begin
    /* CPU reset is intentionally absent; integrations inhibit new reservations and drain. */
    if (system_reset_i) begin
      /* clearing owners does not claim that payload bytes have been erased. */
      for (integer index = 0; index < DEPTH; index = index + 1) begin
        state_q[index] <= FREE;
      end
      head_q <= 0; tail_q <= 0; reserve_index_q <= 0; capture_index_q <= 0; assembler_index_q <= 0;
      reserved_q <= 0; capture_q <= 0; assembler_q <= 0; dma_q <= 0; sent_q <= 0; bound_q <= 0;
      epoch_q <= 0; first_tick_q <= 0; head_slot_q <= 0; reservation_q <= 0; capture_token_q <= 0;
      allocated_q <= 0; released_q <= 0; retired_q <= 0; admitted_q <= 0; dma_slot_q <= 0;
      assembler_record_q <= 0; dma_record_q <= 0; sticky_q <= 0; fault_o <= 0;
    /* owned records and evidence progress independently of CPU execution and new admission. */
    end else begin
      /* each ring state commits once after all same-edge precedence has been resolved. */
      for (integer index = 0; index < DEPTH; index = index + 1) begin
        state_q[index] <= state_d[index];
      end
      head_q <= head_d; tail_q <= tail_d; reserve_index_q <= reserve_index_d;
      capture_index_q <= capture_index_d; assembler_index_q <= assembler_index_d;
      reserved_q <= reserved_d; capture_q <= capture_d; assembler_q <= assembler_d;
      dma_q <= dma_d; sent_q <= sent_d; bound_q <= bound_d;
      epoch_q <= epoch_d; first_tick_q <= first_tick_d; head_slot_q <= head_slot_d;
      reservation_q <= reservation_d; capture_token_q <= capture_token_d;
      allocated_q <= allocated_d; released_q <= released_d; retired_q <= retired_d;
      admitted_q <= admitted_d; dma_slot_q <= dma_slot_d;
      assembler_record_q <= assembler_record_d; dma_record_q <= dma_record_d;
      sticky_q <= sticky_d; fault_o <= faults != 0;
    end
  end

`ifndef SYNTHESIS
  /* reduced test depths retain the same power-of-two ring and nonzero identity capacity. */
  initial begin
    if (DEPTH < 2 || DEPTH > 256 || (DEPTH & (DEPTH - 1)) != 0 || COUNTER_LIMIT == 0)
      $fatal(1, "unsupported record reservation parameters");
  end
`endif
endmodule

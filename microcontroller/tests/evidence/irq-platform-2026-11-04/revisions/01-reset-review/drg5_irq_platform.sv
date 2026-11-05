/* retain machine interrupt sources independently of CPU issue, idle and hart reset. */
module drg5_irq_platform #(
  parameter integer BLOCK_CAPACITY = 64
) (
  input logic clk_i, system_reset_i,
  input logic command_i, write_i,
  input logic [31:0] addr_i, wdata_i,
  input logic [1:0] size_i,
  input logic [3:0] wstrb_i,
  input logic [31:1] event_set_i,
  input logic block_ready_i,
  output logic error_o,
  output logic [31:0] rdata_o, mip_levels_o,
  output logic [63:0] mtime_o, mtimecmp_o,
  output logic msip_o,
  output logic [31:0] ext_pending_o, ext_enable_o, block_count_o,
  output logic overflow_o, stop_o
);
  localparam integer COUNT_BITS = BLOCK_CAPACITY < 2 ? 1 : $clog2(BLOCK_CAPACITY + 1);
  logic [COUNT_BITS-1:0] count_q;
  logic [31:1] events_q, clear_events;
  logic known, direction_ok, legal_write, acknowledge;

`ifndef SYNTHESIS
  /* a finite notification ledger must fit its software-visible count. */
  initial begin
    assert (BLOCK_CAPACITY >= 1 && BLOCK_CAPACITY <= 65535)
      else $fatal(1, "invalid block notification capacity");
  end
`endif

  /* decode complete addresses and reject bad commands before any register action. */
  always_comb begin
    known = 1;
    direction_ok = 1;
    /* the timer aperture includes a separately declared external-event controller. */
    case (addr_i)
      /* these registers allow both reads and writes. */
      32'h40001000, 32'h40001004, 32'h40001008, 32'h4000100c,
      32'h40001010, 32'h40001014, 32'h40001018: begin end
      /* notification count and sticky overflow are read-only. */
      32'h4000101c, 32'h40001024: direction_ok = !write_i;
      /* an empty acknowledged queue rejects without consuming a simultaneous arrival. */
      32'h40001020: direction_ok = write_i && (!wdata_i[0] || count_q != 0);
      default: known = 0;
    endcase
    error_o = command_i && (!known || !direction_ok || size_i != 2 ||
        addr_i[1:0] != 0 || wstrb_i != (write_i ? 4'hf : 4'h0));
    legal_write = command_i && write_i && !error_o;
    acknowledge = legal_write && addr_i == 32'h40001020 && wdata_i[0];
    clear_events = legal_write && addr_i == 32'h40001014 ? wdata_i[31:1] : 31'b0;
    rdata_o = 0;
    /* accepted reads return pre-edge state without hidden snapshot or clear effects. */
    if (command_i && !write_i && !error_o) begin
      /* every legal read has one explicit register value. */
      case (addr_i)
        32'h40001000: rdata_o = mtime_o[31:0];
        32'h40001004: rdata_o = mtime_o[63:32];
        32'h40001008: rdata_o = mtimecmp_o[31:0];
        32'h4000100c: rdata_o = mtimecmp_o[63:32];
        32'h40001010: rdata_o = {31'b0, msip_o};
        32'h40001014: rdata_o = ext_pending_o;
        32'h40001018: rdata_o = ext_enable_o;
        32'h4000101c: rdata_o = block_count_o;
        32'h40001024: rdata_o = {31'b0, overflow_o};
        default: rdata_o = 0;
      endcase
    end
  end

  /* source levels remain visible while CPU or platform enable bits mask delivery. */
  always_comb begin
    block_count_o = 32'(count_q);
    ext_pending_o = {events_q, count_q != 0};
    mip_levels_o = 0;
    mip_levels_o[3] = msip_o;
    mip_levels_o[7] = mtime_o >= mtimecmp_o;
    mip_levels_o[11] = |(ext_pending_o & ext_enable_o);
    stop_o = overflow_o;
  end

  /* only qualified system reset clears the platform; hart reset has no connection. */
  always_ff @(posedge clk_i) begin
    /* events during held system reset are discarded with the stopped acquisition epoch. */
    if (system_reset_i) begin
      mtime_o <= 0;
      mtimecmp_o <= 64'hffffffffffffffff;
      msip_o <= 0;
      events_q <= 0;
      ext_enable_o <= 0;
      count_q <= 0;
      overflow_o <= 0;
    end
    /* this clock must continue during WFI and any future CPU debug halt. */
    else begin
      mtime_o <= mtime_o + 64'd1;
      events_q <= (events_q & ~clear_events) | event_set_i;
      /* an accepted decrement creates capacity for a same-edge block arrival. */
      if (block_ready_i && !acknowledge) begin
        /* saturation reports an unretained notification and requests hardware stop. */
        if (count_q == COUNT_BITS'(BLOCK_CAPACITY)) overflow_o <= 1;
        /* no notification wraps the count back to an apparently empty queue. */
        else count_q <= count_q + 1'b1;
      end
      /* simultaneous arrival and acknowledgement retain the previous count. */
      else if (acknowledge && !block_ready_i) begin
        count_q <= count_q - 1'b1;
      end
      /* a command pulse represents exactly one already accepted physical transaction. */
      if (legal_write) begin
        /* an mtime-half write overrides the entire coincident timer increment. */
        case (addr_i)
          32'h40001000: mtime_o <= {mtime_o[63:32], wdata_i};
          32'h40001004: mtime_o <= {wdata_i, mtime_o[31:0]};
          32'h40001008: mtimecmp_o[31:0] <= wdata_i;
          32'h4000100c: mtimecmp_o[63:32] <= wdata_i;
          32'h40001010: msip_o <= wdata_i[0];
          32'h40001018: ext_enable_o <= wdata_i;
          /* pending and acknowledgement writes are handled by their independent ledgers. */
          default: begin end
        endcase
      end
    end
  end
endmodule

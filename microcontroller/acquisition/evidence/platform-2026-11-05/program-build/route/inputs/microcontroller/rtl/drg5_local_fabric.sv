/* connect bounded local memories and MMIO without a store buffer or hidden retries. */
module drg5_local_fabric #(
  parameter ROM_FILE = "",
  parameter IRAM_FILE = "",
  parameter DRAM_FILE = ""
) (
  input logic clk_i, reset_i, isolated_i,
  input logic [3:0] i_accept_delay_i, i_response_delay_i,
  input logic [3:0] d_accept_delay_i, d_response_delay_i,
  input logic i_req_valid_i,
  output logic i_req_ready_o,
  input logic [31:0] i_req_addr_i, i_req_tag_i,
  input logic [1:0] i_req_parcels_i,
  output logic i_rsp_valid_o,
  input logic i_rsp_ready_i,
  output logic [31:0] i_rsp_tag_o, i_rsp_data_o,
  output logic [1:0] i_rsp_parcels_o, i_rsp_fault_o, i_rsp_status_o,
  input logic d_req_valid_i,
  output logic d_req_ready_o,
  input logic [31:0] d_req_addr_i, d_req_wdata_i, d_req_tag_i,
  input logic d_req_write_i,
  input logic [1:0] d_req_size_i,
  input logic [3:0] d_req_wstrb_i,
  output logic d_rsp_valid_o,
  input logic d_rsp_ready_i,
  output logic [31:0] d_rsp_tag_o, d_rsp_rdata_o,
  output logic [1:0] d_rsp_status_o,
  input logic [31:1] event_set_i,
  input logic block_ready_i,
  output logic [31:0] mip_levels_o, ext_pending_o, ext_enable_o,
  output logic [63:0] mtime_o,
  output logic status_write_o, output_valid_o,
  output logic [31:0] status_o,
  output logic [7:0] output_data_o,
  output logic busy_o
);
  logic [31:0] rom [0:2047];
  logic [31:0] iram [0:16383];
  logic [31:0] dram [0:8191];
  logic [31:0] i_rom_data_q, i_iram_data_q, d_rom_data_q, d_iram_data_q, d_dram_data_q;
  logic [31:0] d_peripheral_data_q, d_read_mask_q;
  logic [1:0] i_memory_select_q, d_memory_select_q;
  logic i_owned_q, i_accepted_q, d_owned_q, d_accepted_q;
  logic [3:0] i_accept_wait_q, i_response_wait_q, i_response_delay_q;
  logic [3:0] d_accept_wait_q, d_response_wait_q, d_response_delay_q;
  logic [31:0] i_addr_q, d_addr_q, d_wdata_q;
  logic [31:0] i_tag_q, d_tag_q;
  logic [1:0] i_parcels_q, d_size_q;
  logic d_write_q;
  logic [3:0] d_strobes_q;
  logic [31:0] i_addr, d_addr, d_wdata, d_read_mask;
  logic [1:0] i_parcels, d_size;
  logic d_write;
  logic [3:0] d_strobes, expected_strobes;
  logic i_accept, d_accept, i_rom, i_iram, d_rom, d_iram, d_dram;
  logic i_legal, d_shape, d_mmio, timer_command, timer_error, d_error;
  logic [31:0] timer_rdata, block_count;
  logic [63:0] mtimecmp;
  logic [31:1] injected_events;
  logic msip, overflow, stop;
  logic unused_observation;

  /* FPGA initialization loads images; reset never initializes ordinary RAM. */
  initial begin
    if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
    if (IRAM_FILE != "") $readmemh(IRAM_FILE, iram);
    if (DRAM_FILE != "") $readmemh(DRAM_FILE, dram);
  end

  /* native RAM read registers precede response selection and lane masking. */
  always_ff @(posedge clk_i) begin
    /* acceptance snapshots both instruction ports without reading peripheral regions. */
    if (!reset_i && i_accept && i_legal) begin
      if (i_rom) i_rom_data_q <= rom[i_addr[12:2]];
      if (i_iram) i_iram_data_q <= iram[i_addr[15:2]];
    end
    /* a data read has one registered memory source and no concurrent write on that port. */
    if (!reset_i && d_accept && !d_error && !d_write) begin
      if (d_rom) d_rom_data_q <= rom[d_addr[12:2]];
      if (d_iram) d_iram_data_q <= iram[d_addr[15:2]];
      if (d_dram) d_dram_data_q <= dram[d_addr[14:2]];
    end
  end

  /* selection and masks belong to the response owner and remain stable during backpressure. */
  assign i_rsp_data_o = (i_memory_select_q == 1 ? i_rom_data_q :
      i_memory_select_q == 2 ? i_iram_data_q : 32'b0) &
      {{16{i_rsp_parcels_o[1]}}, {16{i_rsp_parcels_o[0]}}};
  assign d_rsp_rdata_o = d_memory_select_q == 1 ? d_rom_data_q & d_read_mask_q :
      d_memory_select_q == 2 ? d_iram_data_q & d_read_mask_q :
      d_memory_select_q == 3 ? d_dram_data_q & d_read_mask_q : d_peripheral_data_q;

  /* first-valid ownership snapshots descriptors and independently sampled delay settings. */
  assign i_addr = i_owned_q ? i_addr_q : i_req_addr_i;
  assign i_parcels = i_owned_q ? i_parcels_q : i_req_parcels_i;
  assign d_addr = d_owned_q ? d_addr_q : d_req_addr_i;
  assign d_wdata = d_owned_q ? d_wdata_q : d_req_wdata_i;
  assign d_size = d_owned_q ? d_size_q : d_req_size_i;
  assign d_strobes = d_owned_q ? d_strobes_q : d_req_wstrb_i;
  assign d_write = d_owned_q ? d_write_q : d_req_write_i;
  assign i_rom = i_addr <= 32'h00001ffc;
  assign i_iram = i_addr >= 32'h00010000 && i_addr <= 32'h0001fffc;
  assign d_rom = d_addr <= 32'h00001fff;
  assign d_iram = d_addr >= 32'h00010000 && d_addr <= 32'h0001ffff;
  assign d_dram = d_addr >= 32'h20000000 && d_addr <= 32'h20007fff;
  assign i_legal = i_addr[1:0] == 0 && i_parcels != 0 && (i_rom || i_iram);
  assign expected_strobes = !d_write ? 4'b0 :
      d_size == 0 ? 4'b0001 << d_addr[1:0] :
      d_size == 1 ? 4'b0011 << d_addr[1:0] : 4'b1111;
  /* successful narrow reads expose only their addressed lanes, as the CPU bus requires. */
  assign d_read_mask = d_size == 0 ? 32'h000000ff << {d_addr[1:0], 3'b000} :
      d_size == 1 ? 32'h0000ffff << {d_addr[1:0], 3'b000} : 32'hffffffff;
  assign d_shape = d_size != 3 && (d_size == 0 || (d_size == 1 && !d_addr[0]) ||
      (d_size == 2 && d_addr[1:0] == 0)) && d_strobes == expected_strobes;
  assign d_mmio = d_size == 2 && d_addr[1:0] == 0 &&
      (d_addr == 32'h40000000 || d_addr == 32'h40000004 || d_addr == 32'h40000008);
  assign d_req_ready_o = !reset_i && !d_accepted_q &&
      (d_owned_q ? d_accept_wait_q == 0 : d_accept_delay_i == 0);
  assign d_accept = d_req_valid_i && d_req_ready_o;
  /* one accepted IRAM write wins a conflicting I-port read; the held fetch then retries admission. */
  assign i_req_ready_o = !reset_i && !i_accepted_q &&
      (i_owned_q ? i_accept_wait_q == 0 : i_accept_delay_i == 0) &&
      !(d_accept && d_write && d_iram && d_shape && i_iram);
  assign i_accept = i_req_valid_i && i_req_ready_o;
  assign i_rsp_valid_o = i_owned_q && i_accepted_q && i_response_wait_q == 0 && !reset_i;
  assign d_rsp_valid_o = d_owned_q && d_accepted_q && d_response_wait_q == 0 && !reset_i;
  assign busy_o = i_owned_q || d_owned_q;

  /* timer commands and latched event injection occur once at physical acceptance. */
  assign timer_command = d_accept && d_shape && d_addr >= 32'h40001000 && d_addr <= 32'h40001fff;
  assign injected_events = event_set_i | ((d_accept && d_shape && d_write &&
      d_addr == 32'h40000008 && d_size == 2 && d_wdata[0]) ? 31'd1 : 31'b0);
  assign d_error = !d_shape || (!(d_rom && !d_write) && !d_iram && !d_dram && !d_mmio && !timer_command) ||
      (timer_command && timer_error);
  drg5_irq_platform interrupt_sources (
    .clk_i, .system_reset_i(reset_i), .command_i(timer_command), .write_i(d_write),
    .addr_i(d_addr), .wdata_i(d_wdata), .size_i(d_size), .wstrb_i(d_strobes),
    .event_set_i(injected_events), .block_ready_i, .error_o(timer_error), .rdata_o(timer_rdata),
    .mip_levels_o, .mtime_o, .mtimecmp_o(mtimecmp), .msip_o(msip),
    .ext_pending_o, .ext_enable_o, .block_count_o(block_count), .overflow_o(overflow), .stop_o(stop)
  );

  /* synchronous memory reads capture the requested word at acceptance, never at presentation. */
  always_ff @(posedge clk_i) begin
    /* only isolated whole-platform reset cancels owned local transactions. */
    if (reset_i) begin
      i_owned_q <= 0;
      i_accepted_q <= 0;
      i_accept_wait_q <= 0;
      i_response_wait_q <= 0;
      i_response_delay_q <= 1;
      i_addr_q <= 0;
      i_tag_q <= 0;
      i_parcels_q <= 0;
      i_rsp_tag_o <= 0;
      i_memory_select_q <= 0;
      i_rsp_parcels_o <= 0;
      i_rsp_fault_o <= 0;
      i_rsp_status_o <= 0;
    /* request ownership survives redirects, CPU idle and all backpressure. */
    end else begin
      /* a zero-delay request can be captured and accepted on this same edge. */
      if (i_req_valid_i && !i_owned_q) begin
        i_owned_q <= 1;
        i_addr_q <= i_req_addr_i;
        i_tag_q <= i_req_tag_i;
        i_parcels_q <= i_req_parcels_i;
        i_accept_wait_q <= i_accept_delay_i == 0 ? 4'b0 : i_accept_delay_i - 1'b1;
        i_response_delay_q <= i_response_delay_i == 0 ? 4'd1 : i_response_delay_i;
      /* a retained first offer counts exactly its requested additional wait edges. */
      end else if (i_owned_q && !i_accepted_q && i_accept_wait_q != 0) begin
        i_accept_wait_q <= i_accept_wait_q - 1'b1;
      end
      /* reject the whole beat without touching peripheral regions. */
      if (i_accept) begin
        i_accepted_q <= 1;
        i_response_wait_q <= (i_owned_q ? i_response_delay_q :
            (i_response_delay_i == 0 ? 4'd1 : i_response_delay_i)) - 1'b1;
        i_rsp_tag_o <= i_owned_q ? i_tag_q : i_req_tag_i;
        i_rsp_parcels_o <= i_parcels;
        i_rsp_status_o <= i_legal ? 2'd0 : 2'd1;
        i_rsp_fault_o <= i_legal ? 2'd0 : i_parcels;
        /* absent parcels are canonical zeros even when their neighboring word is readable. */
        if (i_legal) begin
          i_memory_select_q <= i_rom ? 2'd1 : 2'd2;
        end else i_memory_select_q <= 0;
      /* elapsed response clocks never re-read modified memory. */
      end else if (i_accepted_q && i_response_wait_q != 0) begin
        i_response_wait_q <= i_response_wait_q - 1'b1;
      end
      /* no second request is accepted until the prior response is consumed. */
      if (i_rsp_valid_o && i_rsp_ready_i) begin
        i_owned_q <= 0;
        i_accepted_q <= 0;
      end
    end
  end

  /* data side effects occur once at acceptance and never repeat while a reply is stalled. */
  always_ff @(posedge clk_i) begin
    status_write_o <= 0;
    output_valid_o <= 0;
    /* platform reset clears peripheral state, but neither RAM nor ROM contents. */
    if (reset_i) begin
      d_owned_q <= 0;
      d_accepted_q <= 0;
      d_accept_wait_q <= 0;
      d_response_wait_q <= 0;
      d_response_delay_q <= 1;
      d_addr_q <= 0;
      d_wdata_q <= 0;
      d_tag_q <= 0;
      d_size_q <= 0;
      d_write_q <= 0;
      d_strobes_q <= 0;
      d_rsp_tag_o <= 0;
      d_memory_select_q <= 0;
      d_read_mask_q <= 0;
      d_peripheral_data_q <= 0;
      d_rsp_status_o <= 0;
      status_o <= 0;
      output_data_o <= 0;
    /* delayed requests retain their original target and value. */
    end else begin
      /* latch admission and completion delays independently on first presentation. */
      if (d_req_valid_i && !d_owned_q) begin
        d_owned_q <= 1;
        d_addr_q <= d_req_addr_i;
        d_wdata_q <= d_req_wdata_i;
        d_tag_q <= d_req_tag_i;
        d_size_q <= d_req_size_i;
        d_write_q <= d_req_write_i;
        d_strobes_q <= d_req_wstrb_i;
        d_accept_wait_q <= d_accept_delay_i == 0 ? 4'b0 : d_accept_delay_i - 1'b1;
        d_response_delay_q <= d_response_delay_i == 0 ? 4'd1 : d_response_delay_i;
      /* count only pre-acceptance edges for this owner. */
      end else if (d_owned_q && !d_accepted_q && d_accept_wait_q != 0) begin
        d_accept_wait_q <= d_accept_wait_q - 1'b1;
      end
      /* reads capture pre-edge peripheral state; errors have no effects and zero data. */
      if (d_accept) begin
        d_accepted_q <= 1;
        d_response_wait_q <= (d_owned_q ? d_response_delay_q :
            (d_response_delay_i == 0 ? 4'd1 : d_response_delay_i)) - 1'b1;
        d_rsp_tag_o <= d_owned_q ? d_tag_q : d_req_tag_i;
        d_rsp_status_o <= d_error ? 2'd1 : 2'd0;
        d_memory_select_q <= 0;
        d_read_mask_q <= d_read_mask;
        d_peripheral_data_q <= 0;
        /* a valid store updates only its declared little-endian lanes. */
        if (!d_error && d_write) begin
          /* independent byte enables infer the local synchronous RAM write ports. */
          for (integer lane = 0; lane < 4; lane = lane + 1) begin
            /* read-only ROM and peripheral accesses cannot enter a RAM write port. */
            if (d_strobes[lane] && d_iram) iram[d_addr[15:2]][lane*8 +: 8] <= d_wdata[lane*8 +: 8];
            if (d_strobes[lane] && d_dram) dram[d_addr[14:2]][lane*8 +: 8] <= d_wdata[lane*8 +: 8];
          end
          /* the output and status registers preserve accepted values across response stalls. */
          if (d_addr == 32'h40000000) begin
            status_o <= d_wdata;
            status_write_o <= 1;
          end
          /* output is a one-cycle strobe with the low byte of an aligned word write. */
          if (d_addr == 32'h40000004) begin
            output_data_o <= d_wdata[7:0];
            output_valid_o <= 1;
          end
        /* mask unused lanes before the CPU performs width extraction and extension. */
        end else if (!d_error) begin
          if (d_rom) d_memory_select_q <= 1;
          else if (d_iram) d_memory_select_q <= 2;
          else if (d_dram) d_memory_select_q <= 3;
          else if (timer_command) d_peripheral_data_q <= timer_rdata;
          else if (d_addr == 32'h40000000) d_peripheral_data_q <= status_o;
          else if (d_addr == 32'h40000004) d_peripheral_data_q <= {24'b0, output_data_o};
        end
      /* completion latency expires independently of downstream response readiness. */
      end else if (d_accepted_q && d_response_wait_q != 0) begin
        d_response_wait_q <= d_response_wait_q - 1'b1;
      end
      /* consuming a response frees exactly its original owner. */
      if (d_rsp_valid_o && d_rsp_ready_i) begin
        d_owned_q <= 0;
        d_accepted_q <= 0;
      end
    end
  end

`ifndef SYNTHESIS
  /* malformed ownership is a test failure rather than a silently repaired request. */
  always_ff @(posedge clk_i) begin
    if (reset_i) assert (isolated_i) else $fatal(1, "local reset requires isolation");
    /* a producer must hold valid and the complete descriptor until acceptance. */
    if (!reset_i && i_owned_q && !i_accepted_q) begin
      assert (i_req_valid_i && {i_req_addr_i, i_req_tag_i, i_req_parcels_i} ==
          {i_addr_q, i_tag_q, i_parcels_q}) else $fatal(1, "unstable local I offer");
    end
    /* stores retain byte enables and data even when the addressed target is invalid. */
    if (!reset_i && d_owned_q && !d_accepted_q) begin
      assert (d_req_valid_i && {d_req_addr_i, d_req_wdata_i, d_req_tag_i, d_req_size_i, d_req_write_i, d_req_wstrb_i} ==
          {d_addr_q, d_wdata_q, d_tag_q, d_size_q, d_write_q, d_strobes_q}) else $fatal(1, "unstable local D offer");
    end
  end
`endif

  /* retain named timer diagnostics without introducing control dependencies. */
  assign unused_observation = ^{mtimecmp, msip, block_count, overflow, stop, isolated_i};
endmodule

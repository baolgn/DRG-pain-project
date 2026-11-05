/* validate one data transfer and form little-endian lanes without owning a bus request. */
module drg5_lsu #(
  parameter bit TEST_REGIONS = 0,
  parameter bit IRAM_WRITE = 0,
  parameter bit TIMER_ENABLED = 0
) (
  input logic [31:0] addr_i, store_value_i, rsp_data_i,
  input logic [1:0] size_i,
  input logic write_i, signed_i,
  output logic allowed_o, misaligned_o,
  output logic [31:0] cause_o, wdata_o, load_value_o,
  output logic [3:0] wstrb_o
);
  logic [32:0] last_address;
  logic region_allowed;
  logic [31:0] selected_data;

  /* a widened inclusive endpoint rejects wrap and requires the whole footprint. */
  always_comb begin
    last_address = {1'b0, addr_i} +
                   (size_i == 0 ? 33'd0 : size_i == 1 ? 33'd1 : 33'd3);
    misaligned_o = (size_i == 1 && addr_i[0]) || (size_i == 2 && addr_i[1:0] != 0);
    region_allowed =
        (!write_i && addr_i <= 32'h00001fff && last_address <= 33'h000001fff) ||
        ((!write_i || IRAM_WRITE) && addr_i >= 32'h00010000 && last_address <= 33'h00001ffff) ||
        (addr_i >= 32'h20000000 && last_address <= 33'h020007fff) ||
        (size_i == 2 && addr_i >= 32'h40000000 && last_address <= 33'h040000fff) ||
        (TIMER_ENABLED && size_i == 2 && addr_i >= 32'h40001000 && last_address <= 33'h040001fff) ||
        (TEST_REGIONS && addr_i >= 32'h50001000 && last_address <= 33'h050001fff) ||
        (TEST_REGIONS && addr_i >= 32'h50002000 && last_address <= 33'h050002fff);
    allowed_o = size_i != 3 && !misaligned_o && !last_address[32] && region_allowed;
    cause_o = allowed_o ? 32'd0 : misaligned_o ? (write_i ? 32'd6 : 32'd4) :
                                                     (write_i ? 32'd7 : 32'd5);
    selected_data = rsp_data_i >> {addr_i[1:0], 3'b000};
    wdata_o = 0;
    wstrb_o = 0;
    load_value_o = 0;
    /* a denied operation has no active byte lanes or consumable load result. */
    if (allowed_o) begin
      /* only the requested low source bytes enter the addressed write lanes. */
      if (write_i) begin
        /* byte and halfword masking prevents neighboring-lane data leakage. */
        case (size_i)
          /* a byte enables exactly its addressed lane. */
          0: begin
            wdata_o = {24'b0, store_value_i[7:0]} << {addr_i[1:0], 3'b000};
            wstrb_o = 4'b0001 << addr_i[1:0];
          end
          /* natural halfword alignment restricts the lane to zero or two. */
          1: begin
            wdata_o = {16'b0, store_value_i[15:0]} << {addr_i[1:0], 3'b000};
            wstrb_o = 4'b0011 << addr_i[1:0];
          end
          /* an allowed word always starts at lane zero. */
          2: begin
            wdata_o = store_value_i;
            wstrb_o = 4'b1111;
          end
          /* rejected widths cannot reach an active store. */
          default: begin end
        endcase
      end
      /* successful reads extract their lane before applying the requested extension. */
      else begin
        /* signedness affects only narrow loads; word data are unchanged. */
        case (size_i)
          0: load_value_o = {{24{signed_i && selected_data[7]}}, selected_data[7:0]};
          1: load_value_o = {{16{signed_i && selected_data[15]}}, selected_data[15:0]};
          2: load_value_o = selected_data;
          /* rejected widths cannot reach an active load. */
          default: begin end
        endcase
      end
    end
  end
endmodule

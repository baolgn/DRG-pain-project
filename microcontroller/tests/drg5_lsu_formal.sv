/* prove LSU permissions and byte routing for every two-state input. */
module drg5_lsu_formal #(
  parameter TEST_REGIONS = 0,
  parameter IRAM_WRITE = 0,
  parameter TIMER_ENABLED = 0,
  parameter MUTATE_STORE = 0
) (
  input [31:0] addr_i, store_value_i, rsp_data_i,
  input [1:0] size_i,
  input write_i, signed_i
);
  wire allowed_o, misaligned_o;
  wire [31:0] cause_o, wdata_o, load_value_o;
  wire [3:0] wstrb_o;
  reg expected_allowed, expected_misaligned, byte_allowed;
  reg [31:0] expected_cause, expected_store, expected_load;
  reg [3:0] expected_strobes;
  reg [32:0] byte_address;
  integer count, lane;

  /* instantiate the same public helper under each independently qualified option set. */
  drg5_lsu #(.TEST_REGIONS(TEST_REGIONS), .IRAM_WRITE(IRAM_WRITE),
             .TIMER_ENABLED(TIMER_ENABLED)) dut (.*);

  /* inspect every constituent byte rather than copying the DUT endpoint comparison. */
  always @* begin
    count = size_i == 3 ? 0 : 1 << size_i;
    lane = addr_i % 4;
    expected_misaligned = 0;
    /* modulo defines natural alignment independently of individual address-bit tests. */
    case (size_i)
      1: expected_misaligned = (addr_i % 2) != 0;
      2: expected_misaligned = (addr_i % 4) != 0;
      default: expected_misaligned = 0;
    endcase
    expected_allowed = count != 0 && !expected_misaligned;
    byte_address = 0;
    byte_allowed = 0;
    /* fixed region prefixes are checked separately for every required byte. */
    for (integer offset = 0; offset < 4; offset = offset + 1) begin
      byte_address = {1'b0, addr_i} + 33'(offset);
      byte_allowed = !byte_address[32] &&
          ((!write_i && byte_address[31:13] == 0) ||
           ((!write_i || IRAM_WRITE) && byte_address[31:16] == 16'h0001) ||
           (byte_address[31:15] == 17'h04000) ||
           (size_i == 2 && byte_address[31:12] == 20'h40000) ||
           (TIMER_ENABLED && size_i == 2 && byte_address[31:12] == 20'h40001) ||
           (TEST_REGIONS && (byte_address[31:12] == 20'h50001 || byte_address[31:12] == 20'h50002)));
      /* inactive byte positions impose no permission on a shorter access. */
      if (offset < count) expected_allowed = expected_allowed && byte_allowed;
    end
    expected_cause = expected_allowed ? 0 : expected_misaligned ? (write_i ? 6 : 4) : (write_i ? 7 : 5);
    expected_store = 0;
    expected_load = 0;
    expected_strobes = 0;
    /* map individual bits so masking, extraction and extension have independent oracles. */
    if (expected_allowed) begin
      /* each enabled store byte comes from the corresponding low source byte. */
      if (write_i) begin
        /* enumerate the actual transferred bytes without a shifted store expression. */
        for (integer offset = 0; offset < 4; offset = offset + 1) begin
          /* natural alignment keeps every active lane within the one bus word. */
          if (offset < count) begin
            expected_store[8*(lane + offset) +: 8] = store_value_i[8*offset +: 8];
            expected_strobes[lane + offset] = 1;
          end
        end
      end
      /* sign extension repeats the selected field's sign only above its actual width. */
      else begin
        /* every result bit has an explicit data or extension source. */
        for (integer bit_number = 0; bit_number < 32; bit_number = bit_number + 1) begin
          /* low result bits route directly from the addressed response lane. */
          if (bit_number < 8*count) expected_load[bit_number] = rsp_data_i[8*lane + bit_number];
          /* upper bits repeat only the requested narrow signed field. */
          else expected_load[bit_number] = signed_i && rsp_data_i[8*(lane + count) - 1];
        end
      end
    end
    /* all outputs remain constrained on denied, read and write inputs. */
    assert(allowed_o == expected_allowed);
    assert(misaligned_o == expected_misaligned);
    assert(cause_o == expected_cause);
    assert(wdata_o == (expected_store ^ ((MUTATE_STORE && expected_allowed && write_i) ? 32'd1 : 32'd0)));
    assert(wstrb_o == expected_strobes);
    assert(load_value_o == expected_load);
  end
endmodule

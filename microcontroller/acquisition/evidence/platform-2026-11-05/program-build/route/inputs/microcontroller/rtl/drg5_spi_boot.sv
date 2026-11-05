/* validate persistent application banks before releasing the CPU from reset. */
module drg5_spi_boot #(
  parameter logic [31:0] ROM_CRC32 = 32'b0,
  parameter integer HALF_PERIOD = 2,
  parameter integer WRITE_MAX_WAIT = 128
) (
  input logic clk_i, reset_i, force_a_i,
  input logic flash_miso_i,
  output logic flash_cs_n_o, flash_sck_o, flash_mosi_o,
  output logic write_valid_o,
  input logic write_ready_i, write_error_i,
  output logic [31:0] write_addr_o, write_data_o,
  output logic busy_o, done_o, fault_o, selected_bank_o,
  output logic [1:0] valid_headers_o,
  output logic [3:0] reason_o
);
  localparam integer WAIT_BITS = WRITE_MAX_WAIT < 2 ? 1 : $clog2(WRITE_MAX_WAIT);
  typedef enum logic [3:0] {
    INITIAL, HEADER_START, HEADER_BYTES, HEADER_DONE, COMMIT_START,
    COMMIT_BYTES, COMMIT_DONE, SELECT_BANK, PAYLOAD_START, PAYLOAD_BYTES,
    WRITE_WAIT, PAYLOAD_CHECK, COMPLETE, FAILED, DRAIN
  } state_t;
  state_t state_q;
  logic force_a_q, header_bank_q, selected_q;
  logic [1:0] header_valid_q, attempted_q;
  logic [31:0] generation_q [0:1];
  logic [31:0] payload_crc_q [0:1];
  logic header_invalid_q;
  logic [7:0] header_byte_q;
  logic [1:0] commit_byte_q;
  logic [16:0] payload_byte_q;
  logic [23:0] word_q;
  logic [31:0] header_crc_q, data_crc_q;
  logic [WAIT_BITS-1:0] write_wait_q;
  logic spi_start_q, spi_valid, spi_ready, spi_busy, spi_done;
  logic [23:0] spi_address_q;
  logic [16:0] spi_length_q;
  logic [7:0] spi_byte;
  logic [31:0] assembled_word;
  logic unused_spi_state;

  /* CRC-32/ISO-HDLC uses reflected polynomial, all-one initialization and final inversion. */
  function automatic logic [31:0] crc_byte(input logic [31:0] current, input logic [7:0] value);
    logic [31:0] next_crc;
    next_crc = current ^ {24'b0, value};
    /* each received byte advances exactly eight polynomial steps. */
    for (integer bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
      next_crc = (next_crc >> 1) ^ (next_crc[0] ? 32'hedb88320 : 32'b0);
    end
    return next_crc;
  endfunction

  /* all transfers use standard SPI reads; this engine cannot program or erase flash. */
  drg5_spi_read #(.HALF_PERIOD(HALF_PERIOD)) reader (
    .clk_i, .reset_i(reset_i || fault_o), .start_i(spi_start_q), .address_i(spi_address_q),
    .length_i(spi_length_q), .miso_i(flash_miso_i), .cs_n_o(flash_cs_n_o), .sck_o(flash_sck_o),
    .mosi_o(flash_mosi_o), .byte_valid_o(spi_valid), .byte_ready_i(spi_ready), .byte_o(spi_byte),
    .busy_o(spi_busy), .done_o(spi_done)
  );
  assign assembled_word = {spi_byte, word_q[23:0]};
  assign spi_ready = state_q == HEADER_BYTES || state_q == COMMIT_BYTES || state_q == PAYLOAD_BYTES;
  assign selected_bank_o = selected_q;
  assign valid_headers_o = header_valid_q;
  assign busy_o = state_q != COMPLETE && state_q != FAILED;
  assign done_o = state_q == COMPLETE;
  assign unused_spi_state = spi_busy;

  /* header validity, word ownership and CRC state advance only on their actual handshakes. */
  always_ff @(posedge clk_i) begin
    spi_start_q <= 0;
    /* whole-platform reset is the only cancellation of an exposed boot memory write. */
    if (reset_i) begin
      state_q <= INITIAL;
      force_a_q <= 0;
      header_bank_q <= 0;
      selected_q <= 0;
      header_valid_q <= 0;
      attempted_q <= 0;
      generation_q[0] <= 0;
      generation_q[1] <= 0;
      payload_crc_q[0] <= 0;
      payload_crc_q[1] <= 0;
      header_invalid_q <= 0;
      header_byte_q <= 0;
      commit_byte_q <= 0;
      payload_byte_q <= 0;
      word_q <= 0;
      header_crc_q <= '1;
      data_crc_q <= '1;
      write_wait_q <= 0;
      spi_address_q <= 0;
      spi_length_q <= 0;
      write_valid_o <= 0;
      write_addr_o <= 0;
      write_data_o <= 0;
      fault_o <= 0;
      reason_o <= 0;
    /* every boot attempt terminates in a validated image or a reset-held failure. */
    end else begin
      case (state_q)
        /* the surrounding board synchronizes a held recovery switch before this sample. */
        INITIAL: begin
          force_a_q <= force_a_i;
          state_q <= HEADER_START;
        end
        /* each bank header is read independently of application memory contents. */
        HEADER_START: begin
          spi_address_q <= header_bank_q ? 24'h420000 : 24'h400000;
          spi_length_q <= 256;
          spi_start_q <= 1;
          header_byte_q <= 0;
          header_crc_q <= '1;
          header_invalid_q <= 0;
          word_q <= 0;
          state_q <= HEADER_BYTES;
        end
        /* malformed fields reject a bank without issuing any IRAM write. */
        HEADER_BYTES: begin
          /* byte order is little-endian for header words and payload words. */
          if (spi_valid) begin
            if (header_byte_q[1:0] != 3) word_q[header_byte_q[1:0]*8 +: 8] <= spi_byte;
            if (header_byte_q < 248) header_crc_q <= crc_byte(header_crc_q, spi_byte);
            /* every fixed field and reserved word has one defined accepted value. */
            if (header_byte_q[1:0] == 3) begin
              case (header_byte_q[7:2])
                0: if (assembled_word != 32'h35475244) header_invalid_q <= 1;
                1: if (assembled_word != 1) header_invalid_q <= 1;
                2: if (assembled_word != 65536) header_invalid_q <= 1;
                3, 4: if (assembled_word != 32'h00010000) header_invalid_q <= 1;
                5: generation_q[header_bank_q] <= assembled_word;
                6: payload_crc_q[header_bank_q] <= assembled_word;
                7: if (assembled_word != ROM_CRC32) header_invalid_q <= 1;
                8: if (assembled_word != 1) header_invalid_q <= 1;
                62: if (assembled_word != ~header_crc_q) header_invalid_q <= 1;
                default: if (assembled_word != 0) header_invalid_q <= 1;
              endcase
            end
            /* the final reserved word is checked before the later commit marker. */
            if (header_byte_q == 255) state_q <= HEADER_DONE;
            else header_byte_q <= header_byte_q + 1'b1;
          end
        end
        /* separate transactions guarantee chip-select deselection between header and commit. */
        HEADER_DONE: if (spi_done) state_q <= COMMIT_START;
        /* the commit lives in its own erase sector at the end of the 128 KiB bank. */
        COMMIT_START: begin
          spi_address_q <= header_bank_q ? 24'h43fffc : 24'h41fffc;
          spi_length_q <= 4;
          spi_start_q <= 1;
          commit_byte_q <= 0;
          word_q <= 0;
          state_q <= COMMIT_BYTES;
        end
        /* a torn or absent commit can never authorize payload execution. */
        COMMIT_BYTES: begin
          /* accumulate the separately programmed four-byte marker. */
          if (spi_valid) begin
            if (commit_byte_q != 3) word_q[commit_byte_q*8 +: 8] <= spi_byte;
            /* header and commit must both be valid before bank selection. */
            if (commit_byte_q == 3) begin
              header_valid_q[header_bank_q] <= !header_invalid_q && assembled_word == 32'h54494d43;
              state_q <= COMMIT_DONE;
            end else commit_byte_q <= commit_byte_q + 1'b1;
          end
        end
        /* both header records are complete before applying generation ordering. */
        COMMIT_DONE: begin
          /* completion belongs only to the current reader command. */
          if (spi_done) begin
            /* inspect bank B even when bank A's header is invalid. */
            if (!header_bank_q) begin
              header_bank_q <= 1;
              state_q <= HEADER_START;
            end else state_q <= SELECT_BANK;
          end
        end
        /* generations use ordinary unsigned ordering; equal generations select golden bank A. */
        SELECT_BANK: begin
          /* forced recovery never silently executes bank B. */
          if (force_a_q && !header_valid_q[0]) begin
            fault_o <= 1;
            reason_o <= 2;
            state_q <= FAILED;
          /* absent valid headers leave the independent configuration port as recovery. */
          end else if (header_valid_q == 0) begin
            fault_o <= 1;
            reason_o <= 1;
            state_q <= FAILED;
          /* select one candidate, retaining the other only as a CRC-failure fallback. */
          end else begin
            selected_q <= !force_a_q && header_valid_q[1] &&
                (!header_valid_q[0] || generation_q[1] > generation_q[0]);
            state_q <= PAYLOAD_START;
          end
        end
        /* a complete 64 KiB payload overwrites every executable application word. */
        PAYLOAD_START: begin
          spi_address_q <= selected_q ? 24'h420100 : 24'h400100;
          spi_length_q <= 65536;
          spi_start_q <= 1;
          payload_byte_q <= 0;
          data_crc_q <= '1;
          word_q <= 0;
          attempted_q[selected_q] <= 1;
          state_q <= PAYLOAD_BYTES;
        end
        /* one assembled word is exposed only after all four bytes have arrived. */
        PAYLOAD_BYTES: begin
          /* the pending word stalls stream consumption until its memory response completes. */
          if (spi_valid) begin
            if (payload_byte_q[1:0] != 3) word_q[payload_byte_q[1:0]*8 +: 8] <= spi_byte;
            data_crc_q <= crc_byte(data_crc_q, spi_byte);
            payload_byte_q <= payload_byte_q + 1'b1;
            /* stable aligned writes use the existing single-owner data-memory adapter. */
            if (payload_byte_q[1:0] == 3) begin
              write_addr_o <= 32'h00010000 + {15'b0, payload_byte_q[16:2], 2'b0};
              write_data_o <= assembled_word;
              write_valid_o <= 1;
              write_wait_q <= 0;
              state_q <= WRITE_WAIT;
            end
          end
        end
        /* ready means completed response, not mere request acceptance. */
        WRITE_WAIT: begin
          /* completed errors prevent release and cannot trigger unsafe replay. */
          if (write_ready_i) begin
            write_valid_o <= 0;
            /* a failed target response cannot establish a valid executable image. */
            if (write_error_i) begin
              fault_o <= 1;
              reason_o <= 4;
              state_q <= FAILED;
            end else state_q <= payload_byte_q == 65536 ? PAYLOAD_CHECK : PAYLOAD_BYTES;
          /* an uncertain timeout retains the exposed word until a late response or isolated reset. */
          end else if (write_wait_q == WAIT_BITS'(WRITE_MAX_WAIT - 1)) begin
            fault_o <= 1;
            reason_o <= 5;
            state_q <= DRAIN;
          end else write_wait_q <= write_wait_q + 1'b1;
        end
        /* release follows both the final write response and complete-payload CRC validation. */
        PAYLOAD_CHECK: begin
          if (~data_crc_q == payload_crc_q[selected_q]) state_q <= COMPLETE;
          /* a rejected application is overwritten completely by the other committed candidate. */
          else if (!force_a_q && header_valid_q[!selected_q] && !attempted_q[!selected_q]) begin
            selected_q <= !selected_q;
            state_q <= PAYLOAD_START;
          /* corrupt forced recovery or two corrupt payloads remain safely halted. */
          end else begin
            fault_o <= 1;
            reason_o <= 3;
            state_q <= FAILED;
          end
        end
        /* a timeout never withdraws or replays an externally owned write. */
        DRAIN: begin
          /* late completion drains the original owner but cannot restore boot success. */
          if (write_ready_i) begin
            write_valid_o <= 0;
            state_q <= FAILED;
          end
        end
        default: state_q <= state_q;
      endcase
    end
  end

`ifndef SYNTHESIS
  /* finite write service is a platform assumption, not permission to cancel an owner. */
  initial begin
    assert (WRITE_MAX_WAIT >= 1) else $fatal(1, "boot write bound must be positive");
  end
`endif
endmodule

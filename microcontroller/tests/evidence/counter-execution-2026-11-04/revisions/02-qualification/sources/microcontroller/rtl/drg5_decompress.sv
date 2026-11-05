/* classify RV32C integer encodings and expand legal instructions without changing raw bytes. */
module drg5_decompress (
  input logic [15:0] instr_i,
  output logic [31:0] expanded_o,
  output logic legal_o, hint_o,
  output logic [1:0] class_o
);
  localparam logic [1:0] ILLEGAL = 0, ORDINARY = 1, HINT = 2, WIDE = 3;
  logic [4:0] rd, rs2, compact_rd, compact_rs1;
  logic [11:0] immediate, offset;
  logic [20:1] jump_offset;
  logic [12:1] branch_offset;

  /* assemble the standard I format from already extended operands. */
  function automatic logic [31:0] encode_i(input logic [6:0] opcode,
      input logic [2:0] funct3, input logic [4:0] dest, source, input logic [11:0] imm);
    return {imm, source, funct3, dest, opcode};
  endfunction

  /* assemble the standard R format without signed expression sizing. */
  function automatic logic [31:0] encode_r(input logic [6:0] funct7,
      input logic [2:0] funct3, input logic [4:0] dest, source1, source2);
    return {funct7, source2, source1, funct3, dest, 7'h33};
  endfunction

  /* assemble word stores from a byte offset. */
  function automatic logic [31:0] encode_store(input logic [4:0] source1, source2,
      input logic [11:0] imm);
    return {imm[11:5], source2, source1, 3'b010, imm[4:0], 7'h23};
  endfunction

  /* extract every compressed immediate with explicit destination bit positions. */
  always_comb begin
    rd = instr_i[11:7];
    rs2 = instr_i[6:2];
    compact_rd = {2'b01, instr_i[4:2]};
    compact_rs1 = {2'b01, instr_i[9:7]};
    immediate = {{6{instr_i[12]}}, instr_i[12], instr_i[6:2]};
    offset = 0;
    jump_offset = {{9{instr_i[12]}}, instr_i[12], instr_i[8], instr_i[10:9],
                   instr_i[6], instr_i[7], instr_i[2], instr_i[11], instr_i[5:3]};
    branch_offset = {{4{instr_i[12]}}, instr_i[12], instr_i[6:5], instr_i[2],
                     instr_i[11:10], instr_i[4:3]};
    expanded_o = 0;
    class_o = ILLEGAL;
    /* reject absent floating-point, RV64 and unallocated extension encodings. */
    case (instr_i[1:0])
      /* quadrant zero contains stack-address generation and compact word memory. */
      2'b00: begin
        /* only these integer operations exist in this RV32 profile. */
        case (instr_i[15:13])
          /* C.ADDI4SPN forbids its zero immediate, including all-zero encoding. */
          3'b000: begin
            offset = {2'b0, instr_i[10:7], instr_i[12:11], instr_i[5], instr_i[6], 2'b0};
            /* the reserved zero case never becomes a HINT. */
            if (offset != 0) begin
              class_o = ORDINARY;
              expanded_o = encode_i(7'h13, 0, compact_rd, 5'd2, offset);
            end
          end
          /* C.LW uses the same scaled offset as C.SW. */
          3'b010: begin
            offset = {5'b0, instr_i[5], instr_i[12:10], instr_i[6], 2'b0};
            class_o = ORDINARY;
            expanded_o = encode_i(7'h03, 3'b010, compact_rd, compact_rs1, offset);
          end
          /* C.SW retains both compact register identities. */
          3'b110: begin
            offset = {5'b0, instr_i[5], instr_i[12:10], instr_i[6], 2'b0};
            class_o = ORDINARY;
            expanded_o = encode_store(compact_rs1, compact_rd, offset);
          end
          default: begin end
        endcase
      end
      /* quadrant one supplies immediate arithmetic, direct jumps and branches. */
      2'b01: begin
        /* RV32 assigns funct3=001 to C.JAL rather than RV64 C.ADDIW. */
        case (instr_i[15:13])
          /* only canonical C.NOP is ordinary among rd=x0 encodings. */
          3'b000: begin
            class_o = (rd == 0 && immediate != 0) || (rd != 0 && immediate == 0) ? HINT : ORDINARY;
            expanded_o = encode_i(7'h13, 0, rd, rd, immediate);
          end
          /* C.J and C.JAL share their signed scattered displacement. */
          3'b001, 3'b101: begin
            class_o = ORDINARY;
            expanded_o = {jump_offset[20], jump_offset[10:1], jump_offset[11],
                          jump_offset[19:12], instr_i[15] ? 5'd0 : 5'd1, 7'h6f};
          end
          /* C.LI x0 is a HINT for every immediate. */
          3'b010: begin
            class_o = rd == 0 ? HINT : ORDINARY;
            expanded_o = encode_i(7'h13, 0, rd, 0, immediate);
          end
          /* C.ADDI16SP and C.LUI reserve zero immediates. */
          3'b011: begin
            /* rd=x2 selects the scaled stack-pointer immediate. */
            if (rd == 2) begin
              offset = {{2{instr_i[12]}}, instr_i[12], instr_i[4:3], instr_i[5],
                        instr_i[2], instr_i[6], 4'b0};
              /* zero is reserved rather than a no-op. */
              if (offset != 0) begin
                class_o = ORDINARY;
                expanded_o = encode_i(7'h13, 0, 5'd2, 5'd2, offset);
              end
            /* C.LUI x0 with a nonzero immediate is a HINT. */
            end else if (immediate != 0) begin
              class_o = rd == 0 ? HINT : ORDINARY;
              expanded_o = {{15{instr_i[12]}}, instr_i[6:2], rd, 7'h37};
            end
          end
          /* compact arithmetic distinguishes custom shifts and RV64-only forms. */
          3'b100: begin
            /* bit 12 is sign data only for ANDI and reserved for RV32 register ALU. */
            case (instr_i[11:10])
              /* RV32 shamt[5]=1 is an unsupported custom instruction. */
              2'b00, 2'b01: begin
                /* zero shifts are legal custom-use HINTs, unlike shamt[5]=1. */
                if (!instr_i[12]) begin
                  class_o = rs2 == 0 ? HINT : ORDINARY;
                  expanded_o = encode_i(7'h13, 3'b101, compact_rs1, compact_rs1,
                                       {1'b0, instr_i[10], 5'b0, rs2});
                end
              end
              /* C.ANDI retains its signed six-bit immediate. */
              2'b10: begin
                class_o = ORDINARY;
                expanded_o = encode_i(7'h13, 3'b111, compact_rs1, compact_rs1, immediate);
              end
              /* RV32 supports SUB, XOR, OR and AND only with bit 12 clear. */
              2'b11: begin
                /* the other half contains unsupported RV64/reserved instructions. */
                if (!instr_i[12]) begin
                  class_o = ORDINARY;
                  /* register ALU funct2 maps to its standard funct3. */
                  case (instr_i[6:5])
                    0: expanded_o = encode_r(7'h20, 0, compact_rs1, compact_rs1, compact_rd);
                    1: expanded_o = encode_r(0, 3'b100, compact_rs1, compact_rs1, compact_rd);
                    2: expanded_o = encode_r(0, 3'b110, compact_rs1, compact_rs1, compact_rd);
                    3: expanded_o = encode_r(0, 3'b111, compact_rs1, compact_rs1, compact_rd);
                  endcase
                end
              end
            endcase
          end
          /* both conditional branches compare the compact source with x0. */
          3'b110, 3'b111: begin
            class_o = ORDINARY;
            expanded_o = {branch_offset[12], branch_offset[10:5], 5'b0, compact_rs1,
                          2'b00, instr_i[13], branch_offset[4:1], branch_offset[11], 7'h63};
          end
        endcase
      end
      /* quadrant two contains shifts, stack memory and register transfers. */
      2'b10: begin
        /* floating-point stack operations remain illegal. */
        case (instr_i[15:13])
          /* custom shamt[5]=1 encodings are rejected before HINT classification. */
          3'b000: begin
            /* RV32 permits only five-bit shifts, including zero-shift HINTs. */
            if (!instr_i[12]) begin
              class_o = rd == 0 || rs2 == 0 ? HINT : ORDINARY;
              expanded_o = encode_i(7'h13, 3'b001, rd, rd, {7'b0, rs2});
            end
          end
          /* C.LWSP x0 is reserved and cannot cause a memory access. */
          3'b010: begin
            /* all other destination registers are legal. */
            if (rd != 0) begin
              offset = {4'b0, instr_i[3:2], instr_i[12], instr_i[6:4], 2'b0};
              class_o = ORDINARY;
              expanded_o = encode_i(7'h03, 3'b010, rd, 5'd2, offset);
            end
          end
          /* the CR format selects JR, MV, EBREAK, JALR or ADD. */
          3'b100: begin
            /* rs2=x0 distinguishes register jumps and the breakpoint encoding. */
            if (rs2 == 0) begin
              /* C.EBREAK retains the ordinary breakpoint trap path. */
              if (rd == 0 && instr_i[12]) begin
                class_o = ORDINARY;
                expanded_o = 32'h00100073;
              /* C.JR x0 is reserved; other jumps use the encoded source. */
              end else if (rd != 0) begin
                class_o = ORDINARY;
                expanded_o = encode_i(7'h67, 0, instr_i[12] ? 5'd1 : 5'd0, rd, 0);
              end
            /* C.MV and C.ADD with rd=x0 are HINTs, including C.NTL encodings. */
            end else begin
              class_o = rd == 0 ? HINT : ORDINARY;
              expanded_o = encode_r(0, 0, rd, instr_i[12] ? rd : 5'd0, rs2);
            end
          end
          /* C.SWSP permits x0 store data and every scaled offset. */
          3'b110: begin
            offset = {4'b0, instr_i[8:7], instr_i[12:9], 2'b0};
            class_o = ORDINARY;
            expanded_o = encode_store(5'd2, rs2, offset);
          end
          default: begin end
        endcase
      end
      /* a wide prefix belongs to the fetch assembler, never to this decompressor. */
      2'b11: class_o = WIDE;
    endcase
    /* all ignored HINTs use an operand-free canonical no-op. */
    if (class_o == HINT) expanded_o = 32'h00000013;
    legal_o = class_o == ORDINARY || class_o == HINT;
    hint_o = class_o == HINT;
  end
endmodule

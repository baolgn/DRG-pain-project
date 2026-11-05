/* provide the fixed M-only CSR inventory with atomic retirement-time updates. */
module drg5_csr #(
  parameter bit C_ENABLED = 0,
  parameter logic [31:0] MISA_VALUE = 32'h40000100,
  parameter logic [31:0] MIMPID_VALUE = 32'b0
) (
  input logic clk_i, reset_i,
  input logic access_i,
  input logic [11:0] addr_i,
  input logic [1:0] op_i,
  input logic [31:0] source_i,
  input logic read_i, write_i, commit_i,
  input logic trap_i,
  input logic [31:0] trap_pc_i, trap_cause_i, trap_tval_i,
  input logic mret_i, retire_i,
  input logic [31:0] mip_levels_i,
  input logic debug_mode_i, debug_ebreak_entry_i,
  output logic legal_o,
  output logic [31:0] old_o, read_value_o, new_o,
  output logic [31:0] mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o,
  output logic [31:0] mie_o, mip_o, mcountinhibit_o,
  output logic [63:0] mcycle_o, minstret_o
);
  logic known, readonly_address;
  logic [31:0] old_value, requested_value, coerced_value;
  logic unused_mip_bits;

  /* pending inputs are synchronized platform levels, with no writable core latch. */
  assign mip_o = mip_levels_i & 32'h00000888;
  assign unused_mip_bits = ^(mip_levels_i & ~32'h00000888);

  /* absent resources reject access even when neither read nor write is requested. */
  always_comb begin
    known = 1;
    readonly_address = 0;
    old_value = 0;
    /* fixed machine registers are decoded explicitly before optional zero HPM windows. */
    case (addr_i)
      12'h300: old_value = mstatus_o;
      12'h301: old_value = MISA_VALUE;
      12'h304: old_value = mie_o;
      12'h305: old_value = mtvec_o;
      12'h310: old_value = 0;
      12'h320: old_value = mcountinhibit_o;
      12'h340: old_value = mscratch_o;
      12'h341: old_value = mepc_o;
      12'h342: old_value = mcause_o;
      12'h343: old_value = mtval_o;
      12'h344: old_value = mip_o;
      12'hb00: old_value = mcycle_o[31:0];
      12'hb80: old_value = mcycle_o[63:32];
      12'hb02: old_value = minstret_o[31:0];
      12'hb82: old_value = minstret_o[63:32];
      /* identity registers occupy read-only CSR address space. */
      12'hf11, 12'hf12, 12'hf14, 12'hf15: readonly_address = 1;
      /* prototype identity is separate from the final named implementation profiles. */
      12'hf13: begin
        readonly_address = 1;
        old_value = MIMPID_VALUE;
      end
      /* manifest-selected standard HPM placeholders are writable constants, not absent resources. */
      default: begin
        known = (addr_i >= 12'h323 && addr_i <= 12'h33f) ||
                (addr_i >= 12'hb03 && addr_i <= 12'hb1f) ||
                (addr_i >= 12'hb83 && addr_i <= 12'hb9f);
      end
    endcase
    requested_value = old_value;
    /* normalized operation codes match READ, WRITE, SET and CLEAR. */
    case (op_i)
      1: requested_value = source_i;
      2: requested_value = old_value | source_i;
      3: requested_value = old_value & ~source_i;
      default: requested_value = old_value;
    endcase
    coerced_value = old_value;
    /* preview the actual stored value after masks and legal-value coercion. */
    if (write_i) begin
      /* immutable registers and unsupported fields retain their fixed values. */
      case (addr_i)
        12'h300: coerced_value = (requested_value & 32'h88) | 32'h1800;
        12'h304: coerced_value = requested_value & 32'h888;
        12'h305: coerced_value = requested_value & 32'hfffffffc;
        12'h320: coerced_value = requested_value & 32'h5;
        12'h340, 12'h343, 12'hb00, 12'hb80, 12'hb02, 12'hb82: coerced_value = requested_value;
        12'h341: coerced_value = requested_value & (C_ENABLED ? 32'hfffffffe : 32'hfffffffc);
        /* invalid software causes preserve the previous WLRL value. */
        12'h342: begin
          /* accept only the specified exception and interrupt causes. */
          if (requested_value <= 7 || requested_value == 11 || requested_value == 32'h80000003 ||
              requested_value == 32'h80000007 || requested_value == 32'h8000000b)
            coerced_value = requested_value;
        end
        default: coerced_value = old_value;
      endcase
    end
    legal_o = access_i && known && !(readonly_address && write_i);
    old_o = legal_o ? old_value : 32'b0;
    read_value_o = legal_o && read_i ? old_value : 32'b0;
    new_o = legal_o ? coerced_value : 32'b0;
  end

  /* reset dominates events; counters use pre-edge inhibit and debug state. */
  always_ff @(posedge clk_i) begin
    /* every hart reset clears counters and disables their automatic increments. */
    if (reset_i) begin
      mstatus_o <= 32'h1800;
      mie_o <= 0;
      mtvec_o <= 0;
      mscratch_o <= 0;
      mepc_o <= 0;
      mcause_o <= 0;
      mtval_o <= 0;
      mcountinhibit_o <= 5;
      mcycle_o <= 0;
      minstret_o <= 0;
    end
    /* no implicit increment can compete with an explicit counter-half write. */
    else begin
      /* ordinary trap and halt-entry cycles still count unless the stated debug exception applies. */
      if (!debug_mode_i && !debug_ebreak_entry_i && !mcountinhibit_o[0])
        mcycle_o <= mcycle_o + 64'd1;
      /* a trap or debug-routed EBREAK never retires an instruction. */
      if (!debug_mode_i && !debug_ebreak_entry_i && !trap_i && retire_i && !mcountinhibit_o[2])
        minstret_o <= minstret_o + 64'd1;
      /* trap entry cannot also apply a normal CSR write or return. */
      if (trap_i) begin
        mstatus_o <= 32'h1800 | (mstatus_o[3] ? 32'h80 : 32'b0);
        mepc_o <= trap_pc_i & (C_ENABLED ? 32'hfffffffe : 32'hfffffffc);
        mcause_o <= trap_cause_i;
        mtval_o <= trap_tval_i;
      end
      /* a machine return restores the interrupt stack while MPP remains fixed. */
      else if (mret_i) begin
        mstatus_o <= 32'h1880 | (mstatus_o[7] ? 32'h8 : 32'b0);
      end
      /* the caller grants commit only at its successful architectural disposition. */
      else if (commit_i && legal_o && write_i) begin
        /* writes to immutable implemented addresses are legal no-ops. */
        case (addr_i)
          12'h300: mstatus_o <= new_o;
          12'h304: mie_o <= new_o;
          12'h305: mtvec_o <= new_o;
          12'h320: mcountinhibit_o <= new_o;
          12'h340: mscratch_o <= new_o;
          12'h341: mepc_o <= new_o;
          12'h342: mcause_o <= new_o;
          12'h343: mtval_o <= new_o;
          12'hb00: mcycle_o <= {mcycle_o[63:32], new_o};
          12'hb80: mcycle_o <= {new_o, mcycle_o[31:0]};
          12'hb02: minstret_o <= {minstret_o[63:32], new_o};
          12'hb82: minstret_o <= {new_o, minstret_o[31:0]};
          /* constant registers retain their values. */
          default: begin end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  /* trap metadata belongs to the caller and must name an implemented machine cause. */
  always_ff @(posedge clk_i) begin
    /* reset ignores all competing event metadata. */
    if (!reset_i && trap_i) begin
      assert (trap_cause_i <= 7 || trap_cause_i == 11 || trap_cause_i == 32'h80000003 ||
              trap_cause_i == 32'h80000007 || trap_cause_i == 32'h8000000b)
        else $fatal(1, "unsupported trap cause supplied to CSR bank");
    end
  end
`endif
endmodule

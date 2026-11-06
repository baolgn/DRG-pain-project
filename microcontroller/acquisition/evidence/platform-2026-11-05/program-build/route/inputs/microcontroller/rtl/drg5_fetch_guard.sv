/* permit only declared side-effect-free SIM1 instruction parcels. */
module drg5_fetch_guard #(
  parameter bit TEST_REGIONS = 0
) (
  input logic [31:0] word_addr_i,
  input logic [1:0] want_i,
  output logic [1:0] allow_o
);
  /* test overlays are explicit fixtures, never peripheral read permissions. */
  function automatic logic executable(input logic [31:0] addr);
    executable = addr <= 32'h00001ffe ||
                 (addr >= 32'h00010000 && addr <= 32'h0001fffe);
    /* each overlay names a safe halfword or the deliberate error responder. */
    if (TEST_REGIONS) begin
      executable = executable ||
          (addr >= 32'h50000000 && addr <= 32'h50000ffe) ||
          addr == 32'h60000000 || addr == 32'h60000006 || addr == 32'hfffffffe;
    end
  endfunction

  /* checking each parcel prevents a wide read of an inaccessible neighbor. */
  always_comb begin
    allow_o = 0;
    /* malformed word bases are denied rather than silently rounded down. */
    if (word_addr_i[1:0] == 0) begin
      allow_o[0] = want_i[0] && executable(word_addr_i);
      allow_o[1] = want_i[1] && executable(word_addr_i + 32'd2);
    end
  end
endmodule

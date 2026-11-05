`include "drg5_datapath_defs.svh"

/* implement all RV32 shifts as five combinational mux stages. */
module drg5_shifter (
  input logic [31:0] value_i, amount_i,
  input logic [1:0] op_i,
  output logic [31:0] value_o,
  output logic valid_o
);
  logic [31:0] step [0:5];
  logic fill;

  /* keep the sign fill fixed to the original operand. */
  always_comb begin
    valid_o = op_i != 2'b11;
    fill = op_i == `DRG5_SHIFT_ARITH && value_i[31];
    step[0] = value_i;
    /* each selected stage shifts by one power of two. */
    for (int stage = 0; stage < 5; stage++) begin
      step[stage+1] = step[stage];
      /* upper amount bits never affect RV32 register shifts. */
      if (amount_i[stage]) begin
        /* left shifts fill with zero; right shifts use the selected sign. */
        if (op_i == `DRG5_SHIFT_LEFT) begin
          step[stage+1] = step[stage] << (1 << stage);
        end
        /* logical shifts insert zero; arithmetic shifts replicate the sign. */
        else begin
          step[stage+1] = (step[stage] >> (1 << stage)) |
                         (fill ? (32'hffffffff << (32 - (1 << stage))) : 32'b0);
        end
      end
    end
    value_o = valid_o ? step[5] : 32'b0;
  end
endmodule

# Independent branch unit evidence

## Table of contents

1. [Evidence record](#evidence-record)

## Evidence record

`drg5_branch` is a combinational decoded-operation unit. It implements BEQ, BNE, BLT, BGE, BLTU, BGEU, JAL and JALR calculations; it does not decode instruction bits, read/write a register file, publish a redirect, retire an instruction or implement traps.

The inputs are 32-bit PC, captured rs1/rs2 values and decoded immediate; four-bit kind (JAL=5, JALR=6, conditional=7); three-bit conditional funct3 and original byte length. The outputs are valid, taken, misaligned and 32-bit target, next PC and link. The default `C_ENABLED=0` accepts length 4. Setting it to 1 additionally accepts original length 2 for future decoded micro-operations; no compressed decoder or C ISA qualification is claimed.

Conditional funct3 values 0/1/4/5/6/7 select equality, inequality, signed less-than/greater-or-equal and unsigned less-than/greater-or-equal. Values 2/3 invalidate conditional operations. JAL/JALR ignore that inactive field. Invalid kind or length makes every output zero.

For a valid operation, link is PC plus original length. Target is PC plus immediate, except JALR uses captured rs1 plus immediate and clears bit 0. Every addition wraps modulo 2^32. Next PC is target when taken and link otherwise. Only taken targets are alignment-checked: two-byte alignment when C_ENABLED, four-byte alignment otherwise. Even odd computed B/J targets from malformed decoded inputs have a defined defensive response through this check. On misalignment, valid/taken and computed target/next-PC/link remain available for diagnostics; the caller suppresses writes and redirects and creates the trap. An untaken conditional never faults on its unused target.

The unit has no destination index. A caller suppresses x0 writes while preserving jump behavior, and supplies the captured old rs1 value for rd=rs1. The directed alias example checks that target calculation uses that supplied operand rather than the new link; complete register hazards and retirement belong to the control integration.

The final retained run passed **1,789,474 behavioral cases and 21,605,111 checks**. It combines all boundary operand pairs with twelve PC/immediate pairings, all operation selectors, all conditions and all three-bit length values in both configurations, followed by 20,000 reproducible full-width cases. Separate mathematical references use signed 64-bit values and widened addition. A corrupted observed target fails its intended comparator.

Both configurations also passed six combinational formal assertions for **all two-state inputs**, with no assumptions. The formal oracle uses 33-bit signed subtraction, widened address arithmetic and numeric operation codes independently of the RTL's sign-aware comparison and macro names. A deliberately corrupted expected link produces the required failed proof. These are comparator/proof-detector controls, not RTL fault-injection coverage. Assertions, assumption count and solver terminals are checked by the runner.

Both configurations passed actual ECP5 synthesis, structural checks and rejection of unintended latches/registers:

| C_ENABLED | LUT4 | CCU2C | L6MUX21 | PFUMX | FF / RAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 420 | 64 | 108 | 150 | 0 |
| 1 | 412 | 64 | 105 | 146 | 0 |

These are component mapping counts. No exact-device route, clock timing, physical-board or complete CPU result is claimed here.

From the repository root:

```sh
python3 microcontroller/tests/run_branch.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools/oss-cad-suite/bin/yosys \
  --build /tmp/drg5-branch-final
```

[summary.json](summary.json) records every source/runner hash, tool versions, outcomes, mapped cells and generated-netlist hashes. Complete commands and logs are retained beside it; generated netlists remain in `/tmp/drg5-branch-final`. [tool-binaries.json](tool-binaries.json) pins the executed binaries. The historical 2026-01-20 FPGA tools and separately qualified 2026-03-01 Verilator bundle remain unchanged. The final RTL SHA-256 is `81fb7fbc54c4c64236738d289fa8fc5a64bd6373efbd66ac2da33086e8d8728e`.

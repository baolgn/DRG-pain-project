# Exhaustive RV32C decompression qualification

Qualified 4 November 2026 against the pinned [C extension, version 2.0, ISA release v20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/c-st-ext.html). The component implements the integer RV32C forms. F, D, RV64-only forms, unsupported custom instructions and reserved encodings are illegal. Existing HINT encodings, including the custom-use HINT space, execute as ignored no-ops.

`drg5_decompress` accepts one 16-bit `instr_i` and combinationally returns `expanded_o[31:0]`, `legal_o`, `hint_o` and `class_o[1:0]`. Class 0 is illegal, class 1 is an ordinary instruction, class 2 is HINT and class 3 is a noncompressed prefix with low bits `11`. Canonical `C.NOP` (`0x0001`) is ordinary. All HINTs expand to `ADDI x0,x0,0`; illegal and wide inputs expand to zero and are not legal. The surrounding pipeline must preserve original bits and instruction length separately; an expanded JAL/JALR must still use the original two-byte length for its link.

The Python oracle enumerates legal semantic instructions by their destination/source registers and signed or unsigned immediate ranges, then *encodes* each halfword through independent immediate scatter tables. It does not decode the halfword through the RTL's quadrant/funct3 decision tree. Overlapping legal encodings are rejected. All remaining halfwords are either illegal or wide according to their low two bits. Cardinalities also match an independently derived format count.

| Classification | Distinct halfwords |
| --- | ---: |
| Illegal | 20,329 |
| Ordinary instruction | 28,461 |
| HINT | 362 |
| Noncompressed prefix | 16,384 |
| Total | 65,536 |

Every halfword was visited in ascending and descending order, with four comparisons per visit and one final cardinality comparison: **524,289 comparisons**. `class_o`, exact expansion, legal status and HINT status are checked separately. Three observation mutations calibrated the classification, immediate expansion and HINT-flag detectors. They failed their specific comparator; unrelated crashes do not pass calibration. No randomized coverage is substituted for enumeration; Verilator's initialization seed is fixed to 1.

Final strict Verilator build passed without HDL warnings. Yosys with the bundled slang frontend passed hierarchy, driver and latch checks, then mapped the component to **274 LUT4, 77 PFUMX and 22 L6MUX21** cells for ECP5, with no flip-flops or latches. This is component synthesis only, not a routed timing or board-resource claim. The runner permits only ABC's informational combinational-network notice, rejecting other warnings and errors.

## Review revisions

1. **Initial implementation.** Strict lint rejected unused hardwired low offset bits. Offset signals were narrowed to their actually consumed `[20:1]` and `[12:1]` ranges, retaining all encoded bits and immediate behavior. Original source and failing lint log are retained in `revisions/01-initial`.
2. **First exhaustive run.** All encoding comparisons and detector calibrations passed. The native Yosys frontend rejected the SystemVerilog function-return syntax; the run did not qualify synthesis. The selected project frontend is slang. A fixture count-report issue was also identified: Verilator's generated final task call folded the global count to 1 despite retaining loop comparisons. Source and logs are retained in `revisions/02-first-exhaustive`.
3. **Tool and evidence review.** The initial slang/ABC9 mapping reported a transformation error despite a successful process exit; it was rejected. The final runner selects the project's established `-noabc9` synthesis path and rejects textual errors as well as failing exits. Comparison count is derived from observed classification counts and the explicit two-pass/four-check traversal, avoiding the simulator bookkeeping problem. Source and logs are retained in `revisions/03-tool-review`.
4. **Final qualification.** Exhaustive comparison, all three calibrated detectors and ECP5 mapping passed on the SHA-bound source in `sources/`. `summary.json` records source/oracle hashes and exact tool versions. The unchanged RTL from the width fix is used by the final component run.

Reproduce from the project root:

```sh
python3 microcontroller/tests/run_decompress.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/yosys \
  --build /tmp/drg5-decompress-tests
```

The retained `oracle.hex` contains all 65,536 class/expansion entries in numeric halfword order. These checks establish combinational classification and decompression, not mixed-width pipeline/fetch behavior, ACT4/Sail qualification or full ISA conformance. Those are separate integration gates.

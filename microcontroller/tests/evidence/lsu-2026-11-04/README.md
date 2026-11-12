# Independent data-access helper evidence

## Table of contents

1. [Evidence record](#evidence-record)

## Evidence record

`drg5_lsu` is a combinational permission and byte-lane helper. It does not decode instructions, own bus requests, interpret response status, retire instructions, implement a timer or publish modified code.

Inputs are the 32-bit effective byte address, unshifted store source, lane-positioned response data, size (0 byte, 1 halfword, 2 word), direction and load signedness. Outputs are permission, misalignment, exception cause, lane-positioned write data, write strobes and extended load value. Every input combination has a defined two-state result. Byte accesses permit any lane, halfwords require even addresses and words require four-byte alignment. Misalignment reports load/store cause 4/6 before region denial cause 5/7. Size 3 reports access cause 5/7 with misalignment false; instruction decoding must independently reject unsupported encoded widths as cause 2.

The complete widened access footprint must fit one permitted region without wrapping. All three parameters default to zero:

| Inclusive byte range | Reads | Writes | Widths / condition |
| --- | --- | --- | --- |
| `00000000–00001fff` | yes | no | byte, halfword, word |
| `00010000–0001ffff` | yes | `IRAM_WRITE` | byte, halfword, word |
| `20000000–20007fff` | yes | yes | byte, halfword, word |
| `40000000–40000fff` | yes | yes | word only |
| `40001000–40001fff` | `TIMER_ENABLED` | `TIMER_ENABLED` | word only |
| `50001000–50001fff` | `TEST_REGIONS` | `TEST_REGIONS` | byte, halfword, word |
| `50002000–50002fff` | `TEST_REGIONS` | `TEST_REGIONS` | byte, halfword, word |
| every other address | no | no | access fault |

The MMIO guard permits a region and width; individual register direction and offset checks belong to the target. Enabling an optional range only permits routing to it. Denied operations return zero write data, write strobes and load value. Reads always return zero write outputs; stores always return zero load value. Store data are masked to the low source byte/halfword/word before positioning in the addressed lanes. Loads select those lanes before sign or zero extension; signedness has no effect on a full word. An allowed operation returns cause zero. The caller must reject unsuccessful or malformed responses before using the computed load value.

The retained behavioral run passed **85,536 input vectors across all eight parameter combinations**, totaling **684,288 profile cases and 2,812,773 checks**. It exercises all widths, directions and signedness values around sixteen address anchors, each with sixteen byte-offset positions and sixteen data patterns, followed by 20,000 deterministic full-width samples. The reference checks permissions byte by byte using a 64-bit address and page-number arithmetic, and forms lane data using byte arithmetic rather than the RTL's endpoint comparisons and shifts. The outcomes include 51,216 allowed reads, 24,404 allowed writes, 213,448 alignment denials and 395,220 access denials. Independently corrupted observed store data and load sign-extension each fail their named comparator.

Every parameter combination also passed **six combinational formal assertions for all two-state inputs, with zero assumptions**. The formal reference uses per-byte region checks and per-bit data assembly. The runner checks the assertion and assumption counts and requires the solver's success terminal. A corrupted expected-store assertion produces the required counterexample. These negative controls establish comparator/proof detection, not general RTL mutation coverage.

All eight configurations passed actual ECP5 synthesis, structural checks and rejection of inferred state. Profile bits are `TEST_REGIONS`, `IRAM_WRITE`, `TIMER_ENABLED` in that order:

| Profile | LUT4 | CCU2C | L6MUX21 | PFUMX | FF / RAM / latch |
| --- | ---: | ---: | ---: | ---: | ---: |
| 000 | 312 | 24 | 54 | 77 | 0 |
| 001 | 226 | 16 | 17 | 39 | 0 |
| 010 | 303 | 24 | 51 | 73 | 0 |
| 011 | 297 | 24 | 52 | 75 | 0 |
| 100 | 260 | 59 | 17 | 57 | 0 |
| 101 | 288 | 43 | 38 | 60 | 0 |
| 110 | 273 | 59 | 31 | 53 | 0 |
| 111 | 287 | 43 | 38 | 60 | 0 |

These are helper mapping counts, not estimates of the complete LSU or CPU. No exact-device placement/routing, clock timing, physical-board result or bus ownership proof is claimed here.

From the repository root:

```sh
python3 microcontroller/tests/run_lsu.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools/oss-cad-suite/bin/yosys \
  --build /tmp/drg5-lsu-final-v2
```

[summary.json](summary.json) records source/runner hashes, tool versions, every outcome, mapped cells and netlist hashes. Complete commands and logs are retained beside it; generated netlists remain in `/tmp/drg5-lsu-final-v2`. [tool-binaries.json](tool-binaries.json) pins the executed binaries. The runner captures source hashes before execution and rejects changes during qualification. The historical FPGA tool pin and separately qualified Verilator bundle remain unchanged. The RTL SHA-256 is `eeac7f5f8d92e4e35030b716e85aabede593afe1d5ca3175e79b9e3e5c83d926`.

Independent review found no RTL or oracle defect. It requested fuller failure diagnostics; the final test now prints the sample index and complete input vector. The previous test source, summary and affected logs are preserved under [revisions/01-before-vector-diagnostics](revisions/01-before-vector-diagnostics). The complete qualification was rerun after that change with identical positive counts and the intended negative outcomes.

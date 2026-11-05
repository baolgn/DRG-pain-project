# Independent forwarding selector evidence

## Table of contents

| Section |
| --- |
| [Evidence record](#evidence-record) |

## Evidence record

`drg5_forward` is a combinational selector for two register operands. It does not decode instructions, determine producer completion, own pipeline tokens, read a register file or authorize architectural effects. The caller supplies source indices/use flags/RF values and three producer descriptors ordered from newest X through M to oldest W.

Each producer has independent valid, write and ready bits, a five-bit destination and a 32-bit value. `producer_rd_i[14:0]` and `producer_value_i[95:0]` use flattened packed lanes: the low five/32 bits are X, the middle bits M, and the high bits W. The three control vectors use the same index ordering.

For each source independently:

| Condition | Value | Match | Selection | Hazard contribution |
| --- | --- | --- | --- | --- |
| source unused or index x0 | zero | 0 | 0 | 0 |
| no valid writing nonzero destination matches | supplied RF value | 0 | 0 | 0 |
| nearest matching producer available | that producer's value | 1 | X=1, M=2, W=3 | 0 |
| nearest matching producer unavailable | zero | 1 | the same nearest index | 1 |

Invalid slots, nonwriters and rd=x0 never match. Readiness does not participate in choosing the nearest identity. An unavailable X or M match therefore prevents fallback to a ready older value. A ready operand can retain its selected value while the other operand is blocked; `hazard_o` is the OR of the two contributions, and the caller must defer operand capture while it is asserted.

`FORWARDING=1`, the default, permits any selected producer whose ready bit is set. `FORWARDING=0` treats selected X/M producers as unavailable regardless of their ready inputs; selected W still requires its ready bit. The caller decides when W is ready. In the integrated conservative mode that means successful retirement; the helper alone does not impose retirement timing. The helper has no state, clock, reset or variable-latency operation. Every two-state input combination has defined outputs.

The final behavioral run passed **3,231,264 input vectors across both modes**, or **6,462,528 mode cases and 45,237,697 checks**. The sweeps cover:

- Every valid/write/ready bit pattern and source-use mask against representative zero/nonzero/equal/unequal source pairs and all 64 producer identity relationships.
- All 32,768 combinations of three producer destinations for each source-one index, with a complementary source-two index.
- Every independent source-index pair against all 64 producer identity relationships, followed by 20,000 reproducible full-width data/control vectors.

The behavioral reference searches from oldest to newest and overwrites candidates before checking readiness, independently of the RTL's first-match search. All seven outputs are compared in both modes. The run observed 545,429 blocked mode cases, 85,742 cases with both sources matched, 1,119,528 cases containing an active x0 source, 3,273,748 cases containing an unused source and 1,380 blocked-X/ready-matching-M fallback opportunities. Deliberately removing a hazard and substituting that forbidden older value each fail their named comparator; failure messages include the complete input vector and expected/observed output.

Both modes passed **seven combinational formal assertions for all two-state source indices, producer indices, flags and values, without assumptions**. A separate one-hot priority reference computes the winning identities and masks their data. A deliberately corrupted expected hazard produces a required counterexample. The runner checks property counts and solver terminals. These detector controls calibrate the comparators; they are not broad RTL mutation coverage or proof of the caller's readiness/ownership logic.

Actual ECP5 synthesis passed structural checks and rejected inferred storage:

| FORWARDING | LUT4 | L6MUX21 | PFUMX | FF / RAM / latch |
| --- | ---: | ---: | ---: | ---: |
| 0 | 243 | 10 | 22 | 0 |
| 1 | 663 | 126 | 271 | 0 |

These are standalone component counts, not complete CPU resource or timing results. No placement, routing, physical-board or clock-frequency qualification is claimed.

From the repository root:

```sh
python3 microcontroller/tests/run_forward.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools/oss-cad-suite/bin/yosys \
  --build /tmp/drg5-forward-final
```

[summary.json](summary.json) records every source/runner hash, result, tool version, mapped count and generated-netlist hash. Complete commands and logs are retained beside it; generated netlists remain in `/tmp/drg5-forward-final`. [tool-binaries.json](tool-binaries.json) pins the executed binaries. Source hashes were checked before and after qualification and again when retaining evidence. Independent source, formal-reference, behavioral-reference and runner reviews found no remaining blocker within this scope. The RTL SHA-256 is `6c88614a024cb1df85bdb4926a4d4bef9bacbc84af803bcbb7cf1b93d150e444`.

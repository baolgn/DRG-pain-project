# RV32M unit qualification, 2026-11-04

## Evidence record

The standalone unit passes the three seeded runs, five detector calibrations, strict Verilator build, and ECP5 synthesis recorded in `summary.json`. This is component evidence; pipeline dependency, exception, and interrupt ordering require the separate integrated-core tests.

The instruction definitions are pinned to the [official M extension, version 2.0, ISA publication v20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/m-st-ext.html). The unit accepts the instruction's `funct3` value as `op_i`:

| `op_i` | Instruction | Result |
| --- | --- | --- |
| 0 | MUL | Low 32 bits of the full product |
| 1 | MULH | High 32 bits of signed × signed product |
| 2 | MULHSU | High 32 bits of signed lhs × unsigned rhs product |
| 3 | MULHU | High 32 bits of unsigned × unsigned product |
| 4 | DIV | Signed quotient, rounded toward zero |
| 5 | DIVU | Unsigned quotient |
| 6 | REM | Signed remainder, nonzero sign equal to the dividend |
| 7 | REMU | Unsigned remainder |

Division by zero returns quotient `0xffffffff` and the original dividend as remainder. Signed `0x80000000 / 0xffffffff` returns quotient `0x80000000` and zero remainder. These cases do not trap and have the same latency as ordinary division.

At an idle rising edge with `start_i=1`, the unit captures both operands, operation, and 64-bit UID. The accepting edge is edge zero. Multiply result-valid appears after edge 2; divide result-valid appears after edge 33. Both meet the respective 4- and 36-clock component ceilings. A continuously running clock and atomic idle-only acceptance are assumptions. There is no separate request-acceptance queue.

`busy_o` remains high through the held result. `ready_i` has no effect before result-valid. A result, including its UID, remains stable until a rising edge with `valid_o && ready_i`; this edge releases ownership. Starting another job on that same edge is a contract violation: the unit's assertion rejects it, and the hardware state machine does not accept that new start. A legal next start occurs at a later idle edge. Downstream delay while holding a result is additional to arithmetic latency and can be unbounded if the consumer never asserts ready.

Only `cold_reset_i` cancels a job and zeros the public outputs. There is no hart-reset, pipeline-flush, interrupt, debug, or clock-gating input. The caller drains a killed instruction's job and discards its UID-tagged result. Architectural debug and a debug halt response are explicitly unimplemented.

| Requirement | Executed check |
| --- | --- |
| All eight results and signedness | Every pair of 16 boundary values, then 8,192 random pairs per opcode and seed; widened host multiplication/division/modulo reference |
| Zero, signed extrema, overflow, rounding, limb carries | Boundary cross-products include zero, ±1, ±2, ±3, signed limits, 16-bit limb boundaries, alternating and dense bit patterns |
| Fixed arithmetic latency | Exact result-valid edge checked for every completed job; no earlier valid permitted |
| Input capture and identity | Operation, operands, and supplied UID change during computation and result stalls; captured UID checked every computation edge |
| Single consumption | Result ownership checked before, at, and after ready; no duplicate result allowed |
| Backpressure | 237,287 or more stalled result edges per seed, including 257-edge holds; early ready tested independently |
| Reset | All arithmetic edges and held-result states for every opcode; 156 resets per seed, followed by fresh reference-checked jobs |
| Detector sensitivity | Wrong observed result, latency, UID, and held result each activate their named comparator; illegal busy start activates the unit assertion |
| Reproducibility and failure trace | Explicit LCG seeds 0, 1, and 305419896; complete command logs; first mismatch includes job inputs and preceding 64 sampled public-interface edges |
| Synthesis suitability | Strict warning-free Verilator build; Yosys/slang hierarchy, driver and no-latch checks; actual ECP5 primitive mapping |

Each seed completed 67,742 jobs, for 203,226 total. The three runs made 12,394,449 comparisons. This is finite simulation coverage, not a proof of every possible sequential input trace. The four observation mutations calibrate the checkers; they are not claims of four discovered RTL defects.

The mapped unit contains 582 LUT4, 464 TRELLIS_FF, 163 CCU2C, 108 PFUMX, 3 L6MUX21, and exactly four MULT18X18D cells. These are standalone component counts and do not substitute for the integrated target's resource, routing, timing, or programming qualification.

Actual revision history:

1. `revisions/01-initial-lint` preserves the initial RTL, fixture, and five strict lint warnings. The unused subtraction carry was removed without changing the 33-bit compare; fixture widths and widened reference temporaries were made explicit. No warning was waived.
2. `revisions/02-qualification` preserves the corrected sources, all three passing runs, five expected failures, mapping log, and source hashes. The post-run review confirmed the widening rules, mixed-sign product correction, fixed-latency special cases, reset priority, and result ownership against the stated contract.
3. `revisions/03-qualification` follows the final comment audit: a concise comment was added before the runner's exception-handling block. RTL and testbench behavior are unchanged. The complete three-seed, five-detector, and ECP5 mapping qualification passed again against the final runner source.
4. `revisions/04-qualification` corrects the fixture comment from “each random pair” to “each random round”: each opcode receives newly drawn operands within a round. The stated 8,192 random pairs per opcode remains accurate. The complete qualification passed again; executable testbench behavior and RTL are unchanged.

Reproduce from the project root with the pinned tool bundle:

```sh
python3 microcontroller/tests/run_muldiv.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/yosys
```

Every runner invocation creates a new immutable attempt directory before executing tools. A failed attempt retains its source snapshot and logs without replacing the last passing summary. `summary.json` includes the exact tool versions and source hashes.

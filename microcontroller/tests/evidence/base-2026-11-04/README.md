# Encoded base execution and forwarding evidence

This evidence qualifies raw RV32I execution through the packet prototype and compares its architectural behavior with diagnostic scheduling, conservative overlap and forwarding. It does not qualify a production CPU top, a complete B0 milestone, Sail comparison or ACT4 execution. The instruction producer is an immutable testbench program adapter; instruction-access faults are supplied by that adapter.

The final run passed nine positive executions: three configurations × schedule seeds `0`, `1` and `305419896`. It also passed five calibrated negative controls. Across positive runs, 477 scenario executions covered 13,266 checked edges, 1,252,295 comparisons, 2,520 normal retirements, 297 trap dispositions and 252 physical memory offers/replies. Each run executes 53 scenarios, 280 normal retirements, 33 traps and 28 physical memory transactions. Qualified cold-reset bootstrap edges are separate from checked-edge counts.

| Configuration | Parameters | Seed 0 edges | Seed 1 edges | Seed 305419896 edges |
| --- | --- | ---: | ---: | ---: |
| Diagnostic | `DIAGNOSTIC=1`, `FORWARDING=0` | 2,140 | 2,131 | 2,130 |
| Conservative overlap | `DIAGNOSTIC=0`, `FORWARDING=0` | 1,272 | 1,263 | 1,262 |
| Forwarded overlap | `DIAGNOSTIC=0`, `FORWARDING=1` | 1,029 | 1,020 | 1,019 |

These are measured totals for finite verification workloads, including scripted input pauses and a held W stage. They are not general CPI or WCET claims. C is disabled; test error regions are enabled. Legacy tests separately qualify reset, external flush, fatal protocol behavior and timeout boundaries.

The independent interpreter computes each complete architectural plan before simulation. Its mask-table decoder, bit-routed immediates, widened arithmetic and signed comparisons do not call production decoder, ALU, branch, LSU or forwarding modules. The plan supplies expected source values, normalized terminal packets, traps, continuations and ordered memory intents. Expected state never uses a DUT result as an oracle input.

Actual RAM/device storage changes from physical request descriptors at acceptance, without deduplication. Separate expected effect storage changes from the next planned semantic intent. The checks compare complete RAM, device counters, last-write state, all defined GPRs and trap storage. Loads to x0 still create requests, device effects or precise faults. Read responses are registered: service at acceptance `A`, reply at `A + response_edges`. The first registered offer at `L` is accepted at `L + accept_extra + 1`. Selected delay values cover every `accept_extra` in 0–3 and `response_edges` in 1–5. These selections are tied to semantic memory ordinals, so speculation cannot change the schedule assigned to an architectural access. `SERVICE` records preserve actual edges.

For each seed, all three modes have exactly equal `ARCH`, `EFFECT`, `FINAL` and selected `SCHEDULE` streams. Each domain is compared separately because legitimate timing changes can interleave architectural and physical events differently. UID allocation, kill counts and cycle numbers are excluded from architectural equality. Exact live-UID conservation, independently authorized kill masks, W eligibility and bounded completion separately detect lost instructions. The explicit NOP must retire exactly once.

Mandatory positive coverage includes all 40 base encoding rows; both outcomes of BEQ, BNE, BLT, BGE, BLTU and BGEU; disabled instruction and malformed metadata rejection; earlier fetch-fault priority; little-endian byte/halfword/word accesses; signed and unsigned loads; x0 behavior; JAL/JALR links and target faults; backward control flow; conservative full FENCE behavior; precise ECALL/EBREAK traps; and a prior eligible preparation edge for each encoded barrier. FENCE operand fields are ignored, including poisoned reserved register fields.

Forwarded overlap requires X, M and W source captures, completed-load M captures only after registered response completion, and both source values captured while their real W producer remains held. Every forwarded run observed 118 X, 8 M and 15 W captures, including 4 completed-load M captures and 2 held-W captures. The nearest-unready test requires a proven-ready older writer masked by the nearer pending producer at the exact intended consumer PC. Each forwarded run observed four witnesses apiece for ALU, branch, address and store-data consumers; successful and rejected loads are included. Conservative overlap observed two witnesses per class.

Five negative controls deliberately corrupt an observed architectural result, captured operand, target effect counter, observed kill mask or observed NOP terminal-valid bit. Each must fail through its named comparator, return a failing exit and emit no positive PASS record. They qualify checker sensitivity; they do not mutate production RTL.

Reproduce from the repository root:

```sh
python3 microcontroller/tests/run_base.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-base-reproduce
```

The tool is the separately qualified Verilator `5.047 devel rev v5.046-19-ge9dd6eaaf (mod)`. Every build uses `--assert -Wall` with no HDL warning waivers. `-CFLAGS -O0` changes only generated C++ optimization. The simulator initialization seed is fixed with `+verilator+seed+1`; the separate fixture `+seed` accepts zero as an ordinary LCG input.

`summary.json` records exact commands, coverage counts, domain hashes and the thirteen source hashes checked before and after execution. `sources/` retains those exact inputs. `source-SHA256SUMS` is relative to the repository root or the retained `sources/` directory; `SHA256SUMS` covers this evidence directory. Each configuration retains build logs, complete positive logs, canonical domain records and replay schedules; negative logs retain the intended first failure.

`revision-history.tar.gz` retains six actual checker revisions and their available logs. Initial executions found fixture errors: reset-release readiness was sampled without its recovery edge, a combinational launch was sampled after the edge, load request strobes were treated as store strobes, and the first physical tag was predicted as zero instead of one. Independent review also corrected younger-barrier launch gating, unsigned branch stimulus, exact terminal eligibility, ready-older masking witnesses and direct-failure negative-control calibration. Revision 4 first passed the forwarded workload; revision 5 first passed all modes and seeds; revision 6 binds masking to exact consumer PCs and adds the lost-NOP detector. Intermediate failures are not counted as passes. No production RTL defect was found by this new fixture's qualification cycle.

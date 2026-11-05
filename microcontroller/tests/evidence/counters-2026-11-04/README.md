# Machine-counter bank qualification, 4 November 2026

Final revision **04** passes three reproducible schedules, each checking C-disabled and C-enabled CSR banks concurrently: **64,827 public clock edges and 777,978 checks**. Every recorded input edge is independently replayed in Python, in addition to the SystemVerilog event-ledger comparison. Five deliberate observation corruptions reach their expected ordinary comparators. Two seven-assertion inductive proofs pass; a counter-expectation mutation produces the required failed proof. Both banks pass strict lint, driver/no-latch checks and native ECP5 synthesis.

## Table of contents

| Section |
| --- |
| [Scope and event model](#scope-and-event-model) |
| [Requirement-to-test matrix](#requirement-to-test-matrix) |
| [Proof and structural checks](#proof-and-structural-checks) |
| [Actual revisions and reassessment](#actual-revisions-and-reassessment) |

[summary.json](summary.json) records exact commands, source hashes, simulator/proof outcomes and mapping counts. [aggregate.json](aggregate.json) records totals and their scope. The complete source, seed logs, compressed CSV ledgers, proof logs and compressed mapped netlists remain in [revisions/04-qualification](revisions/04-qualification/). Earlier attempts are retained separately.

## Scope and event model

This fixture instantiates the existing `drg5_csr` bank. It tests the bank's normalized event/control interface; it does not implement a pipeline decoder, architectural Debug Mode, a halt controller, DMI or a debugger. C0/C1 select the bank's alignment behavior, but the counters themselves have no instruction-length input. A synthetic compressed-retirement record contributes one `retire_i` event. Real mixed-width instruction execution and final debug integration require separate checks.

The independent ledger begins with explicit reset values, never observed DUT storage. It selects counter halves through arithmetic division/remainder, applies CSR operations per bit, records old-state inhibition, and treats an explicit half-write as replacement in the **pre-edge whole counter**. Each public pre-edge read/preview and post-edge counter/inhibit value is compared in both banks. The optional full CSV includes raw input controls, expected state and observed C0 state. Python independently replays those raw controls without consulting either the DUT state or the SystemVerilog expected-state columns to compute its next result; both columns must then match.

Directed records represent ordinary 32-bit retirement, compressed retirement, stalls, trap entry, interrupt entry, WFI and idle clocks, ordinary halt entry, already halted cycles, resume, successful step, trapping step and debug-routed EBREAK. These are constructed **bank events**, not evidence that an architectural debug FSM executed those transitions. Halt/step entry uses non-debug pre-state; resume uses debug pre-state. Debug-routed EBREAK suppresses the entry-cycle increment independently of a later debug-cause choice. Both counters freeze while `debug_mode_i` is asserted, but explicit legal abstract counter writes can still update their selected halves. Fixed stopcount behavior is tested; no programmable stopcount field is added.

The six CSR forms are represented by independently constructed normalized read/write intent. Register-index zero and a nonzero source index holding value zero receive different write suppression. Immediate forms use the supplied unsigned five-bit constant. Read suppression does not suppress an otherwise requested write. The fixture checks those bank controls; it does not claim to verify encoded CSR decoding. Invalid architectural alias probes are modeled as illegal-instruction trap events. A separate adversarial collision corpus supplies even combinations that a correct architectural caller would never issue, allowing reset/trap/return/write priority to be tested directly.

## Requirement-to-test matrix

| Requirement | Executed check |
| --- | --- |
| Count cycles during stalls and ordinary trap/IRQ/WFI handling | Directed event ledger plus every-edge replay; counting depends on clock, pre-edge CY and debug state, not useful instruction progress. |
| Count only actual successful retirement | Constructed retirement events contribute once, including the compressed label; trap/IRQ/debug records contribute none. The pipeline must supply the truthful event. |
| RV32 low/high access | Every implemented counter half is read/written; pre-edge values are compared before the reading instruction's own update. No implicit paired-read latch is assumed. |
| Coherent software read | High-low-high retries on a deliberately forced low-word rollover for both counters; successful tuples match the independent low-read instant. The driver uses checked DUT read data. |
| Inhibition | All CY/IR combinations, writes and reserved-bit coercion; the writing edge uses old inhibition and the next edge uses the new bits. |
| Counter writes and rollover | Each of four half-writes independently defeats a pending full-width rollover; the untouched pre-edge half is preserved. Ordinary low carry and modulo-2^64 wrap are also required coverage. |
| Debug stop | Ordinary halt entry, halted intervals, resume edge, step/trapping step, debug EBREAK and four explicit halted counter-half writes. |
| Reset and simultaneous events | All 128 combinations of reset/trap/return/commit/retire/debug/debug-EBREAK around selected counter writes, plus random values and controls. |
| Missing extensions | cycle/time/instret aliases and high aliases, mcounteren and absent adjacent control addresses reject access; selected standard machine HPM placeholders stay zero. No Zicntr/Zihpm claim. |
| Reproducibility | Seeds 0, 1 and 305419896 drive a nonzero-seeded xorshift stream. Each schedule retains 20,000 mixed-control events and full public-input CSV evidence. |
| Non-vacuous random counting | Random-region setup explicitly enables counting every 64 events; those setup edges are excluded from the random-active counters. Rare reset every 257 events supplements the exhaustive reset collision matrix. |
| Detector calibration | Mutated carry, debug clock increment, trapping retirement, write-edge increment and suppressed read each fail their named ordinary comparator. |

The final random schedules exercise **4,174 / 4,248 / 4,219** active cycle increments and **1,037 / 1,116 / 1,071** enabled retirement increments, respectively. These are input-event coverage counts, not program throughput or interrupt latency measurements. The final marker's `cases=4` identifies four directed phase milestones, not the number of tested instructions or event combinations.

## Proof and structural checks

The existing independent `drg5_csr_formal.sv` model is rerun against the current exact bank source. It checks seven assertions for all symbolic normalized CSR/event inputs under two assumptions: the first edge resets the bank, and a non-reset caller trap has an implemented cause. Both C0 and C1 produce an inductive success; a changed expected counter produces a definite failed proof. This is a two-state proof of the bank and its declared interface, not proof of raw instruction decode, debug-event generation or whole-core retirement.

Separate native component maps use the pinned open-source tools and classic ABC (`synth_ecp5 -noabc9`). C0 maps to 3,507 LUT4 / 384 flip-flops; C1 maps to 2,755 LUT4 / 384 flip-flops. These are maps of the **whole standalone CSR bank**, not just two counters or the integrated CPU. Heuristic mapping differences are not an isolated area-improvement claim. Neither establishes routing, achieved clock frequency or the CPU resource gate.

## Actual revisions and reassessment

1. Revision 01 passed a directed/seeded smoke run and Python edge replay. Review then added a separate full-wrap write collision for each of the four counter halves and modeled invalid architectural alias probes as traps.
2. Revision 02 passed the first full simulation, detector, proof and mapping matrix. Self-review found that low LCG bits sampled every four draws left random debug controls repetitive; directed coverage remained valid, but the randomized active-count claim was weak.
3. Revision 03 changed to xorshift, made the high-low-high driver consume checked DUT data, corrected comment style, and added mandatory active-count coverage. The coverage gate correctly rejected the schedule: frequent resets continually restored inhibited counters, making random counting nearly vacuous. The failed log and complete event CSV remain retained.
4. Revision 04 uses rare reset and periodic explicit inhibition release, excluding setup edges from random-active coverage. All three schedules, independent replays, five detectors, both inductive proofs, the formal detector and both maps pass with unchanged final sources.

No production RTL defect or production edit was required by these test revisions. These results qualify the stated counter-bank behavior; they do not qualify architectural debug or advertise complete Zicntr.

Reproduce from the project root with an independent evidence destination:

```sh
python3 microcontroller/tests/run_counters.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/yosys \
  --build /tmp/drg5-counters-reproduce \
  --evidence-dir /tmp/drg5-counters-reproduce-evidence
```

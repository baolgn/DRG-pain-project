# Machine counter execution qualification

The final result is recorded in `summary.json` and `aggregate.json`. This fixture executes raw instruction bytes through the production frontend, decoder and five-stage controller. It compares the two machine counters at every clock edge against a separate clock and architectural execution ledger. The terminal instruction oracle uses program metadata constructed before execution; it does not infer expected results from the DUT's decoder or retirement flags.

## Table of contents

| Section |
| --- |
| [Reproduction and scope](#reproduction-and-scope) |
| [Requirement-to-test matrix](#requirement-to-test-matrix) |
| [Trace format and replay](#trace-format-and-replay) |
| [Review and revision record](#review-and-revision-record) |

Final revision 10 passed 12 configuration/seed runs containing 216 programs, 138,817 checked clock edges and 6,880,296 assertions. Independent execution records contain 5,727 successful retirements, including 171 compressed instructions, plus 216 synchronous traps and 12 interrupt entries. All three runtime and five offline negative controls failed at their intended detectors. These totals include only the final positive matrix, not earlier revisions or deliberately corrupted runs.

This is finite simulation evidence for machine counters and their execution trace. It does not qualify Zicntr, integrated architectural debug, ACT4/Sail conformance, FPGA timing, programming or acquisition service deadlines. The core has no architectural debug entry interface; its CSR bank's debug hooks remain tied low. Separate counter-bank evidence tests those hooks, including debug-entry precedence and stopped counters.

## Reproduction and scope

Run from the repository root:

```sh
python3 microcontroller/tests/run_counter_execution.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator
```

`summary.json` records the actual Verilator version, commands, elaboration parameters and SHA-256 hashes of every attributed input, including the package, observer, fixture, replay helper, runner and Makefile. `sources/` retains those exact inputs. Each attempt retains its own input snapshot and diagnostics under `revisions/`; unsuccessful attempts are not removed. The runner rejects warnings and any input change during qualification. Generated compiler caches are disposable and excluded from evidence.

The four independently elaborated configurations are C enabled with overlap and forwarding, C enabled with overlap and interlocks, C enabled with one-in-flight diagnostic mode, and C disabled with overlap and forwarding. All enable M, Zicsr, Zifencei and machine interrupts for this fixture. The C-disabled profile is a counter test configuration with M enabled; it is not an RV32I-only qualification or a declaration of final core conformance.

Each configuration uses seeds `0`, `1` and `305419896`. The fixed program corpus is independent of the seed. An explicitly seeded xorshift32 generator changes stage holds and instruction-memory service. Every run must reach all five stage-hold bins, all four instruction acceptance-delay settings and all six instruction response-delay settings. Counter read results and execution time may differ with timing; the C-enabled configurations must construct identical program-image digests.

Instruction RAM snapshots requested parcels at acceptance. Its target-owned acceptance-age setting is 0–3 and its response-age setting is 1–6; the fixture registers ownership and service, so these settings are not end-to-end CPU latency claims. Data RAM uses independent acceptance-age and response-age thresholds of 7 and 11. Service continues while pipeline stages stall. Each port allows one outstanding request, retains an immutable descriptor from first offer, and provides one matching response. There is no response reordering or unsafe reset. The fixture gives I and D stress watchdogs 128 clocks, limits each program to 12,000 execution clocks and drains 140 clocks after its terminal exception.

## Requirement-to-test matrix

| Requirement | Independent check and directed coverage |
| --- | --- |
| Count clocks, including stalls and idle | Every non-reset edge advances the cycle reference according to the pre-edge CY inhibit bit. Holds, request acceptance waits, delayed replies, DIV, fences and twelve WFI idle clocks are included. |
| Count actual successful instructions | A separate program oracle validates original PC, raw bits, length, result and terminal disposition before incrementing the retirement reference. Compressed HINT/arithmetic instructions count once. |
| Exclude exceptions and interrupt entry | ECALL, EBREAK, C.EBREAK, illegal instructions, a misaligned load to x0 and six absent counter aliases trap without ordinary GPR/CSR effects or instret increments. External interrupt entry saves the independent boundary PC and does not create a retirement. MRET itself retires normally. |
| RV32 halves and writes | All six CSR forms access each of `mcycle`, `mcycleh`, `minstret`, `minstreth`; reads use the pre-edge value. A half write preserves the opposite pre-edge half and overrides the whole same-counter increment. |
| Read/write suppression | Destination x0 suppresses CSRRW/CSRRWI reads. Source index x0 suppresses CSRRS/CSRRC writes; zimm=0 suppresses CSRRSI/CSRRCI writes. Nonzero register index x5 containing zero still writes and suppresses the same-counter increment. The explicit `nonzero_index_zero_writes` coverage field counts that latter distinction. |
| Inhibition | Masks 0, CY, IR and CY\|IR are exercised. WARL bits are modeled independently. A write changes inhibition for subsequent edges, preserving the old mask's effect on its own edge. |
| Carry and wrap | Separate programs force both low halves through carry and both full counters through 64-bit modulo wrap. Encoded high/low/high CSR sequences are executed. The separate bank fixture tests a forced torn read and the required retry algorithm. |
| Reset and trace identity | Eighteen isolated cold-reset episodes restore counters to zero and inhibition to 5. Only x0 is initially defined in the GPR oracle. Observer capture is armed once; later resets advance epochs without resetting capture sequence or cumulative successful-retirement totals. |
| Physical request conservation | Target offers, acceptances and responses are counted separately from retirement. A rejected misaligned load cannot reach the target. Redirected instruction responses retain physical ownership and are discarded. |
| Instruction conservation | Independently assigned input identities must have exactly one live stage owner until one terminal or explicit kill. No terminal may bypass an older live owner, and no live owner may remain when a program drains. |
| Reconstructible capture | Complete packed observer records, schema, readable edge context and mandatory footer are retained. A standalone Python replay reconstructs counter updates, CSR accesses, GPR operands, PC continuity, instruction owners and bus owners without running the RTL. |

## Trace format and replay

Positive captures reside in the `trace_directory` named by `summary.json`; each result's `trace` is a basename relative to that directory. The archive is deterministic gzip (`mtime=0`). `trace_archive_sha256` hashes gzip bytes. The nested `replay.trace_sha256` hashes the replay input bytes; `trace_hash_encoding` explicitly says `plain_jsonl` for the runner's original capture or `gzip_archive` when the standalone helper is invoked directly on an archive. These hashes are not interchangeable. `aggregate.json` records both original-capture and archive hashes.

The first JSONL line declares `DRG5-OBS1`, packed width, seed and configuration. Each following clock record includes a complete hexadecimal `observe_t` payload and readable edge, reset epoch, sequence, cumulative retirement, counter, terminal PC and original instruction fields. `schema.json` maps every leaf name to width and least-significant bit offset and binds those offsets to the archived package hash. The first isolated capture-rearm record is intentionally invalid with sequence zero. All subsequent records require contiguous sequences. The final JSON line gives exact edge, sequence, epoch and cumulative retirement totals. Truncation, a missing complete middle record, missing footer or observation overflow invalidates the capture.

`trace_t.order` counts instruction terminal events, including traps. Observer `retired_before/after` counts successful retirements independently of architectural counter inhibition and writes. Counter values alone cannot reconstruct the number of instructions that actually executed. The observer retains pipeline ownership and admission masks, original raw/decompressed instruction context, operands, destinations, CSR accesses, faults, reset/debug inputs, interrupt/redirection events and both physical bus descriptors and responses. `schema.json` is authoritative for the complete field inventory.

To replay a retained capture, use the archived helper and package so later source changes cannot alter interpretation:

```sh
python3 microcontroller/tests/evidence/counter-execution-2026-11-04/sources/microcontroller/tests/replay_counter_trace.py \
  microcontroller/tests/evidence/counter-execution-2026-11-04/revisions/10-qualification/c1-d0-f1-seed-0.trace.jsonl.gz \
  --package microcontroller/tests/evidence/counter-execution-2026-11-04/sources/microcontroller/rtl/drg5_control_pkg.sv
```

The replay independently checks counter/inhibit CSR suppression, pre-edge read values, requested writes, destination selection and returned old values. For other instruction classes it reconstructs recorded architectural flow and operand consistency; the SystemVerilog program oracle provides the instruction-result reference. Neither checker is advertised as a complete independent ISA model.

There is no optional hardware trace RAM in this implementation. Host serialization does not stall the CPU. The passive observer reports identity/count overflow as invalid evidence rather than silently wrapping a usable capture; the separate observer fixture exercises reduced-width overflow. File loss is detected by continuity and the mandatory footer, and archived bytes are covered by hashes.

## Review and revision record

| Attempt | Observed result and resulting change |
| --- | --- |
| 01 | Strict parsing rejected a hexadecimal literal adjacent to `?`; token spacing was corrected. |
| 02 | Strict lint exposed newly added observer I-fatal pins and unused high bits of array indices; the pins and bounded indexing were completed without warning waivers. |
| 03 | Runtime stopped on a fixture sampling error: it observed a transient combinational fetch-fatal indication between response consumption and responder deassertion. |
| 04 | Moving the ledger into one posedge monitor reduced generated C++ size and compilation cost; the same sampling failure remained, so this was not recorded as a functional fix. |
| 05 | Pre-edge protocol-fatal sampling and a settled observation phase resolved that issue. The next failure exposed a wrong fixture assumption that read strobes were 15; this bus correctly uses zero read strobes. |
| 06 | Corrected the read-strobe expectation. The first complete smoke program set and standalone trace replay passed. |
| 07 | Replaced low-bit LCG scheduling with xorshift and required coverage of every stage and service-delay setting. The strengthened smoke test and replay passed. |
| 08 | Six complete matrix runs and replays passed, then a later compiler process failed with `Disk quota exceeded`. This was an environmental interruption, not a counter failure. Source and diagnostic evidence were preserved. |
| 09 | Reclaimed only disposable completed build caches, added automatic post-profile cache cleanup and explicit trace-directory metadata. The full matrix and seven detector calibrations passed. |
| 10 | Corrected a misleading coverage-label name, made capture/archive hashes explicit, and strengthened offline CSR destination/return checks with a dedicated corruption calibration. The final result and totals are recorded in the adjacent machine-readable summaries. |

Runtime negative controls corrupt one observed cycle increment, one compressed-instruction increment and one trapping-instruction increment. Offline negative controls remove a complete record, remove the footer, inject observer overflow, corrupt the post-edge counter with consistent readable metadata, and corrupt a CSR returned old value while preserving its independent CSR-access fields. Each must fail at its named detector; an unrelated failure, timeout or ordinary PASS marker does not qualify a detector.

All initial failures above were fixture construction, fixture sampling or host resource issues. This execution work did not discover or claim a production counter arithmetic defect. The finite passing corpus and calibrated detectors support the stated counter/trace scope; they do not prove every possible program or schedule.

# Mixed-width execution qualification, 4 November 2026

## Evidence record

The real `drg5_frontend` and `drg5_control` pass six configurations × three seeds, with four calibrated negative controls. [summary.json](summary.json) binds the actual RTL, fixture, runner and Makefile. [aggregate.json](aggregate.json) independently totals the positive results.

| Configuration | C | M | Occupancy | Forwarding |
| --- | --- | --- | --- | --- |
| c1-m1-d0-f1 | Enabled | Enabled | Overlapping | Enabled |
| c1-m1-d0-f0 | Enabled | Enabled | Overlapping | Interlocked |
| c1-m1-d1-f1 | Enabled | Enabled | One instruction | Enabled |
| c1-m0-d0-f1 | Enabled | Disabled; raw M traps | Overlapping | Enabled |
| c0-m1-d0-f1 | Disabled | Enabled | Overlapping | Enabled |
| c0-m0-d0-f1 | Disabled | Disabled | Overlapping | Enabled |

All use the real IRQ-enabled controller, two-bit fetch generations and 64-clock I/D stress deadlines. C-disabled profiles retain IALIGN=32 and reject short prefixes; they do not inherit compressed test claims. The seeds are `0`, `1` and `305419896`.

Final positive totals are **1,041 cases, 436,413 sampled edges and 12,412,093 comparisons**: 20,988 normal retirements, 1,053 traps, 52 killed instructions, 3,875 compressed retirements and 362 retired 32-bit instructions starting in an upper halfword. The 765 NOP/HINT semantic retirements include ordinary C.NOP. The corpus executes 180 unconditional transfers and 441 conditional branches.

Instruction requests conserve **40,905 offers = acceptances = replies**. Data requests conserve **1,260 offers = acceptances = replies**; the 60 deliberately rejected accesses have no effects. The other data transactions produce exactly 564 reads and 636 writes. There are 1,152 stale instruction responses, including 12 measured response/error handshakes coincident with an actual redirect input. These are finite observed totals, not claims that all possible schedules were enumerated.

The program builder writes raw encodings and separately supplies requested operation semantics. The retirement oracle uses those semantics and independent architectural registers/memory; it never reads the DUT's expanded instruction to obtain the expected result. Original PC, bytes, byte-valid mask and length are checked both against program storage and against the originally admitted packet. A live-UID ledger checks every stage after each edge, with explicit retirement and cancellation dispositions.

The instruction target samples bytes once at acceptance, returns only requested parcels and zeros absent/faulted lanes. Instruction and data acceptance delays are independent from their post-acceptance response delays. Physical data effects occur once at acceptance and have a separate architectural-effect reference. MMIO reads and writes increment a target counter; a load into x0 still performs the read. No response-loss replay is modeled or authorized.

Program data use a separate LCG stream from stage holds and target service. For each seed, the forwarded, interlocked and diagnostic C1/M1 profiles now execute identical generated images and produce matching 64-bit program, retirement and physical-effect digests. Every run also performs its ordinary per-event semantic comparison. Matching finite digests are corroborating evidence, not a collision-free formal equivalence proof. C/M-disabled profiles intentionally execute different architectural outcomes.

| Requirement | Executed cases and check |
| --- | --- |
| Every integer C format | Directed arithmetic, compact-register and stack memory, C.J/C.JAL/C.JR/C.JALR, C.BEQZ/C.BNEZ and C.EBREAK; seeded 128-instruction mixed program. Exhaustive 65,536-encoding classification belongs to the separate decompressor unit evidence. |
| HINT behavior | Every C HINT family and C.NOP retire once without GPR or memory changes; undefined nonzero registers are not used by the independent HINT oracle. |
| Illegal code points | Zero ADDI4SPN/ADDI16SP/LUI, LWSP x0, JR x0, custom RV32 shifts, absent floating-point forms and RV64 arithmetic at PC mod4=0/2. |
| Original identity | Raw bits, byte-valid mask, length and start PC remain exact through every stage, stall, trap and cancellation. |
| Links and target alignment | C.JAL and C.JALR use PC+2; C.JALR with rs1=x1 reads old x1 before link write; odd register target clears bit zero; taken and untaken compact branches and halfword targets. |
| Wide instructions crossing a word | Mixed programs place 32-bit arithmetic, M operations, WFI and MRET at PC mod4=2; a word beginning at `0xfffffffe` consumes its second half at address zero and continues at PC2. |
| First/second fetch faults | Both start alignments retain the instruction-start mepc; second-parcel faults retain only original low bytes and set mtval=start+2. Both error positions total 54 checked traps each across final profiles. |
| Safe parcel boundaries | A complete 16-bit instruction at the last executable parcel succeeds without accessing its denied neighbor; a 32-bit instruction needing that neighbor faults at its own start. No instruction request reaches a peripheral region. |
| Stale errors | Delayed offered and accepted wrong-path second parcels drain after redirect; a third case handshakes the error on the redirect edge itself. |
| Finite service/stall grid | Each C-enabled run enumerates acceptance delays0–3 × response waits0–3 × two wide-instruction alignments:32 cases with rotating stage holds, memory dependencies and a taken C branch. Response wait zero means the next registered edge after acceptance; this target does not produce a same-edge combinational acceptance response. |
| Independent randomized stalls | All five stages receive seeded backpressure; I acceptance0–4 and response1–6 are independently selected. Directed stale-response cases use18 clocks in either phase. |
| Compact memory faults/effects | C.LWSP x0 with MMIO SP traps without reading; C.SWSP x0 writes zero once. Stack and compact-register loads/stores check natural alignment and guaranteed-no-effect data errors. An older delayed data fault wins over a younger C.EBREAK/store. |
| Trap/MRET alignment | A C.EBREAK at PC10 preserves mepc bit1. A real CSR handler reads10, writes15 (WARL14), and MRET resumes at PC14. |
| WFI/IRQ through real fetch | Raw WFI at PC34 straddles a word, then a retained external event wakes the idle core. IRQ mepc is38; the handler masks mie while the level remains pending, and a straddling MRET resumes the compact instruction at PC38. No new fetch launches while entry is pending. Twelve final IRQs are checked. |
| Late producer dependency | Signed DIV at an upper halfword feeds C.ADDI and a taken C.BEQZ. Overlapping profiles observe22–24 edges with an unfinished M producer and a compact consumer waiting; diagnostic mode intentionally cannot overlap them. |
| Detector sensitivity | Corrupt original bytes, observed trap PC, observed link result, or a physical MMIO write effect; each must fail its exact ordinary comparator and cannot print a success terminal. |
| Failure reproduction | Exact tools/commands/seeds and source snapshots; each first failure prints owner state and the preceding32 sampled instruction/stage records. |

Actual revision history is retained under `revisions`:

1. Initial source and strict lint findings, including missing width-use annotations and one lexical spacing error.
2. Additional fixture-only lint correction.
3. First functional run exposed a fixture sampling race: the checker observed a combinational fatal condition after the manager consumed a response but before the target cleared its response. Sampling that observation at the actual edge fixed the oracle; no production RTL changed.
4. Follow-up width-use annotation after adding wrapped fetch storage.
5. First50-case real-frontend smoke pass, including WFI/IRQ and CSR return.
6. Expanded83-case smoke pass with deterministic service grid and coincident redirect/error response.
7. Expanded84-case smoke pass adding the late DIV-to-C dependency.
8. First full six-profile/three-seed run and all four detectors passed. Review found that a shared program/service RNG made diagnostic timing change later generated programs, limiting the equivalence claim.
9. Final qualification separates the RNG streams and requires matching same-program architectural/effect digests across occupancy profiles; all18 positive runs and four detectors pass again.

No RTL defect was identified by this fixture. The independent classification unit, old fetch formal checks and the broader legacy regressions remain separately scoped evidence. This record is finite simulation; it does not establish ACT4/Sail compliance, all-input formal coverage, compiled firmware timing, ADC/DMA integration, FPGA routing/frequency, board programming or architectural debug. The64-clock stress deadline and deliberately controlled handler are not a production interrupt-latency claim.

Reproduce from the project root:

```sh
python3 microcontroller/tests/run_compressed_execution.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-compressed-execution
```

Each invocation retains an attempt's sources and logs before qualification. Only a complete passing full run replaces the primary summary; a smoke run or failure remains in its own revision directory. `SHA256SUMS` seals the final evidence tree.

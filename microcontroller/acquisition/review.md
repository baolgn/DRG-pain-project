# ACQ-R1 definition review

Reviewed 2026-11-05 against baseline commit `f46110aafafa6e7ae68029486fd64a05e9b9f5ad`. This review covers the [behavior contract](contract.md), [ADC profile](adc-profile.md), [architecture guide](README.md), definition completeness and source-comment consistency. It does not report an implemented acquisition engine or a passed hardware qualification.

The definition evidence below belongs to commit `584743d`; its recorded document hashes preserve that revision. The subsequent [board qualification](board-qualification.md) tightens the initial VDRIVE allowance to the direct ECP5 interface's 3.135–3.465 V envelope and adds paired-rail/sequencing requirements. The old definition-check files are retained unchanged, not relabeled as measurements of a board or the revised electrical profile.

## Revisions and findings

The following findings led to corrections in the ACQ-R1 definition.

| Area | Finding | Correction |
| --- | --- | --- |
| 1. Existing design boundary | Diagrams left mode alternatives, record packing and closure meanings open; synthetic guard could be mistaken for a physical ADC receiver | Named one normative ACQ-R1 profile, rejected every other tuple, separated implemented guard from future engine, and stated the conditioned-voltage/Abbott boundary |
| 2. Manufacturer and ADC profile | Register defaults are not the recording image; ADC edge direction and CRC prose require care | Froze register bytes, internal reference, exact silicon ID, VDRIVE restriction, mode-2 edges, service-only test mode, pipelined register responses and CRC-enable transition; compared local datasheet and ADI driver |
| 3. Timing and encoding | A 2 µs BUSY bound plus 11.2 µs clocks and guards cannot fit the old 13 µs overall target; partial words lacked presence semantics | Selected a 1072-tick conservative budget and 1120-tick deadline; froze signed18 order, presence mask, 48-byte records, 64-byte headers and CRC32C |
| 4. Lifecycle | A single occupied response slot could not report busy; synchronous zero-slot stop was unreachable; time uncertainty was absent from the explicit validity formula | Separated admission/final-completion/service paths, constrained zero-slot outcomes to pre-first-edge isolation, added TIME_UNCERTAIN to validity, and made suspicious bad-CRC status stopping mandatory |
| 5. Ownership | Block-sequence allocation, terminal acknowledgement, same-edge STOP/ARM and CPU halt outside RUN needed explicit outcomes | Defined publication sequence allocation, archive acknowledgement before restart, global fault/STOP precedence, service cancellation, pre-edge capacity and persistent CPU-independent drain |
| 6. Loss and commands | Notification-only overflow conflicted with uncertain slot accounting; stale service acknowledgements and integer maximum behavior needed distinction | Distinguished counted event loss from missing boundary evidence, specified rejection/no-op outcomes, and separated exact exhaustion from arithmetic overflow |
| 7. Consistency and source checks | A prose review alone cannot establish byte sums, CRC arithmetic or unchanged code behavior | Checked layouts, signed codes, independent CRC recurrences/polynomial division, timing/storage arithmetic, source tokens, Python syntax and document links; results below |

## Definition coverage

| Required meaning | Final location |
| --- | --- |
| Supported/unsupported ADC combinations, reference, calibration, channel map and configuration | Contract input/configuration sections; complete ADC image and startup sequence in profile |
| SAFE, CONFIGURING, READY, RUN, STOPPING, DRAINING, CLOSED, FAULT | State table plus global priority, command matrix and default rejection |
| Cadence, simultaneous channels, marker vs aperture vs host time | Cadence section and physical timing qualification |
| Reset, rate/timebase and relevant analog changes ending epochs | Epoch boundary table, immutable descriptor/timebase identity, quality amendments |
| Valid, invalid, partial, missing, stale, untriggered and lost data | Conversion table, explicit validity formula, presence/flag definitions and terminal ledger |
| Normal stop, exact fault/loss closure, uncertain closure and no terminal evidence | Stop/loss outcome table and archive `INCOMPLETE` inference |
| CPU, interrupts, debug/reset, ownership and restart | Independent service paths, IRQ semantics, CPU responsibility table and restart predicates |

Unknown input/format combinations have explicit rejection or fault behavior. A rejected change does not end an unchanged epoch; an actual change does. Physical unknowns are qualification failures or uncertain outcomes, never invented measurements. MMIO addresses and host-container transport remain future bindings to these logical semantics; neither is represented as an implemented API.

## Checks and retained evidence

- [Definition consistency](evidence/definition-2026-11-05/definition-check.json): 61 checks passed. These cover record/header byte coverage, all flag bits, eight signed18 pattern values, CRC16 `064E → 2137`, both 208-bit status-pattern CRCs using recurrence and independent polynomial division, CRC32C `123456789 → E3069283`, timing margins, throughput/storage and integer-boundary examples. Nine changed coding files match the baseline's executable tokens. The report binds the final contract/profile hashes.
- [Comment audit](evidence/definition-2026-11-05/comments.json): all 205 active source/build files, 6,869 comments, 2,164 nonempty SystemVerilog begin blocks, 717 declarations, 1,732 Python scopes and 520 C/C++ scopes; no reported case or scope-context findings.
- [Manual comment review](evidence/definition-2026-11-05/comment-review.json): added 37 concise lowercase explanations across nine files, covering assembly blocks, interrupt setup/dispatch/return, conditional negative tests, linker sections and board pins. Existing names, acronyms and units retain their proper case. All 93 active Python files compile; no active tracked code file is absent from the audit inventory.
- [Final repository checks](evidence/definition-2026-11-05/final-check.json): local links resolve, changed code tokens remain identical, and whitespace validation passes. No CPU/ADC functional change is claimed from comment edits.

The comment scope is all active first-party coding/build files. Historical checksum-bound source snapshots, third-party archives and generated outputs remain historical evidence. Rewriting their comments would change the bytes underlying old results rather than improve current code. The lexical audit cannot prove prose truth or concision; manual review supplements it, especially assembly, linker and single-statement control blocks. Existing historical evidence remains applicable to its original source hashes.

Physical ADC capture, the full control/MMIO binding, external FIFO/DMA/memory, host persistence and independent-supervisor behavior still require implementation and the explicit release gates in the contract. No hardware test, new RTL qualification or end-to-end recording pass is implied by the 61 definition checks.

## Subsequent timing review

ACQ-R1 revision 3 adds the [timing budget](timing-budget.md) and its separate [review evidence](evidence/timing-2026-11-05/review.json). It distinguishes the exact 1068-tick completion from the conservative 1072-tick allocation, retains the 1120-tick deadline, and adds tolerance, external min/max paths, bounded service/storage waits and independent supervision. The earlier evidence above remains tied to its original revision; it is not a validation of these new requirements. Physical timing closure is still pending.

## Subsequent format review

Revision 4 freezes the [binary formats](formats.md) and records separate [format evidence](evidence/formats-2026-11-05/review.json). Independent implementations check exact packing and reject contradictory flags, unbound/mutated context, stale leases, impossible stream histories and inconsistent loss metadata. The prior definition and timing evidence remains unchanged and bound to its original sources; this format work does not qualify hardware capture or atomic publication.

## Subsequent clock/reset lifecycle review

[ACQ-R1-CDC1](clock-reset-lifecycle.md) supplements revision 4 without changing its binary formats. Separate [lifecycle evidence](evidence/lifecycle-2026-11-05/review.json) records finite reachable-state exploration, deliberate failing controls and source-comment checks. Corrections cover delayed bilateral fences, ARM-created epoch binding, stopped-clock supervision, CPU-reset request retention and uncertain publication. These abstract results do not certify RTL or physical CDC/reset behavior.

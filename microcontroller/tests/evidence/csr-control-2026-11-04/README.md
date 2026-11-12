# Encoded CSR and trap integration qualification

This evidence qualifies the `OP_MACHINE` raw32 packet-entry prototype, not a complete CPU or the future B1/F configurations. The default `misa` remains RV32I; `mimpid` remains zero. `C_ENABLED=1` checks the parameterized `mepc` alignment path only, without claiming a compressed decoder or C-enabled ISA image. Architectural interrupt delivery, architectural debug, WFI, FENCE.I, production frontend integration, ACT4/Sail conformance, routing, timing and board programming are outside this result.

## Table of contents

1. [Revision history](#revision-history)

The fixture independently decodes supplied instruction bits, reconstructs operand intent, maintains GPR definedness and machine state, and compares the complete terminal packet and trace. It computes CSR read/write permission and suppression from encoded indices, not source values, and models dynamic CSR values from its own pre-edge state. Every accepted identity must have exactly one stage owner. A separate target ledger checks each accepted MMIO effect; memory completion must already be registered before the retirement edge begins.

The directed corpus covers six CSR forms, x0 versus nonzero zero-valued register sources, discarded destinations, source/destination aliasing, read-only and absent addresses, writable constant CSRs, WARL/WLRL values, counters and inhibit timing, held dynamic reads, nested ECALL/EBREAK traps, MRET alignment, returned-target faults, supplied earlier fetch faults, malformed SYSTEM instructions, pending flushes, delayed or rejected older MMIO, reset and fatal containment. Random cases supplement this corpus with an explicit 32-bit LCG and three retained seeds.

| Requirement | Executed stimulus | Independent detection |
| --- | --- | --- |
| Six Zicsr forms and exact access suppression | 36 form/destination/source partitions; 36 read-only/absent permission partitions; rd=rs1 aliases | Complete packet/trace, GPR state, separate read/write validity; read/write detector controls |
| Completed M-only inventory | Every scalar CSR; HPM window boundaries; absent lower-privilege/debug/PMP/counter aliases | Independent address table, legal-value coercion and actual stored state; storage detector control |
| Dynamic counters and pending state | Rollover, half writes, old inhibit timing, zero-valued nonzero sources, held reads | Per-edge 64-bit independent state, preparation versus retirement samples; stale/counter detector controls |
| Precise traps and MRET | ECALL, EBREAK, nested entry, alignment masks, illegal SYSTEM/CSR, earlier fetch faults, returned-target fault | Trap state, whole terminal and redirect targets; return detector control |
| Ordered memory and cancellation | Offered/accepted side-effectful reads/stores, delayed/rejected responses, older load dependencies, simultaneous flush | Separate request/effect ledger, pre-edge completion prerequisite, exact live identity multiplicity |
| Reset/fatal priority | Prepared CSR and MRET with reset or ownerless response | Atomic storage, trace/kill/redirect and fatal record comparison; kill detector control |
| Varied operands and stalls | 32 cases per seed with three seeds in both alignments | Recorded address/form/hold/source/destination bins and minimum coverage guards |

**Passed:** six behavioral runs (two alignment elaborations × three seeds), totaling 1,062 scenarios, 36,316 checked edges, 6,605,152 checks, 4,758 successful retirements, 384 precise traps and 60 offered/responded memory operations. All fourteen detector runs failed at their intended comparators. Strict Verilator lint produced no warnings or HDL waivers. `summary.json` retains exact commands and the fourteen source/build-input hashes; `sources/` preserves those bytes. `verification.json` records independent result/log/hash checks and generated executable hashes.

The final random-address masks are `0xffff`, `0xbfff` and `0xfed7` for seeds 0, 1 and 305419896: 16, 15 and 13 distinct address choices. Destination masks cover 18, 19 and 17 GPR indices respectively. Each run reaches every CSR form and hold duration, and both register-source classes. These masks match an independent replay of all 256 LCG draws per seed. This measured coverage supplements the fixed directed corpus; it is not an exhaustive program-space proof.

The pinned simulator is Verilator 5.047 (`v5.046-19-ge9dd6eaaf (mod)`) from OSS CAD Suite 2026-03-01. Tool and bundle hashes are in `tool-binaries.json`. Reproduce with `python3 microcontroller/tests/run_csr_control.py --verilator /path/to/oss-cad-suite/bin/verilator --build /tmp/drg5-csr-control-tests`; the runner always uses the three recorded seeds and strict flags.

## Revision history

1. `revisions/01-resumed/` preserves the earliest available incomplete fixture. Earlier development snapshots are unavailable.
2. `revisions/02-reviewed-fixture/` removes obsolete unused ports, adds a pre-edge registered-response prerequisite, counter write-suppression cases, a fault at a returned-to target, fatal/MRET collision, and initial random cases. The retained preliminary lint log precedes the final ordinary comment additions in this snapshot; the executable build logs bind the compiled revision. This variant's low-bit LCG selection was subsequently found to repeat only two address choices per seed. Its six behavioral runs and fourteen calibrated detector runs passed; the source-bound results remain intermediate because of the subsequently identified coverage weakness.

3. `revisions/03-random-coverage/` preserves the corrected high-bit generator selection, explicit coverage bins/guards, and fuller failure context. It changes test quality without changing production RTL.

The negative controls corrupt observed fields and must fail their ordinary comparators. They qualify the checkers; they do not establish exhaustive RTL mutation coverage. Full standalone CSR address/intent enumeration and the bank induction proofs under declared caller assumptions live in the separate CSR bank evidence directory.

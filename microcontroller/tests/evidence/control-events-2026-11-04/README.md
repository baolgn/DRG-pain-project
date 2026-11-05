# Control-flow event evidence

This follow-up executes previously source-reviewed event interactions of the existing packet-control prototype. It does not add production RTL or establish full CPU/ISA conformance. Branch/JAL instructions use actual decode and X execution. CSR, MRET, load and ordinary result operations are explicit synthetic packets; no CSR instruction decoder, compressed decoder or production CPU top is claimed.

Reproduce from the repository root:

```sh
python3 microcontroller/tests/run_control_events.py --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator --build /tmp/drg5-control-events-recheck
```

The runner accepts another explicit simulator path. The tested executable reports `5.047 devel rev v5.046-19-ge9dd6eaaf (mod)` from OSS CAD Suite 2026-03-01. Both C0 and C1 elaborate with overlapping occupancy. Every build uses fatal `-Wall` diagnostics and active `--assert`, without warning waivers. `-CFLAGS -O0` affects generated C++ optimization only. The scenarios are deterministic; `+verilator+seed+1` fixes simulator initialization.

Both configurations passed 11 scenarios, 47,931 comparisons, and 279 clock edges: one isolated bootstrap reset edge before observing DUT state, followed by 278 checked edges. Each run observed 29 terminal attempts (26 normal retirements and 3 traps), 7 exact instruction kills, 7 accepted flushes, 4 completed external-flush redirects, 3 required flush-abort pulses, and 4 completed load obligations. The 13 reset edges include the bootstrap, 11 per-case cold resets, and one directed hart reset.

| Event category | Cases per configuration | Required observation |
|---|---:|---|
| Held normal W JAL / taken BEQ | 2 | Flush kills the instruction, redirects once, and commits no link |
| Held faulting W control | 1 | Flush is accepted and remains pending through three held clocks; releasing W traps once and aborts the flush |
| Younger independent X jump behind issued load | 4 | First-valid OFFER and accepted WAIT phases, each with success and access-error responses; the younger jump dies while the load remains protected through W |
| Hart reset of held W jump | 1 | No old link or redirect; UID/order behavior is preserved and a new packet executes after reset |
| Software mepc write/readback and MRET | 1 | Writing 0x203 reads/returns as 0x200 in C0 or 0x202 in C1; MRET restores MIE, then a real JAL executes from that return PC |
| CSR W bypass to both equal branch sources | 2 | D transfers on the actual CSR W edge, with both captured source values equal to the independent old CSR value or read-suppressed zero |

C0's held-fault case is a taken JAL to a word-misaligned target. C1 allows every even target, so its held-fault case uses an illegal branch encoding. These deliberately distinct causes exercise the same pending-flush protection rule. The CSR mtvec setup separately confirms word alignment in both configurations.

The reference owns accepted UIDs, original packets, independently constructed normalized control expectations, GPR/CSR state and architectural PC. It predicts the exact kill set, W eligibility, flush acceptance/completion/abort, redirect and first-valid memory grant. Every live UID must occupy exactly one stage. The independent issued-memory bit persists after a bus response until W disposition; manager-busy is not its authority. A successful load's trace keeps its sequential continuation even if the same edge publishes the external flush target; a rejected load traps and aborts the flush. Exact D-capture packet checks distinguish correct dual-source bypass from merely obtaining the same branch outcome.

Three observation-corruption types run separately in both configurations: an unauthorized kill, a missing flush-abort observation, and an incorrect MRET trace continuation. All six must fail at their named detector with a nonzero exit and no passing record. These calibrate the comparators and are not mutations of implementation RTL.

This fixture's executed reset collision is a held normal W jump. Reset plus outstanding data ownership remains covered by the separate legacy manager/control regressions; it is not newly claimed here. Previous control-flow and control-fetch evidence remains independently scoped.

Independent review found and corrected a fixture startup assumption: the first checked case previously inspected stage bits before any reset. The explicit isolated bootstrap now precedes all checked DUT observations. No production RTL defect or change was required.

`summary.json` records exact commands, tool version, results and SHA-256 values of all compiled sources, macro header, runner and Makefile. Hashes matched before and after qualification and again at retention. Complete build/run and expected-failure logs are retained here. Generated binaries/C++ remain outside the repository; `SHA256SUMS` covers this evidence bundle.

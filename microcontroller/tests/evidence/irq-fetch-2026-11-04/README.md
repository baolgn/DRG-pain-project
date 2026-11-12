# Real-fetch interrupt boundary qualification

## Evidence record

The actual `drg5_fetch` manager and `drg5_control` machine decoder passed offered
and accepted I-owner interrupt scenarios under separately elaborated four-edge and
32-edge request deadlines. The ordinary mepc comparator rejected its deliberate
single-observation corruption. All HDL compiled with strict `-Wall` and no waived
warnings. `summary.json` binds the full participating RTL, include, fixture and
runner source set; `sources/` preserves those exact bytes.

| Profile | IRQ raised during | Longest I lifetime | IRQ entry | First handler instruction in D |
| --- | --- | --- | --- | --- |
| I4 | Unaccepted offer | 3 edges | 2 cycles | 9 cycles |
| I4 | Accepted request awaiting response | 4 edges | 3 cycles | 10 cycles |
| I32 stress | Unaccepted offer | 22 edges | 21 cycles | 28 cycles |
| I32 stress | Accepted request awaiting response | 22 edges | 21 cycles | 28 cycles |

I lifetimes count inclusive sampled edges from the first observed request-valid
through the matching response handshake, independent of the manager's launch pulse.
The test captures `first_offer_edge` only when request-valid is physically observed;
the completion check uses `completion_edge - first_offer_edge + 1 <= I_LIMIT`.
The displayed per-case I maximum is cumulative within its elaborated profile.
IRQ latency begins at the first clock edge sampling the newly asserted external
level and ends at registered IRQ entry or actual handler-PC `0x100` in D.
The I4 worst case of 10 cycles is below the 224-cycle first-handler-D budget for
these assumptions. I32 is deliberately separate stress evidence, not an F80
service or physical clock-frequency claim. This fixture does not measure division,
debug halt or a complete firmware register-save sequence.

The ROM program initializes x1, writes `mtvec=0x100`, enables MEIE, sets MIE with
encoded Zicsr instructions, and runs a NOP prefix. At the actual `0x40` I request,
the test asserts and retains MEIP while independently delaying either acceptance
or response. The responder eventually returns a canonical guaranteed-no-effect
instruction access error. Entry must wait through that old ownership, including
the completion edge. The error can enter the fetch buffer while IRQ entry is
pending; the IRQ redirect discards it before architectural admission. It is not
claimed as a stale bus response dropped before the redirect.

The bridge connects `fetch.busy_o` directly to `control.fetch_busy_i`, gates new
fetch launches with `run_enable && !entry_pending_o`, returns CPU redirects to
fetch, and preserves original instruction bytes/fault metadata in `OP_MACHINE`
packets. Synchronous target state records every offered descriptor, acceptance
and response independently. Assertions check immutable stalled descriptors, no
duplicate accepted offer, tag order, exact one-response conservation, and the
actual service lifetime. No modeled busy surrogate replaces manager ownership.

Retirement must follow the independent original-PC/raw-instruction sequence with
monotonic retirement order and no fault record for `0x40`. IRQ entry must have no
simultaneous retirement, capture the next unretired PC in mepc and the IRQ record,
set external interrupt cause/zero mtval, and redirect to the programmed vector.
The handler initializes x11 and stores the independently expected `0x800` to
`0x20000000` exactly once; its store retires only after that effect. The ordinary
store responder accepts once and replies on the following edge. Prefetch drains
before each new isolated reset epoch.

Reproduce from the repository root:

```sh
python3 microcontroller/tests/run_irq_fetch.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-irq-fetch-repeat
```

The recorded tool is Verilator `5.047 devel rev v5.046-19-ge9dd6eaaf (mod)`.
The Makefile `irq-fetch` target runs the same source-bound qualification. Full
commands, positive measurements and the intended detector failure are retained
in the accompanying logs. This remains a non-C verification bridge, not a
production frontend, formal proof, physical FPGA qualification or full-system
latency measurement under all memory-contention cases.

The first fixture failed strict lint because it initialized signals also driven by `always_comb`
and left diagnostic bits unconsumed (`revisions/01-initial-fixture/`). Those were
corrected without warning suppression. The first executable fixture then reached
the handler but incorrectly expected D tag zero; the existing manager allocates
its first D tag as one (`revisions/02-first-execution/`). Correcting that fixture
expectation produced the first passes. A subsequent independent control review
found UID-exhaustion discovery could collide with pending IRQ entry for a held
input that was not permitted to allocate. The root implementation added the
IRQ/WFI allocation veto to exhaustion discovery and defensively excluded new UID
containment from the safe-entry predicate. `revisions/03-before-uid-admission-review/`
retains the preceding passing logs and full source set. Both profiles and the
detector were rerun against the corrected, frozen core; the final source-bound
measurements above are unchanged. Seeded exhaustion collision tests belong to the
separate IRQ-control evidence, not this fetch fixture. No earlier snapshot is
claimed to have passed against the corrected source.

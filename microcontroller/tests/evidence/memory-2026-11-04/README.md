# Decoded-memory integration evidence

## Evidence record

This qualification exercises real raw-32 OP_MEMORY load/store decode, real RF operand capture and dependency handling, X effective-address/lane formation, pre-offer permission checks, and a surviving single-request manager through terminal disposition or containment. It remains a packet-control prototype, not a complete CPU or ISA-conformance result. C_ENABLED stays 0 in this fixture; C1 mapping and migrated control/event tests have separate evidence. Non-memory/control setup operations remain explicit synthetic packets.

Reproduce from the repository root:

```sh
python3 microcontroller/tests/run_memory.py --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator --build /tmp/drg5-memory-recheck
```

The runner accepts another explicit simulator path. The tested executable reports `5.047 devel rev v5.046-19-ge9dd6eaaf (mod)` from OSS CAD Suite 2026-03-01. Every build retains fatal `-Wall` and active `--assert`, without HDL warning waivers. `-CFLAGS -O0` changes generated C++ optimization only. Completed precompiled-header/object/archive caches are removed after linking to bound temporary disk use; generated source, executable binaries and logs remain outside the repository.

Four elaborations and eight positive runs passed:

| Configuration | Schedule seed | Cases | Clock edges | Checks | Offers / matching replies |
|---|---:|---:|---:|---:|---:|
| minimum | 1 | 3 | 52 | 402339 | 3 / 3 |
| base | 0 | 142 | 3410 | 15060124 | 126 / 126 |
| base | 1 | 142 | 3285 | 15037907 | 126 / 126 |
| base | 305419896 | 142 | 3403 | 15058865 | 126 / 126 |
| enabled | 0 | 142 | 3424 | 15062630 | 129 / 129 |
| enabled | 1 | 142 | 3289 | 15038645 | 129 / 129 |
| enabled | 305419896 | 142 | 3432 | 15064047 | 129 / 129 |
| diagnostic-default | 1 | 14 | 303 | 1528422 | 10 / 10 |

Across the eight runs: 869 case executions, 20,598 clock edges and 92,252,979 assertion checks. Clock counts include one explicit isolated bootstrap edge per run before any checked DUT observation. Terminal-attempt counters include both normal retirement and traps; 1,962 terminal attempts include 169 traps. Matching reply totals include contained late, uncertain or malformed replies that match an owned request; separate injected orphan/wrong-tag responses appear in the response logs.

The two main profiles use overlapping occupancy and deadline 128 with the explicit test error windows enabled. `base` keeps instruction-RAM writes and the timer aperture disabled; `enabled` enables both flags. Its timer aperture is a deterministic plain-register target used to verify guard forwarding, not a timer/IRQ implementation. `diagnostic-default` instantiates all control defaults, including one-instruction occupancy, disabled test windows/optional regions and deadline 128. `minimum` separately exercises the advertised deadline of one clock, including acceptance and matching response on that final edge and first-edge timeouts before/at acceptance.

The main runs cover every aligned byte/halfword/word lane; signed and unsigned loads; canonical narrow stores; destination/source overlap; same-register store sources; negative load displacement and modulo-32-bit address wrap; natural alignment and region denial before first valid; illegal load/store funct3 and malformed/prefault metadata; x0 success, access rejection and effectful reads; ordinary and nearest-producer dependencies; load-to-load/store W forwarding; and held older normal/fault/control disposition before younger MMIO effects.

The physical target and architectural reference use separate RAM arrays, aperture registers and device counters. Actual accepted commands service the target directly, with no tag deduplication. Expected effects use immutable validated instruction intents and separately maintained state. All RAM bytes, including untouched neighbors, and every aperture register are compared. READ_TICKET increments once even when rd=x0; WRITE_TICKET preserves its payload. Wrong direction/reserved MMIO registers, target errors and invalid uncertainty-register offsets/widths return status01 with no effect. The uncertainty window has one word register at offset zero. Explicit status10 scripts choose zero or one actual effect for both effectful MMIO reads and writes; neither outcome permits replay.

Four decoded-memory flush cases cover effectful reads and stores in offered and accepted phases. The issued-token reference persists after response capture until W; the successful trace retains its instruction continuation while the external flush selects the next stream. Three hart-reset phases cover an unaccepted offer, an accepted command and acceptance on the reset edge, retaining target effects while suppressing orphan retirement. Default-deadline OFFER/WAIT timeouts cover both effectful reads and stores, including late ordinary acceptance/response. The snapshot comparison checks the first fatal reason and exact original exposure, remains unchanged across later drainage and hart reset, and clears only under qualified cold isolation. Wrong-tag, premature, duplicate, orphan, malformed-data, status10 and status11 replies have explicit directed cases. A matching response on the exact final allowed edge succeeds. Public fatal status is checked before and after edges so a transient pre-deadline pulse cannot pass merely because the final snapshot is clear.

Schedules use the documented full-period LCG32: `state = (1664525 * state + 1013904223) mod 2^32`. Seeds 0, 1 and 305419896 are explicit and independent of the fixed simulator initialization argument `+verilator+seed+1`. Each offer logs selected `accept_extra` and `response_edges`; actual ACCEPT and RESPONSE rows retain cycle, identity/descriptor, status and effect context. Without a directed hold, a request first presented after edge L is accepted at L + accept_extra + 1; the registered target responds at acceptance edge A + response_edges. All selected acceptance values 0–3 and response values 1–5 were observed across the main runs. Directed holds/reset/error scripts override ordinary timing and remain visible in actual edge rows. Only the separate minimum-deadline compatibility case accepts and responds on the same edge. The `*-schedule.log` files extract these rows; full `seed-*.log` files retain pass/failure context.

Five deliberately activated detector types run under both guard profiles, for ten expected failures: ownerless request-valid observation, corrupted store-lane observation, an extra physical device read effect, incorrect load writeback, and an incorrect deadline exposure snapshot. Each must fail at its named detector with nonzero exit and no passing record. These calibrate the independent checkers; they do not mutate production RTL. Other inherited mutation switches are not qualified or counted by this runner.

Independent review separated registered public fatal status from same-edge internal containment, preventing a premature public fatal pulse before the last permitted reply edge. The final minimum-deadline run checks that behavior directly. The strict one-clock-deadline build exposed an unsigned `< 0` lint failure in the age saturation condition. The implementation uses a reachable-state-equivalent `!= limit` saturation condition; the final eight positives and ten negative controls all ran against that corrected source. An earlier development fixture incorrectly expected arbitrary requested word data to be malformed; the case was corrected to a nonzero store acknowledgment. Intermediate failures were not counted as passes. The malformed requested-word case was a fixture error; premature public fatal assertion was an RTL interface timing defect; and the N=1 unsigned-comparison warning was an RTL parameter lint defect. All were resolved before final qualification. Tag/UID exhaustion remains separately source-reviewed rather than being reached by this finite integration run.

`summary.json` retains exact commands, tool version, selected-delay coverage, pass records, intended failure messages and SHA-256 values for all ten compiled/referenced source files. Hashes matched before and after qualification and again at retention. `SHA256SUMS` binds this evidence bundle. Generated binaries/C++ are not copied into the repository.

# FENCE and instruction synchronization execution evidence

This fixture connects the production frontend, fetch engine, compressed buffer and controller to one shared executable-memory model. It independently compares original instruction bytes, lengths, PC sequence, register results, trap state, physical bus effects and instruction ownership. `summary.json` is produced only after all configured profiles, seeds, detector calibrations and unchanged-source checks pass. A smoke record alone does not qualify the full matrix.

## Table of contents

| Section |
| --- |
| [Qualified result](#qualified-result) |
| [Assumptions and limits](#assumptions-and-limits) |
| [Requirement-to-test matrix](#requirement-to-test-matrix) |
| [Detector calibration](#detector-calibration) |
| [Revisions and reassessment](#revisions-and-reassessment) |

The test runner is `microcontroller/tests/run_fence_execution.py`; the testbench is `microcontroller/tests/drg5_fence_execution_tb.sv`. Run `make -C microcontroller/tests fence-execution` with the project's qualified Verilator path, or invoke the runner with `--verilator` and `--build`. The runner retains exact commands, tool output and source SHA-256 values. `+seed=0`, `+seed=1` and `+seed=305419896` drive local reproducible generators. `+debug_owners` adds edge-by-edge physical-owner observations.

## Qualified result

Revision 09 passed strict warning-free elaboration for six profiles and three seeds per profile: C1/FI1 with overlap/forwarding, overlap/interlock and diagnostic occupancy; C0/FI1 with overlap/forwarding; and C1/FI0 plus C0/FI0 with overlap/forwarding. The 18 positive runs covered 5,826 cases, 23,544,765 checks, 46,330 successful retirements, 9,912 FENCE retirements, 504 FENCE.I retirements and 105 completed executable writes. There were 18 discarded obsolete fetch errors, including nine coincident with synchronization redirects. All five deliberately faulty runs failed at their required independent detector. The pinned executable reported `Verilator 5.047 devel rev v5.046-19-ge9dd6eaaf (mod)`.

## Assumptions and limits

- The I port and D port each permit one exposed transaction. An offer owns an immutable descriptor until acceptance; an accepted transaction owns exactly one response. Acceptance and response delays are independently controlled.
- I responses snapshot selected halfwords at acceptance. Executable stores update shared bytes only on successful D response completion, using checked byte enables and lane-positioned data. Acceptance before or on the write-completion edge may snapshot old data; later acceptance must see the new bytes.
- The fixture models an 8 KiB reset ROM and an 8 KiB writable executable region beginning at `0x00010000`. MMIO lies at `0x40000000`; the external writer's completion register is at `0x40000010`. Instruction fetches into MMIO are rejected by the independently checked offer-range invariant.
- Ordinary MMIO effects occur exactly once at acceptance. The effect ledger includes reads targeting x0. The separate retirement ledger must account for every effect. A guaranteed rejection returns status 1 and changes no bytes or effect counters.
- Directed old I offers wait 70 cycles before acceptance. Selected accepted responses wait 70 cycles, or 100 cycles for the two-halfword straddled patch. Ordinary service is seeded independently; D acceptance and response delays are separate. Stress watchdogs are 128 cycles. These are verification schedules, not production real-time budgets.
- A DMA writer continues on the fixture clock independently of CPU stalls. Its completion flag becomes visible only after the executable write becomes globally visible. The CPU polls that flag, performs FENCE, then FENCE.I. A separate counterexample executes FENCE.I before an unrelated delayed DMA write; old code executes legally while DMA is still pending. This demonstrates why a CPU fence cannot establish another agent's completion.
- Self-modifying programs have independent metadata specifying the expected new instruction image, while initial physical memory contains old encodings. The oracle never derives expected decoded semantics from RTL expansion. Old buffered bytes and snapshots must be discarded even when their old data happen to represent legal instructions.
- C-enabled tests include 16-to-16 changes, 32-to-32 changes at a halfword start, and both 16/32-bit width transitions. Non-C tests use word-aligned 32-bit instructions. M is disabled in this fixture; divider/fence composition is covered separately by the event fixture. There is no ACT4/Sail, formal, FPGA timing, programmer or acquisition qualification claim here.
- This is finite directed and seeded simulation. It does not establish all possible schedules. Early raw FENCE.I serialization prevents allocation of younger architectural pipeline instructions; the reachable stale state tested here is frontend output, parcel buffering and physical fetch ownership.

## Requirement-to-test matrix

| Requirement | Directed exercise | Independent detector |
| --- | --- | --- |
| All FENCE predecessor/successor domains, including empty | 256 masks, all 16 fm values, FENCE.TSO, PAUSE and unused fields | Older D owner must be complete; exact MMIO read/write retirement and physical ledgers |
| Side-effectful reads are ordered like writes | x0 MMIO read, FENCE, store, FENCE, x0 MMIO read | Acceptance effect counts equal retired effects; no duplicate offers or accepts |
| FENCE.I waits for completed executable writes | SW and two SH writes complete after independent delayed acceptance | No D owner at FENCE.I retirement; shared image modified only on successful response |
| Buffered old instruction invalidation | Old victim held by frontend while FENCE.I is stalled at W | Required old-buffer coverage and exact post-fence original-byte/length comparison |
| Old unaccepted request retained | Delayed victim acceptance spans synchronization | Stable complete descriptor; mandatory selected-victim response drop |
| Old accepted response rejected | Accepted old snapshot delayed past synchronization | One response owner; permanent stale disposition; new image at retirement |
| Wrong-path errors discarded | Delayed old access error and error coincident with redirect | Required old-error and same-edge-drop counters; precise trap oracle |
| Shared-word and straddled parcel correctness | FENCE.I and victim share a fetched word; modified 32-bit victim starts at upper halfword | Parcel-aware targeting; original PC, length and bytes preserved |
| Compressed instruction width changes | 16-to-16, 16-to-32 and 32-to-16 rewrites | Independent new-length PC sequence, results and original bits |
| Instruction access faults precede FENCE.I | First or second parcel fails; aligned and C-straddled starts | Cause 1, instruction-start mepc, exact mtval/raw-valid and no FENCE.I retirement |
| Older D error retains priority | Rejected executable store followed by FENCE.I | Cause 7, zero byte/effect change, no younger synchronization retirement |
| Held FENCE.I does not execute repeatedly | Explicit bounded W stall and randomized ordinary stage stalls | Single ordered UID retirement, exactly one synchronization per instruction |
| Unused fields do not create dependencies | 32 rd/rs1/imm patterns with encoded registers uninitialized | No operand requirement or register write; same PC+4 synchronization |
| Disabled and unsupported encodings are precise | FI-disabled profiles; funct3 values 2 through 7 | Cause 2, project mtval=0 convention, no architectural/bus side effects |
| External writer completion is separate | Completion polling plus FENCE/FENCE.I; deliberately early counterexample | New image after acknowledgment; old image and still-pending writer in early sequence |
| No lost, duplicated or killed instruction retires | Every case records accepted packets, stage owners, kills and trace order | Exact UID conservation across all stages and one ordered retirement per surviving UID |
| Result is reproducible and attributable | Six elaborations, three seeds, strict source-before/source-after comparison | Identical program construction across occupancy variants; archived inputs and logs |

## Detector calibration

The runner requires each deliberate defect to fail at its named detector, with no successful terminal marker. `mutate_redirect` masks the actual redirect input to the production frontend while keeping the CPU retirement trace intact; old buffered code must reach the instruction-image comparator. `mutate_raw` corrupts observed instruction bits. `mutate_stale` corrupts the disposition of a selected obsolete physical fetch. `mutate_dma` publishes completion before writing the shared executable bytes. `mutate_effect` duplicates a real MMIO effect. These controls demonstrate both instruction-visibility and physical-side-effect detection; they are not counted as successful DUT executions.

## Revisions and reassessment

1. Revision 01 rejected unused fixture signals under strict lint. Subsequent code explicitly identifies unused diagnostic fields; no lint warning was waived.
2. Revision 02 caught a driver error: the final W-hold edge left hold asserted forever. The release edge now explicitly clears hold.
3. Revisions 03 and 04 exposed incorrect stale-owner schedule targeting. Target selection now distinguishes the victim halfword from the preceding FENCE.I parcel in the same fetched word. A function evaluates the newly captured descriptor immediately, avoiding stale continuous-wire values inside the procedural responder.
4. Revision 05 passed the first strict smoke but used broad global stale counts. Reassessment tightened these to selected-victim old owners and required actual old buffered bytes in the redirect-bypass case.
5. Revisions 06 and 07 correctly rejected the tightened straddled case: its old response completed four clocks before FENCE.I redirected. The retained `owner-timing.log` shows acceptance at step 163, response at step 234 and redirect at step 238. The two-SH case now delays its accepted response 100 cycles instead of 70, preserving the 128-cycle watchdog and the mandatory old-owner check.
6. Revision 08 passed strict smoke after these corrections. Five pilot mutations also reached their intended independent detectors. The final qualification is reported separately by `summary.json`; the earlier smoke and failed attempts remain archived.

7. Revision 09 completed the full matrix, all five detector calibrations and the final unchanged-source check. Its source archive and summary are the qualification result.

No production RTL defect was found during these fixture revisions. The limitations above remain part of the evidence rather than being replaced by a claim of exhaustive correctness.

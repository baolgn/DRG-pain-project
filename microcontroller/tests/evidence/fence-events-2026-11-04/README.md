# FENCE.I event-composition evidence

Final qualification revision 07 passes both C-disabled and C-enabled controllers with M, IRQ and Zifencei enabled. The two deterministic runs execute **34 cases, 2,104 checks and 682 clock edges**. Exact commands, input sources and tool output are retained in `revisions/07-qualification`; `summary.json` binds the current files to those results.

The fixture sends real raw FENCE.I and DIV instructions through OP_MACHINE. Synthetic CSR packets establish interrupt state without adding an unrelated firmware prologue. The fence packet deliberately contains false operand/destination annotations; production raw decode must replace them. This is a packet-level event fixture: `fetch_busy_i` models a surviving instruction transaction. The separate [execution fixture](../fence-execution-2026-11-04/README.md) checks actual frontend requests, invalidation and stale responses.

Each C configuration checks:

- Flush and hart reset while FENCE.I is held in each of F/D/X/M/W, plus prepared W: six cases of each disposition. An aborted fence never retires or emits a late synchronization redirect.
- External interrupt before W admission: the fence is killed and the saved PC identifies the unexecuted fence.
- External interrupt after W admission: the held fence finishes once, then the modeled old fetch owner delays interrupt entry. The saved continuation is PC+4.
- An older synchronous load-access fault kills a younger fence and retains its precise trap state.
- OP_BASE rejects FENCE.I even when OP_MACHINE enables Zifencei.
- A real blocking DIV to x0 completes before the later FENCE.I. The 34 observed busy-X samples are coverage, not a new arithmetic or whole-fence latency bound.

Every edge independently accounts accepted identities, live stage owners, kills, reset aborts and terminal dispositions. An instruction cannot retire while a smaller live UID remains. Trace checks cover original fence identity, ignored operands, absent GPR/CSR effects, one continuation and interrupt/trap state. No device transaction is permitted in these event-only scenarios. Both IALIGN settings use their own elaboration; the C-enabled reset/flush scenarios include a fence starting at PC 2.

Actual revisions and reassessment:

1. Strict lint rejected unused trace fields and high stage-index bits. Explicit observation and stage-range validation resolved both; no warning waiver was added.
2. The first executable run passed twelve stage-abort cases, then rejected a fixture assumption that an interrupt enters in its first eligible clock. The controller first latches drainage; the fixture now observes the bounded eligibility/drain/entry sequence.
3. Both initial event profiles passed after that correction, and the IRQ check was strengthened to require redirect-valid as well as the target.
4. Added real M-enabled DIV/fence composition; both profiles passed.
5. Review added an independent oldest-live-UID assertion, preventing a younger terminal from bypassing an older instruction even if retirement order numbers are sequential.
6. Moved the supplementary DIV/fence order check after the clock edge; its previous placement was tautological inside the loop. Both final profiles passed again.

7. Reproduction review found that summary metadata assumed the evidence directory was inside the repository. The runner now records revision paths relative to the chosen evidence directory. Both profiles passed again with the normal destination and a separate `/tmp` destination.

No production RTL change was required by these fixture revisions. There is no formal proof, real frontend latency measurement, external-debug implementation or FPGA qualification claim in this record.

Reproduce from the project root:

```sh
python3 microcontroller/tests/run_fence_events.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-fence-events-reproduce \
  --evidence-dir /tmp/drg5-fence-events-reproduce-evidence
```

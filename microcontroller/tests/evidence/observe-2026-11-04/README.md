# Observation adapter qualification

Final revision 03 passes **18 schedules, 792 sampled edges and 2,373 checks**, plus four required detector failures. The six elaborations cover default 64-bit identities; separate sequence, epoch and normal-retirement exhaustion; simultaneous sequence/retirement exhaustion; and simultaneous exhaustion of all three. Each runs seeds 0, 1 and 305419896.

This is an adapter transport and identity test. It supplies deliberately changing pre-edge inputs and independently changing post-edge output values, including arbitrary synthetic events that need not be a legal CPU program. The entire **3,147-bit observe_t payload** is compared while valid. Real instruction semantics and counter behavior are checked by the separate counter-bank and frontend-execution fixtures.

The fixture checks:

- Pre-edge requests, responses, operands, admission, reset/debug inputs and counter values pair with the same edge's settled terminal, IRQ, kill, fatal and post-counter values.
- Every ordinary terminal adds one to a separate lifetime retirement observation; traps add none. This total is independent of writable/inhibited minstret and CPU reset.
- Sequence numbers start at one after capture rearm. One asserted CPU-reset episode consumes one epoch, without resetting the lifetime observation counts.
- Exhaustion saturates the applicable identity, sets the matching sticky reason bits and invalidates the capture. Simultaneous exhaustion preserves all relevant bits. CPU reset alone cannot restore validity.
- Rearming requires capture_reset during a positively isolated cold reset. It starts a declared new capture; it is not an implicit repair of lost history.

The four detector cases must fail at their named ordinary comparison or contract assertion: a pre/post phase substitution, a corrupted normal-retirement total, silently valid overflow and unsafe rearm. Generic failure or a missing success marker alone does not qualify a detector.

The observation adapter has no output feeding CPU execution, no ready/backpressure path and no hardware trace FIFO or circular buffer. A consumer must sample every settled valid record; gaps, overflow and incomplete capture invalidate reconstruction. The real execution runner separately verifies the file-capture schema, contiguous records and mandatory end footer.

Actual review revisions are retained:

1. Four independent exhaustion/default profiles and all four detectors passed.
2. Review added coincident exhaustion coverage and concise missing block context. Strict lint rejected a 32-bit logical-negation operand in the new fixture schedule; no warning was waived.
3. Replaced that expression with an explicit comparison. All six profiles, three seeds and four detectors passed. Production observer logic did not change during these test revisions.

The separate current structural evidence maps the adapter with no latches or unsupported constructs. It is not instantiated inside the CPU, and its register cost is not hidden in the controller's resource totals. There is no composed-core formal proof or physical trace-capture hardware claim here.

Reproduce from the project root:

```sh
python3 microcontroller/tests/run_observe.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-observe-reproduce \
  --evidence-dir /tmp/drg5-observe-reproduce-evidence
```

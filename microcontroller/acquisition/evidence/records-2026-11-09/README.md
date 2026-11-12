# Record reservation evidence

This capture checks the synthetic record ledger and its connection to the existing scheduler. [review.json](review.json) binds the final source and document hashes to the retained artifacts. Each campaign preserves its own original source snapshot and tool output; earlier results apply only to those captured revisions.

## Final results

| Campaign | Retained result |
| --- | --- |
| Ledger | [records-r2/summary.json](records-r2/summary.json): 26 directed cases and 160 randomized records per Verilator seed, using seeds 1, 305419896 and 3735928559. Icarus repeats at depths 4 and 256. One reduced-token case exercises the limit of seven. Four corrupted observations fail the ledger, record, order and unknown-value comparators. |
| Scheduler connection | [storage-r2/summary.json](storage-r2/summary.json): seven directed integration cases pass in Verilator and Icarus. Three corrupted observations fail the payload, credit and unknown-value comparators. |
| Structure | Default-depth process lowering, memory collection and structural checks pass without inferred latches. The ledger retains exactly two memory arrays. Full generic synthesis passes separately at depth four. These are not device mapping or routed timing results. |
| Comments | [comments.json](comments.json) checks 233 active coding/build files and 7,844 comment blocks. No checked block context or permitted-case requirement fails. Immutable historical snapshots are excluded. |

The ledger seeds produce 33,269, 32,504 and 33,115 predicate evaluations. Icarus at depth 256 produces 129,796, and the reduced-token case produces 261. The final integration suite produces 38,954 in each simulator. These totals include repeated per-edge invariants, not that many distinct scenarios.

The independent ledger scoreboard compares whole 48-byte payloads and their epoch/slot identities. It checks ordered admission and retirement, stable offers and producers under backpressure, reservation-token uniqueness, stage counts and widened allocation conservation. Directed cases cover full capacity, ring wrap, duplicate or stale responses, rejected rebinding, pending placeholders behind an unresolved conversion, cancellation versus completion, assembly enqueue with DMA dequeue, release/admission/reserve precedence, early DMA completion and isolated reset. Random stimulus chooses synthetic results, cancellations and DMA service delays with fixed seeds.

The integration test connects the real timebase, scheduler, storage adapter and record ledger. Synthetic capture and DMA peers are the only producer/consumer models. Its cases cover normal fixed-grid launches, first-slot STOP, an unfinished conversion followed by a missing-slot notification, full capacity, CPU-reset cancellation, a launch behind an unacknowledged confirmation, and a launch colliding with a missing notification. In the final full-capacity case, positive DMA completion occurs on the fifth scheduled edge. It retires the older record but cannot supply credit for that same edge: four slots remain admitted, the fifth is explicitly lost, and no late conversion follows.

The unresolved-conversion case deliberately holds its synthetic producer beyond the future 1,120-tick capture deadline to test ownership under missing service. It does not qualify that deadline.

Testbench inputs change away from the rising sampling edge. Transfers are compared using pre-edge values and retained state after sequential updates. Every wait is bounded, unknown comparisons fail, and each requested VCD contains captured transitions. Negative controls deliberately corrupt selected observations and must fail their intended comparison. They do not prove sensitivity to every possible defect.

## Revisions and review findings

| Revision | Observed result |
| --- | --- |
| records-r1 | Simulation stages passed, but the source changed during the campaign's structural work. The runner rejected final attribution and produced no success summary. Logs and pre-build snapshots remain retained; this campaign is not a final qualification. |
| records-r2 | The final ledger and expanded 26-case testbench pass the complete source-bound campaign, including default-depth simulation and structural checks. |
| storage-r1 | The seven connected cases passed. Its full-ring case held DMA stalled at the due edge and did not test coincident positive completion. |
| storage-r2 | The full-ring case now places positive DMA completion on the exact due edge and checks that admission still uses pre-edge credit. All seven cases pass again with the final testbench. |

Source review corrected the adapter's handling of malformed simultaneous launches so an older confirmation or missing notification retains priority. It also removed a combinational feedback path from launch to missing-notification readiness. Readiness now uses pre-edge reservation and binding state. The default-depth state implementation changed from rotating dynamic-array updates to constant-index transitions to keep structural elaboration bounded without changing ownership precedence or adding storage.

The final logical allocation is 14,336 bytes for the frozen 56-byte ring entries plus 2,481 registered metadata/staging bits across the ledger and adapter. Rounded together, this is 14,647 bytes within the existing 16 KiB ingress allocation. It does not claim a specific EBR count, mapped resource fit or 80 MHz timing closure.

## Retention and reproduction

Final campaign VCDs are retained as lossless `.vcd.gz` files. Each `waveforms.json` records the original size and SHA-256 and, when retained, the compressed size and SHA-256. Earlier campaign waveforms are identified by their original hashes and sizes without retaining duplicate waveform bytes. Object trees, executables and `.vvp` files are omitted. Original temporary runs and historical project evidence remain unchanged.

The wrappers [run_acquisition_records.py](../../../tests/run_acquisition_records.py) and [run_acquisition_storage.py](../../../tests/run_acquisition_storage.py) select tools and retain results. The comparisons reside in [drg5_acquisition_records_tb.sv](../../../tests/drg5_acquisition_records_tb.sv) and [drg5_acquisition_storage_tb.sv](../../../tests/drg5_acquisition_storage_tb.sv). The hardware implementations are [drg5_acquisition_records.sv](../../../rtl/drg5_acquisition_records.sv) and [drg5_acquisition_storage.sv](../../../rtl/drg5_acquisition_storage.sv), connected to unchanged [scheduler](../../../rtl/drg5_acquisition_scheduler.sv) and [timebase](../../../rtl/drg5_acquisition_timebase.sv) sources.

With the recorded OSS CAD Suite binaries on PATH, run from the repository root with new output directories:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_records.py --output /tmp/drg-records-replay
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_storage.py --output /tmp/drg-storage-replay
```

The summaries record exact executable versions and hashes. The captured tools are Verilator 5.055 development, Icarus Verilog 14.0 development and Yosys 0.70+336. Current Python sources also compile in memory. Existing active coding files retain their prior bytes; six new files implement the ledger, adapter, testbenches and runners.

These checks exercise one clock domain with synthetic complete records and positive DMA-completion attestations. They do not implement or qualify a serial receiver, CRC/analog validity, asynchronous FIFO pointers, clock-domain reset coordination, actual DMA memory writes, block publication, CPU execution, independent physical supervision or board programming. A stopped producer or DMA peer leaves its owner charged until external supervision resolves or contains it. No board was used, and no firmware or FPGA image was written.

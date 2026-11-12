# Timebase and scheduler evidence

This directory retains source-bound checks of the fixed acquisition grid and its connection to the control peripheral. Development occurred on November 6, 2026 in America/New_York; the captured summaries record their actual UTC execution times. [review.json](review.json) identifies the final sources and retained artifacts. Each campaign's source snapshot applies to that run, including earlier revisions that differ from the committed files.

The implemented path is [drg5_acquisition_timebase.sv](../../../rtl/drg5_acquisition_timebase.sv), [drg5_acquisition_scheduler.sv](../../../rtl/drg5_acquisition_scheduler.sv), [drg5_acquisition_control.sv](../../../rtl/drg5_acquisition_control.sv) and [drg5_acquisition_timing.sv](../../../rtl/drg5_acquisition_timing.sv). The [scheduler specification](../../slot-scheduler.md) and [integration contract](../../timing-integration.md) define the acceptance edge, fixed grid, held notification, end receipt and physical qualification boundary.

## Final results

| Campaign | Evidence and result |
| --- | --- |
| Scheduler | [scheduler-r3/summary.json](scheduler-r3/summary.json): 30 named cases and 80 seeded frames for each of three Verilator seeds; four-state Icarus repeat; one reduced-counter exhaustion case; five expected comparator failures; default-parameter Yosys synthesis of scheduler and timebase without inferred latches. |
| Connected control and scheduler | [timing-r2/summary.json](timing-r2/summary.json): ten public-interface cases, ten accepted ARM bindings and 13 launch events in both Verilator and Icarus; two expected comparator failures; default-parameter Yosys synthesis without inferred latches. |
| Control regression | [control-r2/summary.json](control-r2/summary.json): 53 named cases and 160 seeded command trials per seed; four-state Icarus repeat; three reduced-counter cases; five expected comparator failures; default-parameter Yosys synthesis without inferred latches. |
| Comment conventions | [comments.json](comments.json): 227 active source/build files, 7,646 comment blocks, no unexpected mixed case or missing checked block context. Historical evidence remains unchanged. Lexical checks do not prove comment accuracy or concision. |

The three scheduler seeds are 1, 305419896 and 3735928559. Their totals are 669,641, 669,245 and 669,413 predicate evaluations, respectively. The large counts primarily come from invariants evaluated on every simulated edge; they are not counts of independent test scenarios. The connected test reports 30,400 predicate evaluations. The control seeds report 40,603, 40,650 and 40,799. Check labels and individual outcomes remain in the simulation logs.

The scheduler cases exercise first-slot admission, the exact 1,600-tick grid, eight-tick CONVST pulses, stop on and between due edges, CPU reset/halt, capture and credit gates, notification backpressure, the inclusive 80-tick handoff deadline, stable held tuples, sealed receipt accounting, timestamp discontinuities, crossing bit 63, the full-width final frame horizon, epoch exhaustion and reduced slot-counter exhaustion. Accounting predicates use widened sums. A skipped clock marker never produces a catch-up conversion.

The connected cases send real MMIO requests to the wrapper with modeled backends. A response held for more than 5,000 clocks does not move the sampling grid. The cases check same-edge ARM binding, off-grid capture/credit activity, downstream stalls, full pulse completion through stop, retained time through CPU reset, stale responses, premature closure, independent receipt acknowledgments and restart gates. They reject an end acknowledgment during the registered fault-report interval before the controller seals its terminal. The control regression separately checks that adjacent fault occurrence beats remain counted when the one-entry event queue is full.

Testbench inputs change away from the DUT rising sampling edge; checks sample after sequential updates. Waits have finite bounds, unexpected unknown values fail, deterministic random streams are explicit, and VCDs are generated. Negative controls corrupt selected observed values and must fail their named comparator. They establish sensitivity of those checks, not coverage of every possible defect. These checks do not provide a formal proof.

## Retained revisions

| Revision | Observed result and change |
| --- | --- |
| scheduler-r1 | Functional simulation and the reduced-counter checks passed. The campaign did not produce a success summary because its warning gate rejected the helper's ABC combinational-network warning. The exact runner, sources and tool logs are retained. This is an incomplete campaign, not a passing qualification. |
| scheduler-r2 | Added per-edge ledger and loss-bound predicates, clarified counter/timestamp behavior, and allowed only the reviewed ABC warning produced for the extracted timebase next-state cone. The campaign passed. |
| scheduler-r3 | Repeated with the final scheduler specification, including the limits of fault timestamps after time discontinuity. RTL and testbench bytes are unchanged from scheduler-r2. This is the final source-bound scheduler result. |
| timing-r1 | The ten connected cases passed before the fault-report interface changed. This result does not qualify adjacent occurrence accounting in the later interface. |
| timing-r2 | Repeated after control and wrapper changes replaced scheduler fault level filtering with an explicit occurrence input. This is the final connected result. |
| control-r1 | Passed with the new occurrence input and an added adjacent-fault case. The snapshot still contains an obsolete ARM-consumption paragraph in its interface document. |
| control-r2 | Repeated with the corrected same-edge ARM paragraph. Executable sources are unchanged from control-r1. This is the final source-bound control result. |

Review also corrected the end-acknowledgment gate to require a positively sealed terminal, preserved scheduler uncertainty through backend closure, allowed requalified idle service isolation to clear, and kept scheduler readiness independent of returned STOP to avoid combinational feedback. Those changes preceded the retained final campaigns. The main architecture diagram now ends a missing-slot decision at STOP and distinguishes the unmeasured pin delay from the logical register event.

The reviewed Yosys messages are limited to expansion of the controller's snapshot array into registers and ABC's combinational-network message for the extracted timebase cone. The summaries list the exact messages. No other warning class is waived by these runners.

## Artifacts and reproduction

Each directory contains exact pre-build sources, tool/version output and command logs. Final scheduler-r3, timing-r2 and control-r2 waveforms are losslessly compressed as `.vcd.gz`; their `waveforms.json` files bind both compressed and original bytes and sizes. Earlier directories retain original waveform hashes and sizes without duplicating those waveforms. Build executables, generated object trees and `.vvp` binaries are omitted. The original temporary run directories were not modified by this retention step.

With the pinned OSS CAD Suite binaries on PATH, run from the repository root using new output directories:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_scheduler.py --output /tmp/drg-scheduler-replay
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_timing.py --output /tmp/drg-timing-replay
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_control.py --output /tmp/drg-control-replay
```

The wrappers are [run_acquisition_scheduler.py](../../../tests/run_acquisition_scheduler.py), [run_acquisition_timing.py](../../../tests/run_acquisition_timing.py) and [run_acquisition_control.py](../../../tests/run_acquisition_control.py). Their independent stimulus and comparisons reside in the corresponding [scheduler](../../../tests/drg5_acquisition_scheduler_tb.sv), [timing](../../../tests/drg5_acquisition_timing_tb.sv) and [control](../../../tests/drg5_acquisition_control_tb.sv) testbenches. Executable versions and hashes are recorded in each summary; the captured suite uses Verilator 5.055 development, Icarus Verilog 14.0 development and Yosys 0.70+336.

All 102 active Python files compile in memory. Comparing the current comment inventory with the previous control campaign shows only three changed pre-existing code files: the control RTL, its testbench and its runner. Seven new source files supply the scheduler, timebase, integration wrapper and two testbench/runner pairs. The other pre-existing active coding files retain their bytes and prior comment conventions.

These results establish the exercised digital timing and ownership behavior with coherent modeled inputs. CPU activity is MMIO stimulus, not execution of the CPU core. There is no ADC sequencer, BUSY/DOUT capture, complete-record assembler, DMA, physical CDC, independently clocked supervisor or connected CPU board image in this path. Reduced service timers do not simulate a real multisecond startup. Generic synthesis does not establish routed 80 MHz timing. No board is available; no programming or physical measurement occurred. The candidate 2.75 ns marker-to-ADC-pin allocation remains unmeasured and is not recorded as a zero-delay calibration.

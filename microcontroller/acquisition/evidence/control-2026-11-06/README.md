# Acquisition control verification

The [final summary](r4/summary.json) records executable checks of the standalone [control RTL](../../../rtl/drg5_acquisition_control.sv) against [ACQ-CONTROL-1](../../control-foundation.md). The [runner](../../../tests/run_acquisition_control.py) selects tools, retains sources and logs, checks detector failures, and verifies that sources did not change during execution. The [testbench](../../../tests/drg5_acquisition_control_tb.sv) supplies stimuli and expected outcomes. Backend qualification, startup, configuration and containment are simulated attestations.

Run from the repository root with Python 3, Verilator, Icarus Verilog and Yosys available on PATH, choosing an unused output directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_control.py \
  --output /tmp/drg-acquisition-control-check
```

The final campaign passes 52 named cases per seed, including the 24 entries of the eight-state, three-command admission matrix. Each seed also exercises 160 reproducible MMIO vectors. The seeds are 1, 305419896 and 3735928559. The check totals are 27,939, 27,969 and 28,105 respectively. These totals count individual comparisons, handshake checks and repeated unknown-output checks; they are not counts of independent scenarios or third-party validation.

Icarus repeats the suite with four-state values. A separate counter-limit-7 profile passes three cases covering saturation, fault visibility after snapshot identity exhaustion, and a dropped occurrence when the queue is empty but no event identity remains. Five negative controls corrupt a response, snapshot, STOP observation, completion or four-state value. Each fails its intended ordinary comparator. These controls demonstrate selected detectors, not detection of every possible RTL defect.

One process generates the clock. Stimulus changes while it is low, and the testbench samples after rising-edge nonblocking updates. Every potentially unbounded wait has a local or global deadline. Test configuration, cancellation and closure deadlines are reduced to 2,048, 16 and 128 cycles; default timer values are separately present in the synthesized RTL. The tests do not wait three physical seconds or establish board timing. The Icarus builds define SYNTHESIS, selecting the hardware branch while retaining all procedural testbench checks. Verilator additionally executes the simulation-only parameter guard.

Yosys synthesizes the default-parameter component and checks for inferred latches. Its reviewed warning reports flattening the snapshot register array. Icarus reports that constant-select sensitivity handling includes the full signal, which does not remove dependencies. Verilator builds without warning waivers. Tool versions, executable hashes, exact commands and diagnostics remain in each revision's logs and summary.

| Revision | Retained change in verification scope |
| --- | --- |
| [r1](r1/summary.json) | Initial passing source-bound campaign after lifecycle, command precedence, STOP identity, configuration and fault-ownership corrections; 51 named cases and one reduced-counter case. |
| [r2](r2/summary.json) | Added an accepted ARM with a stalled bus response followed by a fault; the binding and original completion survive while closure proceeds. There are 52 named cases. |
| [r3](r3/summary.json) | Added live cause visibility after snapshot exhaustion and dropped-event accounting after event identity exhaustion; three reduced-counter cases. |
| [r4](r4/summary.json) | Repeated the final campaign after clarifying the synthesis-view comment, upstream transfer-size responsibility and exhaustion cause description. RTL and testbench behavior are unchanged from r3. |

The source review corrected same-edge faults admitting orphan operations, reused no-epoch STOP acknowledgment identities, active qualification being confused with a future proposal, historic CPU-stop causes affecting later epochs, and lost uncertainty after a supervisor pulse. It also corrected service isolation and backend-owner retention, offending-response evidence, snapshot exhaustion visibility and lost-event accounting. [review.json](review.json) binds the retained files and states the verification limits.

All original logs and source snapshots are retained. Generated executables, object files and simulator binaries remain outside this evidence directory. Waveforms are losslessly gzip-compressed; [waveforms.json](waveforms.json) records compressed and original hashes. For example:

```sh
gzip -dc microcontroller/acquisition/evidence/control-2026-11-06/r4/four-state.vcd.gz \
  > /tmp/drg-acquisition-control.vcd
```

The [final comment audit](comments.json) covers 220 active coding files and 7,457 comments, excluding immutable historical captures. All 217 pre-existing active sources retain their original bytes. The three added code files follow the same lowercase and block-context convention. One hundred active Python sources compile without writing bytecode files.

These results establish simulated component behavior and generic synthesizability. They do not establish formal exhaustiveness, CPU integration, physical CDC, 80 MHz timing closure, ADC operation, DMA correctness, archive durability or independent hardware supervision. No board was programmed or physically observed.

# CPU debug qualification, 4 November 2026

The final matrix checks the Debug 1.0 CPU controls through public halt/resume and abstract-register ports. Four C/diagnostic configurations each pass seeds 0, 1 and 305419896. Each run executes twenty directed scenarios with seeded request-acceptance and response delays. The [summary](summary.json) binds exact sources and commands; [aggregate](aggregate.json) separates simulation totals from detector calibration.

Coverage includes all GPRs and x0, selected machine/debug CSRs and illegal accesses, DCSR masks, DPC alignment, reset-halt including release-edge requests, ordered halt during exposed reads/stores and division, reset drainage, normal resume without repeated MMIO, branch/JAL/JALR steps, compressed and halfword-aligned wide packets, trap-then-halt before the handler, deferred target-fetch faults, WFI, masked pending interrupts, EBREAK/C.EBREAK routing, cause priority and counter writes/rollover/freeze. Counter expectations evolve separately from observed storage. Explicit scenario instruction/trap totals check each step, while independent bus accounting checks effects at acceptance.

The longest observed call from halt/step wait to actual halted status is **42 core edges**. Delayed MMIO cases configure 7–15 clocks before acceptance eligibility and 9–19 clocks before response eligibility; acceptance and response are distinct sampled events. Division uses the implemented blocking unit. The fixture also supplies an independent four-edge fetch-busy interval. This is a measured finite-schedule maximum, not a bound on host latency, arbitrary external holds or a physical frontend. The external Debug Module, transport, production frontend and OpenOCD/GDB combination require their separate integration results.

Twelve deliberately corrupted runs reach the intended ordinary detectors: changed step continuation, changed halted counter observation and duplicate MMIO effects. Strict Verilator warnings are not waived. Revisions preserve the initial core, rejected fixture lint and first full matrix. Final comment-only corrections were rebuilt and all twelve positive and twelve negative runs repeated. The core's final CSR-bank implementation is unchanged; debug mode now drives its existing stopcount hooks through the controller.

Reproduce from the workspace root:

```sh
python3 microcontroller/tests/run_debug_core.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-debug-core-reproduce \
  --evidence-dir /tmp/drg5-debug-core-reproduce/evidence
```

No ACT4/Sail, complete formal proof, routed clock or physical debugger claim follows from this component record. Raw C packet execution here does not replace the production fetch-buffer checks.

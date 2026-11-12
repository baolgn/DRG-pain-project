# CPU and platform tests

## Purpose

This directory contains executable testbenches, simulator drivers, proof harnesses and Python orchestration for the DRG5 implementation. A runner selects tools, configurations, seeds and expected outcomes. The SystemVerilog or C++ fixture supplies stimuli and independent checks; the hardware under test remains in [RTL](../rtl/README.md). Keeping those roles separate makes a reported pass traceable to the actual implementation and checker.

## Instructions

Run examples from the repository root with Python 3, a host C++ toolchain and Verilator. Checks that include synthesis or proof also require the appropriate Yosys frontend and solver. The [formal guide](../verification/formal/README.md) describes the slang/SymbiYosys/Yices flow; it differs from the built-in Yosys SAT induction used by some unit runners. The Makefile also uses `rg` for named failure detection. C++ trace and synthetic drivers may require zlib development files.

The acquisition control [runner](run_acquisition_control.py) builds [drg5_acquisition_control_tb.sv](drg5_acquisition_control_tb.sv) against the standalone [control peripheral](../rtl/drg5_acquisition_control.sv). It requires Verilator, Icarus Verilog (`iverilog` and `vvp`) and Yosys. The testbench drives inputs while the clock is low and samples after rising-edge nonblocking updates, uses bounded waits, and rejects unknown results. The runner records deterministic seeds, source hashes, named cases, detector failures and waveforms in a new output directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_control.py \
  --output /tmp/drg-acquisition-control-check
```

The [retained control evidence](../acquisition/evidence/control-2026-11-06/README.md) distinguishes simulation and generic synthesis from the ADC, CPU fabric, CDC and physical supervision work that remains outside this component.

The [scheduler runner](run_acquisition_scheduler.py) exercises [drg5_acquisition_scheduler_tb.sv](drg5_acquisition_scheduler_tb.sv), including fixed-grid timing, pulse widths, stalls and counter boundaries. The [connected timing runner](run_acquisition_timing.py) exercises [drg5_acquisition_timing_tb.sv](drg5_acquisition_timing_tb.sv) through MMIO, checking shared ARM timing and the separate scheduler/control closure owners. Both use Verilator, Icarus Verilog and Yosys, retain waveforms, and require a new output directory. The [scheduler evidence](../acquisition/evidence/scheduler-2026-11-06/README.md) also retains the affected control regression.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_scheduler.py \
  --output /tmp/drg-acquisition-scheduler-check
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_timing.py \
  --output /tmp/drg-acquisition-timing-check
```

The [record runner](run_acquisition_records.py) checks the stimulus and scoreboard in [drg5_acquisition_records_tb.sv](drg5_acquisition_records_tb.sv). The [storage integration runner](run_acquisition_storage.py) connects the real scheduler and reservation adapter in [drg5_acquisition_storage_tb.sv](drg5_acquisition_storage_tb.sv). Synthetic capture results and positive DMA completions exercise complete payloads, ordering, cancellation, full capacity, and simultaneous transfers. Default-depth structural checks preserve memories; full generic synthesis uses depth four. The [retained results](../acquisition/evidence/records-2026-11-09/README.md) state the tested configurations and remaining CDC and hardware limits.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_records.py \
  --output /tmp/drg-acquisition-records-check
PYTHONDONTWRITEBYTECODE=1 python3 microcontroller/tests/run_acquisition_storage.py \
  --output /tmp/drg-acquisition-storage-check
```

Available captures identify Ubuntu/Linux tools, including Verilator `5.047 devel rev v5.046-19-ge9dd6eaaf (mod)` and more than one Yosys revision. This is evidence for those recorded tool builds, not a claim that every current package release works. Select executable paths explicitly and retain a new run's versions and hashes. Windows, WSL and macOS have not been qualified.

The standalone CSR runner is a compact example of the complete pattern:

```sh
python3 microcontroller/tests/run_csr.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/yosys \
  --build /tmp/drg5-csr-new
```

Use a new build directory even when a particular runner permits reuse. This command performs behavioral checks, named failure-detector cases, C-enabled and C-disabled induction checks, an intentionally failing proof, and ECP5 structural mapping. A negative test passes only when the intended failure appears; an arbitrary compiler error or crash does not qualify the detector. Induction requires its induction-success result, while structural mapping does not establish routed timing.

The [Makefile](Makefile) provides convenient targets for many standalone families. Read the corresponding runner's `--help` before using a target with custom arguments; the runner is the authoritative interface. Some legacy targets and runners retain fixed installation or output paths. For broader directed coverage, [run_directed.py](../verification/run_directed.py) copies current sources into isolated workspaces and supports an explicit evidence destination. The [verification guide](../verification/README.md) explains that safer aggregate path.

Read logs, JSON summaries and named expected outcomes together. Preserve `evidence/` and `revisions/` as captured records: an old passing summary applies only to its recorded source bytes, configuration and tools. Several earlier campaign bundles are not included in this publication. Their absence neither invalidates the supplied independent records nor supplies a new pass for current source.

## Implementation

| Area | Representative entry points | Scope |
| --- | --- | --- |
| Pipeline control and datapath | [Makefile](Makefile), [run_base.py](run_base.py), [run_forward.py](run_forward.py) | Diagnostic/overlap control, register results and dependency forwarding. |
| Fetch and control flow | [run_fetch.py](run_fetch.py), [run_fetch_buffer.py](run_fetch_buffer.py), [run_branch.py](run_branch.py) | Fetch ownership, buffering and branch/jump behavior. |
| Memory and privileged state | [run_lsu.py](run_lsu.py), [run_memory.py](run_memory.py), [run_csr.py](run_csr.py), [run_csr_control.py](run_csr_control.py) | Memory operations, standalone CSRs and their integrated commit/trap behavior. |
| Interrupts and extensions | [run_irq_control.py](run_irq_control.py), [run_muldiv.py](run_muldiv.py), [run_decompress.py](run_decompress.py), [run_counters.py](run_counters.py) | Interrupt control and configured arithmetic, compressed and counter features. |
| Debug | [run_debug_core.py](run_debug_core.py), [run_debug_module.py](run_debug_module.py), [run_debug_system.py](run_debug_system.py), [run_debug_remote.py](run_debug_remote.py) | Core debug, module transactions, integrated transport and remote debugger interaction. |
| Local platform and boot | [run_local_platform.py](run_local_platform.py), [run_local_fabric.py](run_local_fabric.py), [run_spi_boot.py](run_spi_boot.py), [run_programming.py](run_programming.py) | Local memory/peripherals and simulated boot/programming contracts. |
| Acquisition and workload | [run_acquisition_guard.py](run_acquisition_guard.py), [run_synthetic_cpu.py](run_synthetic_cpu.py) | Acquisition guard behavior and bounded CPU execution with modeled traffic. |
| Independent record checks | [replay_counter_trace.py](replay_counter_trace.py), [replay_debug_trace.py](replay_debug_trace.py), [replay_synthetic_cpu.py](replay_synthetic_cpu.py) | Reconstruct declared behavior from retained traces; these are separate from stimulus generation. |

A sensible CPU verification progression starts with datapath, register-file, CSR and arithmetic checks, then fetch/control/memory integration, extension and interrupt behavior, debug, and the local platform. Formal and reference-model checks add separate evidence at the relevant stages; they do not become interchangeable with simulation or board measurements.

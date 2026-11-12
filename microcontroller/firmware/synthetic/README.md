# Synthetic CPU firmware

## Purpose

This workload runs compiled RV32IMC firmware on the implemented CPU while a simulation supplies acquisition, shared-memory and host-service traffic. Its `SYNTH80` profile uses a nominal 80 MHz time scale. That name does not establish a physical FPGA frequency, an ADC interface, external-memory qualification or an end-to-end recording result.

## Instructions

The [build wrapper](build.py) reuses the parent firmware builder's image-extraction and command-logging helpers. It requires the fixed xPack compiler prefix documented in [firmware setup](../README.md); this wrapper has no compiler-prefix option. Use a new output directory:

```sh
python3 microcontroller/firmware/synthetic/build.py \
  --output /tmp/drg5-synthetic-firmware-new
```

To compile and execute the actual RTL workload, use [run_synthetic_cpu.py](../../tests/run_synthetic_cpu.py). This runner requires Verilator at `/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator`, the fixed compiler installation, a host C++ toolchain and zlib development files. Its evidence directory must not exist; a new build directory also keeps generated simulator state separate from earlier runs.

```sh
python3 microcontroller/tests/run_synthetic_cpu.py \
  --output /tmp/drg5-synthetic-evidence-new \
  --build /tmp/drg5-synthetic-build-new
```

The default run uses seeds 1 and 305419896, an active-reset case and a deliberately wrong DSP result. The wrong-result case succeeds as a detector test only when the expected independent checker rejects it. Omitting that case with `--skip-negative` reduces the checks performed. Read each run's logs and `result.json`, the top-level `summary.json`, and the source and firmware hashes together.

[replay_synthetic_cpu.py](../../tests/replay_synthetic_cpu.py) checks a retained retirement/event stream without rebuilding the simulator. Its `--run`, `--schema` and `--output` arguments must identify records from the same run. Replay checks the declared event and retirement contracts; it is not a complete independent ISA model.

The supported evidence environment is Ubuntu/Linux. Windows, WSL and macOS have no verified execution result for this flow.

## Implementation

| Source | Responsibility |
| --- | --- |
| [main.c](main.c) | Runs the foreground workload and manages its block lifecycle. |
| [kernel.h](kernel.h) | Defines the deterministic integer workload shared with the host model. |
| [trap.S](trap.S) | Supplies the leaf interrupt handler used by this workload. |
| [build.py](build.py) | Compiles and inspects target artifacts; it does not implement the signal-processing algorithm. |
| [drg5_synthetic_debug.sv](../../tests/synthetic/drg5_synthetic_debug.sv) | Provides the simulation-specific CPU/debug integration and test-region permissions. |
| [synthetic_cpu_sim.cpp](../../tests/synthetic_cpu_sim.cpp) | Supplies modeled traffic, ownership checks, debug transactions and independent results. |

Each modeled eight-channel acquisition frame occupies a 1,600-clock period. A 256-frame block therefore spans 409,600 nominal clocks, or 5.12 ms at the stipulated time scale. The firmware reads sixteen signed 18-bit channel-zero values, spaced sixteen frames apart, through the simulation-only aperture starting at `0x50001000`. The kernel applies `[1, -2, 1]` with history reset for each block, accumulates its diagnostic energy/signature using the declared unsigned modulo-2^32 arithmetic, and exercises division by 17. These results are workload signatures, not calibrated energy, RMS or a biomarker.

The harness models capture and transport service, retains block ownership across debug halt and reset, and checks the actual CPU's instruction and interrupt behavior. The [native stress model](../../synthetic/README.md) separately exercises longer simulated durations. Its results and the bounded RTL results cover different execution models and must remain separately identified.

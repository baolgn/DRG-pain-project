# Development documentation

This directory describes the requirements and qualification work that connect the implemented digital platform to the intended DRG recording system. The [development workflow](pre-coding-workflow.md) covers source definition, analog feasibility, acquisition timing, memory ownership and staged integration. Cultured extracellular sources remain provisional, and biological protocols, biomarker validation and modulation remain future work.

## Table of contents

1. [Installation](#installation)
2. [First simulation check](#first-simulation-check)
3. [Documentation map](#documentation-map)
4. [Recording and biological scope](#recording-and-biological-scope)

## Installation

Clone the repository as described in the [project overview](../README.md#installation). Development uses free and open-source tools on Ubuntu. The source can be obtained on Windows or macOS, but the current build helpers include POSIX process handling and fixed Linux tool paths. Native Windows, WSL and macOS execution remain unverified; an Ubuntu environment needs its own validation when hosted on another operating system.

On Ubuntu, install the host utilities before configuring the selected component's toolchain. A C++ compiler and Make build simulator executables, ripgrep supports existing test targets, and zlib headers support compressed trace handling.

```sh
sudo apt update
sudo apt install git python3 python3-venv build-essential ripgrep zlib1g-dev
```

Install the hardware tools outside the checkout. [Verilator's installation guide](https://verilator.org/guide/latest/install.html) describes simulator setup, and [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) supplies open-source FPGA and verification tools with host-specific activation instructions. Firmware needs a bare-metal [RISC-V GNU toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain) that supports the selected RV32 instruction set and ILP32 ABI. Installing a recent tool does not reproduce a historical result automatically; each run must record the tools and inputs it actually uses.

```sh
python3 --version
make --version
verilator --version
yosys --version
```

Some runners accept executable paths, while others use the fixed layouts documented in their component guides. Inspect the selected runner's options before execution. Windows and macOS users must resolve those differences within their chosen environment; the availability of an upstream tool for an operating system does not qualify every project workflow on it.

## First simulation check

The `fetch-buffer` target in the [test Makefile](../microcontroller/tests/Makefile) calls [run_fetch_buffer.py](../microcontroller/tests/run_fetch_buffer.py). That runner compiles [drg5_fetch_buffer_tb.sv](../microcontroller/tests/drg5_fetch_buffer_tb.sv) with [drg5_fetch_buffer.sv](../microcontroller/rtl/drg5_fetch_buffer.sv) and checks parcel assembly behavior. From the repository root, select a new build directory and run the following command after activating Verilator and the C++ build tools.

```sh
make -C microcontroller/tests fetch-buffer \
  VERILATOR=verilator BUILD_ROOT=/tmp/drg5-first-run
```

This check exercises one digital component without accessing hardware. The [test guide](../microcontroller/tests/README.md) explains the other directed checks, and the [verification guide](../microcontroller/verification/README.md) distinguishes those runs from formal properties, reference comparisons and archive-dependent campaigns. Compiling firmware, simulating it, programming a device and observing a physical recording remain separate qualification steps.

## Documentation map

| Guide | Purpose |
| --- | --- |
| [Development workflow](pre-coding-workflow.md) | Defines source assumptions, budgets and integration gates before complete acquisition and board implementation. |
| [Microcontroller overview](../microcontroller/README.md) | Maps the implemented CPU, local platform and supporting software to the proposed recording system. |
| [Acquisition](../microcontroller/acquisition/README.md) | Separates the implemented guard from the proposed ADC interface, recording format and DMA path. |
| [Acquisition contract](../microcontroller/acquisition/contract.md) | Freezes the initial ADC profile, epochs, cadence, validity, records, commands and closure outcomes. |
| [Acquisition timing budget](../microcontroller/acquisition/timing-budget.md) | Separates ADC requirements from controller allocations, checks deadline margins, and bounds or supervises every wait before state-machine design. |
| [Acquisition binary formats](../microcontroller/acquisition/formats.md) | Freezes exact record/block/descriptor bytes, integrity, context bindings, identifier lifetimes and loss intervals with independent producer/host checks. |
| [Acquisition clock/reset lifecycle](../microcontroller/acquisition/clock-reset-lifecycle.md) | Defines fixed clock domains, coherent crossings, reset retention/containment and requalification; checks abstract reset races without claiming physical CDC proof. |
| [Electrical and Ubuntu qualification](../microcontroller/acquisition/qualification.md) | Reviews evaluation-board routing and power ownership, runs exact-device tool checks, and identifies unperformed physical gates. |
| [Memory](../microcontroller/memory/README.md) | Describes local storage and the proposed shared-memory ownership and service contracts. |
| [Signal processing](../microcontroller/signal-processing/README.md) | Distinguishes the diagnostic arithmetic workload from planned calibrated analysis. |
| [Hardware references](../datasheets/README.md) | Identifies the manufacturer documents used for electrical and interface design. |
| [Changelog](../CHANGELOG.md) | Records development milestones and subsequent changes. |

## Recording and biological scope

A usable recording interface must establish the electrode or upstream source, reference arrangement, units, gain, filtering, sample timing and invalid intervals. Synthetic electrical inputs provide the initial qualification route. The current documentation does not define a validated biological recording protocol or establish a neural-sample interface from an implanted stimulator.

Later biomarker work must distinguish voltage spectra from event-timing statistics and account for the recording chain's transfer function and artifacts. A spectral peak alone does not establish a pathological oscillator. Modulation studies depend on a validated recording and analysis method and remain outside the implemented platform.

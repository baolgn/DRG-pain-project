# Development and qualification workflow

This workflow connects the implemented CPU platform to the proposed eight-channel DRG signal processor. The repository contains CPU and local-platform RTL, a synthetic acquisition guard, compiled diagnostic firmware and verification sources. The full ADC interface, external working-memory system, host archive and neural-analysis chain remain proposed. The [microcontroller overview](../microcontroller/README.md) identifies the implementation, while the [acquisition](../microcontroller/acquisition/README.md), [memory](../microcontroller/memory/README.md) and [signal-processing](../microcontroller/signal-processing/README.md) component documents separate current behavior from future modules.

The initial electrical target uses synthetic extracellular signals. Cultured DRG neurons provide a provisional biological target, and the physical recording connection remains undecided. No physical ADC connection or documented neural-sample output from an Abbott system forms part of the implemented path. Biological recording protocols, biomarker validation and therapeutic modulation remain outside this workflow.

## Requirements and source boundary

Each requirement needs a value, units, provenance, status and acceptance method. A datasheet limit, proposed engineering target, simulated result and physical measurement carry different evidential weight. Measured hardware performance requires a traceable setup and uncertainty; logical simulation timing alone cannot supply it.

| Planning quantity | Provisional value | Qualification boundary |
| --- | --- | --- |
| Input | Eight extracellular channels; 0.5–5000 Hz useful band | The electrode, reference arrangement and actual source transfer function remain undecided. |
| Signal envelope | 20 µVpp–2 mVpp | This characterizes a synthetic design space rather than a guaranteed biological detection range. |
| Source impedance | 10–100 kΩ per input arm; 1 MΩ stress case | Complex impedance, imbalance and cable capacitance must replace the simplified model for a selected source. |
| Offset and common mode | ±100 mV differential; ±0.5 V common mode | Gain, bias returns, protection and supply rails must accommodate simultaneous extremes. |
| ADC operating point | AD7606C-18 software mode, ±2.5 V single-ended range, low bandwidth, oversampling off | Upstream circuitry provides differential electrode measurement; configuration and physical operation remain unqualified. |
| Digital cadence | Eight channels at 50 kSPS each | A 20 µs slot and proposed 80 MHz clock define the timing budget, not a measured FPGA operating point. |
| Continuity target | Thirty-minute synthetic bench recording and a 100 ms host stall | The eventual hardware must preserve raw records or explicitly account for every invalid or lost interval. |

The source interface must identify units, gain, filters, sample clock, channel order, reference, offsets, clipping and gaps. A passive electrode requires loading and bias analysis. An upstream analog headstage requires its output transfer function and grounding contract. A digital recording requires a documented data format and bypasses the analog capture path. These alternatives must not share undocumented assumptions.

## Electrical feasibility and ADC integration

The [INA819 datasheet](../datasheets/ina819.pdf), [OPA2140 datasheet](../datasheets/opa2140.pdf) and [AD7606C-18 datasheet](../datasheets/ad7606c-18.pdf) constrain the analog chain. The [evaluation-board guide](../datasheets/eval-ad7606c-fmcz-ug-1870.pdf), [schematic](../datasheets/eval-ad7606c18fmcz-schematic.pdf) and [layout](../datasheets/eval-ad7606c18fmcz-layout.pdf) constrain power, connector use and logic levels. Physical inspection must establish the actual board revision, component population and configuration.

A stage-by-stage budget must cover source loading, integrated noise, simultaneous offset/common-mode headroom, gain, anti-alias rejection, phase and overload recovery. Recording reference, amplifier REF, bias return, shield and circuit ground serve different functions. A shared reference also requires an eight-channel loading calculation. The shorted-input target of 2 µV RMS over 0.5–5000 Hz and the 1% loading-error target remain feasibility goals until measurements support them.

The ADC integration gate requires controlled startup, reset, configuration readback, pin ownership, matched conversion completion, serial framing and independently checked status/CRC behavior. Conversion timing, serial clocks, chip-select guards, synchronization and board delays must fit the complete slot. The [acquisition guard](../microcontroller/rtl/drg5_acquisition_guard.sv) supplies no ADC pin driver, so its synthetic tests cannot close these electrical gates.

## Capacity, timing and ownership

The proposed record format preserves all 18 ADC bits in signed 32-bit words and reserves metadata for status, integrity and validity. A frame's scheduled aperture defines sample time; host arrival time does not. Configuration changes, discontinuities and recovery create explicit epoch boundaries.

| Budget | Proposed value | Required evidence |
| --- | --- | --- |
| Serial frame | 224 bits; 11.2 µs of clocks at 20 MHz | Qualify the complete transaction with conversion, pin timing and margins. |
| Stored block | 256 × 48-byte records plus a 64-byte header | Freeze field packing, lengths, byte order and integrity rules before production interoperability tests. |
| Raw storage rate | 2,412,500 bytes/s | Include all recorded metadata and any transport overhead in host sizing. |
| Thirty-minute raw allocation | 4,342,500,000 bytes before additional container/transport overhead | Demonstrate sustained archive throughput and available storage. |
| Ring | 64 blocks; 790,528 bytes | Admit the 100 ms host-stall case only with at least 24 truly free blocks and qualified service margins. |
| Memory service | 4.825 MB/s for capture plus one export read; 7.4125 MB/s during a 5 MB/s export drain | Check arbitration latency, maintenance, metadata and fault handling as well as aggregate bandwidth. |
| Working-memory envelope | At least the proposed 2 MiB allocation | Keep external storage separate from local executable RAM, CPU data, FIFO and other on-chip allocations. |

Acquisition owns sample cadence and raw record production. Consumers receive generation-tagged leases only after completed writes make a block visible. A release cannot authorize reuse while reads remain outstanding. A stop must drain or positively contain old work, account for the final tail and quarantine storage with uncertain writes. CPU halt, reset and optional processing overload must preserve those ownership rules.

## Ubuntu tool and target qualification

Every required development tool must be free and open source and usable on Ubuntu. The tool record must identify versions, licenses, consumed source hashes, target support and reproducible commands. An open instruction set alone does not establish an open FPGA build, programmer or debugger path. Exact-device synthesis and routing also do not prove a physical board works.

| Development activity | Tool path | Acceptance boundary |
| --- | --- | --- |
| Schematic and PCB design | KiCad | Check library provenance, connector/power constraints and fabrication outputs. |
| Analog modeling | ngspice with separately qualified component models | Record model licenses, simulator compatibility and missing behavior. |
| RTL simulation and formal checks | Verilator, Yosys and compatible open formal tools | Check actual production modules, meaningful failure controls and explicit proof assumptions. |
| FPGA implementation | Yosys and nextpnr with an open device database/bitstream flow | Close timing and resource limits for the exact part, package, speed grade and clock constraints. |
| Firmware | RISC-V GNU toolchain and an independent ISA reference | Match ISA, ABI, linker layout and startup/trap conventions. |
| Programming and debug | openFPGALoader and OpenOCD/GDB where the exact target supports them | Qualify FPGA configuration, persistent storage access and CPU debug as distinct operations. |
| Numerical reference and host analysis | Python, NumPy and SciPy | Pin versions, preserve units and compare causal production behavior against independent numerical results. |

The prototype route uses an FPGA with a custom RISC-V CPU. FPGA configuration changes the implemented hardware; firmware changes the program that hardware executes. Persistent boot and recovery must work without a functioning application. A temporary SRAM download does not establish persistent boot, and the FPGA configuration port does not automatically provide a RISC-V CPU debug interface.

## Integration and acceptance sequence

The existing local platform provides a concrete integration starting point. [drg5_local_fabric.sv](../microcontroller/rtl/drg5_local_fabric.sv) supplies 8 KiB ROM, 64 KiB instruction RAM and 32 KiB local data RAM. [run_local_platform.py](../microcontroller/tests/run_local_platform.py) exercises compiled firmware against that platform. The [synthetic workload](../microcontroller/firmware/synthetic/main.c) then exercises real CPU arithmetic and control while the surrounding test environment models shared-memory and host behavior. These boundaries must remain visible when interpreting results.

| Integration gate | Completion condition |
| --- | --- |
| Local CPU platform | Startup initializes required state; instruction/data transactions, traps, interrupts and debug produce independently checked effects. |
| Guard and synthetic composition | Slot identity, invalid records, stop reasons, tail accounting and CPU-reset/debug interaction satisfy the guard contract. Model results remain separate from RTL and physical measurements. |
| Shared-memory implementation | DMA, arbitration, publication, leases, wrap/reuse and uncertain-write quarantine work with bounded service under CPU, debug and transport contention. |
| Physical ADC capture | Qualified power and pins produce correctly ordered signed samples, status and CRC, with measured cadence and explicit fault recovery. |
| Raw host archive | Sustained eight-channel capture survives the specified stall and endurance cases; independent replay finds no silent duplication, loss or metadata inconsistency. |
| Signal processing | Independent vectors verify scaling, filters, state transitions, decimation and spectral normalization within stated tolerances and complete-workload budgets. |
| Board and persistent recovery | Timing/resource closure, physical programming, power-cycle boot and recovery from invalid images pass on the exact assembled target. |

Verification must retain the source and tool identity, complete outcome, expected failure controls and material exclusions for each campaign. A passing model does not establish a hardware implementation, a short CPU run does not establish continuous long-duration RTL execution, and a diagnostic arithmetic result does not establish biological interpretation. Physical qualification begins with calibrated synthetic inputs and advances only when the source, analog chain, capture, memory and archive each meet their stated acceptance conditions.

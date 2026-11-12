# Electrical interface and Ubuntu qualification

Reviewed 2026-11-05 on `feature/acquisition-engine`, starting from `584743d`. **Overall electrical/build/programming pass condition: NOT PASSED.** No board was available for physical inspection or testing. The electrical interface has a documented candidate design and explicit constraints; the host tools can build exact-device bitstreams. Actual assembly identity, an approved ADC adapter, physical timing and programming/operation remain unqualified.

This result must not be promoted to a physical pass because a schematic, example inventory, successful compiler or programmable file exists. The [inspection record](board-inventory.json) retains unknown physical observations as null. Acquisition remains unavailable until its physical gates close.

## Qualification ledger

| Gate | Result and evidence |
| --- | --- |
| ADC assembly, U4 marking, connectors and actual links | **Not performed: no board.** [Drawing-level board review](board-qualification.md) distinguishes intended parts from fitted observations. |
| Analog channels, control routing and ownership | Drawing-level routes documented, including channels 1–8, digital control/data contacts, power/reference and unused signal ownership. No FPGA-to-ADC adapter or physical continuity pass. |
| Power and static voltage compatibility | Constraints and worst-case calculations documented. VIN-pulled enable, rail tracking, absolute pin limits and unpowered isolation remain physical gates. |
| Verilator | Strict timed simulation checks 2,048 active cycles and generates a waveform. [Tool qualification](../qualification/README.md). |
| Yosys and required device primitives | `synth_ecp5` maps PLL, block RAM, DSP, carry and USRMCLK smoke; a separate full P25 build uses the slang frontend and active flash-clock path. |
| nextpnr and bitstream generation | Exact `--85k --package CABGA381 --speed 6` smoke route and `ecppack` pass; full programmable P25 build also routes and packs. No ignored timing-failure or unconstrained-pin bypass is used. |
| SymbiYosys | Proof and cover pass; the deliberately false assertion produces a counterexample, not a timeout/tool error relabeled as success. |
| GTKWave | Actual GUI process loads the generated VCD, finds 11 facilities and adds five expected traces. VCD/FST conversion is a separate check. |
| Open-source programmer | Pinned openFPGALoader reports the selected ULX3S/FT231X/FPGA support; generated bitstreams pass part/IDCODE parsing; full P25 SRAM plan passes without hardware access. |
| Physical SRAM programming, flash/readback and power-cycle boot | **Not performed: no board.** No detection or hardware programming command ran; no target was selected, programmed or erased. |
| Complete 80 MHz acquisition system | **Not qualified.** Small 80 MHz smoke success is not full CPU, ADC, memory, transport or analog qualification. |

The selected tool target is **ULX3S v3.1.7 D&M, LFE5U-85F-6BG381C**, with FT231XQ on US1, expected USB VID:PID `0403:6015` and FPGA configuration IDCODE `0x41113043`. These are admission requirements, not measurements of a connected board. The source inventory also names W25Q128JVSIQ; its marking and JEDEC ID must be checked before persistent programming.

## Electrical findings and corrections

The [board review](board-qualification.md) uses the supplied research, UG-1870 Rev. A, schematic 02_057655 Rev. C, layout 08-057655 Rev. A and AD7606C-18 Rev. B, with hashes and visual cross-checks. Material corrections are:

1. **J1–J4 are channel 1–4 positive inputs; J5–J8 are their negative inputs.** Channels 5–8 use the drawn terminal/header routes. Connector population, orientation, negative-input ground links and channel-8 bypass links need inspection.
2. **CARRIER_POWER_GOOD is not a presumed 3.3 V input/output.** R2 and R7 pull the shared U2/U3 enable net toward VIN; FMC D1 must not connect directly to ECP5 GPIO without a reviewed voltage-rated interface. P4 is documented for 7–9 V, distinct from the carrier's 12 V option. Moving JP2 alone does not qualify the enable path.
3. **Reference ownership is exclusive.** R1 selects the internal reference; P5/J9 and JP6/R13 must not leave another reference driving REFIN/REFOUT. Software selection cannot prove the fitted paths.
4. **The direct-interface voltage envelope is tightened.** ADC VDRIVE and ECP5 LVCMOS33 VCCIO must each remain within 3.135–3.465 V with qualified signal peaks. Independent rail extremes can still exceed the ADC's `VDRIVE+0.3 V` limit, so paired-rail tracking, sequencing and unpowered isolation are additional conditions. Nominal 3.3 V labels and positive logic-threshold margins are insufficient.
5. **R77 must be open.** The optional CONVST-to-CS compatibility link would defeat R1's separate trigger/chip-select ownership. The 100 Ω series resistors do not translate voltage. A populated carrier and a standalone controller must never drive the same net.

The [ADC profile](adc-profile.md) and [contract](contract.md) incorporate the corrected electrical envelope. Earlier definition evidence remains bound to commit `584743d`; its hashes are not rewritten to imply these later checks existed then. The input boundary remains conditioned analog voltages at the ADC. No Abbott recording interface is inferred.

## Complete CPU build

The [P25 evidence](evidence/platform-2026-11-05/retention.json) extends the small primitive smoke with the existing programmable CPU/boot design, built from the current repository sources. The host is Ubuntu 26.04.1 LTS x86-64. Firmware uses xPack RISC-V GCC 15.2.0-1, the exact IMC architecture/ILP32 flags in [build.json](evidence/platform-2026-11-05/firmware/build.json), private runtime and canonical boot ROM. Synthesis uses OSS CAD Suite 2026-03-01 and its open-source slang plugin; exact tools, database, source and firmware hashes are retained.

| Build result | Recorded value |
| --- | --- |
| Profile/top | `P25-SPI-BOOT-1`, stage 2, `drg5_ulx3s_programmable` |
| Physical clock selected by PLL parameters | 25 MHz nominal; not 80 MHz |
| Effective route constraint | 27.77777862548828 MHz in the machine-readable report, representing the 10% period guard |
| Internal route Fmax | 28.55021858215332 MHz; this is an estimate, not a physical measurement |
| Mapped primitives | 48 DP16KD, 4 MULT18X18D, 1 EHXPLLL, 1 USRMCLK; full cell/port data in the summary |
| Generated bitstream | [drg5.bit](evidence/platform-2026-11-05/program-build/route/drg5.bit), 596,132 bytes, SHA-256 `9111efbd680d9531475ae561394c4c3a509e0d5d417c1d36e03c51e27a88e1a9` |
| SRAM operation plan | [operation.json](evidence/platform-2026-11-05/sram-plan/operation.json): `plan-ready`, `executed=false`, empty commands, no persistent write |
| Overall build status | [qualification.json](evidence/platform-2026-11-05/program-build/qualification.json): `routed-and-packed-hardware-unverified` |

The [route summary](evidence/platform-2026-11-05/program-build/route/summary.json), [route log](evidence/platform-2026-11-05/program-build/route/route.log), [full compressed timing report](evidence/platform-2026-11-05/program-build/route/route.json.gz) and [packing log](evidence/platform-2026-11-05/program-build/route/pack.log) retain the actual outcome. USRMCLK is actively connected to the boot flash clock in this top; the separate smoke's high-impedance USRMCLK instance only checks mapping/packing support. Neither test proves physical flash operation.

One nextpnr warning prints the existing 27.8 MHz constraint and derived 25 MHz PLL constraint with misleading labels. Review of the retained [pinned `ecp5/pack.cc` implementation](https://github.com/YosysHQ/nextpnr/blob/858177d136dc897202c7a36c62a1af27cce6fcbe/ecp5/pack.cc#L2727-L2740), SHA-256 `3c6842deafc1d62c1fa8c5530ad7ad68e50877599cb38d6aba7a88ef2f89f03d`, shows that this branch returns without replacing the existing constraint. The final machine-readable CPU clock constraint is 27.77777862548828 MHz and the final log reports PASS at 27.78 MHz; these are the acceptance evidence, not an assumption that the warning is harmless. The synthesis log also retains ABC's combinational-network warning. Neither warning is hidden. The internal P25 pass does not close external SPI/ADC delays or the full CPU's previously failed 80 MHz target.

Large derived mapped/routed netlists and text configuration were excluded from the committed compact evidence; their hashes and sizes are in retention.json. The packed bitstream, actual source snapshots, firmware artifacts, commands, logs and compressed full timing report are retained. Rebuilds remain subject to source/tool identity and qualification rather than assuming any future generated file is the same bitstream.

## Reproducing the Ubuntu path

Use the exact archive digest, native dependencies and commands in the [tool guide](../qualification/README.md). The supported host for this qualification is Ubuntu/Linux x86-64; it does not establish native Windows, macOS or an arbitrary newer bundle. The route is Verilator simulation, Yosys/slang plus `synth_ecp5`, nextpnr-ecp5 plus the Trellis device database, `ecppack`, then openFPGALoader. SymbiYosys and GTKWave provide separate verification/inspection steps. No proprietary FPGA suite, solver, programming executable or IP generator is required by the tested host path.

For the existing complete CPU path, install the pinned GCC and suite in the documented locations or use verified compatibility symlinks. Existing paths must be inspected, never silently overwritten. `run_programmable.py` and the image validator still use `/tmp/drg5-arch-tools/gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-`; the programmer defaults to the pinned suite path under `/tmp/drg5-control-tools-20260301`. An explicit `--prefix` on the firmware builder alone does not change the other validators' fixed prefix.

The compiler archive is [xPack RISC-V GCC 15.2.0-1 Linux x64](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/tag/v15.2.0-1), 433,494,794 bytes, SHA-256 `aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758`. After the tool guide's suite installation, this installation recipe supplies both compatibility paths. Its subshell stops on an existing directory or failed checksum; on an already configured host, verify and reuse the existing installation instead of running it again.

```sh
# prepare verified tools without replacing an existing installation.
(
  set -eu
  mkdir /tmp/drg5-arch-tools
  mkdir /tmp/drg5-arch-tools/gcc
  cd /tmp/drg5-arch-tools
  curl --fail --location --output gcc.tar.gz \
    https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz
  printf '%s\n' 'aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758  gcc.tar.gz' | sha256sum --check
  tar -xzf gcc.tar.gz -C gcc
  mkdir /tmp/drg5-control-tools-20260301
  ln -s /tmp/drg5-acquisition-tools/oss-cad-suite \
    /tmp/drg5-control-tools-20260301/oss-cad-suite
)
```

From the repository root, with those prerequisites satisfied and new output directories:

```sh
python3 microcontroller/firmware/build.py --profile imc \
  --output /tmp/drg5-qualified-firmware
timeout --signal=TERM --kill-after=10s 1800s \
  python3 microcontroller/synth/run_programmable.py \
  --tools /tmp/drg5-control-tools-20260301/oss-cad-suite \
  --firmware /tmp/drg5-qualified-firmware \
  --output /tmp/drg5-qualified-p25
python3 microcontroller/programming/program_board.py config-sram \
  --configuration /tmp/drg5-qualified-p25/route/drg5.bit \
  --route-summary /tmp/drg5-qualified-p25/route/summary.json \
  --inventory microcontroller/programming/inventory.example.json \
  --output /tmp/drg5-qualified-sram-plan
```

The last command is a **host-only plan** using an explicitly unverified example. It neither selects a board nor proves that hardware can be programmed. The retained command logs identify the tested tool paths and the compatibility symlink used for the fixed GCC prefix.

The pinned nextpnr ECP5 flow does not establish general external `set_input_delay`, `set_output_delay`, uncertainty or arbitrary SDC false-path support. Unsupported/ignored constraints cannot be counted as timing closure. ADC and memory interfaces need separately reviewed I/O budgets, constraints actually understood by the selected tools, CDC checks and physical captures before activation. The full raw stream also needs a separately qualified high-throughput host link: the onboard FT231X 3 Mbaud 8N1 UART is at most 0.3 MB/s, below the 2.4125 MB/s raw-block rate. US1 programming/control success would not qualify acquisition transport.

## Programming and physical acceptance

When hardware becomes available, record the actual PCB/assembly, FPGA and flash markings, USB serial, supply state, pin ownership and adapter identity first. Keep the ADC disconnected for the first reviewed FPGA smoke. Read-only openFPGALoader identification must select the inspected FTDI serial and return the expected exact chain/IDCODE; a first-found cable is not sufficient. The [programming wrapper](../programming/README.md) rejects execution using the placeholder inventory and pins the loader identities.

Only after those prerequisites pass may a hardware operator execute the reviewed SRAM plan with the verified inventory. Retain loader output plus independently observed operation over a declared duration and repeated reset/program cycles. A success exit code alone does not prove the intended circuit runs. SRAM loading is volatile; persistent flash programming additionally requires verified flash identity, explicit region ownership, backup where needed, bounded writes/readback and power-cycle/recovery observation. No flash erase/write or physical programming was attempted here.

The ADC gate separately requires the [board inspection matrix](board-qualification.md#inspection-and-release-record), an approved adapter/LPF, runtime ADC ID and configuration readback, pattern/status/CRC captures and measured pin timing. It cannot be closed by the FPGA programmer identifying its own JTAG device. The conditioned analog chain and sustained recording/transport acceptance remain distinct gates.

## Verification records

The verification records include source and drawing inspections, target and tool identities, positive and failure controls, voltage and ownership corrections, and route and waveform results. Failed checks and tool runs remain available alongside passing results.

The final [audit record](evidence/hardware-review-2026-11-05/review.json) and [comment report](evidence/hardware-review-2026-11-05/comments.json) cover all current active source/build files, syntax, source stability and evidence hashes. Historical snapshots, generated outputs and third-party sources preserve their original bytes; they are not relabeled as current implementations.

The result is a reproducible host build/tool qualification and a concrete electrical review with identified blockers. It is **not** an assertion that the actual assembly or complete recording/programming system is qualified. Physical hardware testing and adapter qualification remain required.

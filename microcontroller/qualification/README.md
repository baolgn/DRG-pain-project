# Ubuntu tool and FPGA qualification

Ubuntu tool qualification on 2026-11-05 passed for the selected **ULX3S v3.1.7 D&M / LFE5U-85F-6BG381C** build target. No board was available, so assembly inspection, JTAG access, configuration, flash readback, power-cycle boot and ADC electrical measurements are **not performed**. A successful bitstream build is not a physical programming result. See the [electrical review](../acquisition/board-qualification.md) and [overall acquisition qualification](../acquisition/qualification.md) for the separate interface and full-platform gates.

## Contents

1. [Exact target and tools](#exact-target-and-tools)
2. [Executed checks](#executed-checks)
3. [Ubuntu reproduction](#ubuntu-reproduction)
4. [Programming path](#programming-path)
5. [Evidence and review](#evidence-and-review)

## Exact target and tools

Host: Ubuntu 26.04.1 LTS, x86-64; host Python 3.13.13. [Native prerequisite identities](evidence/ubuntu-2026-11-05/host-tools.json) record the resolved C++ compiler, Make and Python bytes/version probes. The selected archive is [OSS CAD Suite Linux x64 2026-03-01](https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/2026-03-01), `oss-cad-suite-linux-x64-20260301.tgz`, **705,999,427 bytes**, SHA-256 **`3558d8cf5b88ba224cf8bae872f83bed11cffdde163b130412e20352029c85f1`**. A date tag or command name alone is insufficient. [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) supplies the bundled runtime; [nextpnr](https://github.com/YosysHQ/nextpnr) and [Project Trellis](https://github.com/YosysHQ/prjtrellis) provide ECP5 implementation and bitstream support.

The runner verifies the archive digest, then compares 201 selected executable, loader, primitive-model and ECP5 device/tile-database files against that archive. The result also records their individual hashes, the exact command arguments and source hashes. Auxiliary shared-library files are supplied by the same bundle but are not individually compared by this 201-file gate; no claim of a complete independent source rebuild is made. The nextpnr chip database is embedded in its hashed executable. Trellis's `devices.json` and 85F `globals.json`, `iodb.json`, `tilegrid.json` and common ECP5 tiledata hashes are recorded separately.

| Component | Executed version | Source identity from bundled license |
| --- | --- | --- |
| Verilator | `5.047 devel v5.046-19-ge9dd6eaaf (mod)` | `e9dd6eaaf0dcecaf39942afda32cb2f243f8ded6` |
| Yosys | `0.62+112`, `687a36af3` | `687a36af388ec45018ab4bec8993f4c4daa5ccac` |
| nextpnr-ecp5 | `0.9-87-g858177d1` | `858177d136dc897202c7a36c62a1af27cce6fcbe` |
| Trellis ecppll/ecppack | Bundle tools executed; source pin below identifies them | `73bd411731808d80ead650bbc9840d9e02911e9e` |
| SymbiYosys | `v0.62-16-g4dabe8a` | `4dabe8ab323ae87d53afd680c84449410c084041` |
| Z3 | `4.15.5`, 64-bit | `76182c7e663d68e8a29eda36442cded9c5eabec1` |
| GTKWave | `3.4.0` | `10cfae614ed8be80b5bb64e8c2194e7dffcd297a` |
| openFPGALoader | `v1.0.0` | `3ae5e5e4a5f055d12f6079616cb1ec1d67bf30f1` |

The Verilator `(mod)` suffix is retained, not normalized away. Source pins describe the bundle's own provenance records; executable hashes identify tested bytes. The March bundle is distinct from the older January tool smoke discussed in the original research. No results are transferred between versions without rerunning the checks.

The retained [license records](evidence/ubuntu-2026-11-05/licenses/index.json) cover Verilator's LGPL/Artistic options, Yosys/nextpnr/SymbiYosys/Trellis ISC-style notices, Trellis database CC0 notice, GTKWave GPL, Z3 MIT and openFPGALoader Apache-2.0. This path uses no proprietary FPGA suite, HDL frontend, IP generator, solver or programming utility. This is tool-license identification, not an assertion that every repository dependency or redistribution obligation has been qualified.

Target constraints are `--85k --package CABGA381 --speed 6`, seed 1, nominal 25 MHz reference on G2 and a generated 80 MHz smoke clock. The selected assembly and exact FPGA package/speed grade must still be physically verified. An IDCODE alone distinguishes neither package, speed grade nor PCB revision. The [existing LPF/programming guides](../synth/README.md) carry the full CPU pin assignments; the smoke uses only G2 and LEDs B2/C2/C1/D2/D1/E2/E1/H3, all LVCMOS33.

## Executed checks

The final [r6 summary](evidence/ubuntu-2026-11-05/r6/summary.json) has `host-tools-and-smoke-pass`; all commands have bounded execution and captured logs. This status deliberately excludes physical programming and complete acquisition qualification.

| Check | Measured result and boundary |
| --- | --- |
| Verilator | Strict `-Wall`, timed/assertion-enabled build; 2,048 checked cycles of counter, 18×18 multiply and read-first RAM after initialization; VCD emitted. No warnings waived. PLL behavior is excluded from portable simulation. |
| Yosys | Built-in `read_verilog -sv` and `synth_ecp5`; zero `check -assert` problems; real ECP5 technology cells required, not just generic logic. This is the tested SystemVerilog subset, not UVM/full-language qualification. |
| nextpnr | 85F/CABGA381/speed-6 route passed 80 MHz; reported smoke Fmax **140.0953 MHz**. No unconstrained-pin or timing-failure bypass. This number is neither measured clock frequency nor full CPU/ADC timing closure. |
| Bitstream | `ecppack --compress` produced a nonempty `.bit`; the production parser accepted part `LFE5U-85F-6CABGA381` and IDCODE `0x41113043`. SHA-256 **`be3f0d438d284964b12465b75710f9433fd57b28edc82664d3ae9dc72997705e`**. No bitstream was sent to a device. |
| SymbiYosys/Z3 | Counter transition proved, count=15 cover reached, deliberately false count=0 assertion produced expected `FAIL`/exit 2. Error/timeout alone cannot satisfy that negative control. This qualifies tool invocation, not complete CPU/acquisition formal properties. |
| GTKWave | VCD→FST conversion passed; actual GUI loaded the VCD, found **11 facilities**, added **5 traces**, and checked that counter/product/RAM-output categories were all present. Display permission is required; headless conversion alone is not this GUI pass. |
| Programmer | Local board/cable/device listings include `ulx3s`, `ft231X` and `0x41113043`. Static support is established. No USB detection, SRAM write, flash write or readback was attempted because no board is available. |

| Required resource | Actual mapped/routed coverage | Remaining qualification |
| --- | --- | --- |
| Carry, LUT and FF | 16 CCU2C mapped; 127 TRELLIS_COMB and 133 TRELLIS_FF routed | Full datapath timing/resource allocation |
| EBR | 1 DP16KD from 512×32 RAM; read-first portable behavior checked | CPU byte enables, dual-port collision modes, initialization and full memory allocation |
| DSP multiply | 1 MULT18X18D | Full signed/unsigned 32-bit arithmetic integration |
| PLL/global clock | 1 EHXPLLL, 1 DCCA; ecppll generated 25→80 MHz parameters | Physical lock, jitter, oscillator tolerance, reset and clock-domain crossings |
| Basic I/O | 9 TRELLIS_IO; all exposed smoke pins constrained | ADC setup/hold, board delay and adapter routing; no external-input timing closure is claimed |
| User flash clock | 1 USRMCLK preserved through route/packing, held high impedance | This smoke tests primitive availability only. Active SPI clock ownership belongs to the separate programmable CPU build and still needs physical readback. |
| DDR/SERDES/SDRAM | Not used by this smoke | Separate implementation and electrical/timing qualification; unavailable by implication |

The full CPU's previous 80 MHz route failed and its P25 profile has a separate route/packing record in the [overall qualification](../acquisition/qualification.md). A small primitive smoke passing 80 MHz does not repair that failure or implement the 80 MHz acquisition engine.

## Ubuntu reproduction

The GTKWave stage requires access to a graphical display. The commands below create new directories and do not change hardware. Independent installation reproducibility remains unverified. Install the Ubuntu prerequisites using the distribution package manager:

```sh
sudo apt update
sudo apt install python3 build-essential curl ca-certificates tar gzip
```

Download the exact asset from the pinned release, verify it before extraction, and use a path without whitespace. The runner calls the bundle's loader/libraries directly for nextpnr/Trellis/GTKWave and uses private cache/configuration directories; it does not repurpose HOME or require host GTK module injection.

```sh
# stop before extraction on an existing directory or failed checksum.
(
  set -eu
  mkdir /tmp/drg5-acquisition-tools
  cd /tmp/drg5-acquisition-tools
  curl --fail --location --output oss-cad-suite-linux-x64-20260301.tgz \
    https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-03-01/oss-cad-suite-linux-x64-20260301.tgz
  printf '%s\n' '3558d8cf5b88ba224cf8bae872f83bed11cffdde163b130412e20352029c85f1  oss-cad-suite-linux-x64-20260301.tgz' | sha256sum --check
  tar -xzf oss-cad-suite-linux-x64-20260301.tgz
)
```

From the repository root, choose new paths for every attempt. The runner refuses existing build/output directories, records failed attempts and never retries a device:

```sh
python3 microcontroller/qualification/run.py \
  --tools /tmp/drg5-acquisition-tools/oss-cad-suite \
  --archive /tmp/drg5-acquisition-tools/oss-cad-suite-linux-x64-20260301.tgz \
  --build /tmp/drg5-acquisition-smoke-build \
  --output /tmp/drg5-acquisition-smoke-evidence
```

Success requires exit zero **and** summary `host-tools-and-smoke-pass`, `source_stable=true`, all command checks passed and matching retained hashes. Individual proof status files distinguish positive PASS from expected negative FAIL. The GUI Tcl script checks real loaded facilities, not the version banner. A display failure leaves the run failed; do not relabel it a complete GTKWave pass.

The full firmware/P25 flow additionally needs the matching RV32 compiler and its runtime libraries. [The overall qualification](../acquisition/qualification.md) records the current-source firmware, route and programming-plan commands. The existing `run_programmable.py` and image validation expect the pinned xPack GCC at `/tmp/drg5-arch-tools/gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-`; `--tools` does not change that compiler prefix. Set up that documented compiler location, or explicitly qualify a code change that makes it configurable. Do not silently substitute a compiler or claim the portable smoke compiled CPU firmware.

## Programming path

The [openFPGALoader first-steps guide](https://trabucayre.github.io/openFPGALoader/guide/first-steps.html) separates volatile SRAM configuration from persistent flash writes. The project's [programming tool](../programming/README.md) adds exact inventory/serial checks, image provenance and readback accounting. Its execution gate pins the March-2026 loader wrapper and executable; an arbitrary newer distribution package is not an approved substitute.

Before physical programming, inspect ULX3S PCB/assembly, FPGA and flash markings; record the actual FT231X USB serial. Selected configuration transport is **US1 / FT231XQ**, VID:PID **0403:6015**, board `ulx3s`, cable `ft231X`; expected FPGA IDCODE is **0x41113043**. The example inventory has `physical_inspection_verified=false` and a placeholder serial, so it is suitable only for planning. The attached-board checks, operating-system USB permissions and cable/driver behavior remain pending.

A future bench run must first verify supply rails, ground, standalone ADC isolation and exact board identity, then perform read-only discovery with the inspected serial. It must reject a missing/multiple/mismatched target. Use the production `program_board.py` flow for the compatible P25 bitstream and firmware bank, not this tool-smoke `.bit`: the smoke has no CPU boot ROM and no matching application ABI. Volatile configuration, persistent configuration, application-bank write/readback and power-cycle application observation are distinct tests. The retained host-only plan proves command preparation, not any of these hardware operations.

US1 is suitable for programming/control, not the required raw acquisition stream: the FT231X USB Full Speed/UART path does not provide the proposed 2.4125 MB/s raw payload and 5 MB/s recovery transport. A separately qualified high-throughput link and ADC adapter remain mandatory. ULX3S is the selected FPGA/tool target, not an already approved acquisition carrier.

## Evidence and review

| Attempt | Result and retained correction |
| --- | --- |
| [r1](evidence/ubuntu-2026-11-05/r1/summary.json) | Strict Verilator rejected declaration/process clock initialization. Corrected the fixture, without disabling the warning. |
| [r2](evidence/ubuntu-2026-11-05/r2/summary.json) | Simulation, synthesis, 80 MHz route, bitstream, formal and conversion checks passed; GTK could not access the display. The run remains failed. |
| [r3](evidence/ubuntu-2026-11-05/r3/summary.json) | Same hardware-free flow with display access passed. Review added archive-member checks, unconditional admission checks, explicit JSON failure on source changes, exact bitstream identity and per-output GUI assertions. |
| [r4](evidence/ubuntu-2026-11-05/r4/summary.json) | Comment/provenance corrections passed all stages; bitstream identical to r3. |
| [r5](evidence/ubuntu-2026-11-05/r5/summary.json) | Provenance pass additionally binds the imported production parser before use and checks its stability, plus all common ECP5 tiledata against the pinned archive; bitstream remains identical. |
| [r6](evidence/ubuntu-2026-11-05/r6/summary.json) | Final pass adds four local Tcl block comments found by manual review; executable statements and bitstream remain identical, and all 21 commands pass. |
| [Missing tools](evidence/ubuntu-2026-11-05/missing-tools/summary.json), [bad archive](evidence/ubuntu-2026-11-05/bad-archive/summary.json) | Expected failure controls preserve failed JSON with no tool launched; wrong-archive rejection also remains active under `python3 -O`. |

Source snapshots retain each attempt's actual inputs. The generated C++/objects, technology netlist and place/route configuration stay in the build directory; retained logs, route report, waveforms, bitstream and hashes establish what was exercised. The records distinguish this qualification from historical CPU release snapshots. Native tool/version and checked-fixture results support Ubuntu feasibility; physical electrical and programming tests remain outstanding.

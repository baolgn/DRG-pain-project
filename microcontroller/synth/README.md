# FPGA synthesis and implementation checks

## Purpose

The synthesis tools measure whether the implemented RTL maps and routes for the selected ECP5 target. They generate reports and optional bitstreams; they do not program a board. A successful mapping establishes a particular source/tool result, while successful routing and packing remain hardware-unverified results.

The [current electrical and Ubuntu qualification](../acquisition/qualification.md) links tool/primitive and programmable-CPU builds, with exact target identity and physical limitations. The [tool qualification runner](../qualification/README.md) exercises the selected open-source tool suite without requiring an attached board.

## Instructions

Use the Ubuntu/Linux x86-64 OSS CAD Suite layout required by [run_fpga.py](run_fpga.py). The runner invokes Yosys with the slang frontend, nextpnr-ecp5, ecppack and ecppll, and records tool and database hashes. It also invokes the suite's Linux dynamic loader and bundled libraries explicitly. Merely installing commands with matching names on `PATH` does not satisfy that layout. On Windows, run these commands inside [Ubuntu WSL2](../../docs/README.md#windows-powershell-and-wsl); on macOS, use an Ubuntu x86-64 VM or [remote Linux host](../../docs/README.md#linux-only-toolchains). The explicit Linux loader excludes native PowerShell and macOS execution, and each WSL or VM run requires its own successful checks.

Build firmware first using [firmware/build.py](../firmware/README.md). The generic runner requires `rom.hex`, `iram.hex` and `firmware.elf`, plus the selected board wrapper, LPF constraints, top module, clock and tool directory. Inspect its arguments before selecting a new target:

```sh
python3 microcontroller/synth/run_fpga.py --help
```

The narrower [run_programmable.py](run_programmable.py) wrapper fixes the supported `P25-SPI-BOOT-1` configuration: the programmable board top, stage 2, a 25 MHz requested clock, the canonical boot ROM and a 10% timing guard. It also requires the firmware builder's fixed GCC installation for image inspection. A preflight validates that compatibility and records the intended route command without performing place and route:

```sh
python3 microcontroller/synth/run_programmable.py \
  --tools /tmp/drg5-control-tools-20260301/oss-cad-suite \
  --firmware /tmp/drg5-firmware-new \
  --output /tmp/drg5-programmable-preflight-new \
  --preflight-only
```

For an actual synthesis and routing run, use another new output directory and omit `--preflight-only`. Read `qualification.json` and the child `route/summary.json`; a preflight does not supply a bitstream or a routing pass. In the generic runner, `--synthesis-only` stops after mapping. Its 10% default guard requests a route constraint of `requested MHz / 0.9`; the guard does not change the intended PLL output clock.

The evidence files identify target, seed, source snapshots, firmware, mapping, timing, route constraints and packed output. Preserve failed attempts alongside successful ones. A passing register-file candidate or standalone unit mapping does not establish the full CPU's timing, memory implementation or physical 80 MHz operation.

## Implementation

| Source | Responsibility |
| --- | --- |
| [run_fpga.py](run_fpga.py) | Orchestrates source snapshots, PLL generation, synthesis, routing, timing checks and packing. |
| [run_programmable.py](run_programmable.py) | Constrains that flow to the canonical programmable boot configuration. |
| [review_fpga.py](review_fpga.py) and [audit_fpga_generic.py](audit_fpga_generic.py) | Inspect a supplied candidate's reports and mapped structure. |
| [audit_fpga.py](audit_fpga.py) | Audits a complete supplied campaign rather than generating a new one. |
| [check_datapath.py](check_datapath.py), [check_fetch.py](check_fetch.py) and [map_regfile.py](map_regfile.py) | Check individual structures and register-file alternatives with their own scopes. |
| [fpga/drg5_ulx3s.lpf](fpga/drg5_ulx3s.lpf) and [fpga/drg5_ulx3s_programmable.lpf](fpga/drg5_ulx3s_programmable.lpf) | Define target pin and timing constraints for the corresponding wrappers. |
| [fpga/probe_target.py](fpga/probe_target.py) | Performs an explicitly requested loader/device probe; it is separate from synthesis. |

The Python files coordinate and inspect external tools. The hardware implementation remains in [RTL](../rtl/README.md), with board integration in the selected board source. Earlier evidence binds its own source bytes and tools; later documentation or code changes do not renew that evidence automatically.

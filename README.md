# DRG pain project

This project studies how dorsal root ganglion signals can be recorded and analyzed to characterize neural activity associated with pain. The immediate goal is a signal-processing platform that preserves raw recordings, sample timing, configuration and data-quality information. Later work will develop recording protocols, investigate candidate biomarkers and evaluate whether controlled modulation can change those signals. Natural oscillations, pathological changes and therapeutic effects remain questions to investigate.

Extracellular recordings from cultured neurons provide the provisional source model. The physical recording connection remains undecided. Current work implements the microcontroller and synthetic verification infrastructure; biological recording, biomarker validation and therapeutic modulation have not been demonstrated.

## [Installation](docs/README.md#installation)

Install [Git](https://git-scm.com/downloads) and clone the repository. Run commands from its root unless a component guide states otherwise. Use paths without whitespace because several current build helpers require them.

```sh
git clone https://github.com/baolgn/DRG-pain-project.git
cd DRG-pain-project
```

On Ubuntu, install the host utilities below, then follow the [development setup](docs/README.md#installation) for the tools needed by the selected component. These packages do not install the FPGA or RISC-V toolchains.

```sh
sudo apt update
sudo apt install git python3 python3-venv build-essential ripgrep zlib1g-dev
```

| Host | Setup and current limitation |
| --- | --- |
| Ubuntu Linux | The documented development route uses free and open-source tools. Retained results apply to their recorded tool versions and source files. |
| Windows | Git can clone the source from PowerShell. Use an Ubuntu environment for the documented build commands; native Windows and hardware access through that environment remain unverified. |
| macOS | Git can clone the source from Terminal. Native tool paths and dependencies require qualification; Intel and Apple silicon workflows remain unverified. An Ubuntu environment provides the closest command layout. |

The [microcontroller test guide](microcontroller/tests/README.md) provides a first simulation check. The [firmware](microcontroller/firmware/README.md), [FPGA synthesis](microcontroller/synth/README.md) and [programming](microcontroller/programming/README.md) guides cover their separate workflows. No complete hardware recording setup has been qualified.

## [Microcontroller](microcontroller/README.md)

The microcontroller combines a custom five-stage RISC-V CPU with local memory, firmware, boot and debug support. An acquisition guard and synthetic workloads exercise timing, ownership and fault handling. The complete ADC receiver, recording DMA, shared-memory system and calibrated signal-analysis chain remain development work. The component guide contains implementation details, architecture diagrams and verification limits.

## [Development and recording requirements](docs/README.md)

The development documentation defines source assumptions, analog and digital budgets, data ownership and acceptance gates. It connects electrical qualification to later recording and analysis work while keeping unresolved source, protocol and biological decisions explicit.

## [Hardware references](datasheets/README.md)

The hardware reference collection contains manufacturer documents for the AD7606C-18 evaluation system, INA819 amplifier and OPA2140 operational amplifier, together with supporting application notes. These documents constrain component selection and interface design; their specifications are not measurements of the assembled project.

The [changelog](CHANGELOG.md) records development milestones and subsequent changes.

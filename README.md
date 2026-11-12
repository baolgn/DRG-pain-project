# DRG pain project

This project studies how dorsal root ganglion signals can be recorded and analyzed to characterize neural activity associated with pain. The immediate goal is a signal-processing platform that preserves raw recordings, sample timing, configuration and data-quality information. Later work will develop recording protocols, investigate candidate biomarkers and evaluate whether controlled modulation can change those signals. Natural oscillations, pathological changes and therapeutic effects remain questions to investigate.

Extracellular recordings from cultured neurons provide the provisional source model. The physical recording connection remains undecided. Current work implements the microcontroller and synthetic verification infrastructure; biological recording, biomarker validation and therapeutic modulation have not been demonstrated.

## [Installation](docs/README.md#installation)

Install [Git](https://git-scm.com/downloads) and clone the repository. Run commands from its root unless a component guide states otherwise. Use paths without whitespace because several current build helpers require them.

```sh
git clone https://github.com/baolgn/DRG-pain-project.git
cd DRG-pain-project
```

### Ubuntu and Debian

Install the host utilities and simulator, then follow the [development setup](docs/README.md#installation) for the tools needed by the selected component. These packages do not install the pinned FPGA or RISC-V toolchains. The development guide also includes [Fedora and Arch commands](docs/README.md#fedora-and-arch-linux).

```sh
sudo apt update
sudo apt install git python3 python3-venv build-essential ripgrep zlib1g-dev \
  curl ca-certificates tar gzip verilator
```

### Windows

For the Linux build workflows, run this command in **Administrator PowerShell** using [Microsoft's WSL installation procedure](https://learn.microsoft.com/en-us/windows/wsl/install):

```powershell
wsl --install -d Ubuntu
```

Restart if requested and finish Ubuntu's account setup. Open Ubuntu from PowerShell:

```powershell
wsl --distribution Ubuntu
```

Run the Ubuntu package and clone commands inside that Linux shell, keeping the checkout in its Linux filesystem. The [Windows setup](docs/README.md#windows-powershell-and-wsl) also provides native PowerShell Git/Python installation and [Python-only checks](docs/README.md#python-only-checks).

### macOS

Install the command-line compiler tools and complete the installer:

```sh
xcode-select --install
```

After installing [Homebrew](https://brew.sh/), run these commands in Terminal for native Python checks and the initial Verilator simulation:

```sh
brew install git python3 make ripgrep verilator
export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"
```

The [macOS setup](docs/README.md#macos-terminal) includes Homebrew installation and version checks. Full FPGA and release workflows that require Linux binaries run on an [Ubuntu x86-64 VM or remote host](docs/README.md#linux-only-toolchains); an ARM Ubuntu guest does not satisfy the pinned x86-64 bundle. Native macOS, WSL and VM runs must establish their own results; retained qualification applies to the recorded Ubuntu tools and inputs.

The [microcontroller test guide](microcontroller/tests/README.md) provides a first simulation check. The [firmware](microcontroller/firmware/README.md), [FPGA synthesis](microcontroller/synth/README.md) and [programming](microcontroller/programming/README.md) guides cover their separate workflows. No complete hardware recording setup has been qualified.

## [Microcontroller](microcontroller/README.md)

The microcontroller combines a custom five-stage RISC-V CPU with local memory, firmware, boot and debug support. An acquisition guard and synthetic workloads exercise timing, ownership and fault handling. The complete ADC receiver, recording DMA, shared-memory system and calibrated signal-analysis chain remain development work. The component guide contains implementation details, architecture diagrams and verification limits.

## [Development and recording requirements](docs/README.md)

The development documentation defines source assumptions, analog and digital budgets, data ownership and acceptance gates. It connects electrical qualification to later recording and analysis work while keeping unresolved source, protocol and biological decisions explicit.

## [Hardware references](datasheets/README.md)

The hardware reference collection contains manufacturer documents for the AD7606C-18 evaluation system, INA819 amplifier and OPA2140 operational amplifier, together with supporting application notes. These documents constrain component selection and interface design; their specifications are not measurements of the assembled project.

The [changelog](CHANGELOG.md) records development milestones and subsequent changes.

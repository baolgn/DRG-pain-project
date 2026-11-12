# Development documentation

This directory describes the requirements and qualification work that connect the implemented digital platform to the intended DRG recording system. The [development workflow](pre-coding-workflow.md) covers source definition, analog feasibility, acquisition timing, memory ownership and staged integration. Cultured extracellular sources remain provisional, and biological protocols, biomarker validation and modulation remain future work.

## Installation

Use Python 3.11 or newer. The acquisition arithmetic, format and lifecycle checks run without third-party Python packages. Simulation additionally needs Verilator, a C++ compiler and Make. The full FPGA, firmware and release workflows have separate toolchain requirements, including Linux x86-64 binaries in several runners.

Run repository commands from the checkout root. Use a checkout and build paths without whitespace for compiled workflows. Code blocks marked `powershell` run in Windows PowerShell; `sh` blocks run in a Linux or macOS shell. The Windows Linux workflow runs `sh` commands inside Ubuntu, not PowerShell.

### Ubuntu and Debian

Install the host utilities and simulator:

```sh
sudo apt update
sudo apt install git python3 python3-venv build-essential ripgrep zlib1g-dev \
  curl ca-certificates tar gzip verilator
```

These packages support the first simulation below. They do not install the pinned FPGA or RISC-V toolchains. Older distribution releases may supply an older Python or simulator; check their versions before running the project.

### Fedora and Arch Linux

On Fedora, install the corresponding packages with DNF. Fedora's [zlib compatibility development package](https://packages.fedoraproject.org/pkgs/zlib-ng/zlib-ng-compat-devel/) supplies the zlib headers:

```sh
sudo dnf install git python3 gcc gcc-c++ make ripgrep zlib-ng-compat-devel \
  curl ca-certificates tar gzip verilator
```

On Arch Linux, update the package database and system together before installing the [build tools](https://archlinux.org/packages/core/any/base-devel/):

```sh
sudo pacman -Syu --needed base-devel git python ripgrep zlib \
  curl ca-certificates tar gzip verilator
```

Use the Linux commands below on either distribution. Their package versions require their own successful checks; the retained Ubuntu results do not qualify these installations.

### Windows PowerShell and WSL

For the existing Linux build workflows, install Ubuntu under WSL 2. In **Administrator PowerShell**, follow [Microsoft's WSL installation instructions](https://learn.microsoft.com/en-us/windows/wsl/install):

```powershell
wsl --install -d Ubuntu
```

Restart if requested and complete Ubuntu's first-launch account setup. In PowerShell, check the distribution version, convert an existing WSL 1 installation if necessary, and enter Ubuntu:

```powershell
wsl --list --verbose
wsl --set-version Ubuntu 2
wsl --distribution Ubuntu
```

Run the Ubuntu package commands above **inside that Ubuntu shell**. Keep the Linux checkout in its Linux filesystem, for example:

```sh
mkdir -p "$HOME/src"
cd "$HOME/src"
git clone https://github.com/baolgn/DRG-pain-project.git
cd DRG-pain-project
uname -m
```

The pinned full-toolchain route requires `x86_64`; an ARM64 WSL installation does not satisfy it. WSL setup does not establish USB programming or the graphical waveform checks. Those require device/display access and separate validation.

For **native PowerShell source access and Python-only checks**, install [Git for Windows](https://git-scm.com/install/windows) and [Python 3.13](https://github.com/microsoft/winget-pkgs/tree/master/manifests/p/Python/Python/3/13) with WinGet:

```powershell
winget install --exact --id Git.Git --source winget
winget install --exact --id Python.Python.3.13 --source winget
```

Open a new PowerShell window after installation, then clone into a directory of your choice:

```powershell
git --version
py -3.13 --version
git clone https://github.com/baolgn/DRG-pain-project.git
Set-Location DRG-pain-project
```

The PowerShell checks below select that Python version explicitly. Git and Python installed on Windows are separate from the packages installed inside WSL.

### macOS Terminal

Install Apple's command-line compiler tools, then finish the installer before continuing:

```sh
xcode-select --install
```

If Homebrew is not installed, use its [official installer](https://brew.sh/) and follow its printed shell setup instructions:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install Git, Python and the native simulation tools. Homebrew's [GNU Make package](https://formulae.brew.sh/formula/make) uses the name `gmake`; adding its `gnubin` directory lets Verilator and child commands find it as `make`:

```sh
brew install git python3 make ripgrep verilator
export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"
python3 --version
make --version
c++ --version
verilator --version
git clone https://github.com/baolgn/DRG-pain-project.git
cd DRG-pain-project
```

Repeat the `export PATH` command in each terminal used for simulation, or add it to the shell configuration. Homebrew package availability depends on the macOS version and architecture; consult its [supported configurations](https://docs.brew.sh/Support-Tiers). These commands provide a native route for the Python checks and the first Verilator simulation. Native macOS results have not been recorded for this project; a run must pass its own checks.

### Linux-only toolchains

Full synthesis, tool qualification, ACT4/Sail campaigns and several higher-level runners select Linux x86-64 executables, the Linux ELF loader, or Linux process/device interfaces. Installing similarly named native tools does not replace those dependencies. On Windows x86-64, use the Ubuntu WSL 2 shell above. On macOS, use an Ubuntu **x86-64** virtual machine or remote host for these workflows. An ARM Ubuntu guest on Apple silicon cannot run the pinned x86-64 tool bundle natively.

With an existing Ubuntu host and SSH access, the following command works from macOS Terminal or Windows PowerShell; replace the example account and hostname with your own:

```sh
ssh developer@ubuntu-host
```

Inside the Ubuntu shell, verify its architecture, install prerequisites, and create a separate checkout there:

```sh
uname -m
python3 --version
sudo apt update
sudo apt install git python3 python3-venv build-essential ripgrep zlib1g-dev \
  curl ca-certificates tar gzip verilator
mkdir -p "$HOME/src"
cd "$HOME/src"
git clone https://github.com/baolgn/DRG-pain-project.git
cd DRG-pain-project
```

Proceed only with `x86_64` and Python 3.11 or newer for the pinned flows. Install the hardware tools outside the checkout using the exact archive and digest in the [tool qualification instructions](../microcontroller/qualification/README.md#ubuntu-reproduction), then configure the compiler and compatibility paths in the [full CPU instructions](../microcontroller/acquisition/qualification.md#reproducing-the-ubuntu-path). Those commands run in Ubuntu, including when it is reached through WSL, a VM or SSH. The existing `/tmp` tool paths refer to that Ubuntu filesystem.

[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) and the [RISC-V GNU toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain) provide upstream tools; reproducing retained results requires the versions and layouts used by the selected runner. The GTKWave qualification needs access to a graphical display. Physical programming needs the board connected and visible to the Linux host; SSH access or a VM by itself does not establish USB access. Neither remote nor virtualized execution has a retained project qualification result.

## Python-only checks

These commands exercise the acquisition timing arithmetic, binary formats and abstract lifecycle models without installing FPGA tools or accessing hardware. Each run uses new destinations: timing writes one JSON file, while formats and lifecycle each create a directory. The `-B` option prevents bytecode files in the checkout; `-O` exercises checks that must remain active with Python assertions disabled.

On Linux, WSL Ubuntu or macOS, run:

```sh
(
  set -e
  drg_output=$(mktemp -d "${TMPDIR:-/tmp}/drg-checks.XXXXXX")
  python3 -B -O microcontroller/acquisition/check_timing.py --output "$drg_output/timing.json"
  python3 -B -O microcontroller/acquisition/check_formats.py --output "$drg_output/formats"
  python3 -B -O microcontroller/acquisition/check_lifecycle.py --output "$drg_output/lifecycle"
  printf 'Results: %s\n' "$drg_output"
)
```

In native Windows PowerShell, run:

```powershell
$drgOutput = Join-Path $env:TEMP ("drg-checks-" + [guid]::NewGuid().ToString("N"))
py -3.13 -B -O microcontroller/acquisition/check_timing.py --output (Join-Path $drgOutput "timing.json")
if ($LASTEXITCODE -ne 0) { throw "Timing checks failed" }
py -3.13 -B -O microcontroller/acquisition/check_formats.py --output (Join-Path $drgOutput "formats")
if ($LASTEXITCODE -ne 0) { throw "Format checks failed" }
py -3.13 -B -O microcontroller/acquisition/check_lifecycle.py --output (Join-Path $drgOutput "lifecycle")
if ($LASTEXITCODE -ne 0) { throw "Lifecycle checks failed" }
Write-Output "Results: $drgOutput"
```

Each command must exit successfully. Read `timing.json`, `formats/summary.json` and `lifecycle/summary.json` in the printed results directory. These checks validate software models and formats, not physical ADC timing or recording.

## First simulation check

After installing the simulator and C++ build tools for the chosen OS, run from the repository root. This shell command works with the Ubuntu/WSL, Fedora, Arch and macOS setup above; on Windows, run it inside Ubuntu:

```sh
python3 --version
make --version
verilator --version
drg_build=$(mktemp -d /tmp/drg-fetch.XXXXXX)
python3 -B microcontroller/tests/run_fetch_buffer.py \
  --verilator "$(command -v verilator)" \
  --build "$drg_build"
```

[run_fetch_buffer.py](../microcontroller/tests/run_fetch_buffer.py) compiles [drg5_fetch_buffer_tb.sv](../microcontroller/tests/drg5_fetch_buffer_tb.sv) with [drg5_fetch_buffer.sv](../microcontroller/rtl/drg5_fetch_buffer.sv), then requires a positive run and a deliberately corrupted observation to fail at the intended comparator. Read `results.json`, `build.log`, `positive.log` and `raw_detector.log` in the build directory. A different simulator release may expose warnings or incompatibilities; those must be resolved before counting the run as passed.

The existing Makefile entry is equivalent, using a new destination on each run:

```sh
drg_build=$(mktemp -d /tmp/drg-fetch-make.XXXXXX)
make -C microcontroller/tests fetch-buffer \
  VERILATOR="$(command -v verilator)" BUILD_ROOT="$drg_build"
```

The Makefile writes the same result files under `$drg_build/fetch-buffer`; the direct Python command writes them directly under `$drg_build`.

This check exercises one digital component without accessing hardware. The [test guide](../microcontroller/tests/README.md) explains the other directed checks, and the [verification guide](../microcontroller/verification/README.md) distinguishes them from formal properties, reference comparisons and archive-dependent campaigns. The component guides identify the Linux-only flows and their pinned tool paths.

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

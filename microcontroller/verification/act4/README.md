# ACT4 architectural-test integration

## Purpose

This adapter coordinates ACT4 test generation, Sail reference signatures and execution on the DRG5 RTL platform. Its target enables C, M, interrupts, Zifencei and writable instruction RAM while disabling debug. It does not certify the final debug system or extend a test result to another configuration. The complete earlier campaign is not distributed with this publication, and architectural qualification remains open.

## Instructions

The runner requires an externally prepared Linux x86-64 tool directory with the exact archives, extracted binaries and Python/Ruby environments it verifies. [run_campaign.py](run_campaign.py) checks archive hashes and compares selected upstream source files and compiler/reference executables against their archives. Installing arbitrary recent versions is insufficient.

| Input | Source-defined pin or configuration |
| --- | --- |
| ACT4 | Commit `e7fe80bfcea852562e6561e14fca2e4010cfb5ad`, framework 0.3.0 and test generator 0.5.0. |
| Sail | Release 0.16, Linux x86-64. |
| Compiler | xPack RISC-V GCC 15.2.0-1; GCC 15.2.0 and binutils 2.45. |
| Python packages | [python-requirements.txt](python-requirements.txt), plus framework/generator packages from the verified ACT4 archive. |
| Ruby packages | The pinned ACT4 source's checksum-bearing `Gemfile.lock`; isolated interpreter, Bundler and gems must satisfy that environment. |

The source archives originate from [ACT4](https://github.com/riscv/riscv-arch-test/tree/e7fe80bfcea852562e6561e14fca2e4010cfb5ad), [Sail 0.16](https://github.com/riscv/sail-riscv/releases/tag/0.16) and [xPack 15.2.0-1](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/tag/v15.2.0-1). The [release bootstrap](../../release/README.md) additionally requires a dependency manifest that is not distributed here; the publication therefore does not provide a complete one-command tool installation.

After constructing and validating the required layout, run from the repository root with new work, build and evidence directories:

```sh
python3 microcontroller/verification/act4/run_campaign.py \
  --tools /tmp/drg5-arch-tools \
  --work /tmp/drg5-act4-work-new \
  --build /tmp/drg5-act4-build-new \
  --evidence /tmp/drg5-act4-evidence-new \
  --seeds 1 24301
```

The work directory must be empty, and seeds must be distinct. The coordinator validates both Sail configurations, generates bounded test files, runs the ACT4 build/reference process, inventories candidates and executes the available DUT ELFs with independent request/response delays. Review `manifest.json`, `campaign.json`, `inventory.json`, tool identities and all phase logs. Capacity omissions, failed signatures, missing schedules and comparison failures keep the result at `qualification_open` and produce a nonzero final exit.

The supplied tooling targets the Ubuntu/Linux environment. Windows, WSL and macOS campaigns are unverified. A new campaign must establish its own result; counts from an omitted earlier campaign cannot establish the published source's conformance.

## Implementation

| Source | Responsibility |
| --- | --- |
| [run_campaign.py](run_campaign.py) | Verifies inputs, orchestrates phases and derives the final campaign status. |
| [drg5.yaml](drg5.yaml) and [test_config.yaml](test_config.yaml) | Declare the CPU architectural profile and ACT4 test environment. |
| [drg5-act4-gcc](drg5-act4-gcc) | Preserves each test's required ISA subset while enforcing `ilp32`, strict alignment, no relaxation and privilege-version checks. |
| [generate_tests.py](generate_tests.py) | Applies bounded file/trap-buffer sizing and explicit generator adaptations without enlarging DUT memory. |
| [rvmodel_macros.h](rvmodel_macros.h) and [link.ld](link.ld) | Define DUT test services, interrupt operations and capacity-enforced placement. |
| [sail.json](sail.json) and [sail-retirement.json](sail-retirement.json) | Define the reference profile with ACT4 devices and the separate retirement-comparison environment. |
| [run_batch.py](run_batch.py), [inventory.py](inventory.py) and [publish.py](publish.py) | Execute available ELFs, account for every candidate and retain the actual verdicts. |
| [check_evidence.py](check_evidence.py) | Calibrates evidence rejection using a complete supplied record and deliberately damaged copies. |

The profile specifies one RV32 machine-only hart with I 2.1, M 2.0, C 2.0, Zicsr 2.0, Zifencei 2.0 and Sm 1.13.0. Machine counters do not advertise Zicntr; U/S/H modes, translation and PMP are absent. The target uses direct-only `mtvec`, natural-alignment traps and the declared CSR WARL/WLRL policies. Read the configuration itself when judging individual tests.

Test text starts at `0x00010000` and has 56 KiB available. The final 8 KiB of instruction memory holds model-specific code, and data, signatures and stack must fit 32 KiB at `0x20000000`. Oversized tests remain explicit omissions. Executed ROM instructions initialize registers for the test environment; this is not a hardware register-reset guarantee.

Sail and the DUT have different platform timer/interrupt device addresses. Sail also differs in reset `mcountinhibit` and some unsupported-value CSR policies. The integration retains known `mcause` WLRL-policy and `timeh` applicability/address-comparison concerns as open comparisons; it does not enable absent CSRs or relabel failures to force a pass. Reference WFI timing is not an oracle for CPU cycle latency. Architectural signatures, bus ownership checks, directed exceptions, formal properties and hardware observations remain separate obligations.

# Bounded controller and fetch formal checks

## Purpose

These runners check production controller and fetch RTL under explicit harness assumptions. They retain positive properties, reachability witnesses and deliberately failing controls. The checks do not establish unbounded whole-core correctness, complete ISA conformance or unrestricted pipeline liveness.

## Instructions

Use an Ubuntu/Linux OSS CAD Suite installation containing Yosys with the slang plugin, SymbiYosys (`sby`) and `yices-smt2`. The controller runners explicitly load slang; a Yosys build without that plugin is insufficient. The fetch runner also uses the selected suite. Native Windows, WSL and macOS execution has not been validated.

Run from the repository root and provide a build directory that does not exist:

```sh
python3 microcontroller/verification/formal/run_formal.py \
  --tools /tmp/drg5-control-tools-20260301/oss-cad-suite \
  --build /tmp/drg5-formal-new
```

The separate admission check requires its own fresh directory:

```sh
python3 microcontroller/verification/formal/run_admission_formal.py \
  --tools /tmp/drg5-control-tools-20260301/oss-cad-suite \
  --build /tmp/drg5-admission-new
```

Inspect `summary.json`, solver logs, the generated job configurations, source snapshots and counterexample/witness files. A timeout, missing native status, unreachable required cover or failed positive property is a failure. Negative controls must produce the intended assertion failure rather than an infrastructure error. The combined wrapper checks both families and their source identities; a successful child does not conceal a failed sibling.

## Implementation

| Source | Responsibility |
| --- | --- |
| [run_formal.py](run_formal.py) | Combines controller and fetch runner results and checks shared source identities. |
| [run_pipeline_formal.py](run_pipeline_formal.py) | Snapshots the production controller and dependencies, constructs bounded safety/progress jobs and runs RTL mutations. |
| [drg5_pipeline_formal.sv](drg5_pipeline_formal.sv) | Implements the independent controller scoreboard and environmental assumptions. |
| [run_admission_formal.py](run_admission_formal.py) | Runs the separate early-admission harness and its negative control. |
| [drg5_progress_admission_formal.sv](drg5_progress_admission_formal.sv) | Adds explicit early packet admission and excludes post-startup external flush. |
| [run_fetch_formal.py](../../tests/run_fetch_formal.py) and [drg5_fetch_formal.sv](../../tests/drg5_fetch_formal.sv) | Check fetch ownership, generation revocation and stale-response handling. |

The controller harness instantiates the overlapping production controller with forwarding enabled and diagnostic mode disabled. C, M, interrupt and debug features remain disabled in this scoped configuration, and the data deadline is 32 clocks. Trusted packets represent result, load, store, redirect, fault and fence operations; they bypass raw instruction decoding. Only x1 is writable, accesses use an aligned word address, and returned load data is fixed. Symbolic operands, holds and response choices still exercise the declared control subset.

| Check | Bound and meaning |
| --- | --- |
| Overlapping controller safety | 16 modeled edges, including the initial two-edge reset; independent UID tracking checks conservation, terminal ordering, disposition and selected architectural state. |
| Overlap witness | A separate bounded cover requires overlap, stalls, memory launch, retirement and discard. |
| Isolated progress | A 40-edge check gives one accepted packet a 32-clock disposition deadline, with the registered observation accounted for. It does not bound arbitrary overlapping traffic. |
| Early-admission progress | Admission by reset-relative edge four places the complete deadline inside the finite proof window; external flush is excluded after startup. |
| Fetch safety | 20 modeled edges for C-disabled and C-enabled cases, with deliberately small generation/tag fields and a wrap/revocation witness. |

Safety does not assume that memory eventually responds. Progress does assume bounded stage holds, target acceptance and response service, and it models only initial reset with ordinary or guaranteed no-effect responses. Those assumptions are part of the result, not properties proved about an external bus. The admission harness closes the finite-window admission gap of the original isolated-progress check without claiming admission under arbitrary flush.

The frontend adapter removes exactly one unsupported concurrent assertion from the proof copy of the controller and records the removed text. An equivalent harness assertion checks that contract; immediate production assertions remain active. Production RTL is not rewritten. Mutation jobs corrupt such obligations as terminal UID, retained request data, killed-instruction state or terminal progress and must be rejected by the checker. Held-packet checks distinguish fields that must remain stable from memory-completion fields that may legitimately advance.

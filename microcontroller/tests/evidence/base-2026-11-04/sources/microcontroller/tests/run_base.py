#!/usr/bin/env python3
"""compare identical raw RV32I programs across diagnostic and overlapping pipeline modes."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


# retain exact commands and complete diagnostics for each build or execution.
def execute(command, log, root):
    # a closed log is inspected only after its process has terminated.
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=300, check=False)
    return result.returncode, log.read_text()


# bind every result to the actual source bytes used by all three elaborations.
def hashes(root, names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# remove only completed compiler caches while retaining binaries and generated sources.
def discard_caches(directory):
    # linked models no longer need their large precompiled headers or object files.
    for path in directory.iterdir():
        # this directory belongs exclusively to the current runner.
        if path.is_file() and path.suffix in {".gch", ".o", ".a"}:
            path.unlink()


# exact architectural streams and physical effects must agree across timing configurations.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    sources = [
        "microcontroller/rtl/drg5_control_pkg.sv",
        "microcontroller/rtl/drg5_decoder.sv",
        "microcontroller/rtl/drg5_immediate.sv",
        "microcontroller/rtl/drg5_shifter.sv",
        "microcontroller/rtl/drg5_alu.sv",
        "microcontroller/rtl/drg5_branch.sv",
        "microcontroller/rtl/drg5_lsu.sv",
        "microcontroller/rtl/drg5_forward.sv",
        "microcontroller/rtl/drg5_control.sv",
        "microcontroller/tests/drg5_base_tb.sv",
    ]
    names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh",
                       "microcontroller/tests/run_base.py", "microcontroller/tests/Makefile"]
    before = hashes(root, names)
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    records, baselines, cycle_counts = [], {}, {}
    acceptance_bins, response_bins = set(), set()
    configurations = [("diagnostic", 1, 0), ("conservative", 0, 0), ("forwarded", 0, 1)]
    # all configurations consume the same instruction images and seed-derived semantic schedules.
    for name, diagnostic, forwarding in configurations:
        directory = build / name
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall", "-j", "2",
                   "-CFLAGS", "-O0", "-Imicrocontroller/rtl", "--top-module", "drg5_base_tb",
                   "--Mdir", str(directory), f"-GDIAGNOSTIC={diagnostic}",
                   f"-GFORWARDING={forwarding}", *sources]
        code, text = execute(command, directory / "build.log", root)
        # no HDL warning is waived or accepted as a passing build.
        if code or "%Warning" in text:
            raise RuntimeError(f"{name} build failed: {directory / 'build.log'}")
        discard_caches(directory)
        # zero is an ordinary LCG seed; Verilator initialization uses its separately fixed seed.
        for seed in [0, 1, 305419896]:
            run = [str(directory / "Vdrg5_base_tb"), "+verilator+seed+1", f"+seed={seed}"]
            log = directory / f"seed-{seed}.log"
            code, text = execute(run, log, root)
            prefix = f"PASS base diagnostic={diagnostic} forwarding={forwarding} seed={seed} "
            # successful termination alone cannot substitute for required coverage checks.
            if code or prefix not in text:
                raise RuntimeError(f"{name} seed {seed} failed: {log}")
            lines = text.splitlines()
            result = next(line for line in lines if line.startswith(prefix))
            canonical = [line for line in lines if line.startswith(("ARCH ", "EFFECT ", "FINAL ", "SCHEDULE "))]
            architectural = [line for line in canonical if not line.startswith("SCHEDULE ")]
            schedules = [line for line in lines if line.startswith(("SCHEDULE ", "SERVICE "))]
            (directory / f"seed-{seed}-canonical.log").write_text("\n".join(canonical) + "\n")
            (directory / f"seed-{seed}-schedule.log").write_text("\n".join(schedules) + "\n")
            # compare each event domain separately because legitimate pipeline timing can interleave them differently.
            domains = {prefix: [line for line in canonical if line.startswith(prefix)]
                       for prefix in ["ARCH ", "EFFECT ", "FINAL ", "SCHEDULE "]}
            # diagnostic execution establishes an independently checked, identically planned comparison baseline.
            if seed not in baselines:
                baselines[seed] = domains
            # no speculative UID, kill count or cycle number enters the architectural comparison.
            elif domains != baselines[seed]:
                raise RuntimeError(f"architectural/effect/schedule differential mismatch: {name} seed {seed}")
            fields = dict(item.split("=", 1) for item in result.split()[2:])
            cycle_counts[name, seed] = int(fields["cycles"])
            # selected delay bins are distinct from actual edge intervals under any directed holds.
            for line in domains["SCHEDULE "]:
                values = dict(item.split("=", 1) for item in line.split()[1:])
                acceptance_bins.add(int(values["accept_extra"]))
                response_bins.add(int(values["response_edges"]))
            records.append({"configuration": name, "seed": seed, "build_command": command,
                            "run_command": run, "exit_code": code, "result": result,
                            "domain_sha256": {key.strip(): hashlib.sha256("\n".join(value).encode()).hexdigest()
                                              for key, value in domains.items()},
                            "architectural_and_effect_rows": len(architectural),
                            "coverage": {key: int(value) for key, value in fields.items()},
                            "required_encoding_rows": 40,
                            "required_branch_outcomes": "taken and untaken for each of BEQ/BNE/BLT/BGE/BLTU/BGEU"})
            print(result, flush=True)
    # these finite workloads must demonstrate a measured benefit, without claiming general CPU performance.
    for seed in [0, 1, 305419896]:
        # diagnostic, conservative overlap and forwarding have strictly decreasing aggregate test cycles.
        if not cycle_counts["forwarded", seed] < cycle_counts["conservative", seed] < cycle_counts["diagnostic", seed]:
            raise RuntimeError(f"expected workload cycle ordering was not observed for seed {seed}")
    # all advertised selected latency values must actually appear in the retained schedules.
    if acceptance_bins != set(range(4)) or response_bins != set(range(1, 6)):
        raise RuntimeError("selected schedule latency coverage incomplete")
    negatives = [("mutate_result", "architectural disposition mismatch"),
                 ("mutate_operand", "independent operand capture mismatch"),
                 ("mutate_effect", "physical device effect mismatch"),
                 ("mutate_kill", "unauthorized kill detector"),
                 ("mutate_nop", "terminal eligibility mismatch")]
    # each observation corruption must fail through its intended existing comparator.
    for mutation, detector in negatives:
        run = [str(build / "forwarded" / "Vdrg5_base_tb"), "+verilator+seed+1", "+seed=1", f"+{mutation}"]
        log = build / f"{mutation}.log"
        code, text = execute(run, log, root)
        # an unrelated abort or missing activation does not qualify a detector.
        if code == 0 or detector not in text or "PASS base " in text:
            raise RuntimeError(f"negative control missed its intended comparator: {log}")
        records.append({"negative_control": mutation, "detector": detector, "run_command": run,
                        "exit_code": code, "first_error": next(line for line in text.splitlines() if "%Fatal" in line)})
    after = hashes(root, names)
    # any concurrent source edit invalidates the combined attribution and requires a new run.
    if before != after:
        raise RuntimeError("base qualification source bytes changed during execution")
    summary = {
        "status": "passed", "scope": "encoded RV32I packet-prototype execution and forwarding differential qualification",
        "verilator": version, "source_sha256": after, "positive_runs": 9,
        "negative_control_runs": len(negatives),
        "coverage_requirements": {"all_base_encoding_rows": 40,
                                  "branch_predicates_with_both_outcomes": 6,
                                  "forwarded_overlap": ["X and M capture", "registered completed-load capture",
                                                        "both sources captured from held W", "ALU/branch/address/store-data nearest-unready masking at exact consumer PC"],
                                  "all_modes": ["real NOP retirement", "one prior barrier preparation edge",
                                                "load-to-x0 device effects", "precise base traps and unsupported-encoding responses"]}, "same_program_differential": "ARCH/EFFECT/FINAL/SCHEDULE domains exactly equal for each seed across all three modes",
        "selected_accept_extra_bins": sorted(acceptance_bins), "selected_response_edge_bins": sorted(response_bins),
        "schedule": {"seed": "LCG32, state initially seed XOR case*0x9e3779b9; all u32 seeds including zero are valid",
                     "generator": "state=(1664525*state+1013904223) modulo 2^32; choose from higher bits",
                     "acceptance": "registered offer L; acceptance at L+accept_extra+1",
                     "response": "actual registered read captured at A; response at A+response_edges (1..5)"},
        "limits": ["testbench instruction adapter supplies immutable raw packets and fetch faults; no production CPU fetch/decode top is claimed",
                   "no Sail/ACT4 execution or ISA conformance milestone is claimed",
                   "cycle comparisons apply only to these finite workloads and scripted unit-fixture stalls",
                   "hostile protocol, reset and timeout cross-products remain separately qualified by the memory fixture",
                   "negative controls corrupt observations or target state; production RTL is not mutated"],
        "results": records,
    }
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS base qualification: {build / 'summary.json'}", flush=True)


# importing this module never starts a simulator or changes evidence.
if __name__ == "__main__":
    main()

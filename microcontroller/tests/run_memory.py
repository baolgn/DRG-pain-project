#!/usr/bin/env python3
"""qualify decoded memory effects, replayable target schedules and finite ownership."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


# retain complete commands and diagnostics without relying on a successful exit alone.
def execute(command, log, root):
    # each log is closed before status and pass markers are inspected.
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=300, check=False)
    return result.returncode, log.read_text()


# bind qualification to all actual source bytes rather than an assumed repository state.
def source_hashes(root, names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# discard only completed compiler caches generated inside this runner's model directory.
def discard_caches(directory):
    # binaries, generated source and logs remain available for execution and investigation.
    for path in directory.iterdir():
        # precompiled headers dominate disk use and are unnecessary after linking.
        if path.is_file() and path.suffix in {".gch", ".o", ".a"}:
            path.unlink()


# use separate elaborations for guard flags, minimum deadline and default diagnostic occupancy.
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
        "microcontroller/rtl/drg5_decompress.sv",
        "microcontroller/rtl/drg5_immediate.sv",
        "microcontroller/rtl/drg5_branch.sv",
        "microcontroller/rtl/drg5_lsu.sv",
        "microcontroller/rtl/drg5_shifter.sv",
        "microcontroller/rtl/drg5_alu.sv",
        "microcontroller/rtl/drg5_forward.sv",
        "microcontroller/rtl/drg5_csr.sv",
        "microcontroller/rtl/drg5_control.sv",
        "microcontroller/tests/drg5_memory_tb.sv",
    ]
    names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh",
                       "microcontroller/tests/run_memory.py", "microcontroller/tests/Makefile"]
    before = source_hashes(root, names)
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    configurations = [
        ("minimum", 0, 1, 1, [1]),
        ("base", 0, 128, 0, [0, 1, 305419896]),
        ("enabled", 1, 128, 0, [0, 1, 305419896]),
        ("diagnostic-default", 0, 128, 2, [1]),
    ]
    records = []
    acceptance_bins = set()
    response_bins = set()
    # positive runs require their exact configuration and declared coverage assertions to pass.
    for name, profile, deadline, scenario, seeds in configurations:
        directory = build / name
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall",
                   "-j", "2", "-CFLAGS", "-O0", "-Imicrocontroller/rtl",
                   "--top-module", "drg5_memory_tb", "--Mdir", str(directory),
                   f"-GPROFILE={profile}", f"-GMAX_WAIT={deadline}",
                   f"-GSCENARIO={scenario}", *sources]
        code, text = execute(command, directory / "build.log", root)
        # HDL warnings remain fatal; generated-code optimization does not disable any checker.
        if code != 0 or "%Warning" in text:
            raise RuntimeError(f"{name} build failed: {directory / 'build.log'}")
        discard_caches(directory)
        # zero is a valid LCG schedule seed, distinct from Verilator's fixed initialization seed.
        for seed in seeds:
            command_run = [str(directory / "Vdrg5_memory_tb"), "+verilator+seed+1", f"+seed={seed}"]
            log = directory / f"seed-{seed}.log"
            code, text = execute(command_run, log, root)
            prefix = f"PASS memory profile={profile} scenario={scenario} deadline={deadline} seed={seed} "
            # a missing positive record cannot be replaced by a normal process exit.
            if code != 0 or prefix not in text:
                raise RuntimeError(f"{name} seed {seed} regression failed: {log}")
            result = next(line for line in text.splitlines() if line.startswith(prefix))
            schedule = [line for line in text.splitlines()
                        if line.startswith(("SCHEDULE ", "ACCEPT ", "RESPONSE "))]
            # emit exact selected schedules and actual bus edges as a separate replay artifact.
            (directory / f"seed-{seed}-schedule.log").write_text("\n".join(schedule) + "\n")
            # aggregate the actual selected delay bins across both main profiles and all seeds.
            for line in schedule:
                # manual minimum-deadline overrides do not qualify ordinary schedule coverage.
                if scenario == 0 and line.startswith("SCHEDULE "):
                    fields = dict(item.split("=", 1) for item in line.split()[1:])
                    acceptance_bins.add(int(fields["accept_extra"]))
                    response_bins.add(int(fields["response_edges"]))
            records.append({"configuration": name, "seed": seed,
                            "build_command": command, "run_command": command_run,
                            "exit_code": code, "result": result,
                            "schedule_rows": len(schedule)})
            print(result, flush=True)
    # declaring a delay range requires observing each selected value in the replay logs.
    if acceptance_bins != set(range(4)) or response_bins != set(range(1, 6)):
        raise RuntimeError(f"schedule bins incomplete: {acceptance_bins}, {response_bins}")
    negative_controls = [
        ("mutate_orphan", "physical request owner disappeared or appeared without permission"),
        ("mutate_lane", "owned request descriptor changed"),
        ("mutate_effect", "physical device effect differs from independent intent"),
        ("mutate_load", "unexpected architectural GPR effect"),
        ("mutate_deadline", "fatal exposure snapshot mismatch"),
    ]
    # each intentional corruption must reach its own detector under both guard profiles.
    for name in ["base", "enabled"]:
        # observation corruption never supplies the expected architectural or effect value.
        for mutation, detector in negative_controls:
            command = [str(build / name / "Vdrg5_memory_tb"), "+verilator+seed+1", "+seed=1", f"+{mutation}"]
            log = build / f"{name}-{mutation}.log"
            code, text = execute(command, log, root)
            # unrelated crashes, timeouts or successful runs do not qualify a comparator.
            if code == 0 or detector not in text or "PASS memory" in text:
                raise RuntimeError(f"negative control did not reach {detector}: {log}")
            records.append({"configuration": name, "negative_control": mutation,
                            "command": command, "exit_code": code, "detector": detector,
                            "first_error": next(line for line in text.splitlines() if "%Fatal" in line)})
    after = source_hashes(root, names)
    # concurrent edits invalidate attribution of a completed result to the current sources.
    if before != after:
        raise RuntimeError("memory qualification sources changed during execution")
    summary = {
        "scope": "decoded memory integration and target-effect qualification of the packet prototype; not full CPU conformance",
        "verilator": version,
        "source_sha256": after,
        "status": "passed",
        "positive_runs": sum(len(item[4]) for item in configurations),
        "negative_control_types": len(negative_controls),
        "negative_control_runs_passed": 2 * len(negative_controls),
        "accept_extra_bins": sorted(acceptance_bins),
        "response_edge_bins": sorted(response_bins),
        "schedule": {
            "generator": "LCG32: state=(1664525*state+1013904223) modulo 2^32; every u32 seed including zero is valid",
            "seed_argument": "+seed; independent from +verilator+seed+1",
            "ordinary_acceptance": "offer registered at L; absent directed holds, acceptance at L+accept_extra+1",
            "ordinary_response": "registered target capture at acceptance A; reply at A+response_edges, with response_edges in 1..5",
            "overrides": "directed hold/reset/error scripts can delay or inject events; actual ACCEPT/RESPONSE rows are retained",
            "minimum_deadline": "separate N=1 compatibility fixture tests same-edge acceptance/response and first-edge timeouts",
        },
        "limits": ["non-memory/control operations remain explicitly synthetic packets",
                   "enabled timer aperture is a plain register target used to qualify guard forwarding, not a timer/IRQ implementation",
                   "main profiles enable test error windows; diagnostic-default uses all default control parameters",
                   "tag/UID exhaustion remains separately source-reviewed; this finite integration run does not exhaust 32/64-bit identities",
                   "negative controls corrupt observations or a target counter; they do not mutate production RTL"],
        "results": records,
    }
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS memory qualification: {build / 'summary.json'}", flush=True)


# keep importable helpers separate from explicit command-line execution.
if __name__ == "__main__":
    main()

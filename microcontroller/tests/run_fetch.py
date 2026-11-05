#!/usr/bin/env python3
"""run independently checked fetch configurations and named negative controls."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


# hash the exact implementation, fixture and runner used by this qualification.
def source_hashes(root):
    names = [
        "microcontroller/rtl/drg5_fetch_guard.sv",
        "microcontroller/rtl/drg5_fetch_buffer.sv",
        "microcontroller/rtl/drg5_fetch.sv",
        "microcontroller/tests/drg5_fetch_tb.sv",
        "microcontroller/tests/run_fetch.py",
        "microcontroller/tests/Makefile",
    ]
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# preserve commands and complete output for every build, run and expected failure.
def execute(command, log, root):
    # close each complete log before inspecting its exit status and diagnostics.
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=240, check=False)
    return result.returncode, log.read_text()


# each configuration changes one advertised interface boundary explicitly.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    before = source_hashes(root)
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    sources = ["microcontroller/rtl/drg5_fetch_guard.sv",
               "microcontroller/rtl/drg5_fetch_buffer.sv",
               "microcontroller/rtl/drg5_fetch.sv",
               "microcontroller/tests/drg5_fetch_tb.sv"]
    configurations = [
        ("c0", 0, 64, 32, 0),
        ("c1", 1, 64, 32, 0),
        ("deadline", 1, 4, 32, 1),
        ("tags", 0, 64, 3, 2),
    ]
    records = []
    # normal runs must complete with their declared configuration's pass record.
    for name, compressed, deadline, tag_bits, scenario in configurations:
        directory = build / name
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall",
                   "-j", "2", "-CFLAGS", "-O0", "--top-module", "drg5_fetch_tb",
                   "--Mdir", str(directory), f"-GC_FETCH={compressed}",
                   f"-GMAX_WAIT_CYCLES={deadline}", f"-GTAG_BITS={tag_bits}",
                   f"-GSCENARIO={scenario}", *sources]
        code, text = execute(command, directory / "build.log", root)
        # warnings remain fatal; no disabled checker is accepted as a clean build.
        if code != 0 or "%Warning" in text:
            raise RuntimeError(f"{name} build failed: {directory / 'build.log'}")
        run = [str(directory / "Vdrg5_fetch_tb"), "+verilator+seed+1"]
        code, text = execute(run, directory / "run.log", root)
        expected = f"PASS fetch C={compressed} scenario={scenario} "
        # an exit code alone cannot establish that the bounded test completed.
        if code != 0 or expected not in text:
            raise RuntimeError(f"{name} regression failed: {directory / 'run.log'}")
        result = next(line for line in text.splitlines() if line.startswith(expected))
        records.append({"configuration": name, "build_command": command,
                        "run_command": run, "exit_code": code, "result": result})
        print(result, flush=True)
    negative_controls = [
        ("mutate_pc", "instruction reference mismatch"),
        ("mutate_raw", "instruction reference mismatch"),
        ("mutate_forbidden_offer", "forbidden instruction bus offer"),
        ("mutate_drop", "missing or spurious stale-response discard"),
    ]
    # intentionally corrupted observations must fail at their own named detector.
    for mutation, detector in negative_controls:
        command = [str(build / "c0" / "Vdrg5_fetch_tb"), "+verilator+seed+1", f"+{mutation}"]
        log = build / f"{mutation}.log"
        code, text = execute(command, log, root)
        # an unrelated crash, timeout or successful run does not qualify a detector.
        if code == 0 or detector not in text or "PASS fetch" in text:
            raise RuntimeError(f"negative control did not reach {detector}: {log}")
        records.append({"negative_control": mutation, "command": command,
                        "exit_code": code, "detector": detector,
                        "first_error": next(line for line in text.splitlines() if "%Fatal" in line)})
    after = source_hashes(root)
    # changing a source during execution invalidates attribution of the evidence.
    if before != after:
        raise RuntimeError("fetch sources changed during qualification")
    summary = {"scope": "fetch framing and transaction ownership unit; not complete CPU conformance",
               "verilator": version, "source_sha256": after, "results": records,
               "status": "passed", "negative_controls_passed": len(negative_controls)}
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS fetch qualification: {build / 'summary.json'}", flush=True)


# preserve importability while keeping the command-line entrypoint explicit.
if __name__ == "__main__":
    main()

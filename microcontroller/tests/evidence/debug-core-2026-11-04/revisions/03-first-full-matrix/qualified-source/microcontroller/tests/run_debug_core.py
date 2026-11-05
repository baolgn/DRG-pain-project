#!/usr/bin/env python3
"""qualify CPU debug boundaries independently from the Debug Module and transport."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


# retain exact commands and complete output for success and expected failures.
def execute(command, log, root):
    """run one bounded qualification command."""
    with log.open("w") as stream:
        stream.write("$ " + " ".join(command) + "\n")
        stream.flush()
        result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT,
                                timeout=600, check=False)
    return result.returncode, log.read_text()


# source bytes are attributed independently of generated simulator objects.
def digests(root, names):
    """hash every input used by this qualification."""
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# four CPU configurations share the same directed cases and reproducible timing seeds.
def main():
    """build, run, calibrate and retain the complete CPU-side qualification."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    evidence = args.evidence_dir.resolve() if args.evidence_dir else root / "microcontroller/tests/evidence/debug-core-2026-11-04"
    evidence.mkdir(parents=True, exist_ok=True)
    sources = ["microcontroller/rtl/" + name + ".sv" for name in [
        "drg5_control_pkg", "drg5_decoder", "drg5_decompress", "drg5_immediate", "drg5_branch",
        "drg5_lsu", "drg5_shifter", "drg5_alu", "drg5_forward", "drg5_csr", "drg5_muldiv", "drg5_control"]]
    sources.append("microcontroller/tests/drg5_debug_core_tb.sv")
    names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh", "microcontroller/tests/run_debug_core.py"]
    before = digests(root, names)
    records = []
    logs = []
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    mutations = {"mutate_dpc": "step continuation mismatch",
                 "mutate_counter": "independent debug counter mismatch",
                 "mutate_duplicate": "MMIO effect missing or duplicated"}
    # serial elaborations bound temporary compiler storage and preserve strict warning handling.
    for compressed, diagnostic in [(0, 0), (1, 0), (0, 1), (1, 1)]:
        profile = f"c{compressed}-d{diagnostic}"
        directory = build / profile
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall", "-j", "2", "-CFLAGS", "-O0",
                   "-Imicrocontroller/rtl", "--top-module", "drg5_debug_core_tb", "--Mdir", str(directory),
                   f"-GC_ENABLED={compressed}", f"-GDIAGNOSTIC={diagnostic}", *sources]
        log = directory / "build.log"
        code, output = execute(command, log, root)
        logs.append(log)
        # warnings invalidate structural qualification even when compilation returns success.
        if code != 0 or "%Warning" in output:
            raise RuntimeError(f"debug core build failed: {log}")
        # independent acceptance and response delays vary across all seeded cases.
        for seed in [0, 1, 305419896]:
            run = [str(directory / "Vdrg5_debug_core_tb"), "+verilator+seed+1", f"+seed={seed}"]
            log = directory / f"seed-{seed}.log"
            code, output = execute(run, log, root)
            logs.append(log)
            prefix = f"PASS debug-core C={compressed} diagnostic={diagnostic} seed={seed} "
            # a complete final marker is required in addition to a successful exit.
            if code != 0 or prefix not in output:
                raise RuntimeError(f"debug core scenario failed: {log}")
            result = next(line for line in output.splitlines() if line.startswith(prefix))
            records.append({"profile": profile, "seed": seed, "build_command": command,
                            "run_command": run, "exit_code": code, "result": result})
            print(result, flush=True)
        # each observer corruption must reach its intended ordinary detector.
        for mutation, detector in mutations.items():
            run = [str(directory / "Vdrg5_debug_core_tb"), "+verilator+seed+1", "+seed=1", f"+{mutation}"]
            log = directory / f"{mutation}.log"
            code, output = execute(run, log, root)
            logs.append(log)
            # unrelated crashes and a surviving PASS are never accepted as calibration.
            if code == 0 or detector not in output or "PASS debug-core" in output:
                raise RuntimeError(f"debug core detector failed: {log}")
            records.append({"profile": profile, "mutation": mutation, "detector": detector,
                            "command": run, "exit_code": code})
        # discard only completed compiler intermediates after preserving the executable and logs.
        for generated in directory.iterdir():
            # sources and evidence are outside this generated build directory.
            if generated.suffix in {".cpp", ".h", ".o", ".a", ".d", ".gch"}:
                generated.unlink()
    after = digests(root, names)
    # concurrent source changes require rerunning the matrix against a stable final revision.
    if before != after:
        raise RuntimeError("debug core sources changed during qualification")
    summary = {"status": "passed", "source_sha256": after, "verilator": version,
               "scope": "CPU Debug 1.0 boundary semantics and abstract register port; external DM/DTM tested separately",
               "seeds": [0, 1, 305419896], "profiles": 4, "positive_runs": 12, "negative_runs": 12,
               "results": records, "limits": [
                   "raw instruction packets isolate CPU behavior; production frontend and JTAG require separate integration",
                   "physical fetch delay is a supplied busy level, not an instruction-bus responder",
                   "counter ledger and explicit scenario totals are independent of writable counter storage",
                   "three corruption controls alter observations or modeled effects, not production RTL",
                   "no full formal, ACT4, routed clock or physical debugger qualification is claimed"]}
    (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    # final evidence retains commands, failures and exact source snapshots.
    for log in logs:
        destination = evidence / "logs" / log.relative_to(build)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(log, destination)
    # preserving qualified bytes prevents later implementation edits from changing historical claims.
    for name in names:
        destination = evidence / "qualified-source" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, destination)
    print(f"PASS debug core qualification: {evidence / 'summary.json'}", flush=True)


# importing the runner exposes helpers without starting a build.
if __name__ == "__main__":
    main()

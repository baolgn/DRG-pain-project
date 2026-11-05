#!/usr/bin/env python3
"""qualify control-flow flush/reset races and configuration-dependent return state."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


# preserve each command's complete diagnostics and independently checked exit status.
def execute(command, log, root):
    # keep generated compiler output out of the concise qualification summary.
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=240, check=False)
    return result.returncode, log.read_text()


# hash all sources before and after the declared configurations and detector controls.
def digest_sources(root, names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# C0 and C1 execute the same event categories with independently specified expectations.
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
        "microcontroller/tests/drg5_control_events_tb.sv",
    ]
    hash_names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh",
                            "microcontroller/tests/run_control_events.py",
                            "microcontroller/tests/Makefile"]
    before = digest_sources(root, hash_names)
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    records = []
    # separate elaborations ensure the IALIGN-dependent CSR and branch paths both execute.
    for compressed in [0, 1]:
        directory = build / f"c{compressed}"
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall",
                   "-j", "2", "-CFLAGS", "-O0", "-Imicrocontroller/rtl",
                   "--top-module", "drg5_control_events_tb", "--Mdir", str(directory),
                   f"-GC_ENABLED={compressed}", *sources]
        code, text = execute(command, directory / "build.log", root)
        # every lint warning remains fatal and no warning waiver is passed to the compiler.
        if code != 0 or "%Warning" in text:
            raise RuntimeError(f"C{compressed} build failed: {directory / 'build.log'}")
        command_run = [str(directory / "Vdrg5_control_events_tb"), "+verilator+seed+1"]
        code, text = execute(command_run, directory / "run.log", root)
        expected = f"PASS control-events C={compressed} "
        # an ordinary zero exit is insufficient without every declared coverage assertion.
        if code != 0 or expected not in text:
            raise RuntimeError(f"C{compressed} regression failed: {directory / 'run.log'}")
        result = next(line for line in text.splitlines() if line.startswith(expected))
        records.append({"configuration": f"c{compressed}", "build_command": command,
                        "run_command": command_run, "exit_code": code, "result": result})
        print(result, flush=True)
    negative_controls = [
        ("mutate_kill", "unjustified or missing event squash"),
        ("mutate_abort", "missing or spurious flush abort"),
        ("mutate_return", "wrong terminal continuation"),
    ]
    # repeat each observation corruption in both configurations at its named detector.
    for compressed in [0, 1]:
        # no unrelated failure or unactivated corruption qualifies a checker.
        for mutation, detector in negative_controls:
            command = [str(build / f"c{compressed}" / "Vdrg5_control_events_tb"),
                       "+verilator+seed+1", f"+{mutation}"]
            log = build / f"c{compressed}-{mutation}.log"
            code, text = execute(command, log, root)
            # require the intended detector, a failing exit and absence of a passing record.
            if code == 0 or detector not in text or "PASS control-events" in text:
                raise RuntimeError(f"negative control did not reach {detector}: {log}")
            records.append({"configuration": f"c{compressed}", "negative_control": mutation,
                            "command": command, "exit_code": code, "detector": detector,
                            "first_error": next(line for line in text.splitlines() if "%Fatal" in line)})
    after = digest_sources(root, hash_names)
    # a source changed during qualification cannot inherit the completed run's result.
    if before != after:
        raise RuntimeError("control-event sources changed during qualification")
    summary = {
        "scope": "control-flow packet prototype event integration; not a complete CPU or ISA-conformance result",
        "verilator": version,
        "source_sha256": after,
        "results": records,
        "status": "passed",
        "negative_control_types": len(negative_controls),
        "negative_control_runs_passed": 2 * len(negative_controls),
        "limits": ["CSR, MRET, ordinary result and load operations are explicit synthetic packets",
                   "real branch/JAL decode and execution are exercised; no production CPU top or C decoder is claimed",
                   "C0 held-fault case uses a taken misaligned JAL; C1 uses an illegal branch encoding",
                   "detector controls corrupt observed output fields, not implementation RTL"],
    }
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS control-events qualification: {build / 'summary.json'}", flush=True)


# expose the explicit command-line entrypoint without running during import.
if __name__ == "__main__":
    main()

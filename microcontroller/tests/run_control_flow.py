#!/usr/bin/env python3
"""qualify actual control-flow execution and independent observation detectors."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


# preserve complete output and exact command disposition for reproducible review.
def execute(command, log, root):
    # keep build output separate from the concise qualification record.
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=240, check=False)
    return result.returncode, log.read_text()


# both alignment configurations run with overlapping and diagnostic occupancy.
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
        "microcontroller/rtl/drg5_fetch_guard.sv",
        "microcontroller/rtl/drg5_fetch_buffer.sv",
        "microcontroller/rtl/drg5_fetch.sv",
        "microcontroller/tests/drg5_control_flow_tb.sv",
    ]
    hash_names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh",
                            "microcontroller/tests/run_control_flow.py",
                            "microcontroller/tests/Makefile"]
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in hash_names}
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    records = []
    # a distinct compiled model proves each elaborated alignment and occupancy choice.
    for compressed, diagnostic in [(0, 0), (1, 0), (0, 1), (1, 1)]:
        name = f"c{compressed}-{'diagnostic' if diagnostic else 'overlap'}"
        directory = build / name
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall",
                   "-j", "2", "-CFLAGS", "-O0", "-Imicrocontroller/rtl",
                   "--top-module", "drg5_control_flow_tb", "--Mdir", str(directory),
                   f"-GC_ENABLED={compressed}", f"-GDIAGNOSTIC={diagnostic}", *sources]
        code, text = execute(command, directory / "build.log", root)
        # no lint waiver or warning is accepted as a qualified build.
        if code != 0 or "%Warning" in text:
            raise RuntimeError(f"{name} build failed: {directory / 'build.log'}")
        command_run = [str(directory / "Vdrg5_control_flow_tb"), "+verilator+seed+1"]
        code, text = execute(command_run, directory / "run.log", root)
        expected = f"PASS control-flow C={compressed} diagnostic={diagnostic} "
        # completion requires the explicit bounded architectural sequence check to pass.
        if code != 0 or expected not in text:
            raise RuntimeError(f"{name} regression failed: {directory / 'run.log'}")
        result = next(line for line in text.splitlines() if line.startswith(expected))
        records.append({"configuration": name, "build_command": command,
                        "run_command": command_run, "exit_code": code, "result": result})
        print(result, flush=True)
    negative_controls = [
        ("mutate_link", "wrong architectural control result"),
        ("mutate_source", "control operands did not come from the independent register bank"),
        ("mutate_target", "redirect target disagreed with independent architectural PC"),
    ]
    # each intentionally corrupted observation must activate its named detector.
    for mutation, detector in negative_controls:
        command = [str(build / "c0-overlap" / "Vdrg5_control_flow_tb"),
                   "+verilator+seed+1", f"+{mutation}"]
        log = build / f"{mutation}.log"
        code, text = execute(command, log, root)
        # an unrelated failure or a pass cannot establish comparator effectiveness.
        if code == 0 or detector not in text or "PASS control-flow" in text:
            raise RuntimeError(f"negative control did not reach {detector}: {log}")
        records.append({"negative_control": mutation, "command": command,
                        "exit_code": code, "detector": detector,
                        "first_error": next(line for line in text.splitlines() if "%Fatal" in line)})
    after = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in hash_names}
    # concurrent source changes invalidate the association between results and checked code.
    if before != after:
        raise RuntimeError("control-flow sources changed during qualification")
    summary = {
        "scope": "control-flow packet prototype with real RF sources and fetch-fault adapter; not CPU conformance",
        "verilator": version,
        "source_sha256": after,
        "results": records,
        "status": "passed",
        "negative_controls_passed": len(negative_controls),
        "limits": ["no compressed decoder: two-byte controls use trusted external expansion",
                   "external-flush interactions with OP_CONTROL are source-reviewed only here",
                   "C-dependent trap mepc masking is executed; C1 mepc CSR-write/MRET masking is source-reviewed",
                   "all non-control program packets supply precomputed operations"],
    }
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS control-flow qualification: {build / 'summary.json'}", flush=True)


# keep the executable entrypoint separate from importable runner helpers.
if __name__ == "__main__":
    main()

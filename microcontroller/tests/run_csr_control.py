#!/usr/bin/env python3
"""qualify encoded Zicsr, trap transitions, counters and independent bus ownership."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


# retain complete diagnostics for successful runs and deliberately corrupted observations.
def execute(command, log, root):
    # each command has a finite deadline and its own full log.
    with log.open("w") as stream:
        stream.write("$ " + " ".join(command) + "\n")
        stream.flush()
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=600, check=False)
    return result.returncode, log.read_text()


# bind all compilation inputs, the runner and the shared build entrypoint to the result.
def digest_sources(root, names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# separate alignment elaborations exercise the same architectural profile and event oracle.
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
        "microcontroller/tests/drg5_csr_control_tb.sv",
    ]
    hash_names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh",
                           "microcontroller/tests/run_csr_control.py",
                           "microcontroller/tests/Makefile"]
    before = digest_sources(root, hash_names)
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    records = []
    # serial compilation bounds host memory while every HDL lint warning remains fatal.
    for compressed in [0, 1]:
        directory = build / f"c{compressed}"
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall",
                   "-j", "2", "-CFLAGS", "-O0", "-Imicrocontroller/rtl",
                   "--top-module", "drg5_csr_control_tb", "--Mdir", str(directory),
                   f"-GC_ENABLED={compressed}", *sources]
        code, output = execute(command, directory / "build.log", root)
        # a compiler exit alone cannot hide an accidentally waived warning.
        if code != 0 or "%Warning" in output:
            raise RuntimeError(f"C{compressed} build failed: {directory / 'build.log'}")
        # runtime generator seeds change operands, addresses and holds after the common directed corpus.
        for seed in [0, 1, 305419896]:
            command_run = [str(directory / "Vdrg5_csr_control_tb"), "+verilator+seed+1", f"+seed={seed}"]
            log = directory / f"seed-{seed}.log"
            code, output = execute(command_run, log, root)
            expected = f"PASS csr-control C={compressed} seed={seed} "
            # all directed coverage guards must finish before the passing record is emitted.
            if code != 0 or expected not in output:
                raise RuntimeError(f"C{compressed} seed {seed} failed: {log}")
            result = next(line for line in output.splitlines() if line.startswith(expected))
            records.append({"configuration": f"c{compressed}", "seed": seed,
                            "build_command": command, "run_command": command_run,
                            "exit_code": code, "result": result})
            print(result, flush=True)
    negative_controls = [
        ("mutate_write", "independent CSR terminal mismatch"),
        ("mutate_read", "independent CSR terminal mismatch"),
        ("mutate_stale", "independent CSR terminal mismatch"),
        ("mutate_return", "independent CSR terminal mismatch"),
        ("mutate_kill", "unjustified CSR squash"),
        ("mutate_storage", "independent CSR storage mismatch"),
        ("mutate_counter", "independent counter edge mismatch"),
    ]
    # each observation corruption must fail the intended comparator in both alignment elaborations.
    for compressed in [0, 1]:
        # unrelated crashes and an unactivated mutation do not qualify a detector.
        for mutation, detector in negative_controls:
            command = [str(build / f"c{compressed}" / "Vdrg5_csr_control_tb"),
                       "+verilator+seed+1", "+seed=1", f"+{mutation}"]
            log = build / f"c{compressed}-{mutation}.log"
            code, output = execute(command, log, root)
            # inspect the actual failure rather than treating any nonzero exit as success.
            if code == 0 or detector not in output or "PASS csr-control" in output:
                raise RuntimeError(f"negative control missed {detector}: {log}")
            records.append({"configuration": f"c{compressed}", "negative_control": mutation,
                            "command": command, "exit_code": code, "detector": detector,
                            "first_error": next(line for line in output.splitlines() if "%Fatal" in line)})
    after = digest_sources(root, hash_names)
    # source edits during compilation or checking invalidate the entire attribution.
    if before != after:
        raise RuntimeError("CSR-control sources changed during qualification")
    summary = {
        "scope": "raw32 OP_MACHINE prototype Zicsr and synchronous machine-trap integration",
        "verilator": version, "source_sha256": after, "results": records, "status": "passed",
        "generator": "32-bit state = 1664525 * state + 1013904223 modulo 2^32; state starts at seed",
        "seeds": [0, 1, 305419896], "randomized_scenarios_per_run": 32,
        "negative_control_types": len(negative_controls), "negative_control_runs_passed": 2 * len(negative_controls),
        "limits": ["not a complete CPU or an ACT4/Sail architectural qualification",
                   "C1 checks configured misa.C and mepc alignment; mixed-width execution has a separate fixture",
                   "already synchronized mip levels are readable; IRQ delivery and architectural debug remain absent",
                   "observation mutations calibrate checkers and are not injected RTL defects",
                   "memory service is directed: one outstanding word operation, independently delayed acceptance and response",
                   "no timing, place-and-route, programming or resource-budget qualification is asserted"],
    }
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS CSR-control qualification: {build / 'summary.json'}", flush=True)


# imports expose helpers without starting compilation or changing evidence.
if __name__ == "__main__":
    main()

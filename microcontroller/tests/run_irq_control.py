#!/usr/bin/env python3
"""qualify IRQ boundaries, retained events, WFI and encoded interrupt service work."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


# keep each reproducible command and its full output, including expected failures.
def execute(command, log, root):
    # finite subprocess deadlines prevent a stalled fixture from hiding its failure.
    with log.open("w") as stream:
        stream.write("$ " + " ".join(command) + "\n")
        stream.flush()
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=600, check=False)
    return result.returncode, log.read_text()


# bind production, test, build entrypoint and runner content to every qualified run.
def digest_sources(root, names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# two alignment elaborations share an independent raw32 architectural and physical-effect oracle.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    sources = ["microcontroller/rtl/" + name + ".sv" for name in [
        "drg5_control_pkg", "drg5_decoder", "drg5_decompress", "drg5_immediate", "drg5_branch", "drg5_lsu",
        "drg5_shifter", "drg5_alu", "drg5_forward", "drg5_csr", "drg5_irq_platform", "drg5_control"]]
    sources += ["microcontroller/tests/drg5_irq_control_tb.sv"]
    hash_names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh",
                           "microcontroller/tests/run_irq_control.py", "microcontroller/tests/Makefile"]
    before = digest_sources(root, hash_names)
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    records, logs = [], []
    negative_controls = [
        ("mutate_irq_pc", "independent IRQ PC/cause mismatch"),
        ("mutate_irq_cause", "independent IRQ PC/cause mismatch"),
        ("mutate_irq_lost", "unexpected noninstruction redirect"),
        ("mutate_counter", "independent IRQ counter mismatch"),
        ("mutate_wfi_wake", "WFI failed to wake on locally enabled pending"),
        ("mutate_wfi_flush_wake", "WFI failed to wake on completed external flush"),
        ("mutate_duplicate_read", "load x0 effect missing or repeated during IRQ drain"),
    ]
    # serial model builds keep resource use bounded without waiving any HDL warning.
    for compressed in [0, 1]:
        directory = build / f"c{compressed}"
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall", "-j", "2",
                   "-CFLAGS", "-O0", "-Imicrocontroller/rtl", "--top-module", "drg5_irq_control_tb",
                   "--Mdir", str(directory), f"-GC_ENABLED={compressed}", *sources]
        log = directory / "build.log"
        code, output = execute(command, log, root)
        logs.append(log)
        # any warning or nonzero result invalidates compilation qualification.
        if code != 0 or "%Warning" in output:
            raise RuntimeError(f"C{compressed} build failed: {log}")
        # seeds vary latency splits and holds after the complete deterministic corpus.
        for seed in [0, 1, 305419896]:
            command_run = [str(directory / "Vdrg5_irq_control_tb"), "+verilator+seed+1", f"+seed={seed}"]
            log = directory / f"seed-{seed}.log"
            code, output = execute(command_run, log, root)
            logs.append(log)
            expected = f"PASS irq-control C={compressed} seed={seed} "
            # PASS is emitted only after every independent architectural and effect check finishes.
            if code != 0 or expected not in output:
                raise RuntimeError(f"C{compressed} seed {seed} failed: {log}")
            result = next(line for line in output.splitlines() if line.startswith(expected))
            records.append({"configuration": f"c{compressed}", "seed": seed,
                            "build_command": command, "run_command": command_run,
                            "exit_code": code, "result": result,
                            "latencies": [line for line in output.splitlines() if line.startswith("LATENCY ")]})
            print(result, flush=True)
        # corruption must activate and fail the named ordinary comparator in both configurations.
        for mutation, detector in negative_controls:
            command_run = [str(directory / "Vdrg5_irq_control_tb"), "+verilator+seed+1", "+seed=1", f"+{mutation}"]
            log = directory / f"{mutation}.log"
            code, output = execute(command_run, log, root)
            logs.append(log)
            # unrelated crashes and missed activation are not passing detector calibration.
            if code == 0 or detector not in output or "PASS irq-control" in output:
                raise RuntimeError(f"C{compressed} negative control missed {detector}: {log}")
            records.append({"configuration": f"c{compressed}", "negative_control": mutation,
                            "command": command_run, "exit_code": code, "detector": detector,
                            "first_error": next(line for line in output.splitlines() if "%Fatal" in line)})
    after = digest_sources(root, hash_names)
    # edits during qualification invalidate attribution even if all simulations passed.
    if before != after:
        raise RuntimeError("IRQ-control sources changed during qualification")
    summary = {
        "status": "passed", "verilator": version, "source_sha256": after, "results": records,
        "scope": "raw32 machine IRQ/WFI control integration and persistent same-clock peripheral platform",
        "seeds": [0, 1, 305419896], "negative_control_types": len(negative_controls),
        "negative_control_runs_passed": 2 * len(negative_controls),
        "generator": "32-bit LCG state = state * 1664525 + 1013904223; initial state = seed",
        "latency_assumptions": [
            "pending origin is the edge at which the platform's retained level becomes visible",
            "one old data owner; acceptance delay + one acceptance edge + response delay <=128 clocks",
            "old instruction ownership indication clears within four clocks; separate fetch fixture checks the actual fetch unit",
            "current stress permits eight serialized X hold clocks; future-divider surrogate replaces this hold with 36",
            "vector delivery is a sixteen-clock adapter delay followed by actual control F-to-D transfer",
            "handler instruction packets are supplied as raw32 encodings without additional input delivery stalls",
            "handler local RAM and MMIO accept one clock after launch and respond one later; no DMA contention",
            "64-byte reserved save area holds ra,t0-t2,a0-a7,t3-t6; ACK effect and response are separate endpoints",
            "actual stores, block ACK, loads and MRET execute; timeout/uncertain responses are containment cases outside healthy bounds"],
        "limits": ["not an ACT4/Sail qualification or a complete CPU",
                   "C1 exercises alignment only in this fixture; raw C execution has separate qualification",
                   "synthetic held arithmetic models a future occupancy budget and does not execute division",
                   "debug is disconnected in this profile; no architectural debug behavior is tested",
                   "finite schedules validate assumptions and measured cases, not every possible WCET schedule",
                   "UID exhaustion is reached with a testbench-only internal counter seed; production parameters are unchanged",
                   "no FPGA route, clock-frequency or physical programming qualification"],
    }
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    evidence = (args.evidence_dir.resolve() if args.evidence_dir else
                root / "microcontroller/tests/evidence/irq-control-2026-11-04-wfi-flush")
    evidence.mkdir(parents=True, exist_ok=True)
    # retain compact complete logs and exact source snapshots without generated binaries.
    for log in logs:
        destination = evidence / log.relative_to(build)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(log, destination)
    shutil.copy2(build / "summary.json", evidence / "summary.json")
    # a source snapshot lets later reviewers distinguish qualification from subsequent edits.
    for name in hash_names:
        destination = evidence / "qualified-source" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
    print(f"PASS IRQ-control qualification: {evidence / 'summary.json'}", flush=True)


# imports expose helpers without starting qualification.
if __name__ == "__main__":
    main()

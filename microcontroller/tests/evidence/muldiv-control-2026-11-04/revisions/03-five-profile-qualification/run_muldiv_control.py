#!/usr/bin/env python3
"""qualify raw RV32M retirement, ownership, dependencies and measured IRQ service."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


# retain each exact command and complete output, including expected failures.
def execute(command, log, root):
    # finite deadlines turn stalled simulations into visible runner failures.
    with log.open("w") as stream:
        stream.write("$ " + " ".join(command) + "\n")
        stream.flush()
        result = subprocess.run(command, cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=600, check=False)
    return result.returncode, log.read_text()


# bind the tested implementation, independent oracle and build entrypoint.
def digest_sources(root, names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


# separate feature enablement from overlap, forwarding and interrupt control.
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
        "drg5_control_pkg", "drg5_decoder", "drg5_immediate", "drg5_branch", "drg5_lsu",
        "drg5_shifter", "drg5_alu", "drg5_forward", "drg5_muldiv", "drg5_csr",
        "drg5_irq_platform", "drg5_control"]]
    sources += ["microcontroller/tests/drg5_muldiv_control_tb.sv"]
    hash_names = sources + ["microcontroller/rtl/drg5_datapath_defs.svh",
                           "microcontroller/tests/run_muldiv_control.py", "microcontroller/tests/Makefile"]
    before = digest_sources(root, hash_names)
    version = subprocess.check_output([args.verilator, "--version"], text=True).strip()
    records, logs = [], []
    profiles = [
        {"M_ENABLED": 1, "DIAGNOSTIC": 0, "FORWARDING": 1, "IRQ_ENABLED": 1},
        {"M_ENABLED": 1, "DIAGNOSTIC": 0, "FORWARDING": 0, "IRQ_ENABLED": 1},
        {"M_ENABLED": 1, "DIAGNOSTIC": 1, "FORWARDING": 1, "IRQ_ENABLED": 1},
        {"M_ENABLED": 1, "DIAGNOSTIC": 0, "FORWARDING": 1, "IRQ_ENABLED": 0},
        {"M_ENABLED": 0, "DIAGNOSTIC": 0, "FORWARDING": 1, "IRQ_ENABLED": 1},
    ]
    negative_controls = [
        ("mutate_m_result", "IRQ register result mismatch"),
        ("mutate_job_uid", "M completion UID mismatch"),
        ("mutate_irq_pc", "independent IRQ PC/cause mismatch"),
        ("mutate_duplicate_read", "M MMIO read effect missing or repeated"),
    ]
    # serial strict builds avoid resource contention without waiving HDL diagnostics.
    for profile in profiles:
        name = "m{M_ENABLED}-d{DIAGNOSTIC}-f{FORWARDING}-irq{IRQ_ENABLED}".format(**profile)
        directory = build / name
        directory.mkdir(parents=True, exist_ok=True)
        command = [args.verilator, "--binary", "--timing", "--assert", "-Wall", "-j", "2",
                   "-CFLAGS", "-O0", "-Imicrocontroller/rtl", "--top-module", "drg5_muldiv_control_tb",
                   "--Mdir", str(directory), *[f"-G{key}={value}" for key, value in profile.items()], *sources]
        log = directory / "build.log"
        code, output = execute(command, log, root)
        logs.append(log)
        # every warning or failed compiler exit invalidates this configuration.
        if code != 0 or "%Warning" in output:
            raise RuntimeError(f"{name} build failed: {log}")
        expected = ("PASS muldiv-control M={M_ENABLED} diagnostic={DIAGNOSTIC} "
                    "forwarding={FORWARDING} IRQ={IRQ_ENABLED}").format(**profile)
        # each seed repeats boundary and cancellation cases before varying operands and service schedules.
        for seed in [0, 1, 305419896]:
            run = [str(directory / "Vdrg5_muldiv_control_tb"), "+verilator+seed+1", f"+seed={seed}"]
            log = directory / f"seed-{seed}.log"
            code, output = execute(run, log, root)
            logs.append(log)
            marker = f"{expected} seed={seed} "
            # the final marker follows every architectural, physical-effect and timing comparison.
            if code != 0 or marker not in output:
                raise RuntimeError(f"{name} seed {seed} failed: {log}")
            result = next(line for line in output.splitlines() if line.startswith(marker))
            records.append({"configuration": name, "parameters": profile, "seed": seed,
                            "build_command": command, "run_command": run, "exit_code": code,
                            "result": result,
                            "latencies": [line for line in output.splitlines() if line.startswith("M_LATENCY ")]})
            print(result, flush=True)
        # one overlapping IRQ profile calibrates all four independent detector classes.
        if profile == profiles[0]:
            # a corruption must reach its named comparator; unrelated failure is insufficient.
            for mutation, detector in negative_controls:
                run = [str(directory / "Vdrg5_muldiv_control_tb"), "+verilator+seed+1", "+seed=1", f"+{mutation}"]
                log = directory / f"{mutation}.log"
                code, output = execute(run, log, root)
                logs.append(log)
                # an inactive mutant or a successful run fails detector calibration.
                if code == 0 or detector not in output or "PASS muldiv-control" in output:
                    raise RuntimeError(f"{name} negative control missed {detector}: {log}")
                records.append({"configuration": name, "negative_control": mutation,
                                "command": run, "exit_code": code, "detector": detector,
                                "first_error": next(line for line in output.splitlines() if "%Fatal" in line)})
    after = digest_sources(root, hash_names)
    # concurrent edits would invalidate the source attribution even if the executable passed.
    if before != after:
        raise RuntimeError("multiply/divide control sources changed during qualification")
    summary = {
        "status": "passed", "verilator": version, "source_sha256": after, "results": records,
        "scope": "raw32 M control integration with independent retirement, job and bus-effect ledgers",
        "profiles": profiles, "seeds": [0, 1, 305419896], "negative_control_runs_passed": len(negative_controls),
        "generator": "32-bit LCG state = state * 1664525 + 1013904223; initial state = seed",
        "measured_arithmetic_edges_from_accepted_start": {
            "multiply": {"first_valid": 2, "X_capture": 3, "earliest_X_transfer": 4, "earliest_retirement": 6},
            "divide": {"first_valid": 33, "X_capture": 34, "earliest_X_transfer": 35, "earliest_retirement": 37}},
        "latency_assumptions": [
            "pending origin is the edge at which a retained same-clock platform event becomes visible",
            "one older data owner: acceptance delay + one acceptance edge + response delay <=128 clocks",
            "a real DIV executes in X and can overlap the older memory operation",
            "instruction ownership indication clears within four clocks; actual fetch RAM is tested separately",
            "at most eight additional serialized X hold clocks after data response in endpoint schedules",
            "vector delivery adapter delays sixteen clocks before raw32 packets resume",
            "the handler uses sixteen actual register-save stores, block ACK, sixteen loads and MRET",
            "handler RAM/MMIO accept one clock after launch and respond one later, without DMA contention",
            "handler packets have no extra delivery stalls; saved context includes the completed divide result",
            "uncertain responses enter containment; healthy IRQ bounds exclude timeout/containment"],
        "limits": [
            "not ACT4/Sail, a complete RV32IM milestone, production fetch integration or FPGA qualification",
            "C is disabled; raw32 adapter replaces instruction fetch and has explicitly bounded delivery",
            "debug is absent and disconnected; no debug halt or resume behavior is claimed",
            "finite schedules measure directed cases and do not prove every possible WCET schedule",
            "diagnostic and IRQ-disabled profiles omit overlap-dependent IRQ service schedules",
            "X transfer and retirement endpoints are earliest measured values, not bounds under unlimited backpressure",
            "unit reset isolation and division corner cases have separate exhaustive/seeded unit evidence"],
    }
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    evidence = (args.evidence_dir.resolve() if args.evidence_dir else
                root / "microcontroller/tests/evidence/muldiv-control-2026-11-04")
    evidence.mkdir(parents=True, exist_ok=True)
    # retain complete logs and source snapshots without generated binaries.
    for log in logs:
        destination = evidence / log.relative_to(build)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(log, destination)
    shutil.copy2(build / "summary.json", evidence / "summary.json")
    # snapshot each hashed file so later edits cannot silently alter the qualified artifact.
    for name in hash_names:
        destination = evidence / "qualified-source" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
    print(f"PASS multiply/divide control qualification: {evidence / 'summary.json'}", flush=True)


# importing helpers does not start qualification.
if __name__ == "__main__":
    main()

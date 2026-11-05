#!/usr/bin/env python3
"""qualify UART framing, capacity and reset at each board clock profile."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


# retain exact inputs and failed commands beside the simulation outputs.
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verilator", type=Path, default=Path("/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = [root / "microcontroller/rtl/drg5_uart_tx.sv", root / "microcontroller/tests/drg5_uart_tx_tb.sv"]
    records = []
    env = os.environ.copy()
    env["XDG_CONFIG_HOME"] = str(output / "config")
    version = subprocess.run([str(args.verilator), "--version"], capture_output=True, text=True, env=env, check=True).stdout.strip()
    # each nominal board frequency uses its real rounded UART divisor.
    for frequency in (80000000, 50000000, 25000000):
        attempt = output / str(frequency)
        attempt.mkdir(exist_ok=True)
        command = [str(args.verilator), "--binary", "--timing", "--assert", "--top-module", "drg5_uart_tx_tb", "--Mdir", str(attempt / "obj"), f"-GCLOCK_HZ={frequency}", *map(str, sources)]
        (attempt / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        # preserve build failures without treating a missing executable as a passing case.
        with (attempt / "build.log").open("w") as log:
            built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env)
        record = {"clock_hz": frequency, "build_exit": built.returncode}
        # execute only the binary produced by this successful build.
        if built.returncode == 0:
            run = subprocess.run([str(attempt / "obj/Vdrg5_uart_tx_tb")], capture_output=True, text=True, env=env)
            (attempt / "run.log").write_text(run.stdout + run.stderr)
            record["run_exit"] = run.returncode
            match = re.search(r"UART pass clock_hz=(\d+) divisor=(\d+) accepted=(\d+) completed=(\d+) discarded=(\d+) checks=(\d+) cycles=(\d+)", run.stdout)
            record["pass"] = run.returncode == 0 and match is not None
            # parse the explicit assertion-clean completion record.
            if match:
                record.update(zip(("clock_hz", "divisor", "accepted", "completed", "discarded", "checks", "cycles"), map(int, match.groups())))
        records.append(record)
    result = {"schema": "DRG5-UART-1", "verilator": version, "sources": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [*sources, Path(__file__).resolve()]}, "runs": records, "pass": all(record.get("pass", False) for record in records)}
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["pass"] else 1


# execute the standalone campaign only when invoked directly.
if __name__ == "__main__":
    raise SystemExit(main())

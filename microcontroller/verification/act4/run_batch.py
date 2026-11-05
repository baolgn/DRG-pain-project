#!/usr/bin/env python3
"""execute each bounded ACT4 ELF and retain individual hardware outcomes."""
import argparse
import gzip
import importlib.util
import json
from pathlib import Path
import shutil


# use the common production-core runner and its independent bus checks.
def main():
    """run all available ELFs; build omissions remain in the build inventory."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--elf-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-arch-exec'))
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--max-cycles', type=int, default=2000000)
    args = parser.parse_args()
    runner = Path(__file__).resolve().parents[1] / 'execution/run_elf.py'
    spec = importlib.util.spec_from_file_location('drg5_elf_runner', runner)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    files = sorted(args.elf_dir.rglob('*.elf'))
    # an empty artifact set cannot be a successful architectural run.
    if not files:
        raise SystemExit('no ACT4 ELFs found')
    # every test retains its exact ELF hash, source fingerprint and schedule seed.
    for elf in files:
        relative = elf.relative_to(args.elf_dir)
        output = args.output / relative.with_suffix('')
        record = {'test': str(relative), 'seed': args.seed}
        # input or infrastructure errors remain visible beside ordinary DUT failures.
        try:
            result = module.execute(elf, args.build, output, seed=args.seed,
                                    max_cycles=args.max_cycles)
            record.update(status=result['status'], summary=str(output / 'summary.json'),
                          elf_sha256=result['elf_sha256'], observed=result['observed'])
            # a failed comparison gets a complete replay trace under the identical seed.
            if result['status'] == 'failed':
                replay = output / 'failure-replay'
                captured = module.execute(elf, args.build, replay, seed=args.seed,
                                          max_cycles=args.max_cycles, trace=True)
                trace = replay / 'trace.jsonl'
                # compression preserves full failure history without accumulating large raw traces.
                with trace.open('rb') as source, gzip.open(replay / 'trace.jsonl.gz', 'wb') as sink:
                    shutil.copyfileobj(source, sink)
                trace.unlink()
                record.update(failure_trace=str(replay / 'trace.jsonl.gz'),
                              failure_replay_summary=str(replay / 'summary.json'),
                              failure_replay_status=captured['status'])
        # preserve failures in setup or execution without dropping the test record.
        except Exception as error:
            record.setdefault('status', 'infrastructure_error')
            record['infrastructure_error'] = str(error)
        records.append(record)
        print(record['status'], relative, flush=True)
        (args.output / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
    raise SystemExit(0 if all(row['status'] == 'passed' for row in records) else 1)


# imports never start a hardware run.
if __name__ == '__main__':
    main()

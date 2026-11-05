#!/usr/bin/env python3
"""run both production-controller and fetch proofs with fresh immutable evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def complete_summary(summary):
    """require matching hashes and actual expected statuses across both families."""
    hashes = dict(summary['sources'])
    pipeline = summary['results'].get('pipeline', {})
    fetch = summary['results'].get('fetch', {})
    # missing summaries cannot silently produce a qualification success.
    for family, key in [(pipeline, 'source_hashes'), (fetch, 'sources')]:
        # failed frontends may leave no native summary.
        if family.get('data') is None:
            continue
        # duplicated source names must refer to identical bytes.
        for path, digest in family['data'].get(key, {}).items():
            # inconsistent snapshots invalidate the combined evidence.
            if path in hashes and hashes[path] != digest:
                raise RuntimeError(f'inconsistent source hash: {path}')
            hashes[path] = digest
    summary['source_sha256'] = hashes
    passed = len(summary['results']) == 2
    # negative controls pass only when their native expected-failure checks succeeded.
    for family in summary['results'].values():
        passed = passed and family['exit_code'] == 0 and family['data'] is not None
        # the native family summary records every required proof, witness and detector.
        if family['data'] is not None:
            passed = passed and bool(family['data']['results']) and all(item['expected_outcome_seen'] for item in family['data']['results'].values())
    summary['status'] = 'PASS' if passed else 'FAIL'
    summary['bounds'] = {'controller_safety': 16, 'controller_isolated_progress': 40,
                         'isolated_disposition_deadline_clocks': 32, 'fetch_safety': 20}
    return summary


def main():
    """collect actual statuses without upgrading bounded results into full proofs."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    microcontroller = here.parents[1]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=False)
    execution_wrapper = build / 'wrapper_at_launch.py'
    shutil.copyfile(Path(__file__).resolve(), execution_wrapper)
    summary = {'scope': 'bounded controller and fetch formal checks; no whole-core ISA or unbounded progress proof',
               'results': {}, 'sources': {},
               'execution_wrapper_path': str(execution_wrapper),
               'execution_wrapper_sha256': hashlib.sha256(execution_wrapper.read_bytes()).hexdigest()}
    jobs = [('pipeline', [sys.executable, str(here / 'run_pipeline_formal.py'), '--tools', str(args.tools.resolve()), '--build', str(build / 'pipeline')]),
            ('fetch', [sys.executable, str(microcontroller / 'tests/run_fetch_formal.py'), '--yosys', str(args.tools.resolve() / 'bin/yosys'), '--build', str(build / 'fetch')])]
    # retain both families even if one fails or times out.
    for name, command in jobs:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        (build / (name + '.log')).write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
        path = build / name / 'summary.json'
        summary['results'][name] = {'exit_code': result.returncode, 'summary': str(path),
                                    'data': json.loads(path.read_text()) if path.exists() else None}
        (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
        print(name, result.returncode, flush=True)
    snapshot = build / 'fetch' / 'sources'
    snapshot.mkdir()
    sources = [microcontroller / 'rtl' / (name + '.sv') for name in ['drg5_fetch', 'drg5_fetch_guard', 'drg5_fetch_buffer']]
    sources += [microcontroller / 'tests/drg5_fetch_formal.sv', microcontroller / 'tests/run_fetch_formal.py', Path(__file__).resolve()]
    # fetch's native runner records hashes; retain the corresponding bytes alongside them.
    for path in sources:
        recorded = execution_wrapper if path == Path(__file__).resolve() else path
        shutil.copyfile(recorded, snapshot / path.name)
        summary['sources'][str(path)] = hashlib.sha256(recorded.read_bytes()).hexdigest()
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    summary = complete_summary(summary)
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    # unavailable summaries and nonzero runner status remain visible qualification failures.
    if summary['status'] != 'PASS':
        raise SystemExit(1)


# direct execution starts the requested proof run.
if __name__ == '__main__':
    main()

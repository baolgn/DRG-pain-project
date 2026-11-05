#!/usr/bin/env python3
"""calibrate evidence guards with intact and deliberately damaged records."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from publish import publish
from run_campaign import finalize_status, verify_source, COMMIT


# fixtures copy one real passing ELF record; actual execution evidence stays untouched.
def main():
    """check evidence failures, schedule accounting, fresh work and pinned tool bytes."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--tests', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=Path('/tmp/drg5-arch-tools'))
    args = parser.parse_args()
    local = Path(__file__).resolve().parent
    name = 'rv32i/I/I-nop-00.elf'
    inventory = json.loads(args.inventory.read_text())
    selected = next(item for item in inventory['records'] if item['test'] == name.replace('.elf', '.S'))
    entry = next(item for item in json.loads((args.run / 'results.json').read_text()) if item['test'] == name)
    original = Path(entry['summary'])
    summary = json.loads(original.read_text())
    checks = []
    # temporary corrupted copies cannot become campaign results or replace retained failures.
    with tempfile.TemporaryDirectory(prefix='drg5-evidence-check-') as temporary:
        base = Path(temporary)
        inventory_path = base / 'inventory.json'
        inventory_path.write_text(json.dumps(dict(inventory, records=[selected], counts={'built': 1})))
        # the intact control prevents a guard that simply rejects every record from passing.
        for case in ['intact', 'missing_summary', 'missing_log', 'inconsistent_marker', 'status_mismatch', 'source_drift']:
            run = base / case / 'run'
            run.mkdir(parents=True)
            current = copy.deepcopy(summary)
            record = dict(entry, summary=str(run / 'summary.json'))
            # each damage targets one independent evidence consistency check.
            if case == 'status_mismatch':
                record['status'] = 'failed'
            # modified historical fingerprints must block attribution to active source.
            if case == 'source_drift':
                source = next(iter(current['build']['sources']))
                current['build']['sources'][source] = '0' * 64
            # absent summaries must never inherit a claimed passing batch status.
            if case != 'missing_summary':
                (run / 'summary.json').write_text(json.dumps(current))
            # absent or contradictory terminal logs invalidate a successful summary.
            if case != 'missing_log':
                console = original.with_name('execution.log').read_text()
                # preserve all other log bytes while removing the required success marker.
                if case == 'inconsistent_marker':
                    console = console.replace('ARCH_EXEC_PASS ', 'INVALID_MARKER ')
                (run / 'execution.log').write_text(console)
            (run / 'results.json').write_text(json.dumps([record]))
            result = publish(args.work, args.tests, inventory_path, base / case / 'published', {'seed1': [run]})
            expected = 'complete_pass' if case == 'intact' else 'qualification_open'
            assert result['status'] == expected, (case, result['status'])
            checks.append({'case': case, 'status': result['status'],
                           'counts': result['executions']['seed1']['counts'],
                           'source_drift': bool(result['build_source_drift'])})
        phases = dict.fromkeys(['sail.json', 'sail-retirement.json', 'generation', 'build', 'inventory',
                               'execution-seed1', 'execution-seed24301'], 0)
        # a phase error or missing requested schedule must override a publisher's provisional pass.
        for case in ['intact_phases', 'failed_phase', 'missing_seed', 'missing_phase', 'publisher_failure']:
            result = {'status': 'complete_pass', 'executions': {'seed1': {}, 'seed24301': {}}}
            current_phases = phases.copy()
            # each case changes one input to the shared campaign/process verdict.
            if case == 'failed_phase':
                current_phases['execution-seed24301'] = 1
            # no results file for one requested seed remains an explicit missing schedule.
            if case == 'missing_seed':
                del result['executions']['seed24301']
            # missing phase evidence cannot be inferred from existing artifacts.
            if case == 'missing_phase':
                del current_phases['build']
            # publisher-detected source drift must propagate to the process exit verdict.
            if case == 'publisher_failure':
                result['status'] = 'qualification_open'
            status = finalize_status(result, current_phases, [1, 24301])
            assert status == ('complete_pass' if case == 'intact_phases' else 'qualification_open'), case
            checks.append({'case': case, 'status': status})
        reused = base / 'reused'
        reused.mkdir()
        (reused / 'old.elf').write_text('stale')
        result = subprocess.run([sys.executable, local / 'run_campaign.py', '--work', reused,
                                 '--evidence', base / 'freshness'], capture_output=True, text=True)
        assert result.returncode != 0 and 'fresh, empty --work' in result.stderr
        checks.append({'case': 'reused_work', 'exit_code': result.returncode, 'stderr': result.stderr.strip()})
    verified = verify_source(args.tools, args.tools / 'act4' / ('riscv-arch-test-' + COMMIT))
    report = {'status': 'passed', 'checks': checks, 'archive_verified_executables': verified,
              'source_sha256': {name: hashlib.sha256((local / name).read_bytes()).hexdigest()
                               for name in ['publish.py', 'run_campaign.py', 'check_evidence.py']}}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(f'evidence guards passed: {len(checks)} cases, {len(verified)} executable archive checks')


# imports expose helpers without running destructive-copy calibration.
if __name__ == '__main__':
    main()

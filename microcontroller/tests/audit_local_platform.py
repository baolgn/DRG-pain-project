#!/usr/bin/env python3
"""replay archived local-platform captures and verify their source and firmware attribution."""
import argparse
from collections import Counter
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

from audit_firmware import audit, compressed_oracle

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = ROOT / 'microcontroller/verification/evidence/local-platform-2026-11-04'


# comparisons bind complete bytes rather than timestamps or tool-success markers alone.
def digest(path):
    """hash one exact input artifact."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# failed audits still identify the first violated evidence condition.
def require(condition, reason):
    """reject missing, stale or contradictory evidence."""
    # a named diagnostic prevents a prior passing report from hiding this attempt.
    if not condition:
        raise ValueError('LOCAL_AUDIT_FAILED ' + reason)


# retained source snapshots and active source bytes have separate identities to verify.
def source_inputs(record, snapshot):
    """require the recorded source cohort to match both retained and current files."""
    # compare every retained input rather than only the top-level module.
    for name, expected in record['source_sha256'].items():
        require(digest(ROOT / name) == expected, 'current source changed: ' + name)
        require(digest(snapshot / name) == expected, 'source snapshot changed: ' + name)


# a complete replay checks current published captures without invoking a simulator.
def main():
    """audit the full campaign, its negative controls and the independent fabric checks."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, default=DEFAULT)
    args = parser.parse_args();base = args.evidence.resolve()
    report = {'status': 'running', 'scope': 'source identity, retained images, raw ISA inspection and archived trace replay'}
    inputs = {str(Path(__file__).relative_to(ROOT)): digest(__file__),
              'microcontroller/tests/audit_firmware.py': digest(ROOT / 'microcontroller/tests/audit_firmware.py'),
              'microcontroller/verification/execution/comparison.py': digest(ROOT / 'microcontroller/verification/execution/comparison.py')}
    artifacts = {};failure = None
    # every failure replaces this audit's status while preserving the actual campaign outputs.
    try:
        summary_path = base / 'summary.json';campaign = json.loads(summary_path.read_text())
        require(campaign['status'] == 'passed' and not campaign['smoke'] and not campaign['source_drift'], 'full successful campaign required')
        revision = Path(campaign['firmware']['imc']['build']['manifest']).parent.parent
        require(digest(summary_path) == digest(revision / 'summary.json'), 'published summary differs from revision')
        artifacts[str(summary_path.relative_to(ROOT))] = digest(summary_path)
        source_inputs(campaign, revision / 'sources')
        # verify actual compiler and simulator executables before relying on their pinned identities.
        for path, expected in campaign['tool_sha256'].items():
            require(digest(path) == expected, 'simulator tool changed')
        oracle = compressed_oracle();inspections = {}
        # all positive profiles and intentionally defective builds retain their original input artifacts.
        for manifest_path in sorted(revision.glob('firmware-*/build.json')):
            build = json.loads(manifest_path.read_text());source_inputs(build, revision / 'sources')
            directory = manifest_path.parent
            # artifact hashes include actual object, archive, image and linker bytes.
            for name, expected in build['artifact_sha256'].items():
                path = directory / name;require(digest(path) == expected, 'firmware artifact changed: ' + str(path))
                artifacts[str(path.relative_to(ROOT))] = expected
            # every compiler subprocess identity remains inspectable after the run.
            for path, expected in build['tool_sha256'].items():
                require(digest(path) == expected, 'firmware tool changed')
            gcc = next(path for path in build['tool_sha256'] if path.endswith('riscv-none-elf-gcc'))
            prefix = gcc.removesuffix('gcc')
            archived = subprocess.check_output([prefix + 'ar', 'p', build['archive'], 'runtime.o'])
            require(archived == Path(build['objects'][-1]).read_bytes(), 'library member differs from inspected object')
            inspections[directory.name] = [audit(path, build['profile'], prefix, oracle)
                                           for path in [*build['objects'], build['elf']]]
            # BSS must have no loaded file bytes and initialized DRAM must have its image in IRAM.
            for load in build['image']['loads']:
                require(not load['filesz'] or load['paddr'] < 0x20000, 'DRAM initialized by loader')
            artifacts[str(manifest_path.relative_to(ROOT))] = digest(manifest_path)
        spec = importlib.util.spec_from_file_location('local_archive_comparison', ROOT / 'microcontroller/verification/execution/comparison.py')
        comparison = importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
        totals = Counter();results = [];configurations = Counter()
        # every run keeps its own schema and immutable initial-memory images.
        for run in campaign['runs']:
            capture = Path(run['command'][4]);directory = capture.parent
            saved = json.loads((directory / 'summary.json').read_text())
            require(saved == {key: value for key, value in run.items() if key != 'configuration'}, 'run publication mismatch')
            trace = directory / 'trace.jsonl.gz'
            require(digest(trace) == run['trace_archive_sha256'], 'compressed trace changed')
            plain = gzip.decompress(trace.read_bytes())
            require(hashlib.sha256(plain).hexdigest() == run['trace_sha256'], 'plain trace changed')
            # retain all run inputs, not just the successful footer or simulator marker.
            for path in directory.iterdir():
                # nested directories are not individual retained input artifacts.
                if path.is_file():
                    artifacts[str(path.relative_to(ROOT))] = digest(path)
            log = (directory / 'execution.log').read_text()
            # ordinary failures must match their exact intended invariant without a success marker.
            if run['negative']:
                require(run['exit_code'] != 0 and run['expected_failure_seen'] and
                        'LOCAL_PLATFORM_FAILURE ' + run['negative'] in log and 'LOCAL_PLATFORM_PASS ' not in log,
                        'negative detector mismatch')
                totals['firmware_detectors'] += 1
                continue
            require(run['exit_code'] == 0 and run['status'] == 'passed', 'positive run failed')
            configuration = run['configuration'];configurations[configuration] += 1
            schema_path = directory.parent / 'trace-schema.json';schema = json.loads(schema_path.read_text())
            artifacts[str(schema_path.relative_to(ROOT))] = digest(schema_path)
            # replay from compressed artifacts without using live simulator state or build caches.
            with tempfile.TemporaryDirectory(prefix='drg5-local-replay-') as temporary:
                path = Path(temporary) / 'trace.jsonl';path.write_bytes(plain)
                terminals, footer = comparison.read_dut(path, schema)
            require(footer == run['replay'], 'replay totals changed')
            expected_traps = 7 if configuration == 'i-forwarded' else 8
            require(footer['traps'] == expected_traps and footer['irqs'] == 4, 'missing trap or IRQ exercise')
            require(any(row['packet.raw'] == 0x10500073 and not row['trap'] for row in terminals), 'WFI did not retire')
            require(run['observed']['idle_clocks'] > 0 and run['observed']['stack_bytes'] <= 4096, 'idle or stack observation')
            # stress schedules must hit every configured acceptance, response and held-stage bin.
            if run['mode'] == 'stress':
                require((run['observed']['acceptance_bins'], run['observed']['response_bins'], run['observed']['hold_bins']) ==
                        (255, 8190, 31), 'incomplete stress schedule')
            totals.update({'positive_runs': 1, 'retired': footer['retired'], 'traps': footer['traps'],
                           'interrupts': footer['irqs'], 'transactions': footer['i_accepts'] + footer['d_accepts']})
            results.append({'configuration': configuration, 'seed': run['seed'], 'mode': run['mode'], 'footer': footer})
        require(configurations == {'imc-forwarded': 3, 'imc-interlocked': 3, 'imc-diagnostic': 3, 'i-forwarded': 3}, 'missing profile schedule')
        require(totals['firmware_detectors'] == 3 and set(campaign['isa_detector']) == {'m', 'float', 'time'}, 'missing detector family')
        # rerun each retained malformed binary through the ordinary instruction auditor.
        for name, record in campaign['isa_detector'].items():
            path = revision / ('unsupported-' + name + '.elf');require(digest(path) == record['input_sha256'], 'ISA detector image changed')
            reason = None
            # the original exact diagnostic must still be obtained from the ordinary checker.
            try:
                audit(path, 'i', prefix, oracle)
            # a valid negative control returns the ordinary exact rejection diagnostic.
            except ValueError as error:
                reason = str(error)
            require(reason == record['expected_failure'], 'ISA detector no longer rejects input')
            artifacts[str(path.relative_to(ROOT))] = digest(path)
        fabric = json.loads((base / 'fabric/summary.json').read_text())
        source_inputs(fabric, base / 'fabric/sources')
        require(fabric['status'] == 'passed' and all(row['expected_outcome_seen'] for row in fabric['results'].values()), 'fabric checks')
        # this is structural memory collection, not a mapped-device or timing claim.
        synthesis = json.loads((base / 'fabric/synthesis.json').read_text())
        require(synthesis['status'] == 'passed' and synthesis['memory_cells'] == 3 and synthesis['no_latches'], 'fabric structural checks')
        require(digest(base / 'fabric/synthesis.log') == synthesis['log_sha256'], 'synthesis log changed')
        report.update(status='passed', totals=dict(totals), replayed=results, configurations=dict(configurations),
                      firmware_inspections=inspections, campaign_revision=str(revision.relative_to(ROOT)))
    # preserve an explicit failed audit instead of borrowing any earlier successful report.
    except Exception as error:
        report['status'] = 'failed';report['failure'] = str(error);failure = error
    # publish this attempt even if current evidence no longer matches its recorded inputs.
    finally:
        report['source_sha256'] = inputs;report['artifact_sha256'] = artifacts
        (base / 'audit.json').write_text(json.dumps(report, indent=2) + '\n')
    # a command success only denotes the scope printed in this source-bound report.
    if failure:
        raise failure
    print('LOCAL_AUDIT_PASS ' + json.dumps(report['totals']), flush=True)


# importing helpers never mutates retained evidence.
if __name__ == '__main__':
    main()

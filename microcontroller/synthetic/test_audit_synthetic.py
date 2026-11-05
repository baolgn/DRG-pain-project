#!/usr/bin/env python3
"""exercise real evidence admission failures without changing retained campaign inputs."""
import argparse
from copy import deepcopy
import gzip
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
AUDITOR = ROOT / 'microcontroller/synthetic/audit_synthetic.py'


def main():
    """retain positive admission and named semantic mutations with exact failure reasons."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--model-cohort', required=True); parser.add_argument('--cpu-cohort', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); evidence = args.evidence.resolve()
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('synthetic_auditor', AUDITOR)
    audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
    model_path = evidence / args.model_cohort / 'summary.json'
    cpu_path = evidence / args.cpu_cohort / 'summary.json'
    guard_path = evidence / 'guard-final-r4/summary.json'
    originals = {path: audit.read(path) for path in [model_path, cpu_path, guard_path]}
    original_read = audit.read; original_text = Path.read_text; original_counts = audit.terminal_counts
    trace_counts = {}; results = []

    def count_once(path, schema):
        """reuse only previously decoded unchanged traces across JSON-only mutations."""
        key = (str(path), audit.digest(path), json.dumps(schema, sort_keys=True))
        # immutable trace identity permits repeated semantic checks without decoding millions of records again.
        if key not in trace_counts:
            trace_counts[key] = original_counts(path, schema)
        return deepcopy(trace_counts[key])

    # a complete unmodified audit must pass before any rejection fixture is credited.
    with patch.object(audit, 'terminal_counts', count_once):
        baseline = audit.audit(evidence, args.model_cohort, args.cpu_cohort)
    audit.require(baseline['artifact_consistency_passed'] and not baseline['overall_pass'] and
                  not baseline['full_soc_30_minute_pass'] and not baseline['physical_80mhz_qualified'], 'baseline scope')
    results.append({'name': 'unmodified-evidence-and-honest-scope', 'passed': True})

    def reject(name, component, changes, reason, text_changes=None):
        """require the intended checker to reject one changed evidence fact."""
        changes = {Path(path).resolve(): value for path, value in changes.items()}
        text_changes = {Path(path).resolve(): value for path, value in (text_changes or {}).items()}

        def fixture_read(path):
            """overlay structured mutations while all other source and artifact checks remain active."""
            path = Path(path).resolve()
            return deepcopy(changes[path]) if path in changes else original_read(path)

        def fixture_text(path, *positional, **keywords):
            """overlay a single event ledger only for its semantic ownership fixture."""
            resolved = path.resolve()
            return text_changes[resolved] if resolved in text_changes else original_text(path, *positional, **keywords)

        observed = ''
        # fixtures exist only in memory; no source, log, image or sealed evidence file is rewritten.
        with patch.object(audit, 'read', fixture_read), patch.object(Path, 'read_text', fixture_text), \
                patch.object(audit, 'terminal_counts', count_once):
            # only a deliberate validation failure at the named gate satisfies a negative fixture.
            try:
                # model mutations exercise the full event-model admission path.
                if component == 'model':
                    audit.model_audit(evidence, args.model_cohort)
                # guard mutations preserve source and standalone mapping checks.
                elif component == 'guard':
                    audit.guard_audit(evidence)
                # CPU mutations retain all unmodified trace, firmware and event checks.
                else:
                    audit.cpu_audit(evidence, args.cpu_cohort, baseline['model'], baseline['guard'])
            # unrelated exceptions remain test failures rather than successful detections.
            except ValueError as error:
                observed = str(error)
        audit.require(reason in observed, name + ': wrong rejection: ' + observed)
        results.append({'name': name, 'passed': True, 'detected': observed})

    def model_mutation(name, mutate, reason, case_name=None):
        """apply matching summary/result mutations so semantic checks cannot hide behind duplication."""
        report = deepcopy(originals[model_path]); changes = {model_path: report}
        # case-level observations are mirrored into their attributed result to exercise deeper checks.
        if case_name:
            case = next(row for row in report['cases'] if row['name'] == case_name)
            mutate(case)
            # detector cases have no successful observation result to mirror.
            if 'observed' in case:
                changes[evidence / args.model_cohort / case_name / 'result.json'] = case['observed']
        # campaign mutations change only the top-level report.
        else:
            mutate(report)
        reject(name, 'model', changes, reason)

    model_mutation('changed-source-hash', lambda s: s['source_sha256'].__setitem__('microcontroller/synthetic/stress.cpp', '0' * 64), 'changed source:')
    model_mutation('omitted-source', lambda s: s['source_sha256'].pop('microcontroller/synthetic/stress.cpp'), 'model source inventory')
    model_mutation('duplicate-model-case', lambda s: s['cases'].__setitem__(-1, deepcopy(s['cases'][0])), 'model case coverage')
    model_mutation('false-physical-claim', lambda s: s.__setitem__('hardware_tested', True), 'model scope')
    model_mutation('false-full-RTL-duration-claim', lambda s: s.__setitem__('full_soc_30_minute_pass', True), 'model scope')
    model_mutation('changed-log-hash', lambda s: s['artifact_sha256'].__setitem__('run.log', '0' * 64), 'changed artifact:', 'host100-0')
    model_mutation('empty-artifact-inventory', lambda s: s.__setitem__('artifact_sha256', {}), 'model case failed:', 'host100-0')
    model_mutation('wrong-detector-reason', lambda s: s.__setitem__('expected_failure', 'segmentation-fault'), 'wrong detector reason', 'detector-duplicate-ack')
    model_mutation('shortened-endurance', lambda s: s.__setitem__('simulated_seconds', 1799), 'case duration invocation', 'endurance-1800s')
    model_mutation('endurance-reclassified-as-containment', lambda s: (s['observed'].update(
        {'scenario': 'cpu-reset', 'stopped': True, 'stop_reason': 'cpu-reset'}), s.__setitem__('healthy_service_pass', False)),
        'model scenario identity', 'endurance-1800s')
    model_mutation('reserve-rejection-falsely-admitted', lambda s: s['observed'].__setitem__('admitted', True),
        'containment classification', 'reserve-rejected')
    model_mutation('reserve-rejection-wrong-stop-reason', lambda s: s['observed'].__setitem__('stop_reason', 'cpu-reset'),
        'containment classification', 'reserve-rejected')
    model_mutation('named-seed-uses-other-invocation', lambda s: (s.__setitem__('seed', 0), s['command'].__setitem__(6, '0')),
        'model seed identity', 'host100-305419896')
    model_mutation('named-seed-uses-other-phase', lambda s: s['observed'].__setitem__('phase_seed_mod160', 0),
        'model seed phase', 'host100-305419896')
    model_mutation('detector-wrong-injected-operation', lambda s: s['command'].__setitem__(3, 'wrong-sample'),
        'detector scenario invocation', 'detector-duplicate-ack')
    model_mutation('lost-frame-unaccounted', lambda s: s['observed'].__setitem__('generated_frames', 90000001), 'frame loss accounting', 'endurance-1800s')
    model_mutation('wrong-raw-byte-count', lambda s: s['observed'].__setitem__('raw_bytes', 4342500031), 'ledger totals', 'endurance-1800s')
    model_mutation('capture-FIFO-overrun', lambda s: s['observed'].__setitem__('peak_queued_capture_bytes_including_metadata', 253), 'capture FIFO capacity', 'host100-0')
    model_mutation('restore-only-24-instead-of-baseline', lambda s: s['observed']['stalls'][1].__setitem__('free_at_onset', 24), 'actual stall baseline', 'endurance-1800s')
    model_mutation('late-reserve-restoration', lambda s: s['observed']['stalls'][0].__setitem__('restored', 16800001), 'stall recovery deadline', 'host100-0')
    model_mutation('missing-source-empty-boundary', lambda s: s['observed']['stalls'][0].__setitem__('eligible_source_empty_tick', 0), 'eligible-source-empty attribution', 'host100-0')
    model_mutation('premature-source-empty-boundary', lambda s: s['observed']['stalls'][0].__setitem__('eligible_source_empty_tick', 8080001), 'source-empty ledger reconstruction', 'host100-0')
    model_mutation('uncertain-transaction-replayed', lambda s: s['observed'].__setitem__('transaction_replays', 1), 'containment replay/trigger', 'memory-response-lost')
    model_mutation('error-with-unreported-effect', lambda s: s['observed'].__setitem__('fault_request_effects', 1), 'no-effect error response', 'memory-no-effect-error')
    host_case = next(row for row in originals[model_path]['cases'] if row['name'] == 'host100-0')
    ledger = audit.ledger_audit(evidence / args.model_cohort / 'host100-0', host_case)
    ledger['release_bytes'] = [0] * len(ledger['release_bytes']); observed = ''
    # unchanged ACK times preserve occupancy while missing delivered bytes violate the service envelope.
    try:
        audit.stall_audit(host_case['observed'], ledger)
    # this fixture must reach the byte-rate check rather than fail an unrelated capacity check.
    except ValueError as error:
        observed = str(error)
    audit.require(observed == 'backlogged 5 MB/s service curve', 'byte service rejection')
    results.append({'name': 'missing-host-byte-service', 'passed': True, 'detected': observed})
    report = deepcopy(originals[guard_path]); report['cases'] = 21
    reject('missing-guard-case', 'guard', {guard_path: report}, 'guard campaign')
    report = deepcopy(originals[cpu_path]); report['runs'][1] = deepcopy(report['runs'][0])
    reject('duplicate-CPU-seed', 'CPU', {cpu_path: report}, 'CPU seed/reset coverage')
    report = deepcopy(originals[cpu_path]); report['hardware_tested'] = True
    reject('CPU-physical-scope-inflation', 'CPU', {cpu_path: report}, 'CPU campaign scope')
    provenance_path = evidence / args.cpu_cohort / 'provenance.json'
    provenance = original_read(provenance_path); provenance['supplemental_dependency_source_sha256'] = {}
    reject('missing-ISA-oracle-provenance', 'CPU', {provenance_path: provenance}, 'CPU supplemental dependency inventory')
    replay_path = evidence / args.cpu_cohort / '1/replay.json'
    replay = original_read(replay_path); replay['inputs_sha256'] = {}
    reject('empty-replay-inputs', 'CPU', {replay_path: replay}, 'CPU replay input inventory')
    replay = original_read(replay_path); replay['counts']['records'] += 1
    reject('forged-retirement-count', 'CPU', {replay_path: replay}, 'CPU trace count attribution')
    report = deepcopy(originals[cpu_path]); report['runs'][0]['trace_sha256'] = '0' * 64
    reject('changed-retirement-artifact', 'CPU', {cpu_path: report}, 'changed artifact:')
    schema_path = evidence / args.cpu_cohort / 'trace-schema.json'
    schema = original_read(schema_path); schema['fields']['packet.raw']['lsb'] += 1
    reject('altered-trace-layout', 'CPU', {schema_path: schema}, 'CPU packed trace layout')
    contract_path = evidence / args.cpu_cohort / 'contract.json'
    contract = original_read(contract_path); contract['observed_max_clocks']['DSP'] -= 1
    reject('understated-DSP-maximum', 'CPU', {contract_path: contract}, 'CPU contract measurement attribution')
    report = deepcopy(originals[cpu_path]); report['runs'][2]['metrics']['active_reset_observed'] = 0
    reject('missing-active-reset', 'CPU', {cpu_path: report,
        evidence / args.cpu_cohort / 'active-reset/result.json': report['runs'][2]['metrics']}, 'CPU workload coverage')
    events_path = evidence / args.cpu_cohort / 'active-reset/events.jsonl'
    events = [json.loads(line) for line in events_path.read_text().splitlines()]
    next(row for row in events if row['event'] == 'active-reset-observed')['shared_owner'] = 0
    reject('reset-without-exposed-owner', 'CPU', {}, 'CPU active reset ownership',
           {events_path: '\n'.join(json.dumps(row) for row in events) + '\n'})
    # malformed compressed bytes exercise the real decoder outside the immutable-trace cache.
    with tempfile.TemporaryDirectory(prefix='drg5-auditor-trace-') as temporary:
        path = Path(temporary) / 'truncated.bin.gz'; path.write_bytes(gzip.compress(bytes(95)))
        observed = ''
        # a short terminal must fail framing instead of accepting a partial successful prefix.
        try:
            original_counts(path, original_read(evidence / args.cpu_cohort / 'trace-schema.json'))
        # only the explicit framing rejection credits this malformed-byte fixture.
        except ValueError as error:
            observed = str(error)
        audit.require(observed == 'CPU trace framing/count', 'truncated terminal rejection')
        results.append({'name': 'truncated-terminal-bytes', 'passed': True, 'detected': observed})
    report = {'schema': 'DRG5-SYNTHETIC-AUDITOR-TEST-1', 'status': 'pass', 'cases': len(results),
              'negative_cases': len(results) - 1, 'results': results,
              'source_sha256': {str(path.relative_to(ROOT)): audit.digest(path) for path in [AUDITOR, Path(__file__).resolve()]},
              'input_sha256': baseline['input_sha256'],
              'scope': 'actual positive admission plus in-memory metadata/event mutations; unchanged trace bytes decoded once per identity; one real truncated gzip fixture'}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    audit.require(not args.output.exists(), 'output already exists')
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print('SYNTHETIC_AUDITOR_TEST_PASS cases=' + str(len(results)))


# imports neither execute audits nor modify campaign evidence.
if __name__ == '__main__':
    main()

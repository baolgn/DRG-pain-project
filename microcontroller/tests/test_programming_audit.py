#!/usr/bin/env python3
"""prove the final artifact auditor rejects inconsistent qualification records."""
import argparse
from copy import deepcopy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('programming_audit', ROOT / 'microcontroller/programming/audit_programming.py')
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def main():
    """mutate in-memory records while leaving all campaign evidence untouched."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); evidence = args.evidence.resolve()
    baseline = AUDIT.audit(evidence)
    assert baseline['artifact_consistency_passed'] and baseline['hardware_unverified'] and not baseline['overall_pass']
    cases = [{'case': 'unaltered-campaign-remains-hardware-unverified', 'passed': True}]
    original_read = AUDIT.read

    def reject(name, mutations, reason):
        """require a specific rejection after replacing selected structured reads."""
        def changed(path):
            """copy records before changing them so fixtures remain immutable."""
            record = original_read(path)
            relative = str(Path(path).relative_to(evidence))
            # untouched records retain their complete original contents.
            if relative in mutations:
                record = deepcopy(record); mutations[relative](record)
            return record
        caught = None
        # replacing the reader tests validation independently of disk corruption detection.
        with patch.object(AUDIT, 'read', changed):
            # the expected error must come from the intended gate.
            try:
                AUDIT.audit(evidence)
            # retain the exact rejecting gate for comparison.
            except ValueError as error:
                caught = str(error)
        assert caught is not None and reason in caught, (name, caught, reason)
        cases.append({'case': name, 'passed': True, 'rejection': caught})

    route = AUDIT.ROUTE + '/summary.json'
    reject('wrong-stage', {route: lambda value: value.update(stage=0)}, 'route profile')
    reject('wrong-clock', {route: lambda value: value.update(clock_mhz=80)}, 'route profile')
    reject('wrong-package', {route: lambda value: value.update(target='LFE5U-85F-6BG256C')}, 'exact target')
    reject('false-hardware-pass', {route: lambda value: value.update(hardware_tested=True)}, 'route scope')
    reject('changed-source', {route: lambda value: value['source_sha256'].update(
        {'microcontroller/rtl/drg5_spi_boot.sv': '0' * 64})}, 'changed source')

    def failed_timing(record):
        """make the actual report fail while keeping its summary consistent."""
        next(iter(record['fmax'].values()))['achieved'] = 20

    reject('guarded-timing-failure', {route: lambda value: failed_timing(value['routing']),
        AUDIT.ROUTE + '/route.json': failed_timing}, 'guarded timing failed')

    def embed_application(record):
        """insert code into a mapped IRAM initialization word."""
        cells = record['modules']['drg5_ulx3s_programmable']['cells']
        cell = next(cell for name, cell in cells.items() if 'fabric.iram.' in name and cell['type'] == 'DP16KD')
        cell['parameters']['INITVAL_00'] = '1' + cell['parameters']['INITVAL_00'][1:]

    reject('embedded-application', {AUDIT.ROUTE + '/mapped.json': embed_application}, 'embedded IRAM application')
    reject('failed-boot-campaign', {'boot-final/summary.json': lambda value: value.update(status='failed')}, 'boot campaign')
    reject('missing-image-check', {'image-final-r2/summary.json': lambda value: value.update(checks=72958)}, 'image campaign')
    reject('missing-image-hashes', {'image-final-r2/summary.json': lambda value: value.update(artifacts={})}, 'image artifact coverage')
    reject('missing-recovery-run', {'integration-final/summary.json': lambda value: value['runs'].pop()}, 'integration coverage')
    reject('duplicated-seed-run', {'integration-final/summary.json': lambda value: value['runs'].__setitem__(1,
        deepcopy(value['runs'][0]))}, 'recovery seed coverage')
    reject('changed-trace', {'integration-final/summary.json': lambda value: value['runs'][0].update(trace_sha256='0' * 64)}, 'trace hash')

    def disable_rom_guard(record):
        """remove the specific alternate-ROM rejection without changing the pass count."""
        next(case for case in record['cases'] if case['name'] == 'self-consistent-alternate-ROM-rejected')['error_detected'] = None

    reject('missing-canonical-ROM-rejection', {'host-tool-service-r5/summary.json': disable_rom_guard}, 'host canonical ROM guard')
    reject('duplicated-host-fixture', {'host-tool-service-r5/summary.json': lambda value: value['cases'].__setitem__(1,
        deepcopy(value['cases'][0]))}, 'host fixture uniqueness')
    reject('missing-package-hash', {'golden-package-final/package.json': lambda value: value['artifacts'].pop('bank.bin')},
        'package artifact coverage')

    def disable_profile_guard(record):
        """remove a clock-profile rejection while preserving the summary count."""
        next(case for case in record['cases'] if case['name'] == 'missing-clock-guard-rejected')['error_detected'] = None

    reject('missing-profile-rejection', {'host-tool-service-r5/summary.json': disable_profile_guard}, 'host fixed-profile guards')
    reject('plan-claims-execution', {'plans-final-r2/config-sram/operation.json': lambda value: value.update(executed=True)}, 'unexecuted plan')
    reject('discovery-claims-programming', {'hardware/discovery.json': lambda value: value.update(configuration_write_attempted=True)}, 'hardware evidence scope')
    data = (evidence / 'application-package-final/bank.bin').read_bytes()
    # independent bank validation must reject both damaged payloads and missing commit markers.
    for name, offset, reason in [('damaged-payload', 273, 'payload CRC'), ('damaged-commit', len(data) - 1, 'bank commit')]:
        damaged = bytearray(data); damaged[offset] ^= 1; caught = None
        # these mutations exercise byte-level validation without relying on package hashes.
        try:
            AUDIT.bank(bytes(damaged), 2)
        # preserve byte-validation failures independently of file hashes.
        except ValueError as error:
            caught = str(error)
        assert caught == reason, (name, caught)
        cases.append({'case': name, 'passed': True, 'rejection': caught})
    result = {'schema': 'DRG5-PROGRAMMING-AUDIT-TEST-1', 'status': 'passed', 'count': len(cases), 'cases': cases,
        'source_sha256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in [Path(__file__).resolve(), ROOT / 'microcontroller/programming/audit_programming.py']},
        'scope': 'read-only campaign audit and in-memory negative fixtures; no physical hardware qualification'}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print('PROGRAMMING_AUDIT_TEST_PASS cases=' + str(len(cases)))


# importing the test module neither modifies evidence nor contacts a device.
if __name__ == '__main__':
    main()

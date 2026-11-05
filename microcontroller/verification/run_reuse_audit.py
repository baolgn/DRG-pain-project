#!/usr/bin/env python3
"""revalidate immutable component evidence without claiming a new execution."""
import hashlib
import json
from pathlib import Path


# exact sources and evidence bytes are independent attribution requirements.
def digest(path):
    """hash a complete existing file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# older unit records omit status but preserve checked tool results and failure detectors.
def main():
    """retain current-source matches and fail any changed historical archive."""
    root = Path(__file__).resolve().parents[2]
    out = root / 'microcontroller/verification/evidence/verification-2026-11-04/reuse'
    out.mkdir(parents=True, exist_ok=True)
    names = [
        'microcontroller/verification/evidence/datapath-2026-11-04/summary.json',
        'microcontroller/tests/evidence/decompress-2026-11-04/summary.json',
        'microcontroller/tests/evidence/forward-2026-11-04/summary.json',
        'microcontroller/tests/evidence/lsu-2026-11-04/summary.json',
        'microcontroller/tests/evidence/muldiv-unit-2026-11-04/summary.json',
        'microcontroller/verification/evidence/fetch-2026-11-04/formal-summary.json',
        'microcontroller/tests/evidence/debug-core-2026-11-04/summary.json',
        'microcontroller/tests/evidence/debug-module-2026-11-04/summary.json',
        'microcontroller/tests/evidence/debug-system-2026-11-04/summary.json',
        'microcontroller/tests/evidence/debug-remote-2026-11-04/revisions/10-qualification/summary.json',
        'microcontroller/tests/evidence/debug-remote-2026-11-04/revisions/11-qualification/summary.json',
        'microcontroller/tests/evidence/debug-remote-2026-11-04/revisions/12-qualification/summary.json',
        'microcontroller/verification/evidence/debug-2026-11-04/compatibility/revisions/07-irq-fetch/result/summary.json',
        'microcontroller/verification/evidence/debug-2026-11-04/structure/summary.json',
    ]
    records = []; seals = {}; failures = []
    # each reused record remains linked to its original execution and scope.
    for name in names:
        path = root / name
        record = json.loads(path.read_text())
        sources = record.get('source_sha256', record.get('sources', {}))
        assert sources, 'missing source attribution: ' + name
        normalized = {}; mismatches = []
        # absolute legacy paths are normalized without resolving nonexistent files elsewhere.
        for source, expected in sources.items():
            current = Path(source)
            # relative records name files below the project root.
            if not current.is_absolute():
                current = root / current
            relative = str(current.relative_to(root))
            normalized[relative] = expected
            actual = digest(current) if current.is_file() else None
            # retain the complete mismatch instead of discarding a failed attribution.
            if actual != expected:
                mismatches.append({'source': relative, 'expected': expected, 'actual': actual})
        archive = next(parent for parent in path.parents if (parent / 'SHA256SUMS').is_file())
        key = str(archive.relative_to(root))
        # each sealed archive is checked once even when several seed records use it.
        if key not in seals:
            checked = 0; broken = []
            # hashes cover unsuccessful attempts too; retaining them cannot make them passes.
            for row in (archive / 'SHA256SUMS').read_text().splitlines():
                expected, filename = row.split(None, 1)
                target = archive / filename.removeprefix('*')
                actual = digest(target) if target.is_file() else None
                checked += 1
                # a missing or changed artifact invalidates the whole archive attribution.
                if actual != expected:
                    broken.append(filename)
            seals[key] = {'files': checked, 'seal_sha256': digest(archive / 'SHA256SUMS'), 'mismatches': broken}
        passed = not mismatches and not seals[key]['mismatches'] and record.get('status', 'passed') == 'passed'
        records.append({'record': name, 'record_sha256': digest(path), 'archive': key,
                        'status': 'reused_exact_sources' if passed else 'rejected',
                        'source_sha256': normalized, 'source_mismatches': mismatches,
                        'scope': record.get('scope'), 'limits': record.get('limits', []),
                        'new_execution': False})
        # changed inputs cannot be represented as current-source evidence.
        if not passed:
            failures.append(name)
    result = {'status': 'passed' if not failures else 'failed',
              'scope': 'historical results revalidated by exact source and archive hashes; no new simulation or proof',
              'records': records, 'seals': seals, 'failures': failures,
              'source_sha256': {str(Path(__file__).relative_to(root)): digest(Path(__file__))}}
    (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    assert not failures, 'historical evidence cannot be reused: ' + repr(failures)
    print(f'REUSE_AUDIT_PASS records={len(records)} archives={len(seals)}')


# importing the audit does not write or execute anything.
if __name__ == '__main__':
    main()

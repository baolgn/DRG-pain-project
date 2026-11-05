#!/usr/bin/env python3
"""exercise fail-closed bootstrap admission without downloads or tool execution."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile


def main():
    """preserve exact negative fixtures, errors and unchanged marker files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    # existing test output may contain evidence from a different source revision.
    if output.exists():
        raise SystemExit('use a new --output directory')
    output.mkdir(parents=True)
    driver = Path(__file__).with_name('bootstrap_tools.py')
    cases = []
    # malformed inputs must fail before a dependency installer or network call can run.
    for name in ['existing-prefix', 'wrong-cache-hash', 'missing-cache',
                 'escaping-filename', 'escaping-target', 'escaping-tar-member']:
        case = output / name
        case.mkdir()
        cache = case / 'input-cache'
        cache.mkdir()
        prefix = case / 'install'
        payload = b'tool fixture\n'
        # a verified archive still cannot write outside its installation destination.
        if name == 'escaping-tar-member':
            buffer = io.BytesIO()
            # package one escaping member so the real extraction filter rejects it.
            with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
                info = tarfile.TarInfo('../escaped')
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
            payload = buffer.getvalue()
        (cache / 'fixture.tgz').write_bytes(payload)
        item = {'file': 'fixture.tgz', 'url': 'https://example.invalid/fixture.tgz',
                'sha256': hashlib.sha256(payload).hexdigest(), 'kind': 'tar', 'target': '.'}
        expected = {'existing-prefix': 'nonexistent --root', 'wrong-cache-hash': 'cache checksum mismatch',
                    'missing-cache': 'missing cached artifact', 'escaping-filename': 'invalid artifact name',
                    'escaping-target': 'target escapes', 'escaping-tar-member': 'outside the destination'}[name]
        # preserve an existing prefix and every byte of its sentinel.
        if name == 'existing-prefix':
            prefix.mkdir()
            (prefix / 'sentinel').write_bytes(b'keep\n')
        # a cache mismatch must not fall through to a network replacement.
        elif name == 'wrong-cache-hash':
            item['sha256'] = '0' * 64
        # offline mode must reject an absent input.
        elif name == 'missing-cache':
            (cache / 'fixture.tgz').unlink()
        # file and destination traversal have independent guards.
        elif name == 'escaping-filename':
            item['file'] = '../fixture.tgz'
        # target validation occurs before archive extraction.
        elif name == 'escaping-target':
            item['target'] = '..'
        manifest = case / 'dependencies.json'
        manifest.write_text(json.dumps({'downloads': [item]}) + '\n')
        command = [sys.executable, str(driver), '--root', str(prefix), '--cache', str(cache), '--manifest', str(manifest)]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (case / 'run.log').write_text(result.stdout)
        assert result.returncode != 0 and expected in result.stdout, name
        assert not (case / 'escaped').exists(), name
        # refusal of an existing prefix must not create a replacement report.
        if name == 'existing-prefix':
            assert (prefix / 'sentinel').read_bytes() == b'keep\n'
            assert not (prefix / 'bootstrap.json').exists()
        cases.append({'name': name, 'passed': True, 'exit_code': result.returncode,
                      'expected_detector': expected, 'command': command,
                      'log_sha256': hashlib.sha256(result.stdout.encode()).hexdigest()})
    summary = {'status': 'pass', 'cases': cases, 'network_enabled': False,
               'source_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in [driver, Path(__file__)]}}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('BOOTSTRAP_NEGATIVE_PASS cases=' + str(len(cases)))


# importing the fixtures performs no setup or hardware action.
if __name__ == '__main__':
    main()

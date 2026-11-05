#!/usr/bin/env python3
"""check deterministic packaging and reject damaged or unsafe handoff archives."""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('package_release', HERE / 'package_release.py')
package = importlib.util.module_from_spec(spec); spec.loader.exec_module(package)


def modified(source, target, mutation):
    """change actual archive members while retaining the ordinary verifier."""
    # each mutation creates a separate gzip stream with deliberate member changes.
    with tarfile.open(source, 'r:gz') as before, tarfile.open(target, 'w:gz') as after:
        # regular positive-fixture members supply complete source payloads.
        for member in before:
            content = before.extractfile(member).read()
            entry = mutation(member, content)
            # omission fixtures intentionally drop one declared member.
            if entry is None:
                continue
            info, data = entry; after.addfile(info, io.BytesIO(data))


def main():
    """retain each admitted or rejected package fixture and bind tested sources."""
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); require = package.require
    require(not args.output.exists(), 'test output must not exist'); results = []

    def rejected(name, action):
        """accept only the expected validation exception as a detector result."""
        # an ordinary successful return means the negative fixture escaped detection.
        try:
            action()
        # validation failures are distinct from infrastructure exceptions.
        except ValueError as error:
            results.append({'name': name, 'passed': True, 'detected': str(error)})
        # unexpected success fails the campaign immediately.
        else:
            raise AssertionError('undetected package defect: ' + name)

    # private fixtures never modify the implementation or retained evidence.
    with tempfile.TemporaryDirectory(prefix='drg5-package-test-') as temporary:
        base = Path(temporary); root = base / 'source'
        (root / 'microcontroller/rtl').mkdir(parents=True); (root / 'docs/release').mkdir(parents=True)
        (root / 'microcontroller/rtl/core.sv').write_text('/* fixture */\nmodule core; endmodule\n')
        (root / 'microcontroller/run.sh').write_text('#!/bin/sh\nexit 0\n'); (root / 'microcontroller/run.sh').chmod(0o755)
        (root / 'docs/release/README.md').write_text('fixture\n')
        (root / 'microcontroller/__pycache__').mkdir(); (root / 'microcontroller/__pycache__/secret.pyc').write_bytes(b'cache')
        (root / 'microcontroller/verification/evidence/fixed/__pycache__').mkdir(parents=True)
        (root / 'microcontroller/verification/evidence/fixed/__pycache__/sealed.pyc').write_bytes(b'retained historical bytes')
        first = package.build(root, base / 'first'); second = package.build(root, base / 'second')
        require(first['sha256'] == second['sha256'], 'archive is not deterministic')
        results.append({'name': 'identical-input-identical-archive', 'passed': True})
        archive = base / 'first' / first['archive']; extracted = base / 'extracted'
        check = package.verify(archive, extracted); require(check['files'] == 4, 'cache or source inventory mismatch')
        require(package.digest(extracted / package.PREFIX / 'microcontroller/rtl/core.sv') == package.digest(root / 'microcontroller/rtl/core.sv'), 'extraction differs')
        require((extracted / package.PREFIX / 'microcontroller/run.sh').stat().st_mode & 0o777 == 0o755, 'wrapper mode differs')
        require((extracted / package.PREFIX / 'microcontroller/verification/evidence/fixed/__pycache__/sealed.pyc').read_bytes() == b'retained historical bytes', 'historical seal input omitted')
        results.append({'name': 'roundtrip-bytes-modes-cache-exclusion', 'passed': True})
        rejected('existing-build-output', lambda: package.build(root, base / 'first'))
        rejected('recursive-output', lambda: package.build(root, root / 'docs/output'))
        rejected('existing-extraction', lambda: package.verify(archive, extracted))
        (root / 'docs/outside').symlink_to(base / 'first' / first['archive'])
        rejected('source-symlink', lambda: package.inventory(root)); (root / 'docs/outside').unlink()
        outside = base / 'outside'; outside.mkdir(); (outside / 'outside.txt').write_text('not a project input')
        linked = base / 'linked-source'; linked.mkdir(); (linked / 'microcontroller').mkdir(); (linked / 'docs').symlink_to(outside)
        rejected('top-tree-symlink', lambda: package.inventory(linked))
        target_name = package.PREFIX + '/microcontroller/rtl/core.sv'

        def mutation(kind):
            """alter one ordinary member or the package's claimed scope."""
            def change(member, data):
                """apply one concrete defect to its selected archive member."""
                # false scope is rejected even when source bytes remain intact.
                if kind == 'false-system-pass' and member.name.endswith('/.release/manifest.json'):
                    value = json.loads(data); value['overall_system_pass'] = True; data = json.dumps(value).encode(); member.size = len(data)
                # only the selected source entry is damaged by other mutations.
                if member.name == target_name:
                    # omission preserves its required manifest entry.
                    if kind == 'missing-member':
                        return None
                    # byte corruption preserves size and the original expected hash.
                    if kind == 'changed-byte':
                        data = b'!' + data[1:]
                    # traversal cannot escape the fresh extraction root.
                    if kind == 'traversal':
                        member.name = package.PREFIX + '/../escaped'
                    # absolute names cannot bypass the required prefix.
                    if kind == 'absolute-path':
                        member.name = '/tmp/drg5-escaped'
                    # a link cannot substitute for a declared regular source file.
                    if kind == 'archive-symlink':
                        member.type = tarfile.SYMTYPE; member.linkname = '/tmp'; member.size = 0; data = b''
                    # executable privilege bits are outside normalized archive permissions.
                    if kind == 'unsafe-mode':
                        member.mode = 0o4755
                return member, data
            return change

        # these fixtures exercise real gzip/tar decoding and ordinary integrity checks.
        for name in ['changed-byte', 'missing-member', 'traversal', 'absolute-path', 'archive-symlink', 'unsafe-mode', 'false-system-pass']:
            damaged = base / (name + '.tar.gz'); modified(archive, damaged, mutation(name))
            rejected(name, lambda damaged=damaged: package.verify(damaged, None))

        def reserved_metadata(member, data):
            """forge a self-listed metadata hash and its matching checksum line."""
            # the manifest must not list metadata as an ordinary checked source file.
            if member.name.endswith('/.release/manifest.json'):
                value = json.loads(data)
                value['files']['.release/manifest.json'] = {'sha256': '0' * 64, 'bytes': 1, 'mode': 0o644}
                data = json.dumps(value).encode(); member.size = len(data)
            # the mirrored checksum defeats a consistency-only metadata check.
            if member.name.endswith('/.release/SHA256SUMS'):
                data = ('0' * 64 + '  .release/manifest.json\n').encode() + data; member.size = len(data)
            return member, data

        damaged = base / 'reserved-metadata.tar.gz'; modified(archive, damaged, reserved_metadata)
        rejected('self-listed-metadata-hash', lambda: package.verify(damaged, None))
        # direct inventory fixtures check malformed type and canonical-path boundaries.
        for name, key, row in [
                ('inventory-parent', 'docs/../escape', {'sha256': '0' * 64, 'bytes': 1, 'mode': 0o644}),
                ('inventory-alias', 'docs//file', {'sha256': '0' * 64, 'bytes': 1, 'mode': 0o644}),
                ('inventory-boolean-size', 'docs/file', {'sha256': '0' * 64, 'bytes': True, 'mode': 0o644}),
                ('inventory-invalid-digest', 'docs/file', {'sha256': 'not-a-hash', 'bytes': 1, 'mode': 0o644})]:
            rejected(name, lambda key=key, row=row: package.validate_inventory({key: row}))
    args.output.mkdir(parents=True)
    report = {'schema': 'DRG5-PACKAGE-TEST-1', 'status': 'pass', 'cases': len(results), 'results': results,
              'source_sha256': {str(p.relative_to(package.ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [HERE / 'package_release.py', Path(__file__).resolve()]}}
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print('RELEASE_PACKAGE_TEST_PASS cases=' + str(len(results)))


# imports only define fixtures; explicit execution owns temporary files.
if __name__ == '__main__':
    main()

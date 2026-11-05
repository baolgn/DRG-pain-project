#!/usr/bin/env python3
"""package a fixed source/evidence tree and verify every extracted byte."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PREFIX = 'drg5-r1-engineering'
TREES = ('microcontroller', 'docs')
EXCLUDED = {'__pycache__'}


def digest(path):
    """hash large evidence without retaining it in memory."""
    value = hashlib.sha256()
    # chunked reads include every byte of retained evidence.
    with path.open('rb') as stream:
        # EOF terminates the digest without an extra allocation.
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def require(condition, message):
    """reject ambiguous or unsafe release inputs."""
    # validation failures never become a passing package report.
    if not condition:
        raise ValueError(message)


def inventory(root):
    """collect regular project files and their normalized archive permissions."""
    records = {}
    # only these public project trees enter the handoff archive.
    for tree in TREES:
        folder = root / tree
        require(not folder.is_symlink(), 'symlink project tree: ' + tree)
        require(folder.is_dir(), 'missing project tree: ' + tree)
        # sorted paths produce deterministic archive order.
        for path in sorted(folder.rglob('*')):
            relative = path.relative_to(root)
            # caches and private configuration are never release inputs.
            if any(part.startswith('.') for part in relative.parts) or (
                    '__pycache__' in relative.parts and 'evidence' not in relative.parts):
                continue
            require(not path.is_symlink(), 'symlink excluded: ' + str(relative))
            # directories are implied by file paths in the portable archive.
            if not path.is_file():
                continue
            name = relative.as_posix()
            require('\n' not in name and '\r' not in name, 'unsupported filename')
            info = path.stat()
            records[name] = {'sha256': digest(path), 'bytes': info.st_size,
                             'mode': 0o755 if info.st_mode & 0o111 else 0o644}
    require(bool(records), 'empty release inventory')
    return records


def validate_inventory(records):
    """keep declared files canonical, typed and outside reserved metadata."""
    require(isinstance(records, dict) and bool(records), 'empty or malformed manifest')
    # reserved metadata cannot claim an unchecked source-file digest.
    for name, row in records.items():
        require(isinstance(name, str), 'nontext inventory path')
        path = PurePosixPath(name)
        require(name == path.as_posix() and not path.is_absolute() and len(path.parts) > 1 and
                path.parts[0] in TREES and '..' not in path.parts and '\\' not in name and
                '\n' not in name and '\r' not in name, 'unsafe or reserved inventory path')
        require(isinstance(row, dict) and set(row) == {'sha256', 'bytes', 'mode'}, 'malformed inventory record')
        require(type(row['bytes']) is int and row['bytes'] >= 0, 'invalid inventory size')
        require(type(row['mode']) is int and row['mode'] in {0o644, 0o755}, 'invalid inventory mode')
        require(isinstance(row['sha256'], str) and re.fullmatch('[0-9a-f]{64}', row['sha256']) is not None,
                'invalid inventory digest')


def add_bytes(archive, name, payload):
    """store deterministic metadata alongside the source inventory."""
    info = tarfile.TarInfo(PREFIX + '/' + name)
    info.size = len(payload); info.mode = 0o644; info.mtime = 0
    archive.addfile(info, io.BytesIO(payload))


def build(root, output):
    """freeze source and evidence without changing the implementation."""
    root = root.resolve(); output = output.resolve()
    require(not output.exists(), 'output must not exist')
    # the destination must not recursively become an archive input.
    for tree in TREES:
        require(not output.is_relative_to(root / tree), 'output overlaps packaged tree')
    records = inventory(root)
    validate_inventory(records)
    output.mkdir(parents=True)
    manifest = {'schema': 'DRG5-RELEASE-PACKAGE-1', 'prefix': PREFIX,
        'overall_system_pass': False, 'trees': list(TREES), 'files': records,
        'exclusions': ['tool installation directories', 'vendor datasheet PDFs outside docs',
                       'private configuration', 'active Python caches; historical evidence caches retained', 'package output directory'],
        'license_scope': 'dependency notices retained; project license is not assigned by this package'}
    payload = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    checksums = ''.join(row['sha256'] + '  ' + name + '\n' for name, row in sorted(records.items())).encode()
    target = output / (PREFIX + '.tar.gz')
    # zero timestamps, normalized ownership and sorted members remove host metadata variation.
    with target.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=6) as compressed:
        # regular files only prevent extraction through links or devices.
        with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
            add_bytes(archive, '.release/manifest.json', payload)
            add_bytes(archive, '.release/SHA256SUMS', checksums)
            # a changed input invalidates the archive instead of producing mixed source versions.
            for name, row in sorted(records.items()):
                path = root / name
                require(path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], 'input changed: ' + name)
                info = tarfile.TarInfo(PREFIX + '/' + name)
                info.size = row['bytes']; info.mode = row['mode']; info.mtime = 0
                # the verifier independently checks the archived stream after creation.
                with path.open('rb') as source:
                    archive.addfile(info, source)
    checked = verify(target, None)
    result = {'schema': 'DRG5-RELEASE-ARCHIVE-1', 'archive': target.name,
        'sha256': digest(target), 'bytes': target.stat().st_size,
        'source_files': len(records), 'source_bytes': sum(row['bytes'] for row in records.values()),
        'manifest_sha256': hashlib.sha256(payload).hexdigest(), 'verified': checked,
        'overall_system_pass': False}
    (output / 'artifact.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    (output / 'SHA256SUMS').write_text(result['sha256'] + '  ' + target.name + '\n')
    return result


def verify(path, extract):
    """validate member names, inventory and hashes before accepting an extraction."""
    destination = extract.resolve() if extract else None
    # an incomplete extraction remains a failed fresh directory, never an overwritten tree.
    if destination:
        require(not destination.exists(), 'extraction directory must not exist')
        destination.mkdir(parents=True)
    expected = None; seen = set(); metadata = {}; count = total = 0
    # streamed verification checks compressed bytes without trusting tar extraction helpers.
    with tarfile.open(path, mode='r|gz') as archive:
        # every member must be explicitly declared, regular and inside the fixed prefix.
        for member in archive:
            parts = PurePosixPath(member.name).parts
            require(member.isfile() and not member.issym() and not member.islnk(), 'nonregular archive member')
            require(parts and parts[0] == PREFIX and '..' not in parts and not member.name.startswith('/'), 'unsafe archive path')
            name = '/'.join(parts[1:]); require(name and name not in seen, 'duplicate or empty archive member'); seen.add(name)
            require(member.name == PREFIX + '/' + name, 'noncanonical archive path')
            stream = archive.extractfile(member); require(stream is not None, 'missing member stream')
            # metadata precedes every source file and is bound by the external archive digest.
            if name in {'.release/manifest.json', '.release/SHA256SUMS'}:
                require(member.size <= 64 * 1024 * 1024, 'oversized package metadata')
                payload = stream.read(); metadata[name] = payload
                # exactly one manifest controls the expected member inventory.
                if name == '.release/manifest.json':
                    manifest = json.loads(payload)
                    require(manifest['schema'] == 'DRG5-RELEASE-PACKAGE-1' and manifest['prefix'] == PREFIX,
                            'unsupported package schema')
                    require(manifest['overall_system_pass'] is False, 'unsupported system-pass claim')
                    require(manifest['trees'] == list(TREES), 'unsupported package trees')
                    expected = manifest['files']; validate_inventory(expected)
                # metadata is retained for ordinary checksum verification after extraction.
                if destination:
                    target = destination / member.name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(payload)
                continue
            require(expected is not None and name in expected, 'undeclared archive member')
            row = expected[name]
            require(member.size == row['bytes'] and member.mode == row['mode'] and member.mode in {0o644, 0o755}, 'member size/mode mismatch')
            value = hashlib.sha256(); size = 0; target_stream = None
            # validated relative paths stay within the newly created extraction directory.
            if destination:
                target = destination / member.name; target.parent.mkdir(parents=True, exist_ok=True); target_stream = target.open('xb')
            # close a partial member even if its digest or I/O fails.
            try:
                # source bytes are checked as they are optionally copied.
                while chunk := stream.read(1024 * 1024):
                    value.update(chunk); size += len(chunk)
                    # verification-only mode performs no filesystem writes.
                    if target_stream:
                        target_stream.write(chunk)
            # a failed extraction is retained for diagnosis and cannot be reused.
            finally:
                # only an explicitly opened destination requires closure.
                if target_stream:
                    target_stream.close()
            require(size == row['bytes'] and value.hexdigest() == row['sha256'], 'member digest mismatch: ' + name)
            # executable wrappers retain only normalized ordinary permission bits.
            if destination:
                target.chmod(row['mode'])
            count += 1; total += size
    require(expected is not None and seen == set(expected) | {'.release/manifest.json', '.release/SHA256SUMS'}, 'incomplete package inventory')
    checksums = ''.join(row['sha256'] + '  ' + name + '\n' for name, row in sorted(expected.items())).encode()
    require(metadata['.release/SHA256SUMS'] == checksums, 'checksum manifest disagreement')
    return {'files': count, 'bytes': total, 'all_member_hashes_pass': True,
            'extracted': destination is not None, 'overall_system_pass': False}


def main():
    """build or verify an explicit handoff archive without contacting hardware."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    create = sub.add_parser('build'); create.add_argument('--root', type=Path, default=ROOT)
    create.add_argument('--output', type=Path, required=True)
    check = sub.add_parser('verify'); check.add_argument('--archive', type=Path, required=True)
    check.add_argument('--extract', type=Path)
    args = parser.parse_args()
    result = build(args.root, args.output) if args.operation == 'build' else verify(args.archive, args.extract)
    print(json.dumps(result, indent=2, sort_keys=True))


# imports never package files or mutate an evidence directory.
if __name__ == '__main__':
    main()

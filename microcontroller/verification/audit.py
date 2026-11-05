#!/usr/bin/env python3
"""audit requirement evidence without converting open release gates into passes."""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote


# source and artifact identity use the same complete-byte hash.
def digest(path):
    """return a file digest without normalizing its contents."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# a reviewed orchestration comment correction does not change executed test behavior.
def comment_delta(root, source, expected):
    """allow only the recorded, AST-identical directed-driver comment revision."""
    record = root / 'microcontroller/verification/evidence/verification-2026-11-04/directed/driver-comment-delta.json'
    # all other changed source bytes invalidate attribution.
    if source != 'microcontroller/verification/run_directed.py' or not record.is_file():
        return None
    delta = json.loads(record.read_text()); current = root / source
    # both versions must match the explicit reviewed record.
    if delta['old_sha256'] != expected or delta['current_sha256'] != digest(current):
        return None
    archived = root / 'microcontroller/verification/evidence/verification-2026-11-04/directed/revisions/01-base/sources' / source
    assert digest(archived) == expected
    assert ast.dump(ast.parse(archived.read_text()), include_attributes=False) == ast.dump(ast.parse(current.read_text()), include_attributes=False)
    return {'source': source, 'executed_sha256': expected, 'current_sha256': digest(current),
            'reason': 'three explanatory comments only; identical parsed Python AST',
            'record': str(record.relative_to(root))}


# every claim names evidence; missing runs remain explicit instead of silently disappearing.
def main():
    """check catalog references, current inputs, reused archives and local document links."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--allow-pending', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    base = root / 'microcontroller/verification/evidence/verification-2026-11-04'
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    replay_directory = base / 'execution/replay-audits' / stamp
    replay_directory.mkdir(parents=True)
    replay_path = base / 'execution/archived-replay.json'
    # retain the preceding attribution before replaying the currently published captures.
    if replay_path.is_file():
        (replay_directory / 'previous-replay.json').write_bytes(replay_path.read_bytes())
    replay_command = [sys.executable, str(root / 'microcontroller/verification/replay_archives.py')]
    replay_log = replay_directory / 'replay.log'
    # a failed replay remains an audit failure even when an older passing record still exists.
    with replay_log.open('w') as stream:
        replay_process = subprocess.run(replay_command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, check=False)
    replay_attempt = {'command': replay_command, 'exit_code': replay_process.returncode,
                      'log': str(replay_log.relative_to(root)), 'log_sha256': digest(replay_log)}
    (replay_directory / 'attempt.json').write_text(json.dumps(replay_attempt, indent=2) + '\n')
    ledger_path = root / 'microcontroller/verification/requirements.json'
    ledger = json.loads(ledger_path.read_text())
    problems = []; pending = []; records = []; annotations = []; unique = set(); tools = {}; artifacts = []
    # collection checks current captures instead of borrowing a preceding campaign's replay.
    if replay_process.returncode:
        problems.append({'reason': 'current archived replay failed', **replay_attempt})
    ids = [row['id'] for row in ledger['requirements']]
    assert len(ids) == len(set(ids)), 'duplicate requirement identity'
    # unsupported or untested behavior still needs an explicit response and coverage limit.
    for row in ledger['requirements']:
        assert row['configured_behavior'] and row['limits'] and row['release_gate'], row['id']
        assert all(key in ledger['evidence'] for key in row['evidence']), row['id']
    # independently bind each cited result to its declared inputs.
    for key, entry in ledger['evidence'].items():
        path = root / entry['path']
        # interim collection can report missing runs but never qualifies them.
        if not path.is_file():
            pending.append({'evidence': key, 'path': entry['path']})
            continue
        record = json.loads(path.read_text())
        sources = record.get('source_sha256', record.get('sources', {}))
        matched = 0; mismatches = []
        # historical-only results are retained without claiming current-source identity.
        if entry['kind'] != 'historical_only':
            # an inventory must bind its generating inputs as well as its artifact names.
            if not sources:
                problems.append({'evidence': key, 'reason': 'no declared source attribution'})
            # legacy absolute source paths must still resolve within this project.
            for source, expected in sources.items():
                current = Path(source)
                # ordinary records use workspace-relative source names.
                if not current.is_absolute():
                    current = root / entry.get('source_base', '.') / current
                relative = str(current.relative_to(root)); unique.add(relative)
                actual = digest(current) if current.is_file() else None
                # exact bytes are the normal attribution rule.
                if actual == expected:
                    matched += 1
                    continue
                explanation = comment_delta(root, relative, expected) if current.is_file() else None
                # retain the exception as annotation-only attribution, not exact source equality.
                if explanation:
                    annotations.append(dict(evidence=key, **explanation))
                # every unreviewed source edit invalidates this result's current attribution.
                else:
                    mismatches.append({'source': relative, 'expected': expected, 'actual': actual})
            problems += [{'evidence': key, 'reason': 'source mismatch', **item} for item in mismatches]
        records.append({'evidence': key, 'path': entry['path'], 'sha256': digest(path),
                        'kind': entry['kind'], 'outcome': record.get('status', 'legacy_checked_results'),
                        'source_entries': len(sources), 'exact_matches': matched, 'source_mismatches': mismatches,
                        'catalog_assembly': record.get('catalog_assembly'),
                        'source_cohorts': record.get('source_cohorts')})
        executable_hashes = record.get('tool_sha256', {}) | record.get('archive_verified_executables', {})
        # archived tool identities are checked where the runner records executable hashes.
        for name, expected in executable_hashes.items():
            tool = Path(name); actual = digest(tool) if tool.is_file() else None
            tools[name] = {'expected': expected, 'actual': actual}
            # a replaced compiler or reference executable breaks the claimed tool identity.
            if actual != expected:
                problems.append({'evidence': key, 'reason': 'tool identity changed', 'tool': name})
        # replay records bind compressed captures and their schemas independently of summaries.
        for name, expected in record.get('artifact_sha256', {}).items():
            artifact = Path(name)
            # ordinary artifact references are relative to the project root.
            if not artifact.is_absolute():
                artifact = root / artifact
            actual = digest(artifact) if artifact.is_file() else None
            artifacts.append({'evidence': key, 'artifact': name, 'matched': actual == expected})
            # a changed trace or schema invalidates its replay result.
            if actual != expected:
                problems.append({'evidence': key, 'reason': 'replay artifact changed', 'artifact': name})
        # generated-program evidence retains exact executable and reference-configuration copies.
        if entry['kind'] == 'fresh_random_reference':
            # each ISA and seed pair must retain its actual loaded image and model settings.
            for run in record['results']:
                directory = root / run['evidence']; elf = directory / 'program.elf'
                configs = list(directory.glob('sail-c*-m*.json'))
                matches = elf.is_file() and digest(elf) == run['elf_sha256'] and len(configs) == 1
                matches = matches and digest(configs[0]) == run['sail_config_sha256']
                artifacts.append({'evidence': key, 'directory': run['evidence'], 'matched': matches})
                # compiler metadata and the actual model configuration remain individually attributable.
                if not matches:
                    problems.append({'evidence': key, 'reason': 'program or model artifact mismatch', 'directory': run['evidence']})
        # architectural campaign manifests resolve their artifacts within their own archive directory.
        if entry['kind'] == 'fresh_architectural_campaign':
            checks = [(record[field], record[field + '_sha256'])
                      for field in ['inventory', 'artifact_archive', 'artifact_index']]
            checks += [(group['results'], group['results_sha256']) for group in record['executions'].values()]
            # optional original baselines and tool pins keep their independent identities.
            for field in ['historical_baseline', 'tools']:
                # a campaign may omit a separately archived baseline.
                if field in record:
                    checks.append((record[field]['path'], record[field]['sha256']))
            # relocated campaign manifests cannot silently refer to unrelated files with matching names.
            for name, expected in checks:
                artifact = path.parent / name
                actual = digest(artifact) if artifact.is_file() else None
                artifacts.append({'evidence': key, 'artifact': str(artifact.relative_to(root)), 'matched': actual == expected})
                # the manifest remains incomplete if any referenced artifact changed or disappeared.
                if actual != expected:
                    problems.append({'evidence': key, 'reason': 'architectural artifact mismatch', 'artifact': str(artifact)})
    reuse = json.loads((base / 'reuse/summary.json').read_text())
    seals = []
    # original historical seals are verified again without modifying their files.
    for name, description in reuse['seals'].items():
        archive = root / name; broken = []; count = 0
        assert digest(archive / 'SHA256SUMS') == description['seal_sha256']
        # every retained file, including a failed attempt, keeps its original identity.
        for line in (archive / 'SHA256SUMS').read_text().splitlines():
            expected, filename = line.split(None, 1)
            target = archive / filename.removeprefix('*'); count += 1
            # missing evidence is as invalid as changed evidence.
            if not target.is_file() or digest(target) != expected:
                broken.append(filename)
        seals.append({'archive': name, 'files': count, 'mismatches': broken})
        problems += [{'archive': name, 'reason': 'broken historical seal', 'file': filename} for filename in broken]
    documents = ['README.md', 'microcontroller/README.md',
                 'microcontroller/rtl/README.md', 'microcontroller/verification/README.md']
    links = 0; document_hashes = {}
    # links resolve from each document's actual directory, independent of the caller's cwd.
    for name in documents:
        path = root / name; document_hashes[name] = digest(path)
        # URLs and document-internal anchors are outside filesystem link qualification.
        for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
            target = target.strip('<>').split('#', 1)[0]
            # a qualified URL does not designate a local file.
            if not target or re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:', target):
                continue
            links += 1
            # missing local targets remain actionable findings.
            if not (path.parent / unquote(target)).resolve().exists():
                problems.append({'document': name, 'reason': 'missing link', 'target': target})
    comment_path = base / 'comment-audit.json'
    comments = json.loads(comment_path.read_text())
    # a lexical pass does not replace the documented semantic comment review.
    for field in ['unexpected_mixed_case', 'missing_sv_context', 'missing_python_context', 'missing_cpp_context']:
        problems += [{'reason': 'comment audit finding', 'field': field, 'finding': finding} for finding in comments[field]]
    # the comment result must describe the current reviewed source bytes.
    for name, expected in comments['source_sha256'].items():
        path = root / name
        # edits after comment qualification require the comment audit to be repeated.
        if not path.is_file() or digest(path) != expected:
            problems.append({'reason': 'stale comment audit', 'source': name})
    ok = not problems and (args.allow_pending or not pending)
    result = {'status': 'passed' if ok else 'failed', 'release_qualified': False,
              'scope': 'evidence attribution, requirement references, comments and local links only; underlying test outcomes retain their limits',
              'requirements': len(ids), 'ledger_sha256': digest(ledger_path), 'records': records,
              'unique_sources': len(unique), 'annotation_only_source_changes': annotations,
              'seals': seals, 'tools': tools, 'program_artifacts': artifacts,
              'archived_replay_attempt': replay_attempt,
              'document_sha256': document_hashes, 'local_links_checked': links,
              'comment_audit_sha256': digest(comment_path), 'pending': pending, 'problems': problems,
              'source_sha256': {str(Path(__file__).relative_to(root)): digest(Path(__file__))}}
    (base / 'review-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    assert ok, 'verification evidence audit has unresolved findings'
    print(f'VERIFICATION_AUDIT_PASS requirements={len(ids)} records={len(records)} pending={len(pending)} release_qualified=false')


# importing the audit cannot write evidence or invoke another tool.
if __name__ == '__main__':
    main()

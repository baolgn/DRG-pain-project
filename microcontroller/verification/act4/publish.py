#!/usr/bin/env python3
"""publish ACT4 artifacts and outcomes independently of temporary build paths."""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[3]
LOCAL = Path(__file__).resolve().parent


# hashes bind reports to the exact archived bytes.
def sha(path):
    """return an artifact fingerprint."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# canonical JSON remains directly readable beside the compressed artifacts.
def save(path, value):
    """write one structured evidence record."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


# multiple inputs may contribute distinct tests to one schedule, such as a repaired shard.
def publish(work, tests, inventory_path, output, runs):
    """retain inputs, self-checking ELFs, reference results and actual DUT verdicts."""
    output.mkdir(parents=True, exist_ok=True)
    inventory = json.loads(inventory_path.read_text())
    save(output / 'inventory.json', inventory)
    records = inventory['records']
    built = {str(Path(item['test']).with_suffix('.elf')): item
             for item in records if item['status'] == 'built'}
    archived = {}
    source_paths = set(LOCAL.glob('*.py')) | set(LOCAL.glob('*.json')) | set(LOCAL.glob('*.yaml'))
    source_paths.update(LOCAL / name for name in ['link.ld', 'rvmodel_macros.h',
                                                'drg5-act4-gcc', 'python-requirements.txt'])
    results = {}
    cohorts = {}
    # actual runner summaries preserve failed verdicts and their source fingerprints.
    for label, directories in runs.items():
        group = []
        seen = set()
        # repaired subsets may be stored separately from the original batch.
        for directory in directories:
            entries = json.loads((directory / 'results.json').read_text())
            # validate and copy each independently executed ELF record.
            for entry in entries:
                name = entry['test']
                # duplicate names or substituted binaries invalidate the schedule record.
                if name in seen or name not in built or (entry.get('elf_sha256') is not None
                                                        and entry['elf_sha256'] != built[name]['elf_sha256']):
                    raise ValueError(f'duplicate, unselected or changed ELF: {label}/{name}')
                seen.add(name)
                original = Path(entry.get('summary', directory / Path(name).with_suffix('') / 'summary.json'))
                destination = output / 'execution' / label / Path(name).with_suffix('')
                destination.mkdir(parents=True, exist_ok=True)
                # infrastructure errors remain records even when no runner summary was produced.
                if not original.exists():
                    group.append(dict(entry, status='infrastructure_error', claimed_status=entry['status'],
                                      evidence_status='missing_runner_summary'))
                    continue
                summary = json.loads(original.read_text())
                save(destination / 'summary.json', summary)
                log = original.with_name('execution.log')
                # each test keeps the complete console and terminal failure tail.
                if log.exists():
                    shutil.copyfile(log, destination / 'execution.log')
                actual = dict(entry, summary=str((destination / 'summary.json').relative_to(output)),
                              summary_sha256=sha(destination / 'summary.json'))
                console = log.read_text() if log.exists() else ''
                issues = []
                # runner summaries expose only architectural pass or failure outcomes.
                if summary.get('status') not in ['passed', 'failed']:
                    issues.append('unknown runner status')
                # batch entries cannot replace or relabel the runner's actual outcome.
                if any(entry.get(key) != summary.get(key) for key in ['status', 'elf_sha256', 'observed']):
                    issues.append('batch record differs from runner summary')
                # the summary must describe this exact ELF and schedule.
                if summary.get('elf_sha256') != built[name]['elf_sha256'] or summary.get('seed') != entry.get('seed', summary.get('seed')):
                    issues.append('runner ELF or seed differs from batch record')
                # standard schedule labels carry a checked seed rather than a display-only name.
                if label.startswith('seed') and label[4:].isdigit() and summary.get('seed') != int(label[4:]):
                    issues.append('schedule label differs from runner seed')
                markers = [line.removeprefix('ARCH_EXEC_PASS ') for line in console.splitlines()
                           if line.startswith('ARCH_EXEC_PASS ')]
                # successful execution requires the logged marker and matching independent observations.
                if summary.get('status') == 'passed':
                    # a clean exit and exactly one marker are both required.
                    if summary.get('exit_code') != 0 or len(markers) != 1 or 'ARCH_EXEC_FAILURE' in console:
                        issues.append('success marker or exit status is inconsistent')
                    # compare the logged accounting record only when one marker exists.
                    elif json.loads(markers[0]) != summary.get('observed'):
                        issues.append('success marker observations differ from summary')
                # every verdict needs its complete log, including failing runs.
                if not log.exists() or not console:
                    issues.append('missing execution log')
                # conflicting evidence blocks qualification even if an entry claimed success.
                if issues:
                    actual.update(status='infrastructure_error', claimed_status=entry['status'], evidence_issues=issues)
                # classify only the exact observed unsupported-cause discrepancy.
                if (actual['status'] == 'failed' and name == 'priv/Sm/Sm_mcause-00.elf'
                        and re.search(r'Bad Value:\s+0x00000007.*Expected Value:\s+0x00000008', console, re.S)):
                    actual['assessment'] = 'oracle_policy_mismatch'
                    actual['detail'] = 'software write8: Sail echoes8; declared M-only WLRL preserves prior7'
                # the upstream counter test accesses absent timeh, leaving a platform-specific pointer.
                elif (actual['status'] == 'failed' and name == 'priv/Sm/Sm_mcsr_cntr-00.elf'
                      and re.search(r'Bad Value:\s+0x40000fbd.*Expected Value:\s+0x0200bfb5', console, re.S)):
                    actual['assessment'] = 'upstream_applicability_mismatch'
                    actual['detail'] = 'timeh is absent; both trap cause2, then compare different MMIO base addresses minus67'
                # copy full failure replays when the campaign runner recorded them.
                if entry.get('failure_trace'):
                    # preserve the trace and its separate replay provenance.
                    for key, filename in [('failure_trace', 'trace.jsonl.gz'),
                                          ('failure_replay_summary', 'failure-replay-summary.json')]:
                        original_artifact = Path(entry[key])
                        shutil.copyfile(original_artifact, destination / filename)
                        actual[key] = str((destination / filename).relative_to(output))
                        actual[key + '_sha256'] = sha(destination / filename)
                group.append(actual)
                build = summary.get('build', {})
                fingerprint = hashlib.sha256(json.dumps(build, sort_keys=True).encode()).hexdigest()
                cohorts.setdefault(fingerprint, {'build': build, 'tests': []})['tests'].append(label + '/' + name)
                source_paths.update(ROOT / name for name in build.get('sources', {}))
        results[label] = {'counts': dict(Counter(item['status'] for item in group)),
                          'missing_built_tests': sorted(set(built) - seen), 'records': group}
        save(output / ('results-' + label + '.json'), results[label])
    # the active input snapshot is distinct from each runner's historical source cohort.
    sources = {str(path.relative_to(ROOT)): sha(path) for path in sorted(source_paths) if path.is_file()}
    drift = {}
    # distinguish archived active inputs from historically executed source cohorts.
    for fingerprint, cohort in cohorts.items():
        changed = {name: {'executed_sha256': value, 'active_sha256': sources.get(name)}
                   for name, value in cohort['build'].get('sources', {}).items() if sources.get(name) != value}
        # historical hashes remain visible and cannot claim execution of later source revisions.
        if changed:
            drift[fingerprint] = changed
    archive_path = output / 'artifacts.tar.gz'
    # stable archive metadata makes identical input sets reproducibly hashable.
    with archive_path.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as compressed:
        # stream the archive so evidence volume does not determine memory usage.
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            def add(path, name):
                """archive an existing file once and record its content hash."""
                # optional artifacts such as non-signature reference outputs may be absent.
                if not path.is_file() or name in archived:
                    return
                info = archive.gettarinfo(str(path), arcname=name)
                info.mtime = info.uid = info.gid = 0
                info.uname = info.gname = ''
                # include exact file bytes without following generated archive names.
                with path.open('rb') as stream:
                    archive.addfile(info, stream)
                archived[name] = sha(path)
            # snapshot active inputs; historical cohort drift is reported separately.
            for name in sources:
                add(ROOT / name, 'source/' + name)
            # the entire macro environment is needed to rebuild generated assembly.
            for path in sorted((tests / 'env').rglob('*')):
                add(path, 'test-inputs/env/' + str(path.relative_to(tests / 'env')))
            # retain validated UDB headers alongside the shared macro environment.
            for path in sorted((work / 'env').rglob('*')):
                add(path, 'configured-env/' + str(path.relative_to(work / 'env')))
            # failed applicable tests keep their source as well as the successful cases.
            for item in records:
                # unsupported profiles remain inventoried without redundant source copies.
                if item['status'] != 'not_applicable':
                    name = item['test']
                    # a changed generated source invalidates the recorded build inventory.
                    if sha(tests / name) != item['source_sha256']:
                        raise ValueError(f'generated input drift: {name}')
                    add(tests / name, 'test-inputs/' + name)
                    stem = Path(name).with_suffix('')
                    elf_relative = Path(str(stem) + '.elf')
                    # compiled artifacts must still match the inventory used for execution.
                    if item['status'] == 'built' and sha(work / 'elfs' / elf_relative) != item['elf_sha256']:
                        raise ValueError(f'built ELF drift: {name}')
                    # retained reference expectations must match the values used during DUT execution.
                    for key, suffix in [('reference_elf_sha256', '.sig.elf'), ('signature_sha256', '.sig')]:
                        # signature-free tests have no reference artifact to validate.
                        if key in item and sha(work / 'build' / Path(str(stem) + suffix)) != item[key]:
                            raise ValueError(f'reference artifact drift: {name}')
                    add(work / 'elfs' / elf_relative, 'elfs/' + str(elf_relative))
                    # reference logs and signatures are independent of the DUT verdict.
                    for suffix in ['.sig.elf', '.sig', '.results', '.sig.log']:
                        relative = Path(str(stem) + suffix)
                        add(work / 'build' / relative, 'reference/' + str(relative))
            # execution logs and structured results survive deletion of every /tmp directory.
            for path in sorted((output / 'execution').rglob('*')):
                add(path, str(path.relative_to(output)))
            # manually captured diagnosis traces remain preserved with their original logs.
            for path in sorted((output / 'failures').rglob('*')):
                add(path, str(path.relative_to(output)))
            # include diagnostics from every recorded build and generation revision.
            for path in sorted(output.glob('*.log')):
                add(path, 'phase-logs/' + path.name)
            # archive tool pins and explicit adapter revisions as separate evidence.
            for name in ['tool-manifest.json', 'Gemfile.lock', 'pointer-repair.json', 'trap-buffer-revision.json',
                         'publisher-negative-checks.json', 'generation-reproducibility.json']:
                add(output / name, 'qualification/' + name)
    save(output / 'artifact-index.json', archived)
    failing = sum(group['counts'].get('failed', 0) + group['counts'].get('infrastructure_error', 0)
                  for group in results.values())
    omissions = [item['test'] for item in records if item['status'] not in ['built', 'not_applicable']]
    missing = any(group['missing_built_tests'] for group in results.values()) or not results
    report = {'status': 'qualification_open' if omissions or failing or missing or drift else 'complete_pass',
              'source_sha256': sources, 'act4_commit': 'e7fe80bfcea852562e6561e14fca2e4010cfb5ad',
              'selected': sum(item['status'] != 'not_applicable' for item in records),
              'build_counts': inventory['counts'], 'omissions': omissions,
              'executions': {label: {'counts': group['counts'], 'missing_built_tests': group['missing_built_tests'],
                                      'results': 'results-' + label + '.json',
                                      'results_sha256': sha(output / ('results-' + label + '.json'))}
                             for label, group in results.items()},
              'source_cohorts': cohorts, 'inventory': 'inventory.json', 'inventory_sha256': sha(output / 'inventory.json'),
              'build_source_drift': drift, 'source_snapshot_scope': 'active inputs; executed historical hashes are in source_cohorts',
              'artifact_archive': 'artifacts.tar.gz', 'artifact_archive_sha256': sha(archive_path),
              'artifact_index': 'artifact-index.json', 'artifact_index_sha256': sha(output / 'artifact-index.json'),
              'assumptions': ['debug disabled', 'one M-only RV32IMC_Zicsr_Zifencei hart',
                              'exact 64 KiB IRAM and 32 KiB DRAM; no memory expansion',
                              'independent bounded request acceptance, response delay and response hold',
                              'reference-only CLINT/SIG addresses are not DUT aliases'],
              'model_limits': ['mcountinhibit reset 0 in Sail versus 5 in DUT',
                               'mcause WLRL software-write policy differs for unsupported causes',
                               'upstream Sm counter test assumes time/timeh despite absent Zicntr',
                               'Sail Xtvec_Ignore is not a complete unsupported-mode coercion oracle',
                               'Sail WFI/time semantics do not establish hardware cycle or interrupt bounds']}
    # a fresh replay may coexist with the separately preserved unmodified baseline evidence.
    baseline = output / 'baseline/manifest.json'
    # preserve the unmodified upstream baseline as a historical result.
    if baseline.exists():
        report['historical_baseline'] = {'path': 'baseline/manifest.json', 'sha256': sha(baseline)}
    tools = output / 'tool-manifest.json'
    # tool pins are archived independently from each runner's RTL source fingerprint.
    if tools.exists():
        report['tools'] = {'path': 'tool-manifest.json', 'sha256': sha(tools)}
    save(output / 'manifest.json', report)
    return report


# labels may repeat to merge repaired tests into the corresponding fixed schedule.
def main():
    """publish a completed or partially failing campaign."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--tests', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run', action='append', default=[], metavar='LABEL=DIRECTORY')
    args = parser.parse_args()
    runs = {}
    # merge directory groups by their explicit schedule label.
    for specification in args.run:
        label, directory = specification.split('=', 1)
        # labels become directory names, never paths supplied by a test program.
        if not label or '/' in label or label in ['.', '..']:
            raise ValueError('invalid run label')
        runs.setdefault(label, []).append(Path(directory))
    report = publish(args.work, args.tests, args.inventory, args.output, runs)
    print(json.dumps({key: report[key] for key in ['status', 'selected', 'build_counts', 'executions']}, indent=2))


# imports provide the publisher without creating or replacing evidence.
if __name__ == '__main__':
    main()

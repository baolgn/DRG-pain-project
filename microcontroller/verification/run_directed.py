#!/usr/bin/env python3
"""run existing directed suites against isolated copies of the delivered CPU sources."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


# each family keeps its original checker, configuration matrix and negative controls.
FAMILIES = {
    'base': ('run_base.py', False, False),
    'memory': ('run_memory.py', False, False),
    'control-flow': ('run_control_flow.py', False, False),
    'control-events': ('run_control_events.py', False, False),
    'csr': ('run_csr.py', False, True),
    'csr-control': ('run_csr_control.py', False, False),
    'irq-control': ('run_irq_control.py', True, False),
    'muldiv-control': ('run_muldiv_control.py', True, False),
    'compressed-execution': ('run_compressed_execution.py', True, False),
    'fence-execution': ('run_fence_execution.py', True, False),
    'fence-events': ('run_fence_events.py', True, False),
}


# all hashes name workspace-relative sources, even when a child uses absolute paths.
def digest(path):
    """return the digest of the exact file bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# completed compiler caches are disposable only after their logs and summaries are copied.
def remove_caches(build):
    """retain binaries and diagnostics while releasing generated compiler storage."""
    # inspect only this completed family's generated build tree.
    for path in build.rglob('*'):
        # generated sources are reproducible from the retained original source snapshot.
        if path.is_file() and path.suffix in {'.cpp', '.o', '.a', '.gch', '.h', '.d'}:
            path.unlink()


# a family failure remains a failed attempt; later families do not overwrite its evidence.
def run_family(root, args, family):
    """copy exact source inputs and execute one complete existing regression family."""
    out = args.evidence_dir.resolve()
    revisions = out / 'revisions'; revisions.mkdir(parents=True, exist_ok=True)
    number = max([int(path.name.split('-')[0]) for path in revisions.iterdir() if path.is_dir()] + [0]) + 1
    attempt = revisions / f'{number:02d}-{family}'; attempt.mkdir()
    build = args.build.resolve() / attempt.name; build.mkdir(parents=True, exist_ok=True)
    snapshot = build / 'workspace'
    names = [str(path.relative_to(root)) for folder in ['microcontroller/rtl', 'microcontroller/tests']
             for path in sorted((root / folder).glob('*')) if path.is_file() and
             (path.suffix in {'.sv', '.svh', '.py'} or path.name == 'Makefile')]
    names.append(str(Path(__file__).resolve().relative_to(root)))
    before = {name: digest(root / name) for name in names}
    # byte-identical workspaces protect sealed historical evidence from child default paths.
    for name in names:
        target = snapshot / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
        archived = attempt / 'sources' / name; archived.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, archived)
    runner, evidence_option, uses_yosys = FAMILIES[family]
    command = ['python3', 'microcontroller/tests/' + runner, '--verilator', args.verilator,
               '--build', str(build / 'objects')]
    # older runners write only their build directory or their own isolated evidence path.
    if evidence_option:
        command += ['--evidence-dir', str(attempt / 'result')]
    # the CSR family includes actual bank proofs and native mapping in its normal invocation.
    if uses_yosys:
        command += ['--yosys', args.yosys]
    summary = {'status': 'running', 'family': family, 'source_sha256': before, 'command': command,
               'scope': 'complete unchanged directed runner on isolated current sources; child limits remain authoritative'}
    # retain even unsuccessful compilation and checker diagnostics.
    try:
        # keep the exact command next to its complete output.
        with (attempt / 'runner.log').open('w') as stream:
            stream.write('$ ' + shlex.join(command) + '\n'); stream.flush()
            result = subprocess.run(command, cwd=snapshot, stdout=stream, stderr=subprocess.STDOUT, timeout=2400)
        summary['exit_code'] = result.returncode
        # successful process termination alone is not sufficient evidence.
        if result.returncode:
            raise RuntimeError('directed family failed: ' + str(attempt / 'runner.log'))
        child_path = attempt / 'result/summary.json' if evidence_option else build / 'objects/summary.json'
        child = json.loads(child_path.read_text())
        # some old successful unit records have no top-level status field.
        if child.get('status', 'passed') != 'passed':
            raise RuntimeError('child summary did not pass')
        summary['child_summary'] = child
        summary['child_summary_sha256'] = digest(child_path)
        shutil.copyfile(child_path, attempt / 'child-summary.json')
        # current-source attribution includes automatically discovered RTL dependencies.
        if before != {name: digest(root / name) for name in names}:
            raise RuntimeError('current sources changed during directed qualification')
        summary['status'] = 'passed'
    # a failure is explicitly recorded before propagating its nonzero result.
    except Exception as error:
        summary['status'] = 'failed'; summary['failure'] = str(error)
        raise
    # evidence survives both expected checker failures and unexpected tool failures.
    finally:
        # copy diagnostics before any successful cache cleanup.
        for path in (build / 'objects').rglob('*'):
            # logs, schedules, summaries and formal witness artifacts are retained without compiler caches.
            if path.is_file() and path.suffix in {'.log', '.json', '.vcd', '.ys', '.smt2'}:
                target = attempt / 'build-records' / path.relative_to(build / 'objects')
                target.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path, target)
        (attempt / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        (out / f'{family}-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    remove_caches(build / 'objects')
    print('DIRECTED_PASS ' + family, flush=True)


# explicit family names prevent a partial run from being mislabeled as the full matrix.
def main():
    """execute requested complete families in a bounded, source-attributed sequence."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--families', nargs='+', choices=list(FAMILIES), default=list(FAMILIES))
    parser.add_argument('--verilator', default='/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator')
    parser.add_argument('--yosys', default='/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/yosys')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-verification-directed'))
    parser.add_argument('--evidence-dir', type=Path, default=Path('microcontroller/verification/evidence/verification-2026-11-04/directed'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    # independent families share no mutable simulator or reference state.
    for family in args.families:
        run_family(root, args, family)


# importing the driver never starts a tool or changes retained evidence.
if __name__ == '__main__':
    main()

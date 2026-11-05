#!/usr/bin/env python3
"""reproduce the pinned ACT4 generation, reference build and RTL campaign."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile

from publish import publish

COMMIT = 'e7fe80bfcea852562e6561e14fca2e4010cfb5ad'
ARCHIVES = {
    'act4.tar.gz': '57b2f4f163bb758f88cf103e8437cfaf6c82c1da84b0652cdbd65ce08118a106',
    'sail.tar.gz': 'f9bb8a32b8f3eddbdf69b3a29d96dff4ba1e77f45877165e0478418367da6bee',
    'gcc.tar.gz': 'aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758',
}


# the archive identity and extracted source both constrain the upstream implementation.
def verify_source(tools, act4):
    """reject altered archives or generator/framework/environment source."""
    # enforce all three previously qualified download hashes.
    for name, expected in ARCHIVES.items():
        observed = hashlib.sha256((tools / name).read_bytes()).hexdigest()
        # a mismatched archive invalidates tool attribution immediately.
        if observed != expected:
            raise ValueError(f'archive checksum mismatch: {name}')
    # generated tests may change; all committed generator and environment inputs must match.
    with tarfile.open(tools / 'act4.tar.gz') as archive:
        # generated assembly may differ, but upstream implementation inputs may not.
        for member in archive.getmembers():
            relative = Path(*Path(member.name).parts[1:])
            selected = str(relative).startswith(('framework/', 'generators/', 'tests/env/', 'testplans/', 'coverpoints/'))
            # compare only committed regular files in the relevant source directories.
            if member.isfile() and selected:
                contents = archive.extractfile(member).read()
                # modified tool source requires its own reviewed version pin.
                if (act4 / relative).read_bytes() != contents:
                    raise ValueError(f'upstream source drift: {relative}')
    # check the actual compiler, assembler, linker, disassembler and reference executable.
    required = {'gcc': {'bin/riscv-none-elf-gcc', 'bin/riscv-none-elf-objdump',
                        'riscv-none-elf/bin/as', 'riscv-none-elf/bin/ld',
                        'libexec/gcc/riscv-none-elf/15.2.0/cc1',
                        'libexec/gcc/riscv-none-elf/15.2.0/collect2'},
                'sail': {'bin/sail_riscv_sim'}}
    verified = {}
    # package checks include the compiler's invoked subprocesses, not only its driver.
    for package, paths in required.items():
        observed = set()
        # archive bytes are already bound to the checked release checksum.
        with tarfile.open(tools / (package + '.tar.gz')) as archive:
            # names retain the release root so extracted installation paths are exact.
            for member in archive.getmembers():
                relative = str(Path(*Path(member.name).parts[1:]))
                # compare only required regular executables from this package.
                if member.isfile() and relative in paths:
                    expected = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
                    binary = tools / package / member.name
                    actual = hashlib.sha256(binary.read_bytes()).hexdigest()
                    # substituted extracted binaries cannot retain the release attribution.
                    if actual != expected:
                        raise ValueError(f'extracted executable drift: {binary}')
                    verified[str(binary)] = actual
                    observed.add(relative)
        # a changed release layout must be reviewed rather than silently skipping checks.
        if observed != paths:
            raise ValueError(f'missing archive executables: {package}: {sorted(paths - observed)}')
    return verified


# phase failures, missing schedules and publisher findings all keep qualification open.
def finalize_status(published, phases, seeds):
    """derive one verdict for the manifest, campaign and process exit."""
    published['phases'] = phases
    published['expected_schedules'] = [f'seed{seed}' for seed in seeds]
    published['missing_schedules'] = sorted(set(published['expected_schedules']) - set(published['executions']))
    published['unexpected_schedules'] = sorted(set(published['executions']) - set(published['expected_schedules']))
    required = {'sail.json', 'sail-retirement.json', 'generation', 'build', 'inventory'}
    required.update(f'execution-seed{seed}' for seed in seeds)
    published['missing_phases'] = sorted(required - set(phases))
    final_pass = (published['status'] == 'complete_pass' and not published['missing_schedules']
                  and not published['unexpected_schedules'] and not published['missing_phases']
                  and all(value == 0 for value in phases.values()))
    published['status'] = 'complete_pass' if final_pass else 'qualification_open'
    return published['status']


# every phase logs its exact command and status; failures do not erase later evidence.
def run(command, log, environment, cwd):
    """run one phase and retain its complete output."""
    # flush the command before execution so failures retain their invocation.
    with log.open('w') as stream:
        stream.write('$ ' + shlex.join(map(str, command)) + '\n')
        stream.flush()
        result = subprocess.run(list(map(str, command)), env=environment, cwd=cwd,
                                stdout=stream, stderr=subprocess.STDOUT, check=False)
    return result.returncode


# prerequisite tools live under the chosen isolated directory, never a system install.
def main():
    """run all applicable tests, including explicit build omissions and DUT failures."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=Path, default=Path('/tmp/drg5-arch-tools'))
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-arch-exec'))
    parser.add_argument('--seeds', type=int, nargs='+', default=[1, 24301])
    args = parser.parse_args()
    local = Path(__file__).resolve().parent
    root = local.parents[2]
    args.tools = args.tools.resolve()
    args.work = args.work.resolve()
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=True)
    initial = {'status': 'qualification_open', 'phase': 'initialization', 'act4_commit': COMMIT,
               'archives': ARCHIVES, 'executions': {},
               'source_sha256': {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in local.iterdir() if path.is_file() and path.suffix != '.md'}}
    # replace any stale verdict before archive verification, validation or tool discovery can fail.
    (args.evidence / 'manifest.json').write_text(json.dumps(initial, indent=2, sort_keys=True) + '\n')
    # stale DAG outputs cannot be attributed to newly generated sources or reference expectations.
    if args.work.exists() and (not args.work.is_dir() or any(args.work.iterdir())):
        raise SystemExit('ACT4 requires a fresh, empty --work directory')
    # duplicate schedules would overwrite evidence instead of adding an independent run.
    if len(set(args.seeds)) != len(args.seeds):
        raise SystemExit('ACT4 requires distinct random seeds')
    act4 = args.tools / 'act4' / ('riscv-arch-test-' + COMMIT)
    verified_binaries = verify_source(args.tools, act4)
    gcc_bin = args.tools / 'gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin'
    sail_bin = args.tools / 'sail/sail-riscv-Linux-x86_64/bin'
    venv = args.tools / 'venv/bin'
    environment = os.environ.copy()
    environment.update(PATH=os.pathsep.join(map(str, [local, args.tools / 'bin', venv,
                                                    gcc_bin, sail_bin])) + os.pathsep + environment['PATH'],
                       DRG5_GCC=str(gcc_bin / 'riscv-none-elf-gcc'),
                       XDG_DATA_HOME=str(args.tools / 'xdg-data'),
                       XDG_CACHE_HOME=str(args.tools / 'xdg-cache'),
                       BUNDLE_PATH=str(args.tools / 'gems'))
    binaries = {'gcc': gcc_bin / 'riscv-none-elf-gcc', 'sail': sail_bin / 'sail_riscv_sim',
                'as': gcc_bin.parent / 'riscv-none-elf/bin/as',
                'ld': gcc_bin.parent / 'riscv-none-elf/bin/ld'}
    tool_report = {'act4_commit': COMMIT, 'archives': ARCHIVES,
                   'archive_verified_executables': verified_binaries,
                   'executables': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                                   for name, path in binaries.items()},
                   'versions': {'ACT4': '0.3.0', 'GCC': '15.2.0', 'binutils': '2.45', 'Sail': '0.16'},
                   'gemfile_lock_sha256': hashlib.sha256((act4 / 'framework/src/act/data/Gemfile.lock').read_bytes()).hexdigest()}
    (args.evidence / 'tool-manifest.json').write_text(json.dumps(tool_report, indent=2) + '\n')
    phases = {}
    # model validation precedes generation so no default full-feature model can slip in.
    for name in ['sail.json', 'sail-retirement.json']:
        phases[name] = run([sail_bin / 'sail_riscv_sim', '--config', local / name,
                            '--validate-config'], args.evidence / (name + '.log'), environment, root)
    generated = args.work / 'tests'
    phases['generation'] = run([venv / 'python', local / 'generate_tests.py', '--act4', act4,
                                '--output', generated], args.evidence / 'generation.log', environment, root)
    # failed validation or generation prevents using partial or stale test trees.
    if any(phases.values()):
        (args.evidence / 'campaign.json').write_text(json.dumps({'phases': phases}, indent=2) + '\n')
        initial['phases'] = phases
        initial['phase'] = 'validation_or_generation_failed'
        (args.evidence / 'manifest.json').write_text(json.dumps(initial, indent=2, sort_keys=True) + '\n')
        raise SystemExit(1)
    work = args.work / 'build'
    phases['build'] = run([venv / 'act', local / 'test_config.yaml', '--test-dir', generated,
                          '--coverpoint-dir', act4 / 'coverpoints', '--workdir', work,
                          '--jobs', '4', '--debug', '--keep-going'], args.evidence / 'build.log', environment, root)
    profile = work / 'drg5-rv32imc'
    phases['inventory'] = run([venv / 'python', local / 'inventory.py', '--tests', generated,
                              '--work', profile, '--build-log', args.evidence / 'build.log',
                              '--output', args.evidence / 'inventory.json'],
                             args.evidence / 'inventory.log', environment, root)
    # available self-checking tests still run when other tests exceed physical capacity.
    if phases['inventory'] == 0:
        # each deterministic schedule has independent result files and logs.
        for seed in args.seeds:
            label = f'execution-seed{seed}'
            phases[label] = run([venv / 'python', local / 'run_batch.py', '--elf-dir', profile / 'elfs',
                                 '--output', args.work / label, '--build', args.build, '--seed', str(seed)],
                                args.evidence / (label + '.log'), environment, root)
    report = {'act4_commit': COMMIT, 'archives': ARCHIVES, 'phases': phases,
              'work': str(args.work), 'seeds': args.seeds,
              'status': 'complete_pass' if all(value == 0 for value in phases.values()) else 'qualification_open'}
    (args.evidence / 'campaign.json').write_text(json.dumps(report, indent=2) + '\n')
    # publish all available evidence even when capacity checks or DUT comparisons fail.
    if phases['inventory'] == 0:
        runs = {f'seed{seed}': [args.work / f'execution-seed{seed}'] for seed in args.seeds
                if (args.work / f'execution-seed{seed}/results.json').exists()}
        published = publish(profile, generated, args.evidence / 'inventory.json', args.evidence, runs)
        report['status'] = finalize_status(published, phases, args.seeds)
        (args.evidence / 'manifest.json').write_text(json.dumps(published, indent=2, sort_keys=True) + '\n')
    # inventory failure also replaces the initialization-only verdict with complete phase results.
    else:
        initial.update(phases=phases, phase='inventory_failed')
        (args.evidence / 'manifest.json').write_text(json.dumps(initial, indent=2, sort_keys=True) + '\n')
    (args.evidence / 'campaign.json').write_text(json.dumps(report, indent=2) + '\n')
    raise SystemExit(0 if report['status'] == 'complete_pass' else 1)


# imports do not start generation or hardware execution.
if __name__ == '__main__':
    main()

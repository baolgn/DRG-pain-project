#!/usr/bin/env python3
"""plan or run isolated acceptance commands without touching hardware or sealed evidence."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite')
ARCH = Path('/tmp/drg5-arch-tools')
PREFIX = str(ARCH / 'gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-')
GDB = Path('/tmp/drg5-debug-gdb/usr/bin/gdb-multiarch')
SUITES = {
    'smoke': ['firmware', 'image', 'host', 'boot', 'guard', 'model'],
    'units': ['datapath', 'regfile', 'arithmetic', 'forward', 'muldiv', 'decompress', 'fetch', 'fetch-buffer'],
    'firmware': ['firmware', 'image', 'local', 'programming'],
    'directed': ['directed'],
    'formal': ['formal', 'admission'],
    'reference': ['random'],
    'architectural': ['act4'],
    'synthetic': ['guard', 'synthetic', 'model'],
    'debug': ['debug-core', 'debug-module', 'debug-system', 'debug-remote'],
    'debug-host': ['debug-remote'],
    'route': ['firmware', 'route'],
}
FIXED_TOOLS = {'boot', 'local', 'programming', 'synthetic', 'act4'}
FIXED_GCC = {'image', 'local', 'programming', 'synthetic', 'random', 'route'}


def digest(path):
    """identify exact source or report bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def plain_paths(paths):
    """reject path syntax unsupported by legacy Yosys scripts and Makefile recipes."""
    # native tool scripts concatenate paths without a portable quoting contract.
    for path in paths:
        # the qualified host layout uses this explicit plain-path alphabet.
        if re.fullmatch(r'[A-Za-z0-9_./-]+', str(path)) is None:
            raise ValueError('qualified paths require ASCII letters, digits, slash, dot, underscore or hyphen')


def checked_output(path, root=ROOT):
    """require a new external directory or the dedicated repository scratch area."""
    supplied = Path(path).absolute()
    output = supplied.resolve()
    root = root.resolve()
    plain_paths([supplied, root])
    # symlinked destinations and reused outputs are not fresh execution roots.
    if supplied != output or output.exists():
        raise ValueError('output must be a new path without symlink components')
    # ordinary source and historical evidence trees are never execution destinations.
    if output == root or root in output.parents:
        allowed = root / '.release-runs'
        # only this dedicated scratch subtree is admitted inside the checkout.
        if allowed not in output.parents:
            raise ValueError('repository outputs must be below .release-runs')
    # an external sealed campaign also remains immutable.
    for ancestor in output.parents:
        # a retained seal identifies protected evidence regardless of its location.
        if (ancestor / 'SHA256SUMS').is_file():
            raise ValueError('output cannot be placed inside sealed evidence')
    return output


def selected(suite):
    """return each selected family once, preserving dependency order."""
    names = [name for jobs in SUITES.values() for name in jobs] if suite == 'all' else SUITES[suite]
    return list(dict.fromkeys(names))


def plan(output, suite, tools=TOOLS, arch=ARCH, prefix=PREFIX, gdb=GDB):
    """build explicit commands; legacy fixed paths are not silently overridden."""
    jobs = selected(suite)
    tools = Path(tools).resolve(); arch = Path(arch).resolve()
    plain_paths([ROOT, output, tools, arch, prefix, Path(gdb).resolve(), sys.executable])
    # some qualified runners have fixed tool paths and cannot honor a new bundle location.
    if set(jobs) & FIXED_TOOLS and tools != TOOLS:
        raise ValueError('selected runners require the documented fixed OSS CAD path')
    # fixed firmware consumers must use the exact compiler installation they actually invoke.
    if set(jobs) & FIXED_GCC and prefix != PREFIX:
        raise ValueError('selected runners require the documented fixed GCC prefix')
    # the random runner also fixes its Sail reference location.
    if 'random' in jobs and arch != ARCH:
        raise ValueError('random reference runner requires the documented fixed architecture tools path')
    workspace = output / 'workspace'
    evidence = workspace / 'microcontroller/verification/evidence/release-run'
    build = output / 'build'
    firmware = evidence / 'firmware'
    python = sys.executable
    commands = {
        'datapath': ['make', '-C', 'microcontroller/tests', 'datapath', 'VERILATOR=' + str(tools / 'bin/verilator'), 'BUILD_ROOT=' + str(evidence / 'datapath')],
        'regfile': [python, 'microcontroller/tests/run_regfile.py', '--verilator', str(tools / 'bin/verilator'), '--build', str(evidence / 'regfile')],
        'arithmetic': [python, 'microcontroller/tests/run_arithmetic_formal.py', '--yosys', str(tools / 'bin/yosys'), '--build', str(evidence / 'arithmetic')],
        'forward': [python, 'microcontroller/tests/run_forward.py', '--verilator', str(tools / 'bin/verilator'), '--yosys', str(tools / 'bin/yosys'), '--build', str(evidence / 'forward')],
        'muldiv': [python, 'microcontroller/tests/run_muldiv.py', '--verilator', str(tools / 'bin/verilator'), '--yosys', str(tools / 'bin/yosys'), '--build', str(build / 'muldiv'), '--evidence-dir', str(evidence / 'muldiv')],
        'decompress': [python, 'microcontroller/tests/run_decompress.py', '--verilator', str(tools / 'bin/verilator'), '--yosys', str(tools / 'bin/yosys'), '--build', str(build / 'decompress'), '--evidence-dir', str(evidence / 'decompress')],
        'fetch': [python, 'microcontroller/tests/run_fetch.py', '--verilator', str(tools / 'bin/verilator'), '--build', str(evidence / 'fetch')],
        'fetch-buffer': [python, 'microcontroller/tests/run_fetch_buffer.py', '--verilator', str(tools / 'bin/verilator'), '--build', str(evidence / 'fetch-buffer')],
        'firmware': [python, 'microcontroller/firmware/build.py', '--profile', 'imc', '--prefix', prefix, '--output', str(firmware)],
        'image': [python, 'microcontroller/tests/test_programming_image.py', '--firmware', str(firmware), '--output', str(evidence / 'image')],
        'host': [python, 'microcontroller/tests/test_program_board.py', '--output', str(evidence / 'host')],
        'boot': [python, 'microcontroller/tests/run_spi_boot.py', '--build', str(build / 'boot'), '--output', str(evidence / 'boot')],
        'guard': [python, 'microcontroller/tests/run_acquisition_guard.py', '--tools', str(tools), '--build', str(build / 'guard'), '--output', str(evidence / 'guard')],
        'model': [python, 'microcontroller/synthetic/run_stress.py', '--output', str(evidence / 'model')],
        'local': [python, 'microcontroller/tests/run_local_platform.py', '--build', str(build / 'local'), '--verilator', str(tools / 'bin/verilator'), '--evidence', str(evidence / 'local')],
        'programming': [python, 'microcontroller/tests/run_programming.py', '--firmware', str(firmware), '--build', str(build / 'programming'), '--output', str(evidence / 'programming')],
        'synthetic': [python, 'microcontroller/tests/run_synthetic_cpu.py', '--build', str(build / 'synthetic'), '--output', str(evidence / 'synthetic')],
        'directed': [python, 'microcontroller/verification/run_directed.py', '--build', str(build / 'directed'), '--verilator', str(tools / 'bin/verilator'), '--yosys', str(tools / 'bin/yosys'), '--evidence-dir', str(evidence / 'directed')],
        'formal': [python, 'microcontroller/verification/formal/run_formal.py', '--tools', str(tools), '--build', str(evidence / 'formal')],
        'admission': [python, 'microcontroller/verification/formal/run_admission_formal.py', '--tools', str(tools), '--build', str(evidence / 'admission')],
        'random': [python, 'microcontroller/verification/execution/run_random.py', '--build', str(build / 'random'), '--verilator', str(tools / 'bin/verilator'), '--evidence', str(evidence / 'random')],
        'act4': [python, 'microcontroller/verification/act4/run_campaign.py', '--tools', str(arch), '--work', str(build / 'act4-work'), '--build', str(build / 'act4-simulator'), '--evidence', str(evidence / 'act4')],
        'route': [python, 'microcontroller/synth/run_programmable.py', '--tools', str(tools), '--firmware', str(firmware), '--output', str(evidence / 'route')],
        'debug-core': [python, 'microcontroller/tests/run_debug_core.py', '--verilator', str(tools / 'bin/verilator'), '--build', str(build / 'debug-core'), '--evidence-dir', str(evidence / 'debug-core')],
        'debug-module': [python, 'microcontroller/tests/run_debug_module.py', '--verilator', str(tools / 'bin/verilator'), '--yosys', str(tools / 'bin/yosys'), '--build-dir', str(build / 'debug-module'), '--evidence-dir', str(evidence / 'debug-module')],
        'debug-system': [python, 'microcontroller/tests/run_debug_system.py', '--verilator', str(tools / 'bin/verilator'), '--build', str(build / 'debug-system'), '--evidence-dir', str(evidence / 'debug-system')],
        'debug-remote': [python, 'microcontroller/tests/run_debug_remote.py', '--verilator', str(tools / 'bin/verilator'), '--openocd', str(tools / 'bin/openocd'), '--gdb', str(Path(gdb).resolve()), '--build', str(build / 'debug-remote'), '--evidence-dir', str(evidence / 'debug-remote')],
    }
    return {'schema': 'DRG5-RELEASE-ACCEPTANCE-1', 'suite': suite, 'output': str(output),
            'workspace': str(workspace), 'hardware_operations': False, 'full_release_pass': False,
            'temporary_storage': str(output / 'temporary'),
            'child_environment_overrides': {'TMPDIR': '<new short private /tmp/d5-*/t alias>'},
            'commands': [{'name': name, 'argv': commands[name], 'expected_scope':
                'qualification remains open; nonzero status is retained' if name == 'act4' else 'native checker scope only'} for name in jobs],
            'limitations': ['no board programming or physical observation is performed',
                'a successful selected suite is not complete architectural or system qualification',
                'ACT4 retains known capacity, mcause-policy and timeh applicability failures',
                'the model executes 1800 virtual seconds, not 1800 seconds of CPU RTL']}


def source_inventory(root=ROOT):
    """copy active implementation and project documentation, excluding generated evidence."""
    paths = []
    # root and ancestor links must be rejected before recursive traversal can follow them.
    for relative in ['microcontroller', 'docs']:
        current = root
        # inspect every existing source-root component rather than only descendant files.
        for component in Path(relative).parts:
            current = current / component
            # a linked directory could otherwise import an external tree unnoticed.
            if current.is_symlink():
                raise ValueError('source root symlink: ' + str(current))
        # a partial checkout cannot stand in for the complete release source tree.
        if not current.is_dir():
            raise ValueError('missing source directory: ' + str(current))
    # generated records and caches are not inputs to a fresh implementation build.
    for path in (root / 'microcontroller').rglob('*'):
        parts = path.relative_to(root).parts
        # active source links must not import files outside the delivered checkout.
        if not any(part in {'evidence', 'revisions', '__pycache__'} for part in parts) and path.is_symlink():
            raise ValueError('active source symlink: ' + str(path))
        # active inputs include ROM images, constraints and build configuration files.
        if path.is_file() and not any(part in {'evidence', 'revisions', '__pycache__'} for part in parts):
            paths.append(path)
    # guard and timing runners retain the architecture documents they consume.
    for path in (root / 'docs').glob('*'):
        # documentation inputs follow the same closed-source-tree rule.
        if path.is_symlink():
            raise ValueError('documentation source symlink: ' + str(path))
        # archive bundles are historical evidence, not active design inputs.
        if path.is_file() and path.suffix in {'.md', '.mmd', '.svg', '.json'}:
            paths.append(path)
    return {str(path.relative_to(root)): digest(path) for path in sorted(paths)}


def stage_sources(workspace, hashes, root=ROOT):
    """preserve exact source bytes and executable modes in the isolated checkout."""
    modes = {}
    # wrappers used by ACT4 must remain executable after staging.
    for name, expected in hashes.items():
        destination = workspace / name; destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
        modes[name] = stat.S_IMODE((root / name).stat().st_mode)
        # a concurrent edit cannot supply unrecorded source bytes or permissions.
        if digest(destination) != expected or stat.S_IMODE(destination.stat().st_mode) != modes[name]:
            raise RuntimeError('source changed while staging: ' + name)
    return modes


@contextmanager
def temporary_alias(target):
    """give classic ABC a short path while keeping compiler data in owned storage."""
    # only a private directory and symlink consume space on the system temporary filesystem.
    with tempfile.TemporaryDirectory(prefix='d5-', dir='/tmp') as directory:
        alias = Path(directory) / 't'; alias.symlink_to(target, target_is_directory=True)
        # the bounded native reproduction uses this literal path rather than resolving it.
        if len(str(alias)) >= 32 or alias.resolve() != target.resolve():
            raise RuntimeError('temporary alias does not match its owned storage')
        yield alias


def invoke(command, workspace, log, timeout, overrides=None):
    """retain output and stop the entire child process group on an expired deadline."""
    started = time.monotonic()
    # each native command owns a separate process group and complete transcript.
    with log.open('w') as stream:
        stream.write('$ ' + shlex.join(command) + '\n'); stream.flush()
        environment = dict(os.environ); environment.update(overrides or {})
        process = subprocess.Popen(command, cwd=workspace, env=environment, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        # a process timeout cannot leave synthesis appending to a later sealed report.
        try:
            code = process.wait(timeout=timeout)
        # first request orderly termination, then kill a nonresponsive process group.
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            # collect the original process after allowing children to terminate.
            try:
                process.wait(timeout=5)
            # a persistent child receives no further grace period.
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()
            # surviving grandchildren cannot keep appending after their parent exits.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            # the group may already be empty after orderly termination.
            except ProcessLookupError:
                pass
            code = 124
        # caller interruption must not orphan a process in its private session.
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL); process.wait()
            raise
        orphan_group = False
        # a native runner may exit after its own timeout while leaving descendants alive.
        try:
            os.killpg(process.pid, signal.SIGKILL)
            orphan_group = True
        # a fully completed native command has no remaining process group.
        except ProcessLookupError:
            pass
        # a nominally successful parent cannot qualify while abandoning child processes.
        if orphan_group and code == 0:
            code = 125
    return {'exit_code': code, 'timeout': timed_out, 'elapsed_seconds': time.monotonic() - started,
            'orphan_group_terminated': orphan_group, 'log_sha256': digest(log)}


def execute(report, timeout):
    """run staged sources and retain each family result without promoting scope."""
    output = checked_output(report['output'])
    output.mkdir(parents=True, exist_ok=False)
    workspace = Path(report['workspace']); workspace.mkdir()
    temporary = Path(report['temporary_storage']); temporary.mkdir()
    hashes = source_inventory()
    modes = stage_sources(workspace, hashes)
    report.update(status='running', source_sha256=hashes, source_mode=modes, results=[])
    summary = output / 'summary.json'
    # remove the private alias only after every launched process group has drained or been killed.
    with temporary_alias(temporary) as alias:
        report['child_environment_overrides']['TMPDIR'] = str(alias)
        report['temporary_alias_removed'] = False
        summary.write_text(json.dumps(report, indent=2) + '\n')
        # independent families still run after another family fails; no failure becomes an expected pass.
        for entry in report['commands']:
            log = output / (entry['name'] + '.log')
            result = invoke(entry['argv'], workspace, log, timeout, report['child_environment_overrides'])
            report['results'].append({'name': entry['name'], **result})
            summary.write_text(json.dumps(report, indent=2) + '\n')
            print('ACCEPTANCE_FAMILY', entry['name'], result['exit_code'], flush=True)
    report['temporary_alias_removed'] = True
    stable = all(digest(workspace / name) == expected and stat.S_IMODE((workspace / name).stat().st_mode) == modes[name]
                 for name, expected in hashes.items())
    report['source_stable'] = stable
    report['checkout_source_unchanged'] = all(digest(ROOT / name) == expected for name, expected in hashes.items())
    report['commands_succeeded'] = stable and all(item['exit_code'] == 0 for item in report['results'])
    report['status'] = 'selected-commands-completed' if report['commands_succeeded'] else 'failed-or-unqualified'
    summary.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['commands_succeeded'] else 1


def main():
    """planning is read-only; execution requires an explicit fresh destination."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=[*SUITES, 'all'], default='smoke')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=TOOLS)
    parser.add_argument('--arch-tools', type=Path, default=ARCH)
    parser.add_argument('--gcc-prefix', default=PREFIX)
    parser.add_argument('--gdb', type=Path, default=GDB)
    parser.add_argument('--timeout', type=int, default=7200)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    # invalid timeouts cannot disable completion bounds or spawn a zero-duration run.
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    report = plan(checked_output(args.output), args.suite, args.tools, args.arch_tools, args.gcc_prefix, args.gdb)
    # no plan command contacts a board; execution runs only the declared software checks.
    if args.execute:
        raise SystemExit(execute(report, args.timeout))
    print(json.dumps(report, indent=2))


# importing the release runner never creates files or launches tools.
if __name__ == '__main__':
    main()

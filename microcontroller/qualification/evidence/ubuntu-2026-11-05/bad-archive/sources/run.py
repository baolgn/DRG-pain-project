#!/usr/bin/env python3
"""retain bounded ubuntu tool and exact-device smoke qualification."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tarfile
import time

ARCHIVE_SHA256 = '3558d8cf5b88ba224cf8bae872f83bed11cffdde163b130412e20352029c85f1'


def digest(path):
    """hash large binaries without reading the whole file into memory."""
    # bounded reads also cover the embedded routing database.
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    """keep admission checks active even under optimized Python execution."""
    # failed prerequisites must stop the current qualification attempt.
    if not condition:
        raise ValueError(message)


def main():
    """qualify host tools while leaving physical programming explicitly untested."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    tools = args.tools.resolve()
    build = args.build.resolve()
    output = args.output.resolve()
    build.mkdir(parents=True, exist_ok=False)
    output.mkdir(parents=True, exist_ok=False)
    inputs = [source / name for name in ['run.py', 'smoke_core.sv', 'smoke_tb.sv', 'smoke_top.sv', 'smoke.lpf', 'formal.sv', 'waveform.tcl']]
    result = {'schema': 'DRG5-UBUNTU-TOOLS-1', 'status': 'started',
              'target': {'board': 'ULX3S v3.1.7 D&M', 'part': 'LFE5U-85F-6BG381C',
                         'density': '85k', 'package': 'CABGA381', 'speed': '6'},
              'host': {'os_release': Path('/etc/os-release').read_text(), 'machine': platform.machine(),
                       'python': platform.python_version()},
              'source_sha256': {},
              'commands': [], 'hardware_programming_performed': False,
              'physical_target_verified': False, 'complete_acquisition_qualified': False}
    env = os.environ.copy()
    env['PATH'] = str(tools / 'bin') + os.pathsep + env['PATH']
    env['GIO_MODULE_DIR'] = env['GIO_EXTRA_MODULES'] = str(build / 'empty-gio')
    env['XDG_CONFIG_HOME'] = str(build / 'config')
    env['XDG_CACHE_HOME'] = str(build / 'cache')
    env['XDG_DATA_HOME'] = str(build / 'data')
    env['XDG_DATA_DIRS'] = str(tools / 'share')
    env['TCL_LIBRARY'] = str(tools / 'lib/tcl8.6')
    env['TK_LIBRARY'] = str(tools / 'lib/tk8.6')
    env['FONTCONFIG_PATH'] = str(tools / 'etc/fonts')
    env['FONTCONFIG_FILE'] = str(build / 'fonts.conf')
    env['GTK_THEME'] = 'Adwaita'
    env.pop('GTK_MODULES', None)
    env.pop('GTK3_MODULES', None)
    loader = [str(tools / 'lib/ld-linux-x86-64.so.2'), '--inhibit-cache', '--inhibit-rpath', '', '--library-path', str(tools / 'lib')]

    def native(name):
        """run bundled libraries directly when the GUI wrapper overwrites cache paths."""
        return loader + [str(tools / 'libexec' / name)]

    def run(name, command, expected=0, marker=None, timeout=120):
        """retain failures and terminate the entire child group on timeout."""
        started = time.monotonic()
        log = output / (name + '.log')
        timed_out = False
        # logs survive compilation, solver and display errors alike.
        with log.open('w') as stream:
            process = subprocess.Popen(command, cwd=build, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            # every launched operation has a finite deadline.
            try:
                code = process.wait(timeout=timeout)
            # kill descendants as well as their launcher before reporting timeout.
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                code = process.wait()
        text = log.read_text(errors='replace')
        passed = not timed_out and code == expected and (marker is None or marker in text)
        result['commands'].append({'name': name, 'argv': command, 'exit_code': code,
                                   'expected_exit_code': expected, 'timeout': timed_out,
                                   'seconds': round(time.monotonic() - started, 3),
                                   'required_marker': marker, 'passed': passed, 'log_sha256': digest(log)})
        print(name + ': ' + ('pass' if passed else 'FAIL'), flush=True)
        # an expected nonzero negative-control result is different from an arbitrary failure.
        if not passed:
            raise RuntimeError(name + ' failed; inspect retained log')
        return text

    # the summary is written even if any qualification stage raises an exception.
    try:
        result['source_sha256'] = {p.name: digest(p) for p in inputs}
        (output / 'sources').mkdir()
        # frozen inputs retain the actual failed fixture after a subsequent correction.
        for path in inputs:
            shutil.copy2(path, output / 'sources' / path.name)
        # private cache paths preserve the user's desktop settings and HOME value.
        for name in ['empty-gio', 'config', 'cache', 'data']:
            (build / name).mkdir()
        (build / 'fonts.conf').write_text((tools / 'etc/fonts/fonts.conf.template').read_text().replace('TARGET_DIR', str(tools)))
        require(all(not any(char.isspace() for char in str(path)) for path in [source, tools, build, output]), 'tool script paths must not contain whitespace')
        require(platform.machine() == 'x86_64', 'this bundle is Linux x86-64 only')
        require(digest(args.archive) == ARCHIVE_SHA256, 'archive digest mismatch')
        result['archive'] = {'name': args.archive.name, 'sha256': ARCHIVE_SHA256, 'bytes': args.archive.stat().st_size}
        binaries = ['yosys', 'yosys-abc', 'nextpnr-ecp5', 'ecppack', 'ecppll', 'verilator_bin',
                    'sby', 'gtkwave', 'openFPGALoader', 'z3']
        result['binary_sha256'] = {str(Path('libexec') / name): digest(tools / 'libexec' / name) for name in binaries}
        result['runtime_sha256'] = {str(p.relative_to(tools)): digest(p) for p in [tools / 'lib/ld-linux-x86-64.so.2', tools / 'share/yosys/ecp5/cells_sim.v', tools / 'share/trellis/database/devices.json']}
        result['trellis_database_sha256'] = {str(p.relative_to(tools)): digest(p) for p in sorted((tools / 'share/trellis/database/ECP5/LFE5U-85F').rglob('*')) if p.is_file()}
        archive_files = {**result['binary_sha256'], **result['runtime_sha256'], **result['trellis_database_sha256']}
        matched = []
        # compare selected executable, primitive and target-database bytes with the pinned archive.
        with tarfile.open(args.archive, 'r|gz') as bundle:
            # inspect the selected files without extracting or modifying the tool installation.
            for member in bundle:
                name = member.name.removeprefix('oss-cad-suite/')
                # unrelated bundle files are not used as substitutes for the selected targets.
                if name in archive_files:
                    stream = bundle.extractfile(member)
                    require(stream is not None and hashlib.file_digest(stream, 'sha256').hexdigest() == archive_files[name], 'installed/archive mismatch: ' + name)
                    matched.append(name)
        require(set(matched) == set(archive_files), 'selected files missing from pinned archive')
        result['archive_files_verified'] = sorted(matched)
        # record banners for every named tool and solver before executing fixtures.
        for name, command in [('verilator-version', [str(tools / 'bin/verilator'), '--version']),
                              ('yosys-version', [str(tools / 'bin/yosys'), '-V']),
                              ('nextpnr-version', native('nextpnr-ecp5') + ['--version']),
                              ('sby-version', [str(tools / 'bin/sby'), '--version']),
                              ('z3-version', [str(tools / 'bin/z3'), '--version']),
                              ('gtkwave-version', native('gtkwave') + ['-V']),
                              ('programmer-version', [str(tools / 'bin/openFPGALoader'), '-V'])]:
            run(name, command)
        run('verilator-build', [str(tools / 'bin/verilator'), '--binary', '--timing', '--trace', '--assert', '-Wall',
                               '--top-module', 'smoke_tb', '--Mdir', str(build / 'simulation'), '-j', '2',
                               str(source / 'smoke_core.sv'), str(source / 'smoke_tb.sv')], timeout=180)
        run('verilator-simulation', [str(build / 'simulation/Vsmoke_tb')], marker='SMOKE_SIM_PASS cycles=2048')
        shutil.copy2(build / 'smoke.vcd', output / 'smoke.vcd')
        run('pll', native('ecppll') + ['-i', '25', '-o', '80', '-n', 'qualification_pll', '-f', str(build / 'pll.v')])
        script = 'read_verilog -sv ' + ' '.join(str(p) for p in [source / 'smoke_core.sv', source / 'smoke_top.sv', build / 'pll.v'])
        script += '; synth_ecp5 -top smoke_top -json ' + str(build / 'smoke.json') + '; check -assert; stat'
        run('yosys-synthesis', [str(tools / 'bin/yosys'), '-p', script], marker='Found and reported 0 problems.')
        cells = json.loads((build / 'smoke.json').read_text())['modules']['smoke_top']['cells']
        counts = Counter(cell['type'] for cell in cells.values())
        result['mapped_cells'] = dict(sorted(counts.items()))
        # require real technology mapping instead of accepting generic or missing resources.
        for primitive in ['DP16KD', 'MULT18X18D', 'EHXPLLL', 'CCU2C', 'USRMCLK']:
            require(counts[primitive] > 0, 'missing required mapped primitive: ' + primitive)
        run('nextpnr-route', native('nextpnr-ecp5') + ['--85k', '--package', 'CABGA381', '--speed', '6', '--seed', '1',
            '--json', str(build / 'smoke.json'), '--lpf', str(source / 'smoke.lpf'), '--freq', '80',
            '--textcfg', str(build / 'smoke.config'), '--report', str(output / 'route-report.json')], timeout=180)
        run('bitstream', native('ecppack') + ['--db', str(tools / 'share/trellis/database'), '--compress', str(build / 'smoke.config'), str(output / 'smoke.bit')])
        require((output / 'smoke.bit').stat().st_size > 1024, 'empty bitstream')
        sys.path.insert(0, str(source.parent / 'programming'))
        import program_board
        result['programming_parser_sha256'] = {name: digest(source.parent / 'programming' / name) for name in ['program_board.py', 'image.py']}
        program_board.configuration_payload((output / 'smoke.bit').read_bytes())
        result['bitstream_part_and_idcode_checked'] = True
        # prove and cover a portable property, then require a real assertion counterexample.
        for name, mode, define, expected, status in [('prove', 'prove', '', 0, 'PASS'), ('cover', 'cover', '', 0, 'PASS'), ('negative', 'bmc', '-D NEGATIVE', 2, 'FAIL')]:
            sby = build / (name + '.sby')
            sby.write_text('[options]\nmode ' + mode + '\ndepth 20\n\n[engines]\nsmtbmc z3\n\n[script]\nread -formal ' + define + ' formal.sv\nprep -top formal\n\n[files]\n' + str(source / 'formal.sv') + '\n')
            run('sby-' + name, [str(tools / 'bin/sby'), '-f', str(sby)], expected=expected, marker='DONE (' + status + ', rc=', timeout=120)
            shutil.copy2(build / name / 'status', output / ('sby-' + name + '-status.txt'))
        run('vcd-to-fst', [str(tools / 'bin/vcd2fst'), str(build / 'smoke.vcd'), str(output / 'smoke.fst')])
        run('gtkwave-load', native('gtkwave') + [str(build / 'smoke.vcd'), '--script=' + str(source / 'waveform.tcl')], marker='GTKWAVE_LOAD_PASS', timeout=30)
        boards = run('programmer-boards', [str(tools / 'bin/openFPGALoader'), '--list-boards'], marker='ulx3s')
        cables = run('programmer-cables', [str(tools / 'bin/openFPGALoader'), '--list-cables'], marker='ft231X')
        devices = run('programmer-devices', [str(tools / 'bin/openFPGALoader'), '--list-fpga'], marker='41113043')
        result['programmer_static_target_match'] = all([boards, cables, devices])
        result['physical_programming_status'] = 'not performed: user confirms no board is available'
        result['status'] = 'host-tools-and-smoke-pass'
    # preserve the exact first failed stage rather than replacing it with a passing rerun.
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = repr(error)
    # source stability and retained artifacts remain auditable for passing and failed attempts.
    finally:
        result['source_stable'] = bool(result['source_sha256']) and all(p.exists() and digest(p) == result['source_sha256'].get(p.name) for p in inputs)
        # source changes invalidate both the process result and the structured result.
        if not result['source_stable']:
            result['status'] = 'failed'
            result['error'] = 'source changed or unavailable during qualification'
        result['artifacts_sha256'] = {p.name: digest(p) for p in sorted(output.iterdir()) if p.is_file() and p.name != 'summary.json'}
        (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['status'] == 'host-tools-and-smoke-pass' and result['source_stable'] else 1


# importing the module neither runs tools nor writes evidence.
if __name__ == '__main__':
    raise SystemExit(main())

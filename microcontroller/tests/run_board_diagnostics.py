#!/usr/bin/env python3
"""qualify board reset and diagnostic stages with a behavioral PLL model."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


# retained source bytes and executable identities bind each observed outcome.
def digest(path):
    """return a file's SHA-256."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# every command keeps complete output before its status is assessed.
def run(argv, directory, label):
    """execute a bounded compiler or simulator command."""
    result = subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180, check=False)
    (directory / (label + '.log')).write_text('$ ' + shlex.join(argv) + '\n' + result.stdout)
    return result.returncode, result.stdout


# compile only the early board stages; the physical PLL is deliberately replaced.
def main():
    """preserve a finite reset/RAM result without claiming physical clock qualification."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verilator', type=Path, default=Path('/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator'))
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-board-diagnostics'))
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build, evidence = args.build.resolve(), args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    build.mkdir(parents=True, exist_ok=False)
    names = ['microcontroller/rtl/drg5_control_pkg.sv',
             'microcontroller/synth/fpga/drg5_ulx3s.sv',
             'microcontroller/tests/board_models/drg5_board_pll.sv',
             'microcontroller/tests/drg5_board_diagnostics_tb.sv',
             'microcontroller/tests/run_board_diagnostics.py']
    hashes = {name: digest(root / name) for name in names}
    snapshot = evidence / 'sources'
    snapshot.mkdir()
    # compile frozen inputs so concurrent edits cannot alter this test's meaning.
    for name in names:
        shutil.copy2(root / name, snapshot / Path(name).name)
    command = [str(args.verilator.resolve()), '--binary', '--timing', '--assert', '-Wall',
               '-j', '2', '-CFLAGS', '-O0', '--Mdir', str(build),
               '--top-module', 'drg5_board_diagnostics_tb',
               '-Wno-TIMESCALEMOD', '-Wno-UNUSEDPARAM', '-Wno-UNUSEDSIGNAL', '-Wno-PROCASSINIT',
               *[str(snapshot / Path(name).name) for name in names[:-1]]]
    code, output = run(command, evidence, 'build')
    # declared lint exclusions retain intentional FPGA initialization and unused stage fields.
    if code or '%Warning' in output:
        raise RuntimeError('board diagnostic build failed; inspect build.log')
    binary = build / 'Vdrg5_board_diagnostics_tb'
    code, output = run([str(binary), '+verilator+seed+1'], evidence, 'run')
    passed = code == 0 and 'BOARD_DIAGNOSTICS_PASS checks=' in output
    version = subprocess.check_output([str(args.verilator.resolve()), '--version'], text=True).strip()
    record = {'status': 'passed' if passed else 'failed', 'seed': 1, 'source_sha256': hashes,
              'verilator': version, 'verilator_wrapper_sha256': digest(args.verilator.resolve()),
              'binary_sha256': digest(binary), 'exit_code': code,
              'checks': output, 'scope': 'stages 0/1 reset, RAM patterns, corruption detection and restart',
              'limitations': ['behavioral clock pass-through; no real PLL frequency or lock acquisition',
                              'no physical board, electrical, placement or metastability evidence',
                              'RAM corruption is explicit testbench injection'],
              'lint_exclusions': ['TIMESCALEMOD: common RTL has no delay semantics',
                                  'UNUSEDPARAM/UNUSEDSIGNAL: unused package and inactive CPU stage fields',
                                  'PROCASSINIT: FPGA reset-release register requires power-up initialization']}
    (evidence / 'summary.json').write_text(json.dumps(record, indent=2) + '\n')
    # a compiler exit alone cannot establish the finite checks completed.
    if not passed:
        raise RuntimeError('board diagnostic execution failed; inspect run.log')
    print('BOARD_DIAGNOSTICS_QUALIFICATION_PASS')


# imports must never launch a simulator or modify evidence.
if __name__ == '__main__':
    main()

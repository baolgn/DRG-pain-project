#!/usr/bin/env python3
"""check local-fabric transactions without requiring a CPU or firmware image."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite')


# commands retain their exact input and output before any verdict is made.
def run(command, log):
    """execute one command and preserve its complete transcript."""
    process = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, check=False, timeout=180)
    log.write_text('$ ' + shlex.join(command) + '\n' + process.stdout)
    return process.returncode, process.stdout


# fingerprints bind cached or copied evidence to actual consumed source bytes.
def digest(path):
    """return the SHA-256 of a source or artifact."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# the ordinary test and both failure controls have different required outcomes.
def main():
    """run strict lint, physical-effect tests and named detector calibrations."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-local-fabric-check'))
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--verilator', default=str(BUNDLE / 'bin/verilator'))
    args = parser.parse_args()
    build = args.build.resolve(); evidence = args.evidence.resolve()
    build.mkdir(parents=True, exist_ok=True); evidence.mkdir(parents=True, exist_ok=True)
    names = ['microcontroller/rtl/drg5_irq_platform.sv', 'microcontroller/rtl/drg5_local_fabric.sv',
             'microcontroller/tests/drg5_local_fabric_tb.sv', 'microcontroller/tests/run_local_fabric.py']
    sources = {name: digest(ROOT / name) for name in names}
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2', '-CFLAGS', '-O0',
               '--Mdir', str(build), '--top-module', 'drg5_local_fabric_tb', *names[:3]]
    code, output = run(command, evidence / 'build.log')
    # lint warnings are rejected rather than filtered or waived.
    if code or '%Warning' in output:
        raise RuntimeError('local-fabric strict build failed')
    results = {}
    modes = [('positive', [], 'LOCAL_FABRIC_PASS'),
             ('effect-detector', ['+mutate_effect'], 'LOCAL_FABRIC_CHECK output effect duplicated'),
             ('reset-detector', ['+bad_reset'], 'local reset requires isolation')]
    # a failing process qualifies only when it reaches the requested detector.
    for name, options, marker in modes:
        code, output = run([str(build / 'Vdrg5_local_fabric_tb'), *options], evidence / (name + '.log'))
        expected = code == 0 if name == 'positive' else code != 0
        seen = expected and marker in output and (name == 'positive' or 'LOCAL_FABRIC_PASS' not in output)
        results[name] = {'exit_code': code, 'expected_outcome_seen': seen, 'marker': marker}
    # files edited during execution invalidate the campaign's source attribution.
    stable = sources == {name: digest(ROOT / name) for name in names}
    passed = stable and all(row['expected_outcome_seen'] for row in results.values())
    record = {'status': 'passed' if passed else 'failed', 'source_sha256': sources,
              'source_stable': stable, 'results': results,
              'scope': 'bounded local-fabric directed simulation and checker calibration; no core ISA or physical FPGA claim',
              'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
              'tool_sha256': {str(Path(args.verilator).resolve()): digest(Path(args.verilator).resolve())}}
    (evidence / 'summary.json').write_text(json.dumps(record, indent=2) + '\n')
    # only the complete positive and named negative matrix earns the final marker.
    if not passed:
        raise RuntimeError('local-fabric qualification failed')
    print('LOCAL_FABRIC_QUALIFICATION_PASS ' + json.dumps(results))


# importing helpers must never build or modify evidence.
if __name__ == '__main__':
    main()

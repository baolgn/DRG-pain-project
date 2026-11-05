#!/usr/bin/env python3
"""qualify RV32M arithmetic, bounded ownership, detector sensitivity, and ECP5 mapping."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess


def execute(command, log, root):
    """retain the exact command and complete output even when a detector fails deliberately."""
    result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=300, check=False)
    log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
    return result


def main():
    """archive every attempted source snapshot before building or changing existing evidence."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--yosys', required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-muldiv-unit'))
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    evidence = (args.evidence_dir.resolve() if args.evidence_dir else
                root / 'microcontroller/tests/evidence/muldiv-unit-2026-11-04')
    revisions = evidence / 'revisions'
    revisions.mkdir(parents=True, exist_ok=True)
    index = 1
    # unique attempt directories preserve actual failed runs without artificial revision inflation.
    while any(revisions.glob(f'{index:02d}-*')):
        index += 1
    attempt = revisions / f'{index:02d}-qualification'
    attempt.mkdir()
    names = ['microcontroller/rtl/drg5_muldiv.sv', 'microcontroller/tests/drg5_muldiv_tb.sv',
             'microcontroller/tests/run_muldiv.py']
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
    # each attempt stores exact source bytes before any subprocess can observe them.
    for name in names:
        target = attempt / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    (attempt / 'source-sha256.json').write_text(json.dumps(before, indent=2, sort_keys=True) + '\n')
    results = {}
    logs = []

    def run(command, name):
        """use attempt-local logs so repeated builds cannot erase an earlier failure trace."""
        log = attempt / name
        logs.append(log)
        return execute(command, log, root)

    # a failed attempt remains visible and never replaces the last passing summary.
    try:
        command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2',
                   '--top-module', 'drg5_muldiv_tb', '--Mdir', str(build / 'obj'), *names[:2]]
        result = run(command, 'build.log')
        # no compiler warning is waived, including unused arithmetic bits or implicit truncation.
        if result.returncode or '%Warning' in result.stdout:
            raise RuntimeError(f'RV32M unit build failed: {attempt / "build.log"}')
        executable = str(build / 'obj/Vdrg5_muldiv_tb')
        # positive runs use explicit zero, one, and mixed-bit LCG seeds.
        for seed in [0, 1, 305419896]:
            result = run([executable, f'+seed={seed}', '+verilator+seed+1'], f'seed-{seed}.log')
            terminal = next((line for line in result.stdout.splitlines()
                             if line.startswith('MULDIV_PASS ')), '')
            fields = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', terminal)}
            # an incomplete positive run is a failure even when the process exits normally.
            if (result.returncode or fields.get('cases') != 67742 or fields.get('resets') != 156 or
                    fields.get('mul_latency') != 2 or fields.get('div_latency') != 33 or
                    fields.get('seed') != seed):
                raise RuntimeError(f'RV32M unit reference comparison failed: seed {seed}')
            results[f'seed-{seed}'] = {'exit': result.returncode, 'terminal': terminal, **fields}
            print(terminal, flush=True)
        calibrations = [
            ('result', '+mutate_result', 'MULDIV_CHECK_FAILED arithmetic result'),
            ('latency', '+mutate_latency', 'MULDIV_CHECK_FAILED completion latency'),
            ('uid', '+mutate_uid', 'MULDIV_CHECK_FAILED result identity'),
            ('hold', '+mutate_hold', 'MULDIV_CHECK_FAILED held result'),
            ('busy-start', '+misuse_start', 'arithmetic start while busy'),
        ]
        # observation mutations calibrate semantic comparators; busy-start exercises a DUT assertion.
        for name, flag, terminal in calibrations:
            result = run([executable, '+seed=1', '+verilator+seed+1', flag], f'detector-{name}.log')
            # unrelated crashes, missing markers, and unexpected passes never qualify a detector.
            if result.returncode == 0 or terminal not in result.stdout or 'MULDIV_PASS ' in result.stdout:
                raise RuntimeError(f'RV32M unit detector did not activate: {name}')
            results[f'detector-{name}'] = {'exit': result.returncode, 'expected_terminal': terminal}
            print('MULDIV_DETECTOR_PASS ' + name, flush=True)
        netlist = build / 'ecp5.json'
        script = ('read_slang --ignore-assertions --top drg5_muldiv ' + names[0] +
                  '; hierarchy -check; proc; opt; check -assert; '
                  'select -assert-none t:$dlatch t:$adlatch; '
                  'synth_ecp5 -noabc9 -top drg5_muldiv; check -assert; stat; write_json ' + str(netlist))
        result = run([args.yosys, '-Q', '-T', '-m', 'slang', '-p', script], 'mapping.log')
        allowed = {'ABC: Warning: The network is combinational.',
                   'ABC: Warning: The network is combinational (run "fraig" or "fraig_sweep").'}
        warnings = [line for line in result.stdout.splitlines() if 'Warning:' in line and line not in allowed]
        # successful parsing alone cannot qualify FPGA mapping or latch freedom.
        if result.returncode or warnings:
            raise RuntimeError(f'RV32M unit mapping failed: {warnings}')
        cells = Counter(cell['type'] for cell in
                        json.loads(netlist.read_text())['modules']['drg5_muldiv']['cells'].values())
        # the four limb multipliers must map to exactly four native ECP5 DSP multipliers.
        if cells.get('MULT18X18D') != 4:
            raise RuntimeError(f'unexpected RV32M multiplier mapping: {dict(cells)}')
        results['mapping'] = {'cells': dict(sorted(cells.items())),
                              'netlist_sha256': hashlib.sha256(netlist.read_bytes()).hexdigest()}
        after = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
        # concurrent source edits invalidate the entire run rather than receiving stale attribution.
        if before != after:
            raise RuntimeError('RV32M unit source changed during qualification')
        summary = {
            'scope': 'standalone RV32M 2.0 unit; pipeline ordering and interrupt entry are separate',
            'specification': 'https://docs.riscv.org/reference/isa/v20260120/unpriv/m-st-ext.html',
            'results': results, 'source_sha256': before,
            'versions': {'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
                         'yosys': subprocess.check_output([args.yosys, '-V'], text=True).strip()},
            'timing': {'unit_start_to_valid_edges': {'multiply': 2, 'divide': 33},
                       'ceilings': {'multiply': 4, 'divide': 36},
                       'assumptions': ['atomic start while idle; no request-acceptance wait',
                                       'clock runs continuously; no clock gating',
                                       'held result persists until ready; consumer delay is additional',
                                       'only cold reset cancels the owned arithmetic job']},
            'limits': ['finite seeded reference simulation; no all-input sequential arithmetic proof',
                       'technology synthesis only; no placed timing, route, or board-programming claim',
                       'no architectural debug interface or halt latency claim'],
        }
        (attempt / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
        shutil.copyfile(attempt / 'summary.json', evidence / 'summary.json')
        shutil.copytree(attempt / 'sources', evidence / 'sources', dirs_exist_ok=True)
        # logs remain available both at the current evidence root and in their immutable attempt.
        for log in logs:
            shutil.copyfile(log, evidence / log.name)
        (attempt / 'outcome.json').write_text('{"passed": true}\n')
        print('MULDIV_QUALIFICATION_PASS seeds=3 jobs=203226 detectors=5 mappings=1', flush=True)
    # preserve failed attempts without replacing the last passing evidence.
    except Exception as error:
        (attempt / 'outcome.json').write_text(json.dumps({'passed': False, 'error': str(error)}, indent=2) + '\n')
        raise


# importing the runner never launches tools or changes source-bound evidence.
if __name__ == '__main__':
    main()

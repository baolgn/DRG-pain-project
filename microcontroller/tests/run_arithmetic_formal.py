#!/usr/bin/env python3
"""prove all arithmetic inputs and require a deliberate counterexample."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """run the same unconstrained miter with and without one corrupted result bit."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--yosys', type=Path, required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-arithmetic-formal'))
    args = parser.parse_args()
    yosys = shutil.which(str(args.yosys)) or str(args.yosys.resolve())
    here = Path(__file__).resolve().parent
    rtl = here.parent / 'rtl'
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    sources = [rtl / 'drg5_shifter.sv', rtl / 'drg5_alu.sv', here / 'drg5_arithmetic_formal.sv']
    results = {}
    # seven assertions must survive lowering; no assumptions restrict operands.
    for name, mutation in [('positive', 0), ('negative', 1)]:
        script = (f'read_verilog -formal -I{rtl} -sv ' + ' '.join(map(str, sources)) +
                  f'; chparam -set MUTATE_RESULT {mutation} drg5_arithmetic_formal; '
                  'prep -top drg5_arithmetic_formal -flatten; chformal -lower; check -assert; '
                  'select -assert-count 7 t:$assert; select -assert-none t:$assume; '
                  'sat -verify -prove-asserts -set-def-inputs -show-inputs')
        command = [yosys, '-Q', '-T', '-p', script]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, check=False)
        (build / (name + '.log')).write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
        expected = 'SAT proof finished - no model found: SUCCESS!' if mutation == 0 else \
                   'ERROR: Called with -verify and proof did fail!'
        correct_status = result.returncode == 0 if mutation == 0 else result.returncode != 0
        # parser failures or missing assertions cannot satisfy either evidence gate.
        if not correct_status or expected not in result.stdout:
            raise RuntimeError(f'{name}: expected proof outcome missing; see {build}')
        results[name] = {'exit_code': result.returncode, 'expected_outcome_seen': True}
    sources += [rtl / 'drg5_datapath_defs.svh', Path(__file__).resolve()]
    summary = {'scope': 'all two-state inputs of ALU and shifter; no pipeline or RF proof',
               'assertions': 7, 'assumptions': 0, 'results': results,
               'sources': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sources}}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('ARITHMETIC_FORMAL_PASS assertions=7 assumptions=0 negative_detected=1')


# keep imports free of proof execution.
if __name__ == '__main__':
    main()

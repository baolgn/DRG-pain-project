#!/usr/bin/env python3
"""verify and map the independent branch unit without a complete CPU claim."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(command, log):
    """retain every command and its full diagnostic output."""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120, check=False)
    log.write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    return result


def main():
    """combine behavioral checks, unconstrained proofs and actual ECP5 mapping."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--yosys', required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-branch-tests'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    rtl = here.parent / 'rtl'
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which(args.yosys) or str(Path(args.yosys).resolve())
    sources = [rtl / 'drg5_branch.sv', rtl / 'drg5_datapath_defs.svh',
               here / 'drg5_branch_tb.sv', here / 'drg5_branch_formal.sv', Path(__file__).resolve()]
    results = {}
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-I' + str(rtl),
               '--top-module', 'drg5_branch_tb', '--Mdir', str(build / 'obj'),
               str(sources[0]), str(sources[2])]
    result = run(command, build / 'build.log')
    # any compilation diagnostic warning invalidates the behavioral qualification.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'branch build failed: {build / "build.log"}')
    # an observation corruption calibrates the intended behavioral comparator.
    for name, flags in [('behavioral', []), ('target_detector', ['+mutate_target'])]:
        result = run([str(build / 'obj/Vdrg5_branch_tb'), '+verilator+seed+1', *flags],
                     build / (name + '.log'))
        expected = result.returncode == 0 and 'BRANCH_PASS ' in result.stdout
        # the detector must identify the target comparison, not an unrelated error.
        if flags:
            expected = result.returncode != 0 and 'BRANCH_CHECK_FAILED target' in result.stdout
        # stop before preserving a failed test as a successful result.
        if not expected:
            raise RuntimeError(f'unexpected branch test outcome: {name}')
        results[name] = {'exit': result.returncode, 'expected_outcome_seen': True}
        print(name, result.stdout.splitlines()[0])

    def qualify(item):
        """isolate proof and mapping outputs so independent jobs can run concurrently."""
        kind, compressed, mutation = item
        name = f'{kind}-c{compressed}' + ('-negative' if mutation else '')
        script = f'read_verilog -formal -I{rtl} -sv {sources[0]}'
        # every input remains unconstrained in the independent arithmetic oracle.
        if kind == 'proof':
            script += (f' {sources[3]}; chparam -set C_ENABLED {compressed} '
                       f'-set MUTATE_LINK {mutation} drg5_branch_formal; '
                       'prep -top drg5_branch_formal -flatten; chformal -lower; '
                       'check -assert; select -assert-count 6 t:$assert; '
                       'select -assert-none t:$assume; '
                       'sat -verify -prove-asserts -set-def-inputs -show-inputs -timeout 45')
        # map both alignment configurations and reject accidental storage or latches.
        else:
            script += (f'; chparam -set C_ENABLED {compressed} drg5_branch; '
                       'hierarchy -check -top drg5_branch; proc; check -assert; '
                       'select -assert-none t:$dlatch t:$dff; '
                       f'synth_ecp5 -top drg5_branch -json {build / (name + ".json")}; '
                       'check -assert; stat')
        result = run([yosys, '-Q', '-T', '-p', script], build / (name + '.log'))
        expected = result.returncode == 0
        # a formal detector succeeds only with an actual failed proof result.
        if mutation:
            expected = result.returncode != 0 and 'ERROR: Called with -verify and proof did fail!' in result.stdout
        # successful proofs must retain the solver terminal, not merely exit zero.
        elif kind == 'proof':
            expected = expected and 'SAT proof finished - no model found: SUCCESS!' in result.stdout
        # tool failures and solver timeouts are never accepted evidence.
        if not expected:
            raise RuntimeError(f'unexpected branch qualification outcome: {name}')
        outcome = {'exit': result.returncode, 'expected_outcome_seen': True}
        # derive mapping counts from the actual technology netlist.
        if kind == 'synth':
            netlist = build / (name + '.json')
            cells = json.loads(netlist.read_text())['modules']['drg5_branch']['cells']
            counts = {}
            # retain every mapped primitive type, including any unexpected storage.
            for cell in cells.values():
                counts[cell['type']] = counts.get(cell['type'], 0) + 1
            outcome['cells'] = counts
            outcome['netlist_sha256'] = hashlib.sha256(netlist.read_bytes()).hexdigest()
        return name, outcome

    # proofs and mapping share only immutable sources and use distinct output files.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results.update(dict(pool.map(qualify, [('proof', 0, 0), ('proof', 1, 0),
                                             ('proof', 0, 1), ('synth', 0, 0), ('synth', 1, 0)])))
    summary = {'scope': 'independent decoded branch unit; optional original short lengths, no compressed decoder',
               'formal_assertions_per_configuration': 6, 'formal_assumptions': 0,
               'results': results,
               'versions': {'yosys': subprocess.check_output([yosys, '-V'], text=True).strip(),
                            'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip()},
               'sources': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('BRANCH_QUALIFICATION_PASS proofs=2 assertions=6 assumptions=0 mappings=2 detectors=2')


# avoid executing simulations or tools merely by importing the runner.
if __name__ == '__main__':
    main()

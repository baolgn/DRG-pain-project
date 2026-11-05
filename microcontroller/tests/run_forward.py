#!/usr/bin/env python3
"""verify both forwarding modes against independent simulation and formal references."""
import argparse
from collections import Counter
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(command, log):
    """retain the exact invocation and complete diagnostic output for every outcome."""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120, check=False)
    log.write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    return result


def main():
    """combine source-bound behavioral checks, unconstrained proofs and ECP5 mapping."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--yosys', required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-forward-tests'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    rtl = here.parent / 'rtl/drg5_forward.sv'
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which(args.yosys) or str(Path(args.yosys).resolve())
    sources = [rtl, here / 'drg5_forward_tb.sv', here / 'drg5_forward_formal.sv', Path(__file__).resolve()]
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall',
               '--top-module', 'drg5_forward_tb', '--Mdir', str(build / 'obj'), str(rtl), str(sources[1])]
    result = run(command, build / 'build.log')
    # a warning-bearing build cannot qualify the selector even when it produces a binary.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'forwarding build failed: {build / "build.log"}')
    results = {}
    cases = [('behavioral', [], 'FORWARD_PASS '),
             ('stall_detector', ['+mutate_stall'], 'FORWARD_CHECK_FAILED hazard'),
             ('fallback_detector', ['+mutate_fallback'], 'FORWARD_CHECK_FAILED source1 value')]
    # each corruption must fail at its own named semantic comparator without a passing terminal.
    for name, flags, terminal in cases:
        result = run([str(build / 'obj/Vdrg5_forward_tb'), '+verilator+seed+1', *flags], build / (name + '.log'))
        expected = result.returncode != 0 if flags else result.returncode == 0
        # unrelated crashes, incomplete positives and unexpected passes never qualify detectors.
        if not expected or terminal not in result.stdout or (flags and 'FORWARD_PASS ' in result.stdout):
            raise RuntimeError(f'unexpected forwarding result: {name}')
        results[name] = {'exit': result.returncode, 'expected_terminal_seen': True}
        print(name, next(line for line in result.stdout.splitlines() if terminal in line), flush=True)

    def qualify(item):
        """keep independent mode proofs and mappings in distinct output files."""
        kind, mode, mutation = item
        name = f'{kind}-f{mode}' + ('-negative' if mutation else '')
        # all producer identities, eligibility bits, readiness bits and data remain unconstrained.
        if kind == 'proof':
            script = (f'read_verilog -formal -sv {rtl} {sources[2]}; '
                      f'chparam -set FORWARDING {mode} -set MUTATE_HAZARD {mutation} drg5_forward_formal; '
                      'prep -top drg5_forward_formal -flatten; chformal -lower; check -assert; '
                      'select -assert-count 7 t:$assert; select -assert-none t:$assume; '
                      'sat -verify -prove-asserts -set-def-inputs -show-inputs -timeout 45')
        # technology mapping must preserve a purely combinational component.
        else:
            script = (f'read_verilog -sv {rtl}; chparam -set FORWARDING {mode} drg5_forward; '
                      'hierarchy -check -top drg5_forward; proc; check -assert; '
                      'select -assert-none t:$dlatch t:$adlatch t:$dff t:$adff t:$sdff; '
                      f'synth_ecp5 -top drg5_forward -json {build / (name + ".json")}; check -assert; stat')
        result = run([yosys, '-Q', '-T', '-p', script], build / (name + '.log'))
        expected = result.returncode == 0
        # the deliberately corrupted expected hazard must produce a genuine failed proof.
        if mutation:
            expected = result.returncode != 0 and 'ERROR: Called with -verify and proof did fail!' in result.stdout
        # a solver timeout or missing success terminal is not an all-input proof.
        elif kind == 'proof':
            expected = expected and 'SAT proof finished - no model found: SUCCESS!' in result.stdout
        warnings = [line for line in result.stdout.splitlines() if 'Warning:' in line
                    and line != 'ABC: Warning: The network is combinational.']
        # syntax errors and unexpected synthesis diagnostics cannot masquerade as a passing run.
        if not expected or warnings:
            raise RuntimeError(f'unexpected forwarding qualification outcome: {name}')
        outcome = {'exit': result.returncode, 'expected_terminal_seen': True}
        # actual mapped primitive counts are evidence, not RTL resource estimates.
        if kind == 'synth':
            netlist = build / (name + '.json')
            cells = json.loads(netlist.read_text())['modules']['drg5_forward']['cells']
            counts = dict(sorted(Counter(cell['type'] for cell in cells.values()).items()))
            # only combinational ECP5 primitives may remain in this selector.
            if set(counts) - {'LUT4', 'L6MUX21', 'PFUMX', 'CCU2C'}:
                raise RuntimeError(f'unexpected forwarding cell types: {counts}')
            outcome['cells'] = counts
            outcome['netlist_sha256'] = hashlib.sha256(netlist.read_bytes()).hexdigest()
        return name, outcome

    jobs = [('proof', 0, 0), ('proof', 1, 0), ('proof', 1, 1), ('synth', 0, 0), ('synth', 1, 0)]
    # no job mutates a shared input or another job's output directory entry.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results.update(dict(pool.map(qualify, jobs)))
    # reject concurrent edits instead of attributing old results to newly read source bytes.
    for path in sources:
        # all behavioral, proof and mapping results must refer to this one snapshot.
        if hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path)]:
            raise RuntimeError(f'forwarding source changed during qualification: {path}')
    summary = {'scope': 'combinational forwarding selection only; caller producer readiness and pipeline ownership are separate',
               'formal_assertions_per_mode': 7, 'formal_assumptions': 0, 'results': results,
               'sources': hashes,
               'versions': {'yosys': subprocess.check_output([yosys, '-V'], text=True).strip(),
                            'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip()}}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('FORWARD_QUALIFICATION_PASS modes=2 proofs=2 assertions=7 assumptions=0 mappings=2 detectors=3')


# importing the runner does not start tools or write qualification artifacts.
if __name__ == '__main__':
    main()

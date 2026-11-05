#!/usr/bin/env python3
"""qualify the standalone CSR inventory, previews, transitions and counter ordering."""
import argparse
from collections import Counter
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def execute(command, log, root):
    """retain the exact command and complete diagnostics, including intended failures."""
    result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=300, check=False)
    log.write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    return result


def main():
    """bind simulation, induction and structural mapping to one immutable source snapshot."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--yosys', required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-csr-tests'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which(args.yosys) or str(Path(args.yosys).resolve())
    sources = ['microcontroller/rtl/drg5_csr.sv', 'microcontroller/tests/drg5_csr_tb.sv',
               'microcontroller/tests/drg5_csr_formal.sv', 'microcontroller/tests/run_csr.py']
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2',
               '-CFLAGS', '-O0', '--top-module', 'drg5_csr_tb', '--Mdir', str(build / 'obj'), *sources[:2]]
    result = execute(command, build / 'build.log', root)
    # no HDL warning is waived in the executable qualification.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'CSR build failed: {build / "build.log"}')
    results = {}
    cases = [('behavioral', [], 'PASS CSR '),
             ('permission_detector', ['+mutate_permission'], 'permission mismatch'),
             ('suppression_detector', ['+mutate_suppression'], 'read suppression mismatch'),
             ('counter_detector', ['+mutate_counter'], 'clock-edge state mismatch'),
             ('trap_contract_detector', ['+invalid_trap'], 'unsupported trap cause supplied to CSR bank')]
    # each corruption or contract violation must fail its intended ordinary check.
    for name, flags, terminal in cases:
        result = execute([str(build / 'obj/Vdrg5_csr_tb'), '+verilator+seed+1', *flags], build / (name + '.log'), root)
        expected = result.returncode != 0 if flags else result.returncode == 0
        # unrelated crashes, missing terminals and accidental positive passes fail qualification.
        if not expected or terminal not in result.stdout or (flags and 'PASS CSR ' in result.stdout):
            raise RuntimeError(f'unexpected CSR simulation result: {name}')
        line = next(line for line in result.stdout.splitlines() if terminal in line)
        results[name] = {'exit': result.returncode, 'terminal': line}
        print(name, line, flush=True)

    def qualify(item):
        """keep independent alignment proofs and mappings in separate output files."""
        kind, compressed, mutation = item
        name = f'{kind}-c{compressed}' + ('-negative' if mutation else '')
        # induction assumes only initial reset and valid caller trap causes; CSR controls are unconstrained.
        if kind == 'proof':
            script = (f'read_verilog -formal -sv -D SYNTHESIS {sources[0]} {sources[2]}; '
                      f'chparam -set C_ENABLED {compressed} -set MUTATE_COUNTER {mutation} drg5_csr_formal; '
                      'prep -top drg5_csr_formal -flatten; async2sync; chformal -lower; check -assert; '
                      'select -assert-count 7 t:$assert; select -assert-count 2 t:$assume; '
                      'sat -seq 4 -tempinduct -prove-asserts -set-assumes -verify -show-inputs -timeout 90')
        # assertions enforce caller contracts in simulation and are intentionally absent from hardware.
        else:
            script = (f'read_verilog -sv -D SYNTHESIS {sources[0]}; '
                      f'chparam -set C_ENABLED {compressed} drg5_csr; '
                      'hierarchy -check -top drg5_csr; proc; check -assert; '
                      'select -assert-none t:$dlatch t:$adlatch; '
                      f'synth_ecp5 -noabc9 -top drg5_csr -json {build / (name + ".json")}; check -assert; stat')
        result = execute([yosys, '-Q', '-T', '-p', script], build / (name + '.log'), root)
        expected = result.returncode == 0
        # the modified expected counter must produce a failed proof rather than a timeout.
        if mutation:
            expected = result.returncode != 0 and 'ERROR: Called with -verify and proof did fail!' in result.stdout
        # an induction result is required; a finite base-case success alone is insufficient.
        elif kind == 'proof':
            expected = expected and 'Induction step proven: SUCCESS!' in result.stdout
        allowed = {'ABC: Warning: The network is combinational (run "fraig" or "fraig_sweep").'}
        warnings = [line for line in result.stdout.splitlines() if 'Warning:' in line and line not in allowed]
        # the exact classic ABC scorr advisory is documented by the pinned synthesis flow.
        if not expected or warnings:
            raise RuntimeError(f'unexpected CSR tool result: {name}')
        outcome = {'exit': result.returncode, 'expected_terminal_seen': True}
        # retain primitive counts and output identity without claiming place-and-route timing.
        if kind == 'synth':
            netlist = build / (name + '.json')
            cells = json.loads(netlist.read_text())['modules']['drg5_csr']['cells']
            counts = dict(sorted(Counter(cell['type'] for cell in cells.values()).items()))
            # only recognized logic, carry and flip-flop primitives may remain.
            if set(counts) - {'LUT4', 'L6MUX21', 'PFUMX', 'CCU2C', 'TRELLIS_FF'}:
                raise RuntimeError(f'unexpected CSR mapped cells: {counts}')
            outcome['cells'] = counts
            outcome['netlist_sha256'] = hashlib.sha256(netlist.read_bytes()).hexdigest()
        return name, outcome

    jobs = [('proof', 0, 0), ('proof', 1, 0), ('proof', 1, 1), ('synth', 0, 0), ('synth', 1, 0)]
    # jobs share read-only sources and retain separate proof/map artifacts.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results.update(dict(pool.map(qualify, jobs)))
    after = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}
    # concurrent source edits invalidate the entire qualification attribution.
    if before != after:
        raise RuntimeError('CSR qualification sources changed during execution')
    summary = {'scope': 'standalone M-only CSR bank; raw CSR decode, interrupt delivery and pipeline arbitration are separate',
               'simulation_profiles': ['C0 default identity', 'C1 default identity', 'C1 explicitly supplied misa/mimpid'],
               'formal_profiles': ['C0 default identity', 'C1 default identity'],
               'formal_assertions_per_profile': 7,
               'formal_assumptions': ['first clock resets bank', 'non-reset trap cause belongs to implemented caller contract'],
               'results': results, 'source_sha256': after,
               'versions': {'yosys': subprocess.check_output([yosys, '-V'], text=True).strip(),
                            'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip()},
               'limits': ['two-state induction with declared caller assumptions',
                          'debug inputs test counter policy only; no debug subsystem is implemented',
                          'synthesis omits caller assertion and establishes no timing or mapped equivalence',
                          'normalized read/write controls are inputs; encoded index/value suppression is checked in integration']}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('CSR_QUALIFICATION_PASS profiles=3 proofs=2 assertions=7 assumptions=2 mappings=2 detectors=5')


# importing the runner does not start tools or mutate evidence.
if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""verify LSU byte behavior and map every optional region configuration."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(command, log):
    """retain exact commands and complete diagnostic output for every outcome."""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120, check=False)
    log.write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    return result


def main():
    """combine byte-reference simulation, all-input proofs and actual ECP5 mapping."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--yosys', required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-lsu-tests'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    rtl = here.parent / 'rtl/drg5_lsu.sv'
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which(args.yosys) or str(Path(args.yosys).resolve())
    sources = [rtl, here / 'drg5_lsu_tb.sv', here / 'drg5_lsu_formal.sv', Path(__file__).resolve()]
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    results = {}
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall',
               '--top-module', 'drg5_lsu_tb', '--Mdir', str(build / 'obj'), str(rtl), str(sources[1])]
    result = run(command, build / 'build.log')
    # warning-bearing builds cannot qualify the helper's behavioral evidence.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'LSU build failed: {build / "build.log"}')
    cases = [('behavioral', [], 'LSU_PASS '),
             ('store_detector', ['+mutate_store'], 'LSU_CHECK_FAILED store lanes'),
             ('sign_detector', ['+mutate_sign'], 'LSU_CHECK_FAILED load extension')]
    # each deliberate corruption must reach its named comparator without a passing terminal.
    for name, flags, terminal in cases:
        result = run([str(build / 'obj/Vdrg5_lsu_tb'), '+verilator+seed+1', *flags],
                     build / (name + '.log'))
        expected = result.returncode != 0 if flags else result.returncode == 0
        # a negative control cannot inherit a prior positive pass marker.
        if flags:
            expected = expected and 'LSU_PASS ' not in result.stdout
        # unrelated crashes and missing detector activation are failures, not evidence.
        if not expected or terminal not in result.stdout:
            raise RuntimeError(f'unexpected LSU outcome: {name}')
        results[name] = {'exit': result.returncode, 'expected_outcome_seen': True}
        print(name, next(line for line in result.stdout.splitlines() if terminal in line), flush=True)

    def qualify(item):
        """isolate all outputs before running independent profiles concurrently."""
        kind, profile, mutation = item
        name = f'{kind}-p{profile}' + ('-negative' if mutation else '')
        params = (f'-set TEST_REGIONS {(profile >> 2) & 1} '
                  f'-set IRAM_WRITE {(profile >> 1) & 1} -set TIMER_ENABLED {profile & 1}')
        # all address, direction, width and data inputs remain unconstrained in each proof.
        if kind == 'proof':
            script = (f'read_verilog -formal -sv {rtl} {sources[2]}; '
                      f'chparam {params} -set MUTATE_STORE {mutation} drg5_lsu_formal; '
                      'prep -top drg5_lsu_formal -flatten; chformal -lower; check -assert; '
                      'select -assert-count 6 t:$assert; select -assert-none t:$assume; '
                      'sat -verify -prove-asserts -set-def-inputs -show-inputs -timeout 45')
        # map the same public helper with no hidden state or inferred latch permitted.
        else:
            script = (f'read_verilog -sv {rtl}; chparam {params} drg5_lsu; '
                      'hierarchy -check -top drg5_lsu; proc; check -assert; '
                      'select -assert-none t:$dlatch t:$dff t:$adff t:$sdff; '
                      f'synth_ecp5 -top drg5_lsu -json {build / (name + ".json")}; check -assert; stat')
        result = run([yosys, '-Q', '-T', '-p', script], build / (name + '.log'))
        expected = result.returncode == 0
        # the corrupted expected-store proof must produce an actual counterexample.
        if mutation:
            expected = result.returncode != 0 and 'ERROR: Called with -verify and proof did fail!' in result.stdout
        # proof success requires the exact solver terminal after property-count guards.
        elif kind == 'proof':
            expected = expected and 'SAT proof finished - no model found: SUCCESS!' in result.stdout
        # synthesis failures, parser errors and solver timeouts never qualify.
        if not expected:
            raise RuntimeError(f'unexpected LSU qualification outcome: {name}')
        outcome = {'exit': result.returncode, 'expected_outcome_seen': True}
        # retain counts from the actual technology netlist rather than RTL estimates.
        if kind == 'synth':
            netlist = build / (name + '.json')
            cells = json.loads(netlist.read_text())['modules']['drg5_lsu']['cells']
            counts = {}
            # every mapped primitive is included, even if unexpectedly inferred.
            for cell in cells.values():
                counts[cell['type']] = counts.get(cell['type'], 0) + 1
                # a combinational helper must never acquire storage in technology mapping.
                if 'FF' in cell['type'] or 'RAM' in cell['type'] or 'LATCH' in cell['type']:
                    raise RuntimeError(f'unexpected LSU storage: {cell["type"]}')
            outcome['cells'] = counts
            outcome['netlist_sha256'] = hashlib.sha256(netlist.read_bytes()).hexdigest()
        return name, outcome

    jobs = [('proof', profile, 0) for profile in range(8)]
    jobs += [('proof', 0, 1)] + [('synth', profile, 0) for profile in range(8)]
    # independent configurations use separate logs and netlists with immutable shared inputs.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results.update(dict(pool.map(qualify, jobs)))
    # reject concurrent changes instead of describing final source bytes as the tested snapshot.
    for path in sources:
        # every formal, behavioral and mapping result must refer to identical source bytes.
        if hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path)]:
            raise RuntimeError(f'LSU source changed during qualification: {path}')
    summary = {'scope': 'combinational LSU policy and lane helper only; no bus ownership or response-status proof',
               'profiles': 'bit2 TEST_REGIONS, bit1 IRAM_WRITE, bit0 TIMER_ENABLED',
               'formal_assertions_per_profile': 6, 'formal_assumptions': 0,
               'results': results, 'sources': hashes,
               'versions': {'yosys': subprocess.check_output([yosys, '-V'], text=True).strip(),
                            'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip()}}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('LSU_QUALIFICATION_PASS profiles=8 proofs=8 assertions=6 assumptions=0 mappings=8 detectors=3')


# importing the runner never launches tools or changes evidence.
if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""lint and map each standalone datapath module with explicit tool paths."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    """bind evidence to the exact source or executable."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log):
    """retain tool output and reject failed lint or synthesis."""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, check=False)
    log.write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    # never convert an unsuccessful tool run into qualification evidence.
    if result.returncode:
        raise RuntimeError(f'{log}: exit {result.returncode}')
    return result.stdout


def main():
    """check state-free logic separately from the intentionally stateful RF."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--yosys', type=Path, required=True)
    parser.add_argument('--verilator', type=Path, required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-datapath-synth'))
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    rtl = Path(__file__).resolve().parent.parent / 'rtl'
    build, evidence = args.build.resolve(), args.evidence.resolve()
    build.mkdir(parents=True, exist_ok=True)
    evidence.mkdir(parents=True, exist_ok=True)
    yosys, verilator = args.yosys.resolve(), args.verilator.resolve()
    names = ['decoder', 'immediate', 'alu', 'shifter', 'regfile']
    versions = {'yosys': run([str(yosys), '-V'], evidence / 'yosys-version.log'),
                'verilator': run([str(verilator), '--version'], evidence / 'verilator-version.log')}

    def module(name):
        """reject latches, unexpected state and unmapped behavioral cells."""
        top = 'drg5_' + name
        sources = [rtl / (top + '.sv')]
        # the ALU instantiates the independently checked shifter.
        if name == 'alu':
            sources.append(rtl / 'drg5_shifter.sv')
        run([str(verilator), '--lint-only', '-Wall', '-I' + str(rtl), '--top-module', top] +
            list(map(str, sources)), evidence / (name + '-lint.log'))
        netlist = build / (name + '.json')
        script = (f'read_verilog -I{rtl} -sv ' + ' '.join(map(str, sources)) +
                  f'; hierarchy -check -top {top}; proc; check -assert; '
                  'select -assert-none t:$dlatch t:$adlatch t:$dlatchsr; '
                  f'synth_ecp5 -top {top} -json {netlist}; check -assert; stat')
        run([str(yosys), '-Q', '-T', '-p', script], evidence / (name + '-synth.log'))
        design = json.loads(netlist.read_text())['modules'][top]
        counts = {}
        allowed = {'LUT4', 'PFUMX', 'L6MUX21', 'CCU2C', '$scopeinfo'}
        # only the selected RF may contain storage primitives.
        if name == 'regfile':
            allowed |= {'TRELLIS_FF', 'TRELLIS_DPR16X4'}
        # mapped cells must belong to the explicit ECP5 primitive set.
        for cell in design['cells'].values():
            kind = cell['type']
            # an unknown cell can hide a latch, black box or unsupported construct.
            if kind not in allowed:
                raise RuntimeError(f'{name}: unexpected mapped cell {kind}')
            counts[kind] = counts.get(kind, 0) + 1
        return name, {'cells': counts, 'netlist_sha256': digest(netlist),
                      'lint_pass': True, 'check_pass': True, 'no_latches': True}

    # each module has separate logs and netlists, so independent jobs cannot collide.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = dict(pool.map(module, names))
    sources = [rtl / ('drg5_' + name + '.sv') for name in names]
    sources += [rtl / 'drg5_datapath_defs.svh', Path(__file__).resolve()]
    summary = {'scope': 'standalone strict lint and ECP5 synthesis; no full CPU timing claim',
               'versions': versions, 'modules': results,
               'sources': {str(path): digest(path) for path in sources}}
    (evidence / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps(results, indent=2, sort_keys=True))


# permit direct execution without running work when imported.
if __name__ == '__main__':
    main()

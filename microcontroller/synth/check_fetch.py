#!/usr/bin/env python3
"""lint and map both fetch framing profiles without claiming CPU timing."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(command, log):
    """retain complete tool diagnostics and reject an unsuccessful stage."""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, check=False)
    log.write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    # tool failures cannot become successful qualification records.
    if result.returncode:
        raise RuntimeError(f'{log}: exit {result.returncode}')
    return result.stdout


def main():
    """check complete fetch hierarchies with the default map and deadline."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--yosys', required=True)
    parser.add_argument('--verilator', required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-fetch-synth'))
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    rtl = Path(__file__).resolve().parent.parent / 'rtl'
    build, evidence = args.build.resolve(), args.evidence.resolve()
    build.mkdir(parents=True, exist_ok=True)
    evidence.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which(args.yosys) or str(Path(args.yosys).resolve())
    verilator = shutil.which(args.verilator) or str(Path(args.verilator).resolve())
    sources = [rtl / ('drg5_fetch' + suffix + '.sv') for suffix in ['_guard', '_buffer', '']]
    versions = {'yosys': run([yosys, '-V'], evidence / 'yosys-version.log'),
                'verilator': run([verilator, '--version'], evidence / 'verilator-version.log')}
    results = {}
    # compressed framing changes the assembler, never the advertised decoder ISA.
    for compressed in [0, 1]:
        name = 'c' + str(compressed)
        run([verilator, '--lint-only', '-Wall', '--top-module', 'drg5_fetch',
             '-GC_FETCH=' + str(compressed)] + list(map(str, sources)), evidence / (name + '-lint.log'))
        netlist = build / (name + '.json')
        script = ('read_verilog -sv ' + ' '.join(map(str, sources)) +
                  f'; chparam -set C_FETCH {compressed} drg5_fetch; '
                  'hierarchy -check -top drg5_fetch; proc; check -assert; '
                  'select -assert-none t:$dlatch t:$adlatch t:$dlatchsr; '
                  f'synth_ecp5 -top drg5_fetch -json {netlist}; check -assert; stat')
        run([yosys, '-Q', '-T', '-p', script], evidence / (name + '-synth.log'))
        counts = {}
        # reject behavioral black boxes, unintended memories and latch cells.
        for cell in json.loads(netlist.read_text())['modules']['drg5_fetch']['cells'].values():
            kind = cell['type']
            # only explicit ECP5 combinational primitives and edge registers remain.
            if kind not in {'LUT4', 'PFUMX', 'L6MUX21', 'CCU2C', 'TRELLIS_FF', '$scopeinfo'}:
                raise RuntimeError(f'{name}: unexpected mapped primitive {kind}')
            counts[kind] = counts.get(kind, 0) + 1
        results[name] = {'cells': counts, 'no_latches': True, 'check_pass': True,
                         'netlist_sha256': hashlib.sha256(netlist.read_bytes()).hexdigest()}
    sources.append(Path(__file__).resolve())
    summary = {'scope': 'standalone fetch synthesis; no route or complete CPU qualification',
               'versions': versions, 'profiles': results,
               'sources': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sources}}
    (evidence / 'synthesis-summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps(results, indent=2, sort_keys=True))


# avoid tool execution when imported for inspection.
if __name__ == '__main__':
    main()

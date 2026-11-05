#!/usr/bin/env python3
"""compare RF storage on the pinned exact ECP5 target without programming hardware."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess


def digest(path):
    """hash an input or generated artifact for reproducibility."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, env=None):
    """retain the exact command and fail on any failed tool stage."""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, env=env, check=False)
    log.write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    # stop rather than preserving a failed stage as successful evidence.
    if result.returncode:
        raise RuntimeError(f'{log}: exit {result.returncode}')
    return result.stdout


def cells(path, top):
    """count actual mapped primitives rather than estimating RTL array cost."""
    design = json.loads(path.read_text())
    counts = {}
    # count every mapped primitive in the selected top module.
    for cell in design['modules'][top]['cells'].values():
        counts[cell['type']] = counts.get(cell['type'], 0) + 1
        # no candidate may acquire an unintended latch.
        if 'latch' in cell['type'].lower():
            raise RuntimeError(f'unexpected latch in {path}')
    return counts


def main():
    """map each candidate and route its identical clocked harness."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-rf-map'))
    parser.add_argument('--evidence', type=Path,
                        default=Path(__file__).parent / 'evidence/register-file-2026-11-04')
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    tools, build, evidence = args.tools.resolve(), args.build.resolve(), args.evidence.resolve()
    build.mkdir(parents=True, exist_ok=True)
    evidence.mkdir(parents=True, exist_ok=True)
    pinned = {
        'libexec/yosys': 'd3f9cc84a6fc75d0052f63cd7f8c812f5a9169722c82ca4014521dce4de8eace',
        'libexec/nextpnr-ecp5': '498e756aadb0fff24a0645adfe5904397c7393d1f7a2ad660e59fba5236bbedc',
        'libexec/yosys-abc': '16533de41738eda7d84759e74a311a64a698612a2aa165f46ca8b23bb91e4029',
    }
    # reject silent tool substitution before assigning the historical bundle pin.
    for relative, expected_hash in pinned.items():
        # executable identity is stronger than an unchanged version string.
        if digest(tools / relative) != expected_hash:
            raise RuntimeError(f'unqualified tool bytes: {relative}')
    yosys = tools / 'bin/yosys'
    loader = tools / 'lib/ld-linux-x86-64.so.2'
    nextpnr = [str(loader), '--inhibit-cache', '--inhibit-rpath', '', '--library-path',
               str(tools / 'lib'), str(tools / 'libexec/nextpnr-ecp5')]
    env = os.environ.copy()
    env.update(XDG_CONFIG_HOME=str(build / 'config'), XDG_CACHE_HOME=str(build / 'cache'),
               XDG_DATA_HOME=str(build / 'data'), QT_QPA_PLATFORM='offscreen')
    candidate_sources = [here / ('drg5_rf_' + name + '.sv') for name in ['ff', 'distributed', 'bram']]
    candidate_sources.append(here.parent / 'rtl/drg5_regfile.sv')
    sources = candidate_sources + [here / 'drg5_rf_map.sv',
               here / 'drg5_rf_pll.v', here / 'drg5_rf_ulx3s.lpf']
    versions = {'yosys': run([str(yosys), '-V'], evidence / 'yosys-version.log'),
                'nextpnr': run(nextpnr + ['--version'], evidence / 'nextpnr-version.log', env)}

    def candidate(item):
        """keep candidate outputs independent so parallel runs cannot collide."""
        number, name = item
        out = build / name
        out.mkdir(exist_ok=True)
        top = 'drg5_regfile' if name == 'selected' else 'drg5_rf_' + name
        standalone = out / 'rf.json'
        script = (f'read_verilog -sv {candidate_sources[number]}; hierarchy -check -top {top}; '
                  f'proc; check -assert; select -assert-none t:$dlatch; '
                  f'synth_ecp5 -top {top} -json {standalone}; check -assert; stat')
        run([str(yosys), '-Q', '-T', '-p', script], evidence / f'{name}-standalone.log')
        netlist = out / 'harness.json'
        script = (f'read_verilog -lib +/ecp5/cells_bb.v; '
                  f'read_verilog -sv {candidate_sources[number]} {sources[4]} {sources[5]}; '
                  f'chparam -set CANDIDATE {number} drg5_rf_map; '
                  f'hierarchy -check -top drg5_rf_map; proc; check -assert; '
                  f'select -assert-none t:$dlatch; '
                  f'synth_ecp5 -top drg5_rf_map -json {netlist}; check -assert; stat')
        run([str(yosys), '-Q', '-T', '-p', script], evidence / f'{name}-harness.log')
        report = evidence / f'{name}-route.json'
        run(nextpnr + ['--85k', '--package', 'CABGA381', '--speed', '6', '--seed', '1',
                       '--freq', '80', '--json', str(netlist), '--lpf', str(sources[6]),
                       '--report', str(report), '--textcfg', str(out / 'route.config')],
            evidence / f'{name}-route.log', env)
        routed = json.loads(report.read_text())
        return name, {'read_latency_clocks': 1 if name == 'bram' else 0,
                      'standalone_cells': cells(standalone, top),
                      'harness_cells': cells(netlist, 'drg5_rf_map'),
                      'route_utilization': routed['utilization'], 'fmax': routed['fmax'],
                      'standalone_netlist_sha256': digest(standalone),
                      'harness_netlist_sha256': digest(netlist),
                      'route_config_sha256': digest(out / 'route.config')}

    # isolate candidate outputs while mapping independent designs concurrently.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = dict(pool.map(candidate, enumerate(['ff', 'distributed', 'bram', 'selected'])))
    summary = {'target': 'LFE5U-85F-6BG381C', 'clock_mhz': 80, 'seed': 1,
               'tool_bundle_sha256': 'dc3ef21adfc388494dc25f9cf4671d8ad1dd7d4b4153fdbc3dcc8debad769547',
               'versions': versions, 'tool_binary_sha256': pinned, 'sources': {os.path.relpath(p, here): digest(p) for p in sources},
               'mapping_script_sha256': digest(Path(__file__).resolve()), 'candidates': results,
               'scope': 'standalone RF plus matched synthetic route harness; no full CPU or hardware pass'}
    (evidence / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps(results, indent=2, sort_keys=True))


# run only when invoked as the mapping entry point.
if __name__ == '__main__':
    main()

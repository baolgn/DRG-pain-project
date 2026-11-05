#!/usr/bin/env python3
"""verify delayed target faults and stale replies through the fetch/control bridge."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    """retain strict simulation commands and independently corrupted observations."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-control-fetch-tests'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    rtl = here.parent / 'rtl'
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    sources = [rtl / (name + '.sv') for name in ['drg5_control_pkg', 'drg5_immediate',
               'drg5_decoder', 'drg5_decompress', 'drg5_branch', 'drg5_lsu', 'drg5_shifter', 'drg5_alu', 'drg5_forward', 'drg5_fetch_guard', 'drg5_fetch_buffer',
               'drg5_fetch', 'drg5_csr', 'drg5_control']]
    sources.append(here / 'drg5_control_fetch_tb.sv')
    all_sources = sources + [rtl / 'drg5_datapath_defs.svh', Path(__file__).resolve()]
    source_hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in all_sources}
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-I' + str(rtl),
               '--top-module', 'drg5_control_fetch_tb', '--Mdir', str(build / 'obj')]
    command += [str(path) for path in sources]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120, check=False)
    (build / 'build.log').write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    # a warning-bearing build never qualifies this bridge.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'control/fetch build failed: {build / "build.log"}')
    results = {}
    cases = [('positive', [], 'CONTROL_FETCH_PASS cases=3'),
             ('target_detector', ['+mutate_target_fault'],
              'CONTROL_FETCH_CHECK_FAILED target instruction owns its fault'),
             ('stale_detector', ['+mutate_stale_drop'],
              'CONTROL_FETCH_CHECK_FAILED live versus stale reply disposition')]
    # every detector must fail at its own semantic comparator rather than merely exit.
    for name, flags, terminal in cases:
        command = [str(build / 'obj/Vdrg5_control_fetch_tb'), '+verilator+seed+1', *flags]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=120, check=False)
        (build / (name + '.log')).write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
        expected = result.returncode != 0 if flags else result.returncode == 0
        # a detector run cannot also advertise a complete positive result.
        if flags:
            expected = expected and 'CONTROL_FETCH_PASS ' not in result.stdout
        # fixture timeouts, parser errors and unrelated crashes cannot qualify.
        if not expected or terminal not in result.stdout:
            raise RuntimeError(f'unexpected control/fetch result: {name}: {result.stdout}')
        results[name] = {'exit': result.returncode, 'expected_terminal_seen': True}
        print(name, next(line for line in result.stdout.splitlines() if terminal in line))
    # reject a run if any concurrent edit changed the source bytes used for qualification.
    for path in all_sources:
        # source hashes describe the pre-build snapshot, never merely the final filesystem.
        if hashlib.sha256(path.read_bytes()).hexdigest() != source_hashes[str(path)]:
            raise RuntimeError(f'source changed during control/fetch verification: {path}')
    summary = {'scope': 'non-C verification bridge only; no production frontend or full CPU qualification',
               'stress_response_deadline': 32, 'results': results,
               'version': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
               'sources': source_hashes}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')


# keep import free of simulation and artifact creation.
if __name__ == '__main__':
    main()

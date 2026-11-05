#!/usr/bin/env python3
"""run RF behavioral checks and deliberately corrupted-observation controls."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    """build all candidates and the selected module without warning suppression."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-regfile-tests'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    sources = [here.parent / 'synth' / ('drg5_rf_' + name + '.sv')
               for name in ['ff', 'distributed', 'bram']]
    sources += [here.parent / 'rtl/drg5_regfile.sv', here / 'drg5_regfile_tb.sv']
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall',
               '--top-module', 'drg5_regfile_tb', '--Mdir', str(build / 'obj')]
    command += [str(path) for path in sources]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (build / 'build.log').write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    # refuse compilation failure or warning-bearing qualification.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'RF build failed: {build / "build.log"}')
    cases = [('positive', []), ('x0_detector', ['+mutate_x0']),
             ('bypass_detector', ['+mutate_bypass'])]
    results = {}
    # require the expected terminal for every positive or negative control.
    for name, flags in cases:
        command = [str(build / 'obj/Vdrg5_regfile_tb'), '+verilator+seed+1', *flags]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (build / (name + '.log')).write_text(result.stdout)
        expected = result.returncode == 0 and 'RF_PASS ' in result.stdout
        # a failed detector control must identify the intended value comparison.
        if flags:
            expected = result.returncode != 0 and 'RF_CHECK_FAILED async read1 value or bypass' in result.stdout
        # an unrelated crash or timeout never qualifies a detector.
        if not expected:
            raise RuntimeError(f'unexpected RF result: {name}: {result.stdout}')
        results[name] = {'exit': result.returncode, 'expected_result': True}
        print(name, result.stdout.splitlines()[0])
    metadata = {'results': results,
                'version': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
                'sources': {str(p.relative_to(here.parent)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in sources}}
    (build / 'results.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')


# keep imports side-effect free for tool and artifact inspection.
if __name__ == '__main__':
    main()

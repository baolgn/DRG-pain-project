#!/usr/bin/env python3
"""run fetch assembly checks and an independently corrupted-observation control."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    """build both framing configurations with all warnings and assertions enabled."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-fetch-buffer-tests'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    sources = [here.parent / 'rtl/drg5_fetch_buffer.sv', here / 'drg5_fetch_buffer_tb.sv']
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall',
               '--top-module', 'drg5_fetch_buffer_tb', '--Mdir', str(build / 'obj')]
    command += [str(path) for path in sources]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120)
    (build / 'build.log').write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
    # warnings and compilation failures cannot qualify this component.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'fetch buffer build failed: {build / "build.log"}')
    results = {}
    # require the positive terminal and the intended failed value comparator.
    for name, flags in [('positive', []), ('raw_detector', ['+mutate_raw'])]:
        command = [str(build / 'obj/Vdrg5_fetch_buffer_tb'), '+verilator+seed+1', *flags]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=120)
        (build / (name + '.log')).write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
        expected = result.returncode == 0 and 'FETCH_BUFFER_PASS ' in result.stdout
        # an unrelated crash never counts as successful detector calibration.
        if flags:
            expected = result.returncode != 0 and 'FETCH_BUFFER_CHECK_FAILED packet raw' in result.stdout
        # preserve every failure for review before refusing the run.
        if not expected:
            raise RuntimeError(f'unexpected fetch buffer result: {name}: {result.stdout}')
        results[name] = {'exit': result.returncode, 'expected_result': True}
        print(name, result.stdout.splitlines()[0])
    metadata = {'results': results,
                'version': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
                'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'sources': {str(p.relative_to(here.parent)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in sources}}
    (build / 'results.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')


# keep importing the runner free from simulation side effects.
if __name__ == '__main__':
    main()

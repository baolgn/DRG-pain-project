#!/usr/bin/env python3
"""retain strict acquisition-guard simulations and their exact source snapshots."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    """identify the exact source or tool bytes consumed by this run."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    """build three independent elaborations without modifying earlier evidence."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=Path, default=Path('/tmp/drg5-control-tools-20260301/oss-cad-suite'))
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    build = args.build.resolve(); build.mkdir(parents=True, exist_ok=True)
    rtl = ROOT / 'microcontroller/rtl/drg5_acquisition_guard.sv'
    cpp = ROOT / 'microcontroller/tests/acquisition_guard_sim.cpp'
    attributed = [rtl, cpp, Path(__file__).resolve(), ROOT / 'microcontroller/acquisition/README.md']
    hashes = {str(path.relative_to(ROOT)): digest(path) for path in attributed}
    # preserved inputs make failed attempts reviewable after later corrections.
    for path in attributed:
        destination = output / 'sources' / path.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, destination)
    verilator = args.tools.resolve() / 'bin/verilator'
    result = {'schema': 'DRG5-ACQUISITION-GUARD-1', 'status': 'started', 'source_sha256': hashes,
              'verilator_sha256': digest(verilator), 'profiles': [],
              'scope': 'standalone synthesizable slot/stop/record guard; modeled external FIFO/DMA acknowledgements; no ADC, board or full-system qualification'}
    passed = True
    # the reduced counter limit changes capacity only; P25 is an explicit rejected profile.
    for name, generics, defines in [('F80', [], []), ('counter-limit', ["-GCOUNTER_LIMIT=64'h7"], ['-DTEST_COUNTER_LIMIT=7']),
                                    ('P25-rejected', ['-GCLOCK_HZ=25000000'], ['-DTEST_CLOCK_HZ=25000000'])]:
        directory = output / name; directory.mkdir()
        command = [str(verilator), '--cc', '--exe', '--build', '--assert', '-Wall', '-j', '2',
            '-CFLAGS', '-O2 -std=c++20 ' + ' '.join(defines), '--top-module', 'drg5_acquisition_guard',
            '--Mdir', str(build / name), *generics, str(rtl), str(cpp)]
        # warnings remain fatal and every build log is retained.
        with (directory / 'build.log').open('w') as log:
            built = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False)
        item = {'profile': name, 'command': command, 'build_exit': built.returncode, 'cases': []}
        ok = built.returncode == 0 and '%Warning' not in (directory / 'build.log').read_text()
        # only a successful strict build may contribute execution evidence.
        if ok:
            executable = build / name / 'Vdrg5_acquisition_guard'
            run = subprocess.run([str(executable)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=120, check=False)
            (directory / 'run.log').write_text(run.stdout)
            item['run_exit'] = run.returncode; item['executable_sha256'] = digest(executable)
            item['cases'] = [json.loads(line.split(' ', 1)[1]) for line in run.stdout.splitlines() if line.startswith('GUARD_CASE_PASS ')]
            ok &= run.returncode == 0 and run.stdout.count('ACQUISITION_GUARD_PASS') == 1 and bool(item['cases'])
        item['passed'] = ok; result['profiles'].append(item); passed &= ok
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)
    result['source_stable'] = hashes == {str(path.relative_to(ROOT)): digest(path) for path in attributed}
    passed &= result['source_stable']; result['status'] = 'passed' if passed else 'failed'
    result['cases'] = sum(len(profile['cases']) for profile in result['profiles'])
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    # an incomplete campaign is not replaced by a passing summary from another profile.
    if not passed:
        raise RuntimeError('acquisition guard campaign failed: ' + str(output))
    print('ACQUISITION_GUARD_CAMPAIGN_PASS cases=' + str(result['cases']))


# importing the runner performs no simulation, evidence writes or device operations.
if __name__ == '__main__':
    main()

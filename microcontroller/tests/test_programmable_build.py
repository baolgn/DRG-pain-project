#!/usr/bin/env python3
"""check fixed-target build admission before expensive tools can run."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    """exercise valid input, incompatible ROM and unavailable stage overrides."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    wrapper = ROOT / 'microcontroller/synth/run_programmable.py'
    reports = []
    # temporary negative firmware must never alter the sealed original.
    with tempfile.TemporaryDirectory(prefix='drg5-build-guard-') as temporary:
        alternate = Path(temporary) / 'alternate'
        shutil.copytree(args.firmware.resolve(), alternate)
        rom = alternate / 'rom.hex'
        words = rom.read_text().splitlines(); words[0] = '00000013'
        rom.write_text('\n'.join(words) + '\n')
        manifest_path = alternate / 'build.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['artifact_sha256']['rom.hex'] = hashlib.sha256(rom.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest) + '\n')
        cases = [('valid', args.firmware, [], None),
                 ('alternate-rom', alternate, [], 'ROM'),
                 ('stage-override', args.firmware, ['--stage', '0'], 'unrecognized arguments')]
        # a nonexistent tool directory proves preflight does not launch hardware tools.
        for name, firmware, extra, reason in cases:
            command = [sys.executable, str(wrapper), '--firmware', str(firmware.resolve()),
                       '--tools', '/nonexistent/drg5-tools', '--output', str(output / name),
                       '--preflight-only', *extra]
            run = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, check=False)
            (output / (name + '.log')).write_text(run.stdout)
            passed = run.returncode == 0 if reason is None else run.returncode != 0 and reason in run.stdout
            # a negative attempt must not produce a route directory.
            passed &= not (output / name / 'route').exists()
            reports.append({'case': name, 'exit': run.returncode, 'passed': passed})
    sources = [wrapper, Path(__file__)]
    result = {'status': 'passed' if all(item['passed'] for item in reports) else 'failed',
              'cases': reports, 'source_sha256': {str(path.relative_to(ROOT)):
                  hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}}
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    # failed admission checks cannot be reported as a qualified build interface.
    if result['status'] != 'passed':
        raise RuntimeError('programmable build guard failed')
    print('PROGRAMMABLE_BUILD_GUARD_PASS 3')


# imports do not run build checks.
if __name__ == '__main__':
    main()

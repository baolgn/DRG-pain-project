#!/usr/bin/env python3
"""compile and execute the independent serial-flash boot qualification fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite')


def digest(path):
    """identify consumed source and evidence bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """retain failed attempts and bind the checker to the actual boot RTL."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    build = args.build.resolve(); build.mkdir(parents=True, exist_ok=True)
    names = ['microcontroller/rtl/drg5_spi_read.sv', 'microcontroller/rtl/drg5_spi_boot.sv',
             'microcontroller/tests/spi_boot_sim.cpp', 'microcontroller/tests/run_spi_boot.py']
    before = {name: digest(ROOT / name) for name in names}
    # snapshot exact inputs before compiling or executing any fixture.
    for name in names:
        target = output / 'sources' / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    verilator = str(TOOLS / 'bin/verilator')
    command = [verilator, '--cc', '--exe', '--build', '--assert', '-Wall', '-j', '2',
               '-CFLAGS', '-O2', '--top-module', 'drg5_spi_boot', '--Mdir', str(build),
               '-GROM_CRC32=1930024838', *(str(ROOT / name) for name in names[:3])]
    # strict HDL compilation permits no warning suppression.
    with (output / 'build.log').open('w') as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=False)
    record = {'command': command, 'source_sha256': before, 'build_exit': result.returncode,
              'scope': 'pin-level SPI model and boot-memory response fixtures; no physical flash qualification'}
    passed = result.returncode == 0 and '%Warning' not in (output / 'build.log').read_text()
    # a failed compiler invocation cannot count as an expected boot rejection.
    if passed:
        executable = build / 'Vdrg5_spi_boot'
        run = subprocess.run([str(executable)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, check=False, timeout=300)
        (output / 'run.log').write_text(run.stdout)
        record.update(run_exit=run.returncode, executable_sha256=digest(executable))
        passed &= run.returncode == 0 and 'SPI_BOOT_PASS cases=24' in run.stdout
    record['source_stable'] = before == {name: digest(ROOT / name) for name in names}
    passed &= record['source_stable']
    record['status'] = 'passed' if passed else 'failed'
    (output / 'summary.json').write_text(json.dumps(record, indent=2) + '\n')
    # retain every diagnostic before emitting a nonzero process status.
    if not passed:
        raise RuntimeError('SPI boot qualification failed: ' + str(output))
    print('SPI_BOOT_QUALIFICATION_PASS ' + str(output))


# importing helpers has no simulation or filesystem effects.
if __name__ == '__main__':
    main()

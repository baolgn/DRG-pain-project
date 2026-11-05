#!/usr/bin/env python3
"""record read-only ULX3S programmer discovery without configuring hardware."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess


# retain command output even when the programmer is inaccessible.
def run(argv, directory, label):
    """run a bounded discovery command and preserve its result."""
    # a hung transport is evidence of failed discovery, never permission to program.
    try:
        result = subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=20, check=False)
        output = result.stdout
        code = result.returncode
    # a timeout records only captured output and does not retry the device.
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b''
        output = output.decode(errors='replace') if isinstance(output, bytes) else output
        code = None
    (directory / (label + '.log')).write_text(output)
    return {'argv': argv, 'exit_code': code, 'log': label + '.log'}, output


# separate visible device inventory from actual programmer access.
def main():
    """save target evidence and fail closed when identification is incomplete."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--loader', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    directory = args.output.resolve()
    # never replace an earlier hardware observation.
    if directory.exists() and any(directory.iterdir()):
        raise ValueError('output directory must be fresh and empty')
    directory.mkdir(parents=True, exist_ok=True)
    devices = []
    # unrelated device names and serial numbers are not needed for this gate.
    for path in sorted(Path('/sys/bus/usb/devices').glob('*')):
        # interface-only nodes have no independent device identity.
        if not (path / 'idVendor').exists():
            continue
        devices.append({'path': path.name,
                        'vid': (path / 'idVendor').read_text().strip(),
                        'pid': (path / 'idProduct').read_text().strip()})
    loader = args.loader.resolve()
    version, version_text = run([str(loader), '-V'], directory, 'version')
    detect, output = run([str(loader), '-b', 'ulx3s', '--detect'], directory, 'detect')
    ids = re.findall(r'(?i)\b(?:0x)?41113043\b', output)
    target = [device for device in devices if (device['vid'], device['pid']) == ('0403', '6015')]
    probe = [device for device in devices if (device['vid'], device['pid']) == ('0403', '6014')]
    detected = bool(detect['exit_code'] == 0 and ids)
    result = {
        'schema': 'DRG5-FPGA-DISCOVERY-1',
        'utc': datetime.now(timezone.utc).isoformat(),
        'status': 'idcode_observed_board_inspection_required' if detected else 'hardware_unqualified',
        'expected': {'board': 'ULX3S v3.1.7 D&M', 'part': 'LFE5U-85F-6BG381C',
                     'config_usb_vid_pid': '0403:6015', 'config_idcode': '0x41113043',
                     'debug_probe': 'Digilent JTAG-HS2 410-249', 'debug_usb_vid_pid': '0403:6014'},
        'usb_device_nodes_available': Path('/dev/bus/usb').exists(),
        'visible_usb_devices': devices,
        'matching_programmers': target, 'matching_debug_probes': probe,
        'expected_idcode_observed': detected,
        'loader': {'path': str(loader), 'version': version_text.strip(),
                   'sha256': hashlib.sha256(loader.read_bytes()).hexdigest()},
        'commands': [version, detect],
        'configuration_write_attempted': False,
        'physical_board_revision_verified': False,
        'limits': 'USB identity or IDCODE cannot prove board revision, package, speed grade, wiring or hardware behavior',
    }
    (directory / 'discovery.json').write_text(json.dumps(result, indent=2) + '\n')
    print(result['status'])
    return 0 if detected else 2


# command failure remains visible to automation without changing any FPGA state.
if __name__ == '__main__':
    raise SystemExit(main())

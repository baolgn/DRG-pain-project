#!/usr/bin/env python3
"""qualify the fixed P25 flash-boot target with its exact ROM ABI."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ROM_SHA256 = 'ada6dda5a9c97670c226d04390773f3a3ad6ab62ed2681f1785342778501eb7f'


def main():
    """validate private firmware copies before invoking the existing route flow."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--preflight-only', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('flash_image', ROOT / 'microcontroller/programming/image.py')
    image = importlib.util.module_from_spec(spec); spec.loader.exec_module(image)
    report = {'profile': 'P25-SPI-BOOT-1', 'hardware_tested': False,
              'status': 'started', 'source_sha256': {}}
    # retain the exact wrapper and validation rules used by this invocation.
    for path in [Path(__file__), ROOT / 'microcontroller/programming/image.py',
                 ROOT / 'microcontroller/programming/boot-rom.hex',
                 ROOT / 'microcontroller/tests/audit_firmware.py',
                 ROOT / 'microcontroller/tests/run_decompress.py']:
        relative = path.relative_to(ROOT)
        destination = output / 'sources' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        report['source_sha256'][str(relative)] = hashlib.sha256(destination.read_bytes()).hexdigest()
    report['firmware_tool_sha256'] = {str(image.DEFAULT_PREFIX) + 'readelf':
        hashlib.sha256(Path(str(image.DEFAULT_PREFIX) + 'readelf').read_bytes()).hexdigest()}
    # retain failed inputs and a structured reason without starting synthesis.
    try:
        firmware = output / 'firmware'
        shutil.copytree(args.firmware.resolve(), firmware)
        rom_path = output / 'sources/microcontroller/programming/boot-rom.hex'
        rom = image.read_hex(rom_path, image.ROM_SIZE)
        # the physical top has this fixed ROM CRC and cannot accept another boot ABI.
        if hashlib.sha256(rom).hexdigest() != ROM_SHA256 or image.crc32(rom) != 0x7309d786:
            raise ValueError('canonical ROM differs from physical boot ABI 1')
        _, _, inspection = image.validate_firmware(firmware, rom_path, image.DEFAULT_PREFIX)
        report['firmware'] = inspection
        report['rom_byte_sha256'] = ROM_SHA256
        report['rom_crc32'] = image.crc32(rom)
        command = [sys.executable, str(ROOT / 'microcontroller/synth/run_fpga.py'),
                   '--tools', str(args.tools.resolve()), '--firmware', str(firmware),
                   '--board', str(ROOT / 'microcontroller/synth/fpga/drg5_ulx3s_programmable.sv'),
                   '--lpf', str(ROOT / 'microcontroller/synth/fpga/drg5_ulx3s_programmable.lpf'),
                   '--top', 'drg5_ulx3s_programmable', '--stage', '2', '--mhz', '25',
                   '--guard-percent', '10', '--seed', str(args.seed), '--output', str(output / 'route')]
        report['route_command'] = command
        report['status'] = 'preflight-only'
        # a preflight record never claims a new synthesis or route result.
        if not args.preflight_only:
            run = subprocess.run(command, cwd=ROOT, check=False)
            report['route_exit'] = run.returncode
            # a generic-flow failure remains a failed programmable candidate.
            if run.returncode:
                raise RuntimeError('synthesis, route or packing failed')
            routed = json.loads((output / 'route/summary.json').read_text())
            expected_rom = hashlib.sha256(rom_path.read_bytes()).hexdigest()
            # verify the actual synthesis snapshot, including its ROM file identity.
            if routed['firmware_sha256']['rom.hex'] != expected_rom:
                raise RuntimeError('routed ROM differs from validated input')
            report['status'] = routed['status']
            report['bitstream_sha256'] = routed['bitstream_sha256']
    # preserve a failed admission or build as a negative result.
    except Exception as error:
        report['status'] = 'failed'
        report['reason'] = str(error)
        raise
    # every started invocation retains its final state.
    finally:
        (output / 'qualification.json').write_text(json.dumps(report, indent=2) + '\n')


# importing the guard does not synthesize or access hardware.
if __name__ == '__main__':
    main()

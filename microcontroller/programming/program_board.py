#!/usr/bin/env python3
"""program one inspected ULX3S without relying on application code or CPU debug."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

from image import BANK_SIZE, COMMIT_SECTOR_OFFSET, HEADER_SIZE, ROM_SIZE, SLOTS, commit_sector, crc32, inspect_bank, next_generation, read_hex, select_bank

ROOT = Path(__file__).resolve().parents[2]
FLASH_SIZE = 0x1000000
CONFIG_LIMIT = 0x400000
ROM_BYTES_SHA = 'ada6dda5a9c97670c226d04390773f3a3ad6ab62ed2681f1785342778501eb7f'
MODES = ['config-sram', 'config-flash', 'update-firmware', 'restore-golden', 'invalidate-application', 'qualify-corrupt-b']
LOADER = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/openFPGALoader')
LOADER_WRAPPER_SHA = '4db258c1854017bd3587af6f4fcec3704d9590aea3beed6f0fa39e6692d2a4fa'
LOADER_EXEC_SHA = '210b005347e3f6d9124c7af0271150f20f6477a57998526b55c8052dcbbf0ca1'


def require(condition, reason):
    """reject an incomplete identity, unsafe range or failed programming phase."""
    # a failed condition never causes an automatic replay or boot attempt.
    if not condition:
        raise ValueError(reason)


def sha(data):
    """identify exactly the bytes written or inspected."""
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    """persist progress before continuing to another external operation."""
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def configuration_payload(raw):
    """accept the selected ecppack header and preserve the loader's exact flash payload."""
    require(raw.startswith(b'\xff\x00'), 'unsupported configuration header')
    start = raw.find(b'\xff', 2)
    require(start >= 2 and b'Part: LFE5U-85F-6CABGA381\x00' in raw[2:start], 'configuration part/package')
    require(raw[start:start + 5] == b'\xff\xff\xff\xbd\xb3', 'unsupported configuration preamble')
    cursor = start + 5
    # only the unencrypted preamble commands emitted by the pinned packer are accepted.
    while cursor < len(raw):
        opcode = raw[cursor]
        # bypass bytes and CRC initialization can precede the mandatory device identity.
        if opcode == 0xff:
            cursor += 1
        # reset the running configuration CRC before identity verification.
        elif opcode == 0x3b:
            require(raw[cursor:cursor + 4] == b'\x3b\0\0\0', 'configuration CRC prelude')
            cursor += 4
        # the mandatory command identifies the exact 85k device before any programming.
        elif opcode == 0xe2:
            require(raw[cursor:cursor + 8] == b'\xe2\0\0\0\x41\x11\x30\x43', 'configuration IDCODE')
            require(cursor + 8 < len(raw), 'truncated configuration payload')
            return raw[start:]
        # unknown or encrypted prefixes need a separately reviewed parser and programming path.
        else:
            raise ValueError('unsupported configuration prelude')
    raise ValueError('configuration lacks device identity')


def checked_inventory(record, executing):
    """keep physical inspection distinct from electronic device identification."""
    expected = {'schema': 'DRG5-BOARD-INVENTORY-1', 'board': 'ULX3S v3.1.7 D&M',
                'part': 'LFE5U-85F-6BG381C', 'flash_part': 'W25Q128JVSIQ',
                'flash_jedec_id': '0xef4018', 'layout': 'DRG5-FLASH-1'}
    # USB descriptors cannot establish these independently inspected assembly details.
    for name, value in expected.items():
        require(record.get(name) == value, 'inventory mismatch: ' + name)
    serial = record.get('ftdi_serial', '')
    require(isinstance(serial, str) and serial and not serial.startswith('-') and
            not any(character.isspace() for character in serial), 'FTDI serial required')
    # a template can produce a reviewable plan but cannot select a physical programmer.
    if executing:
        require(record.get('physical_inspection_verified') is True and not serial.startswith('REPLACE_'), 'physical inspection and actual serial required')
    return serial


class NativeRunner:
    """run pinned loader commands with exact serial selection and a retained journal."""
    def __init__(self, loader, serial, output, report):
        """bind executable identities and identify one live FT231X before any configuration change."""
        self.output = output; self.report = report
        loader = loader.resolve()
        require(sha(loader.read_bytes()) == LOADER_WRAPPER_SHA, 'unqualified loader wrapper')
        binary = loader.parent.parent / 'libexec/openFPGALoader'
        require(sha(binary.read_bytes()) == LOADER_EXEC_SHA, 'unqualified loader executable')
        matches = []
        # an exact serial and USB identity prevent cable-order-dependent selection.
        for device in Path('/sys/bus/usb/devices').glob('*'):
            # interface-only nodes do not carry an independent device identity.
            if not all((device / field).exists() for field in ['idVendor', 'idProduct', 'serial']):
                continue
            values = [(device / field).read_text().strip() for field in ['idVendor', 'idProduct', 'serial']]
            # a duplicate serial is rejected with an ambiguous programmer count.
            if values == ['0403', '6015', serial]:
                matches.append(device.name)
        require(Path('/dev/bus/usb').exists() and len(matches) == 1, 'exact programmer unavailable or ambiguous')
        self.base = [str(loader), '-b', 'ulx3s', '--ftdi-serial', serial, '--freq', '100000']

    def run(self, label, arguments):
        """perform one command without retries, preserving timeout and partial-write uncertainty."""
        command = self.base + list(map(str, arguments))
        row = {'command': command, 'label': label, 'started_utc': datetime.now(timezone.utc).isoformat()}
        self.report['commands'].append(row)
        save(self.output / 'operation.json', self.report)
        # streaming to a file avoids losing diagnostics if a slow USB command times out.
        with (self.output / (label + '.log')).open('w') as log:
            process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=3600, check=False)
        text = (self.output / (label + '.log')).read_text()
        clean = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text)
        row.update(exit=process.returncode, log_sha256=sha(text.encode()))
        save(self.output / 'operation.json', self.report)
        require(process.returncode == 0 and not re.search(r'\bFAIL\b|\bError:', clean, re.IGNORECASE), 'loader failed: ' + label)
        return clean


def dump(runner, output, label, offset, length):
    """verify dump length because the pinned CLI can ignore a failed dump return value."""
    path = output / (label + '.bin')
    require(not path.exists(), 'readback destination already exists')
    runner.run(label, ['--dump-flash', '--skip-reset', '--offset', hex(offset), '--file-size', str(length), path])
    require(path.exists() and path.stat().st_size == length, 'incomplete flash dump: ' + label)
    return path.read_bytes()


def perform(mode, configuration, summary_path, inventory_path, rom_path, output, bank=None,
            execute=False, loader=LOADER, runner_factory=NativeRunner):
    """stage a reviewable operation, then optionally execute its bounded persistent effects."""
    output = Path(output).resolve(); output.mkdir(parents=True, exist_ok=False)
    record = {'schema': 'DRG5-PROGRAM-1', 'mode': mode, 'status': 'preparing', 'executed': execute,
              'persistent_write_launched': False, 'hardware_boot_validated': False, 'commands': [],
              'limits': 'configuration access is distinct from CPU debug; refresh is not power-cycle or application validation'}
    save(output / 'operation.json', record)
    # every exit retains the last completed phase and whether persistent writes were exposed.
    try:
        require(mode in MODES, 'unsupported programming mode')
        inventory = json.loads(Path(inventory_path).read_text())
        serial = checked_inventory(inventory, execute)
        summary = json.loads(Path(summary_path).read_text())
        config = Path(configuration).read_bytes(); payload = configuration_payload(config)
        require(summary.get('target') == 'LFE5U-85F-6BG381C' and summary.get('top') == 'drg5_ulx3s_programmable', 'wrong routed boot design')
        require(summary.get('status') == 'routed-and-packed-hardware-unverified' and summary.get('bitstream_sha256') == sha(config), 'configuration lacks matching route/pack evidence')
        route_clock = summary.get('route_clock_mhz')
        require(summary.get('stage') == 2 and summary.get('clock_mhz') == 25.0 and
                summary.get('guard_percent') == 10 and summary.get('guard_constraint_verified') is True and
                isinstance(route_clock, (int, float)) and abs(route_clock - 25.0 / 0.9) <= 1e-6,
                'unsupported programmable stage or clock guard')
        require(0 < len(payload) <= CONFIG_LIMIT, 'configuration exceeds reserved region')
        # all external tools consume frozen local copies, never the user's mutable source paths.
        (output / 'configuration.bit').write_bytes(config)
        save(output / 'route-summary.json', summary)
        save(output / 'inventory.json', inventory)
        rom_hex = Path(rom_path).read_bytes()
        (output / 'boot-rom.hex').write_bytes(rom_hex)
        rom = read_hex(output / 'boot-rom.hex', ROM_SIZE); rom_crc = crc32(rom)
        require(sha(rom) == ROM_BYTES_SHA and rom_crc == 0x7309d786, 'programmable boot ABI requires the canonical ROM')
        require(summary['firmware_sha256']['rom.hex'] == sha(rom_hex), 'configuration ROM identity')
        record.update(configuration_sha256=sha(config), configuration_flash_payload_sha256=sha(payload),
                      configuration_flash_payload_bytes=len(payload), serial=serial, rom_crc32=rom_crc)
        bank_raw = None
        # normal updates cannot select the protected golden slot.
        if mode in ['update-firmware', 'restore-golden']:
            require(bank is not None, 'firmware bank required')
            bank_raw = Path(bank).read_bytes(); details = inspect_bank(bank_raw, rom_crc)
            require(mode != 'restore-golden' or details['generation'] == 1, 'golden generation must be one')
            record.update(slot='B' if mode == 'update-firmware' else 'A', bank=details)
            (output / 'bank.bin').write_bytes(bank_raw)
            (output / 'staged.bin').write_bytes(bank_raw[:COMMIT_SECTOR_OFFSET] + b'\xff' * 4096)
            (output / 'invalid-commit.bin').write_bytes(b'\xff' * 4096)
            (output / 'commit-sector.bin').write_bytes(commit_sector())
        # explicit service operations may invalidate B while preserving a validated golden fallback.
        if mode in ['invalidate-application', 'qualify-corrupt-b']:
            require(bank is None, 'service operation uses inspected flash contents, not an input bank')
            record.update(slot='B', expected_boot_bank='A', service_operation=True,
                          purpose=('invalidate B before generation-epoch service reset' if mode == 'invalidate-application' else
                                   'deliberately corrupt B payload byte17 bit0 without changing CRC; qualification fixture only'))
            (output / 'invalid-commit.bin').write_bytes(b'\xff' * 4096)
        # planning changes no FPGA state and does not require the board to be attached.
        if not execute:
            action = {'config-flash': 'program configuration', 'update-firmware': 'invalidate, stage, verify and commit B',
                      'restore-golden': 'invalidate, stage, verify and commit golden A',
                      'invalidate-application': 'erase B commit only, then verify A selection',
                      'qualify-corrupt-b': 'write deliberately CRC-invalid B fixture, then verify A selection'}
            record.update(status='plan-ready', steps=(['identify FPGA', 'load volatile configuration'] if mode == 'config-sram' else
                ['identify FPGA', 'clear SRAM and identify flash', 'back up all 16 MiB',
                 action[mode],
                 'verify all bytes and preservation outside the allowed erase region', 'refresh configuration']))
            save(output / 'operation.json', record)
            return record
        runner = runner_factory(loader, serial, output, record)
        identity = runner.run('detect-fpga', ['--detect'])
        require(re.findall(r'(?im)^\s*idcode\s+(?:0x)?([0-9a-f]+)\s*$', identity) == ['41113043'] and
                re.findall(r'(?im)^\s*irlength\s+(\d+)\s*$', identity) == ['8'], 'unexpected FPGA IDCODE or JTAG chain')
        # loading SRAM never erases or rewrites persistent boot storage.
        if mode == 'config-sram':
            loaded = runner.run('load-sram', ['-m', output / 'configuration.bit'])
            require(bool(re.search(r'Disable configuration:\s*DONE\b', loaded)), 'SRAM programming did not complete')
            record['status'] = 'sram-loaded-application-observation-required'
        # every SPI operation deliberately clears SRAM and keeps the CPU unavailable until verified completion.
        else:
            flash = runner.run('detect-flash', ['--detect', '-f', '--skip-reset'])
            require(bool(re.search(r'JEDEC ID:\s*0xef4018\b', flash, re.IGNORECASE)), 'unexpected flash JEDEC ID')
            before = dump(runner, output, 'flash-before', 0, FLASH_SIZE)
            record['backup_sha256'] = sha(before)
            expected = bytearray(before)
            # configuration programming owns only complete erase sectors below the application banks.
            if mode == 'config-flash':
                end = (len(payload) + 4095) & ~4095
                expected[:end] = b'\xff' * end; expected[:len(payload)] = payload
                record.update(persistent_write_launched=True, allowed_erase_range=[0, end])
                save(output / 'operation.json', record)
                runner.run('write-configuration', ['-f', '--verify', '--skip-reset', '--offset', '0', output / 'configuration.bit'])
            # an application update preserves configuration, golden A and every unallocated flash byte.
            else:
                require(before[:len(payload)] == payload, 'installed configuration differs from the compatible routed image')
                slot = record['slot']; offset = SLOTS[slot]
                old_a = before[SLOTS['A']:SLOTS['A'] + BANK_SIZE]
                old_b = before[SLOTS['B']:SLOTS['B'] + BANK_SIZE]
                # service records intentionally preserve history while invalidating the old application epoch.
                if mode in ['invalidate-application', 'qualify-corrupt-b']:
                    previous = select_bank(old_a, old_b, rom_crc)
                    require('A' in previous['valid'], 'valid golden A required for service')
                    record['previous_selection'] = previous
                    # the fixture starts from a valid stored application, then introduces one precise payload fault.
                    if mode == 'qualify-corrupt-b':
                        require('B' in previous['valid'], 'valid B required for corruption qualification')
                        corrupted = bytearray(old_b); corrupted[HEADER_SIZE + 17] ^= 1
                        (output / 'corrupt-fixture.bin').write_bytes(corrupted)
                        require(select_bank(old_a, corrupted, rom_crc)['selected'] == 'A', 'corruption fixture lacks golden fallback')
                        record.update(persistent_write_launched=True, allowed_erase_range=[offset, offset + BANK_SIZE],
                                      fixture_sha256=sha(corrupted), fixture_fault={'payload_byte': 17, 'xor_mask': 1})
                        save(output / 'operation.json', record)
                        runner.run('qualify-corrupt-bank', ['-f', '--verify', '--skip-reset', '--file-type', 'bin', '--offset', hex(offset), output / 'corrupt-fixture.bin'])
                        expected[offset:offset + BANK_SIZE] = corrupted
                    # erasing only the commit sector provides an explicit service reset without generation wrap.
                    else:
                        start = offset + COMMIT_SECTOR_OFFSET
                        record.update(persistent_write_launched=True, allowed_erase_range=[start, start + 4096])
                        save(output / 'operation.json', record)
                        runner.run('invalidate-bank', ['-f', '--verify', '--skip-reset', '--file-type', 'bin', '--offset', hex(start), output / 'invalid-commit.bin'])
                        expected[start:start + 4096] = b'\xff' * 4096
                    require(select_bank(old_a, expected[offset:offset + BANK_SIZE], rom_crc)['selected'] == 'A', 'service operation lacks golden fallback')
                # generation advancement requires a valid golden fallback and never wraps.
                else:
                    # ordinary updates require a next generation; golden service keeps its fixed generation one.
                    if mode == 'update-firmware':
                        require(record['bank']['generation'] == next_generation(old_a, old_b, rom_crc), 'firmware generation must be the next valid generation')
                    record.update(persistent_write_launched=True, allowed_erase_range=[offset, offset + BANK_SIZE])
                    save(output / 'operation.json', record)
                    runner.run('invalidate-bank', ['-f', '--verify', '--skip-reset', '--file-type', 'bin', '--offset', hex(offset + COMMIT_SECTOR_OFFSET), output / 'invalid-commit.bin'])
                    require(dump(runner, output, 'invalidated-commit', offset + COMMIT_SECTOR_OFFSET, 4096) == b'\xff' * 4096, 'commit invalidation failed')
                    runner.run('stage-bank', ['-f', '--verify', '--skip-reset', '--file-type', 'bin', '--offset', hex(offset), output / 'staged.bin'])
                    staged = dump(runner, output, 'staged-readback', offset, BANK_SIZE)
                    require(staged == (output / 'staged.bin').read_bytes(), 'staged bank differs')
                    require(not inspect_bank(staged, rom_crc, require_commit=False)['committed'], 'staging published a commit')
                    runner.run('commit-bank', ['-f', '--verify', '--skip-reset', '--file-type', 'bin', '--offset', hex(offset + COMMIT_SECTOR_OFFSET), output / 'commit-sector.bin'])
                    expected[offset:offset + BANK_SIZE] = bank_raw
            after = dump(runner, output, 'flash-after', 0, FLASH_SIZE)
            require(after == expected, 'flash verification or protected-region preservation failed')
            record['readback_sha256'] = sha(after)
            # reset has a void CLI return; its success marker must be checked independently of exit status.
            refreshed = runner.run('refresh', ['--reset'])
            require(bool(re.search(r'Refresh:\s*DONE\b', refreshed)) and 'Flash is blank' not in refreshed, 'configuration refresh failed')
            record['status'] = 'flash-verified-power-cycle-and-application-observation-required'
        save(output / 'operation.json', record)
        return record
    # failure leaves the CPU unconfigured when possible; it never replays an uncertain write or auto-boots it.
    except Exception as error:
        record.update(status='failed-no-automatic-retry', error=str(error))
        save(output / 'operation.json', record)
        raise


def main():
    """make planning the default and require explicit execution of a concrete selected operation."""
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=MODES)
    parser.add_argument('--configuration', type=Path, required=True)
    parser.add_argument('--route-summary', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--rom', type=Path, default=Path(__file__).with_name('boot-rom.hex'))
    parser.add_argument('--bank', type=Path)
    parser.add_argument('--loader', type=Path, default=LOADER)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    result = perform(args.mode, args.configuration, args.route_summary, args.inventory, args.rom,
                     args.output, args.bank, args.execute, args.loader)
    print(result['status'])


# importing the helper never touches a programmer or flash.
if __name__ == '__main__':
    main()

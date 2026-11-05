#!/usr/bin/env python3
"""exercise programming policy with an independent sector-erase NOR transport model."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'microcontroller/programming'))
import image
import program_board as board


def check(condition, reason):
    """stop the campaign on a lost preservation, ordering or failure-handling guarantee."""
    # any failed host-policy check is a campaign failure.
    if not condition:
        raise AssertionError(reason)


class FlashModel:
    """model actual sector erasure and one-way programming separately from host expectations."""
    def __init__(self, initial, fault=None):
        """start with independent persistent bytes and an optional injected transport defect."""
        self.flash = bytearray(initial)
        self.fault = fault
        self.labels = []
        self.erased = []
        self.started = 0

    def factory(self, loader, serial, output, report):
        """replace only physical transport; retain production identity and phase checks."""
        self.started += 1
        self.output = output
        self.report = report
        return self

    def run(self, label, arguments):
        """simulate CLI results including exit-zero failed dumps and uncertain writes."""
        self.labels.append(label)
        self.report['commands'].append({'label': label, 'arguments': list(map(str, arguments)), 'transport': 'model'})
        board.save(self.output / 'operation.json', self.report)
        # plain configuration identity does not access SPI or modify flash.
        if label == 'detect-fpga':
            identity = '41112043' if self.fault == 'wrong-fpga' else '41113043'
            text = 'index 0:\n\tidcode 0x' + identity + '\n\tirlength 8\n'
            return text + (text if self.fault == 'multiple-FPGAs' else '')
        # SPI access is deliberately distinct from ordinary JTAG identification.
        if label == 'detect-flash':
            return 'JEDEC ID: 0xef4017' if self.fault == 'wrong-flash' else 'JEDEC ID: 0xef4018'
        # refreshing can fail despite the loader returning zero.
        if label == 'refresh':
            return 'Refresh: FAIL' if self.fault == 'refresh-failed' else 'Refresh: DONE'
        # SRAM loading has no persistent side effect.
        if label == 'load-sram':
            return 'parse: DONE' if self.fault == 'SRAM-incomplete' else 'Disable configuration: DONE'
        # dump failure may produce a short file while the pinned CLI exits zero.
        if '--dump-flash' in arguments:
            start = int(arguments[arguments.index('--offset') + 1], 0)
            size = int(arguments[arguments.index('--file-size') + 1])
            data = bytes(self.flash[start:start + size])
            # detect corrupted staged bytes before publishing the commit sector.
            if label == 'staged-readback' and self.fault == 'staged-corruption':
                data = data[:300] + bytes([data[300] ^ 1]) + data[301:]
            # exact dump lengths are required independently of process exit status.
            if label == 'flash-before' and self.fault == 'short-dump':
                data = data[:-1]
            Path(arguments[-1]).write_bytes(data)
            return 'Read: DONE'
        check('-f' in arguments and '--skip-reset' in arguments, 'unexpected modeled operation')
        offset = int(arguments[arguments.index('--offset') + 1], 0)
        raw = Path(arguments[-1]).read_bytes()
        # configuration text headers never enter the serial flash byte stream.
        if label == 'write-configuration':
            raw = board.configuration_payload(raw)
        end = (offset + len(raw) + 4095) & ~4095
        start = offset & ~4095
        self.erased.append([label, start, end])
        self.flash[start:end] = b'\xff' * (end - start)
        # an interrupted write is exposed once and must never be retried automatically.
        if (label == 'stage-bank' and self.fault == 'uncertain-write') or \
                (label in ['qualify-corrupt-bank', 'invalidate-bank'] and self.fault == 'uncertain-service-write'):
            self.flash[offset:offset + 257] = raw[:257]
            raise TimeoutError('model response lost after partial programming')
        # NOR programming clears bits after explicit sector erase.
        for index, value in enumerate(raw):
            self.flash[offset + index] &= value
        # independent preservation readback must detect an unintended external-sector write.
        if label == 'commit-bank' and self.fault == 'outside-corruption':
            self.flash[0x600000] ^= 1
        return 'Write: DONE'


def main():
    """retain exact test identities and phase records without claiming physical-board qualification."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    cases = []
    rom_path = ROOT / 'microcontroller/programming/boot-rom.hex'
    rom = image.read_hex(rom_path, image.ROM_SIZE)
    payload = bytes((index * 13 + 7) & 255 for index in range(image.PAYLOAD_SIZE))
    raw_config = b'\xff\x00Part: LFE5U-85F-6CABGA381\x00\xff\xff\xff\xbd\xb3\xff\x3b\0\0\0\xe2\0\0\0\x41\x11\x30\x43' + b'\x5a' * 9001
    config_payload = board.configuration_payload(raw_config)
    golden = image.make_bank(payload, rom, 1)
    current = image.make_bank(payload[::-1], rom, 2)
    updated = image.make_bank(bytes(value ^ 0xa5 for value in payload), rom, 3)
    initial = bytearray(b'\xff' * board.FLASH_SIZE)
    initial[:len(config_payload)] = config_payload
    initial[image.SLOTS['A']:image.SLOTS['A'] + image.BANK_SIZE] = golden
    initial[image.SLOTS['B']:image.SLOTS['B'] + image.BANK_SIZE] = current
    initial[0x500000:0x500008] = b'preserve'
    # all fixtures are synthetic; neither a routed artifact nor physical transport is substituted silently.
    with tempfile.TemporaryDirectory(prefix='drg5-host-programming-') as directory:
        work = Path(directory)
        (work / 'design.bit').write_bytes(raw_config)
        inventory = json.loads((ROOT / 'microcontroller/programming/inventory.example.json').read_text())
        inventory.update(ftdi_serial='MODELED_SERIAL', physical_inspection_verified=True)
        board.save(work / 'inventory.json', inventory)
        board.save(work / 'summary.json', {'target': 'LFE5U-85F-6BG381C', 'top': 'drg5_ulx3s_programmable',
                   'status': 'routed-and-packed-hardware-unverified', 'bitstream_sha256': board.sha(raw_config),
                   'stage': 2, 'clock_mhz': 25.0, 'route_clock_mhz': 25.0 / 0.9,
                   'guard_percent': 10, 'guard_constraint_verified': True,
                   'firmware_sha256': {'rom.hex': board.sha(rom_path.read_bytes())}})

        def run(name, mode='update-firmware', bank=updated, flash=initial, fault=None, expected=None, execute=True):
            """run production host code and require the exact expected failure boundary."""
            model = FlashModel(flash, fault)
            bank_file = work / (name + '.bin'); bank_file.write_bytes(bank)
            output = work / name
            error_text = None
            # each injected failure is classified without converting it into a success result.
            try:
                bank_argument = None if mode in ['invalidate-application', 'qualify-corrupt-b'] else bank_file
                result = board.perform(mode, work / 'design.bit', work / 'summary.json', work / 'inventory.json',
                                       rom_path, output, bank_argument, execute=execute, runner_factory=model.factory)
            # transport and validation failures must stop at their original boundary.
            except (ValueError, TimeoutError) as error:
                error_text = str(error)
                result = json.loads((output / 'operation.json').read_text())
            check((error_text is None) == (expected is None), name + ': unexpected success/failure ' + str(error_text))
            # stable error text identifies which guarantee rejected the operation.
            if expected is not None:
                check(expected in error_text, name + ': wrong error ' + error_text)
                check(result['status'] == 'failed-no-automatic-retry', name + ': failure status')
            check(len(model.labels) == len(set(model.labels)), name + ': command replay')
            cases.append({'name': name, 'status': 'pass', 'error_detected': error_text,
                          'phases': model.labels, 'erase_ranges': model.erased})
            # synthetic full-flash dumps need not accumulate after their preserved phase record is complete.
            shutil.rmtree(output)
            return model, result

        model, result = run('plan-does-not-contact-hardware', execute=False)
        check(model.started == 0 and not model.labels and result['status'] == 'plan-ready', 'plan contacted hardware')
        model, result = run('normal-B-update')
        expected_flash = bytearray(initial)
        expected_flash[image.SLOTS['B']:image.SLOTS['B'] + image.BANK_SIZE] = updated
        check(model.flash == expected_flash, 'normal update changed protected bytes')
        check(model.labels == ['detect-fpga', 'detect-flash', 'flash-before', 'invalidate-bank', 'invalidated-commit',
                               'stage-bank', 'staged-readback', 'commit-bank', 'flash-after', 'refresh'], 'update phase ordering')
        check(model.erased == [['invalidate-bank', 0x43f000, 0x440000], ['stage-bank', 0x420000, 0x440000],
                               ['commit-bank', 0x43f000, 0x440000]], 'erase region containment')
        model, _ = run('golden-service-restore', mode='restore-golden', bank=golden)
        check(model.flash == initial and all(0x400000 <= start < end <= 0x420000 for _, start, end in model.erased), 'golden service range')
        model, _ = run('volatile-configuration', mode='config-sram')
        check(model.flash == initial and model.labels == ['detect-fpga', 'load-sram'], 'SRAM path modified flash')
        model, _ = run('persistent-configuration', mode='config-flash')
        check(model.flash[:len(config_payload)] == config_payload and model.flash[0x400000:] == initial[0x400000:], 'configuration payload or firmware preservation')
        # identity and backup failures occur before the first persistent write.
        for name, fault, error in [('wrong-FPGA', 'wrong-fpga', 'unexpected FPGA'), ('multiple-FPGAs', 'multiple-FPGAs', 'unexpected FPGA'),
                                   ('wrong-flash', 'wrong-flash', 'unexpected flash'),
                                   ('short-readback', 'short-dump', 'incomplete flash dump')]:
            model, _ = run(name, fault=fault, expected=error)
            check(not model.erased, name + ': persistent effect before rejection')
        run('exit-zero-incomplete-SRAM-load', mode='config-sram', fault='SRAM-incomplete', expected='SRAM programming did not complete')
        model, _ = run('wrong-generation', bank=current, expected='next valid generation')
        check(not model.erased, 'generation rejection after erase')
        broken = bytearray(initial); broken[image.SLOTS['A'] + 300] ^= 1
        model, _ = run('missing-golden', flash=broken, expected='golden A required')
        check(not model.erased, 'invalid golden allowed erase')
        broken = bytearray(initial); broken[0] ^= 1
        model, _ = run('wrong-installed-configuration', flash=broken, expected='installed configuration differs')
        check(not model.erased, 'configuration mismatch allowed erase')
        exhausted = bytearray(initial)
        exhausted[image.SLOTS['B']:image.SLOTS['B'] + image.BANK_SIZE] = image.make_bank(payload, rom, 0xffffffff)
        model, _ = run('generation-exhaustion', flash=exhausted, expected='generation exhausted')
        check(not model.erased, 'generation wrap allowed erase')
        model, _ = run('wrong-golden-generation', mode='restore-golden', bank=updated, expected='golden generation')
        check(not model.labels, 'golden generation contacted hardware')
        malformed = bytearray(updated); malformed[300] ^= 1
        model, _ = run('corrupt-input-bank', bank=malformed, expected='payload CRC')
        check(not model.labels, 'input CRC contacted hardware')
        # failed staging cannot publish a commit or refresh the FPGA.
        for name, fault, error in [('corrupt-staged-readback', 'staged-corruption', 'staged bank differs'),
                                   ('uncertain-write-no-replay', 'uncertain-write', 'response lost')]:
            model, _ = run(name, fault=fault, expected=error)
            check('commit-bank' not in model.labels and 'refresh' not in model.labels, name + ': published uncertain data')
            check(model.flash[image.SLOTS['A']:image.SLOTS['A'] + image.BANK_SIZE] == golden, name + ': golden changed')
            check(model.flash[0x43fffc:0x440000] == b'\xff' * 4, name + ': old commit survived invalidation')
        model, _ = run('outside-write-detected', fault='outside-corruption', expected='protected-region preservation')
        check('refresh' not in model.labels, 'preservation failure booted automatically')
        run('exit-zero-refresh-failure', fault='refresh-failed', expected='refresh failed')
        model, _ = run('intentional-corrupt-B-fixture', mode='qualify-corrupt-b')
        expected_fixture = bytearray(initial)
        expected_fixture[image.SLOTS['B'] + image.HEADER_SIZE + 17] ^= 1
        check(model.flash == expected_fixture, 'corruption fixture changed another byte')
        check(image.select_bank(golden, model.flash[image.SLOTS['B']:image.SLOTS['B'] + image.BANK_SIZE], image.crc32(rom))['selected'] == 'A', 'corruption fixture did not select golden')
        model, _ = run('explicit-B-invalidation', mode='invalidate-application')
        expected_invalid = bytearray(initial); expected_invalid[0x43f000:0x440000] = b'\xff' * 4096
        check(model.flash == expected_invalid and model.erased == [['invalidate-bank', 0x43f000, 0x440000]], 'invalidation changed bank body')
        model, _ = run('exhausted-epoch-service-reset', mode='invalidate-application', flash=exhausted)
        check(image.next_generation(golden, model.flash[image.SLOTS['B']:image.SLOTS['B'] + image.BANK_SIZE], image.crc32(rom)) == 2, 'explicit invalidation did not reset eligibility')
        restored, _ = run('post-epoch-reset-normal-update', flash=model.flash, bank=current)
        check(restored.flash[image.SLOTS['A']:image.SLOTS['A'] + image.BANK_SIZE] == golden and
              restored.flash[image.SLOTS['B']:image.SLOTS['B'] + image.BANK_SIZE] == current, 'epoch reset replacement failed')
        # service is rejected before erasure unless golden A remains a valid recovery image.
        for mode in ['invalidate-application', 'qualify-corrupt-b']:
            broken = bytearray(initial); broken[image.SLOTS['A'] + 300] ^= 1
            model, _ = run(mode + '-invalid-A', mode=mode, flash=broken, expected='valid golden A required')
            check(not model.erased, 'service without golden A erased flash')
            model, _ = run(mode + '-uncertain-no-replay', mode=mode, fault='uncertain-service-write', expected='response lost')
            check('refresh' not in model.labels and model.flash[image.SLOTS['A']:image.SLOTS['A'] + image.BANK_SIZE] == golden, 'uncertain service harmed recovery')
        broken = bytearray(initial); broken[image.SLOTS['B'] + 300] ^= 1
        model, _ = run('fixture-requires-valid-starting-B', mode='qualify-corrupt-b', flash=broken, expected='valid B required')
        check(not model.erased, 'corruption fixture started from invalid B')
        canonical_rom_path = rom_path
        rom_path = work / 'alternate-rom.hex'
        words = canonical_rom_path.read_text().splitlines(); words[0] = f'{int(words[0], 16) ^ 1:08x}'
        rom_path.write_text('\n'.join(words) + '\n')
        summary = json.loads((work / 'summary.json').read_text())
        summary['firmware_sha256']['rom.hex'] = board.sha(rom_path.read_bytes())
        board.save(work / 'summary.json', summary)
        model, _ = run('self-consistent-alternate-ROM-rejected', expected='requires the canonical ROM')
        check(model.started == 0, 'alternate ROM contacted programmer')
        rom_path = canonical_rom_path
        summary['firmware_sha256']['rom.hex'] = board.sha(rom_path.read_bytes())
        board.save(work / 'summary.json', summary)
        # a self-consistent bitstream hash cannot admit an unsupported stage or timing profile.
        for name, field, value in [('stage-zero-rejected', 'stage', 0), ('changed-core-clock-rejected', 'clock_mhz', 50.0),
                                    ('missing-clock-guard-rejected', 'guard_constraint_verified', None),
                                    ('wrong-route-clock-rejected', 'route_clock_mhz', 25.0),
                                    ('wrong-guard-percent-rejected', 'guard_percent', 0)]:
            changed = dict(summary)
            # a missing required field is rejected just like an explicitly unsupported value.
            if value is None:
                changed.pop(field)
            # retain all unrelated valid fields so each admission check is independently exercised.
            else:
                changed[field] = value
            board.save(work / 'summary.json', changed)
            model, _ = run(name, expected='unsupported programmable stage or clock guard')
            check(model.started == 0, name + ': contacted programmer')
        board.save(work / 'summary.json', summary)
        # an incomplete physical inspection is rejected even when a mock transport could otherwise run.
        inventory['physical_inspection_verified'] = False
        board.save(work / 'inventory.json', inventory)
        model, _ = run('uninspected-board', expected='physical inspection')
        check(model.started == 0, 'uninspected physical assembly contacted programmer')
    sources = ['microcontroller/programming/program_board.py', 'microcontroller/programming/image.py',
               'microcontroller/programming/inventory.example.json', 'microcontroller/tests/test_program_board.py']
    report = {'schema': 'DRG5-HOST-PROGRAMMING-TEST-1', 'status': 'pass', 'count': len(cases), 'cases': cases,
              'source_sha256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources},
              'limits': 'synthetic bitstream and sector-erase NOR transport; no actual programmer, routed image or power-cycle validation'}
    board.save(args.output / 'summary.json', report)
    print('PASS host programming cases=' + str(len(cases)))


# direct execution runs only modeled programming tests.
if __name__ == '__main__':
    main()

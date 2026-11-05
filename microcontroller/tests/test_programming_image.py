#!/usr/bin/env python3
"""exercise bank corruption, commit interruption and protected-golden recovery."""
import argparse
import importlib.util
import json
from pathlib import Path
import random
import shutil
import struct

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('bank_image', ROOT / 'microcontroller/programming/image.py')
image = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(image)


def main():
    """retain actual package inputs, independently damaged fixtures and power-cut outcomes."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--rom', type=Path, default=ROOT / 'microcontroller/programming/boot-rom.hex')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    rom, payload, audited = image.validate_firmware(args.firmware, args.rom)
    rom_crc = image.crc32(rom)
    source_paths = [Path(__file__), ROOT / 'microcontroller/programming/image.py', args.rom]
    before = {str(path.relative_to(ROOT)): image.sha256(path.read_bytes()) for path in source_paths}
    counts = {}; checks = 0

    def check(condition, reason, group):
        """count meaningful assertions by the behavior they constrain."""
        nonlocal checks
        assert condition, reason
        checks += 1; counts[group] = counts.get(group, 0) + 1

    def rejects(raw, reason, group):
        """require the precise intended validation failure, not an unrelated exception."""
        # malformed records cannot produce an apparently valid descriptor.
        try:
            image.inspect_bank(raw, rom_crc)
        # named failures calibrate the individual validation gates.
        except ValueError as error:
            check(reason in str(error), str(error), group)
        # accepting an intentionally damaged bank is a test failure.
        else:
            check(False, 'accepted corrupt bank: ' + reason, group)

    def rejected_call(operation, reason):
        """calibrate the executable-package gates before constructing any flash image."""
        # an intentionally damaged source package must fail its specific validation boundary.
        try:
            operation()
        # parser errors and unsupported instruction errors are both explicit package rejections.
        except ValueError as error:
            check(reason in str(error), str(error), 'package_validation')
        # a successful package build would authorize bytes that the negative control changed.
        else:
            check(False, 'accepted invalid package: ' + reason, 'package_validation')

    bad_rom = args.output / 'wrong-rom.hex'
    wrong_words = args.rom.read_text().splitlines(); wrong_words[0] = '00000000'
    bad_rom.write_text('\n'.join(wrong_words) + '\n')
    rejected_call(lambda: image.validate_firmware(args.firmware, bad_rom), 'configuration ROM differs')
    elf = (args.firmware / 'firmware.elf').read_bytes()
    # ELF flags and entry are independently constrained even if a manifest claims the right profile.
    for offset, value in [(24, 0x10000), (36, 0), (36, 5)]:
        malformed = bytearray(elf); struct.pack_into('<I', malformed, offset, value)
        rejected_call(lambda: image.elf_images(malformed), 'ELF profile or entry')
    mutant = args.output / 'mutant-package'
    shutil.copytree(args.firmware, mutant)
    words = (mutant / 'iram.hex').read_text().splitlines(); words[0] = '00000553'
    (mutant / 'iram.hex').write_text('\n'.join(words) + '\n')
    rejected_call(lambda: image.validate_firmware(mutant, args.rom), 'artifact hash iram.hex')
    manifest = json.loads((mutant / 'build.json').read_text())
    manifest['artifact_sha256']['iram.hex'] = image.sha256((mutant / 'iram.hex').read_bytes())
    (mutant / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    rejected_call(lambda: image.validate_firmware(mutant, args.rom), 'ELF and word images differ')
    forged = bytearray(elf)
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', forged)
    changed = False
    # replace only the IRAM entry instruction, leaving the frozen boot ROM unchanged.
    for number in range(header[10]):
        fields = struct.unpack_from('<8I', forged, header[5] + number * header[9])
        # initialized application code has this exact physical load base.
        if fields[0] == 1 and fields[3] == 0x10000 and fields[4] >= 4:
            struct.pack_into('<I', forged, fields[1], 0x00000553); changed = True
    check(changed, 'application segment not found', 'package_validation')
    (mutant / 'firmware.elf').write_bytes(forged)
    manifest['artifact_sha256']['firmware.elf'] = image.sha256(forged)
    (mutant / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    rejected_call(lambda: image.validate_firmware(mutant, args.rom), 'unsupported instruction 0x00000553')

    check(image.crc32(b'123456789') == 0xcbf43926, 'standard CRC check vector', 'crc_reference')
    a = image.make_bank(payload, rom, 1)
    b = image.make_bank(payload, rom, 2)
    staged = image.make_bank(payload, rom, 3, False)
    check(image.inspect_bank(a, rom_crc)['generation'] == 1, 'golden generation', 'format')
    check(image.select_bank(a, b, rom_crc)['selected'] == 'B', 'newer application', 'selection')
    check(image.select_bank(a, b, rom_crc, True)['selected'] == 'A', 'manual golden recovery', 'selection')
    check(image.select_bank(a, a, rom_crc)['selected'] == 'A', 'generation tie', 'selection')
    check(image.next_generation(a, b, rom_crc) == 3, 'next generation', 'selection')
    rejects(staged, 'uncommitted bank', 'commit')
    check(not image.inspect_bank(staged, rom_crc, False)['committed'], 'staging inspection', 'commit')

    # every individual header-bit error must be rejected, including its CRC and reserved tail.
    for bit in range(image.HEADER_SIZE * 8):
        damaged = bytearray(b); damaged[bit // 8] ^= 1 << (bit % 8)
        # header corruption can fail a structural field before its checksum is examined.
        try:
            image.inspect_bank(damaged, rom_crc)
        # any validation rejection is appropriate for this exhaustive integrity sweep.
        except ValueError:
            check(True, 'header bit rejected', 'header_bit_corruption')
        # generation is intentionally variable, but its stale header CRC still rejects the bit flip.
        else:
            check(False, 'header bit accepted ' + str(bit), 'header_bit_corruption')

    # each payload byte participates in the CRC, including padding emitted by the linker.
    for index in range(image.PAYLOAD_SIZE):
        damaged = bytearray(b); damaged[image.HEADER_SIZE + index] ^= 1 << (index % 8)
        rejects(damaged, 'payload CRC', 'payload_byte_corruption')

    mutations = [(0, 0, 'magic'), (4, 2, 'format version'), (8, 4, 'payload length'),
                 (12, 0x20000000, 'load address'), (16, 0x10002, 'entry'),
                 (28, rom_crc ^ 1, 'ROM compatibility'), (32, 2, 'profile'), (36, 1, 'reserved')]
    # recomputed header checksums cannot legitimize unsupported fields.
    for offset, value, reason in mutations:
        damaged = bytearray(b); struct.pack_into('<I', damaged, offset, value)
        struct.pack_into('<I', damaged, 248, image.crc32(damaged[:248]))
        rejects(damaged, reason, 'structural_validation')

    # hardware ignores unused storage, while the host rejects noncanonical package padding.
    padded = bytearray(b); padded[image.HEADER_SIZE + image.PAYLOAD_SIZE] = 0
    rejects(padded, 'padding', 'padding_policy')
    check(image.select_bank(a, padded, rom_crc)['selected'] == 'B', 'hardware padding scope', 'padding_policy')
    erased = bytes([255]) * image.BANK_SIZE
    check(image.select_bank(erased, erased, rom_crc)['selected'] is None, 'both banks invalid', 'selection')
    check(image.select_bank(erased, b, rom_crc, True)['selected'] is None, 'forced invalid A cannot use B', 'selection')
    check(image.select_bank(erased, b, rom_crc)['selected'] == 'B', 'unforced valid B', 'selection')
    exhausted = image.make_bank(payload, rom, image.MAX_GENERATION)
    # generation exhaustion requires explicit service and never wraps to zero.
    try:
        image.next_generation(a, exhausted, rom_crc)
    # the failure must name exhaustion rather than an unrelated corrupted bank.
    except ValueError as error:
        check('generation exhausted' in str(error), str(error), 'generation_exhaustion')
    # integer wrap would silently invert boot preference.
    else:
        check(False, 'generation wrapped', 'generation_exhaustion')

    # an already valid old application remains safe before commit invalidation completes.
    check(image.select_bank(a, b, rom_crc)['selected'] == 'B', 'pre-update application', 'power_cuts')
    work = bytearray(b)
    golden_digest = image.sha256(a)
    # interrupted erasure of the commit word either preserves old B or selects untouched A.
    for count in range(5):
        interrupted = bytearray(b)
        interrupted[image.COMMIT_OFFSET:image.COMMIT_OFFSET + count] = bytes([255]) * count
        selected = image.select_bank(a, interrupted, rom_crc)['selected']
        check(selected in ('A', 'B') and (selected != 'B' or interrupted == b), 'commit invalidation cut', 'power_cuts')
    work[image.COMMIT_SECTOR_OFFSET:] = bytes([255]) * image.SECTOR_SIZE
    # every sector-erase boundary retains the verified all-one commit word.
    for offset in range(0, image.BANK_SIZE, image.SECTOR_SIZE):
        work[offset:offset + image.SECTOR_SIZE] = bytes([255]) * image.SECTOR_SIZE
        check(image.select_bank(a, work, rom_crc)['selected'] == 'A', 'erase power cut', 'power_cuts')
        check(image.sha256(a) == golden_digest, 'golden changed during erase', 'golden_protection')
    # every page-program boundary before commit must still select A.
    for offset in range(0, image.BANK_SIZE, 256):
        work[offset:offset + 256] = staged[offset:offset + 256]
        check(image.select_bank(a, work, rom_crc)['selected'] == 'A', 'body power cut', 'power_cuts')
        check(image.sha256(a) == golden_digest, 'golden changed during program', 'golden_protection')
    check(bytes(work) == staged, 'complete staged readback', 'power_cuts')
    rng = random.Random(0x64726735)
    # random partial page programs model torn zero-bit transitions while commit remains erased.
    for _ in range(128):
        cut = rng.randrange(image.BANK_SIZE)
        torn = bytearray(bytes([255]) * image.BANK_SIZE)
        torn[:cut] = staged[:cut]
        torn[cut] &= staged[cut] | rng.randrange(256)
        check(image.select_bank(a, torn, rom_crc)['selected'] == 'A', 'torn body page', 'power_cuts')
    final_sector = image.commit_sector()
    # commit-sector programming never shares an erase block with header or payload.
    for count in range(image.SECTOR_SIZE + 1):
        torn = bytearray(staged)
        torn[image.COMMIT_SECTOR_OFFSET:image.COMMIT_SECTOR_OFFSET + count] = final_sector[:count]
        chosen = image.select_bank(a, torn, rom_crc)['selected']
        check(chosen == ('B' if count == image.SECTOR_SIZE else 'A'), 'commit-sector power cut', 'power_cuts')
    zeros = [bit for bit in range(32) if not (image.COMMIT >> bit) & 1]
    # each proper prefix of commit-word bit programming remains unauthorized.
    for count in range(len(zeros) + 1):
        word = 0xffffffff
        # program only a subset of the required NOR zero bits.
        for bit in zeros[:count]:
            word &= ~(1 << bit)
        torn = bytearray(staged); struct.pack_into('<I', torn, image.COMMIT_OFFSET, word)
        check(image.select_bank(a, torn, rom_crc)['selected'] == ('B' if count == len(zeros) else 'A'),
              'partial commit word', 'power_cuts')

    # checksums cannot identify a legal instruction that deliberately loops forever.
    hung_payload = bytearray(payload); struct.pack_into('<I', hung_payload, 0, 0x0000006f)
    hung = image.make_bank(hung_payload, rom, 3)
    check(image.select_bank(a, hung, rom_crc)['selected'] == 'B', 'CRC-valid application semantics', 'behavioral_recovery')
    check(image.select_bank(a, hung, rom_crc, True)['selected'] == 'A', 'manual recovery from semantic defect', 'behavioral_recovery')
    corrupt = bytearray(b); corrupt[image.HEADER_SIZE] ^= 1
    check(image.select_bank(a, corrupt, rom_crc)['selected'] == 'A', 'automatic corruption fallback', 'behavioral_recovery')
    repaired = image.make_bank(payload, rom, 4)
    check(image.select_bank(a, repaired, rom_crc)['selected'] == 'B', 'replaced damaged application', 'behavioral_recovery')
    fixtures = {'golden.bin': a, 'application.bin': b, 'corrupt-application.bin': bytes(corrupt),
                'hung-application.bin': hung, 'repaired-application.bin': repaired,
                'staged.bin': staged, 'commit-sector.bin': final_sector}
    # fixtures drive RTL/CPU tests separately; this Python oracle makes no hardware execution claim.
    for name, raw in fixtures.items():
        (args.output / name).write_bytes(raw)
    check(before == {str(path.relative_to(ROOT)): image.sha256(path.read_bytes()) for path in source_paths},
          'source changed during test', 'source_identity')
    result = {'status': 'passed', 'checks': checks, 'groups': counts, 'seed': 0x64726735,
              'source_sha256': before, 'firmware_audit': audited, 'rom_crc32': rom_crc,
              'artifacts': {name: image.sha256(raw) for name, raw in fixtures.items()},
              'limitations': ['NOR operation-boundary/torn-bit model; no real flash endurance or electrical evidence',
                  'CRC detects corruption probabilistically, not malicious replacement or program correctness',
                  'a semantic-defect fixture is selected by CRC; actual hung-program recovery needs the CPU/platform test']}
    (args.output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PROGRAMMING_IMAGE_PASS ' + json.dumps({'checks': checks, 'groups': counts}))


# imports never generate fixtures or run validation campaigns.
if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""package fixed-ABI firmware into independently committed flash banks."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
BANK_SIZE = 0x20000
HEADER_SIZE = 256
PAYLOAD_SIZE = 0x10000
ROM_SIZE = 0x2000
COMMIT_OFFSET = 0x1fffc
COMMIT_SECTOR_OFFSET = 0x1f000
SECTOR_SIZE = 0x1000
SLOTS = {'A': 0x400000, 'B': 0x420000}
MAGIC = 0x35475244
COMMIT = 0x54494d43
PROFILE = 1
MAX_GENERATION = 0xffffffff
MARCH = 'rv32i2p1_m2p0_c2p0_zicsr2p0_zifencei2p0'
DEFAULT_PREFIX = '/tmp/drg5-arch-tools/gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-'


def require(condition, reason):
    """reject malformed inputs with a stable image-validation reason."""
    # a partial validation cannot produce a usable image descriptor.
    if not condition:
        raise ValueError('FIRMWARE_IMAGE_INVALID ' + reason)


def crc32(data):
    """use reflected IEEE CRC-32 with initial and final all-one complements."""
    return zlib.crc32(data) & 0xffffffff


def sha256(data):
    """record exact artifact identity without claiming code authentication."""
    return hashlib.sha256(data).hexdigest()


def read_hex(path, length):
    """read a complete little-endian word image without address directives or hidden padding."""
    words = Path(path).read_text().splitlines()
    require(length % 4 == 0 and len(words) == length // 4, 'word-image length')
    require(all(re.fullmatch(r'[0-9a-fA-F]{8}', word) for word in words), 'word-image encoding')
    return b''.join(struct.pack('<I', int(word, 16)) for word in words)


def commit_sector():
    """isolate final commit programming from every header and payload erase sector."""
    return b'\xff' * (SECTOR_SIZE - 4) + struct.pack('<I', COMMIT)


def make_bank(payload, rom, generation, committed=True):
    """encode exactly one fixed-size bank with deterministic reserved bytes."""
    require(len(payload) == PAYLOAD_SIZE and len(rom) == ROM_SIZE, 'payload or ROM length')
    require(type(generation) is int and 0 <= generation <= MAX_GENERATION, 'generation range')
    header = bytearray(HEADER_SIZE)
    struct.pack_into('<9I', header, 0, MAGIC, 1, PAYLOAD_SIZE, 0x10000, 0x10000,
                     generation, crc32(payload), crc32(rom), PROFILE)
    struct.pack_into('<I', header, 248, crc32(header[:248]))
    raw = bytearray(b'\xff' * BANK_SIZE)
    raw[:HEADER_SIZE] = header
    raw[HEADER_SIZE:HEADER_SIZE + PAYLOAD_SIZE] = payload
    # a staged image deliberately has no valid commit word anywhere in its final sector.
    if committed:
        raw[COMMIT_SECTOR_OFFSET:] = commit_sector()
    return bytes(raw)


def inspect_bank(raw, rom_crc, require_commit=True, strict_padding=True):
    """validate format, frozen boot compatibility, integrity and optional host-only padding."""
    require(len(raw) == BANK_SIZE, 'bank length')
    magic, version, length, address, entry, generation, payload_crc, expected_rom, profile = struct.unpack_from('<9I', raw)
    require(magic == MAGIC, 'magic')
    require(version == 1, 'format version')
    require(length == PAYLOAD_SIZE, 'payload length')
    require(address == 0x10000 and entry == 0x10000, 'load address or entry')
    require(expected_rom == rom_crc, 'boot ROM compatibility')
    require(profile == PROFILE, 'ISA or boot ABI profile')
    require(raw[36:248] == bytes(212) and raw[252:256] == bytes(4), 'reserved header bytes')
    require(struct.unpack_from('<I', raw, 248)[0] == crc32(raw[:248]), 'header CRC')
    payload = raw[HEADER_SIZE:HEADER_SIZE + PAYLOAD_SIZE]
    require(crc32(payload) == payload_crc, 'payload CRC')
    commit = struct.unpack_from('<I', raw, COMMIT_OFFSET)[0]
    # only a separately programmed final-sector word authorizes boot selection.
    if require_commit:
        require(commit == COMMIT, 'uncommitted bank')
    # staging accepts erased commit state, never a malformed partial commit.
    else:
        require(commit in (COMMIT, 0xffffffff), 'partial commit')
    # hardware ignores unused storage; the host requires deterministic erased padding.
    if strict_padding:
        require(raw[HEADER_SIZE + PAYLOAD_SIZE:COMMIT_OFFSET] == b'\xff' *
                (COMMIT_OFFSET - HEADER_SIZE - PAYLOAD_SIZE), 'non-erased padding')
    return {'generation': generation, 'payload_crc32': payload_crc, 'rom_crc32': expected_rom,
            'profile': profile, 'payload_bytes': length, 'load_address': address, 'entry': entry,
            'committed': commit == COMMIT, 'sha256': sha256(raw)}


def select_bank(a, b, rom_crc, force_a=False):
    """model boot selection using unsigned generations, an A tie-break and no wraparound."""
    valid = {}; rejected = {}
    # failed payloads cannot remain eligible merely because their headers were newer.
    for name, raw in [('A', a), ('B', b)]:
        # the independent oracle validates complete stored bytes before selecting execution.
        try:
            valid[name] = inspect_bank(raw, rom_crc, strict_padding=False)
        # malformed banks remain visible in the decision record.
        except ValueError as error:
            rejected[name] = str(error)
    # manual recovery never falls through to the potentially defective application bank.
    if force_a:
        selected = 'A' if 'A' in valid else None
    # a strict comparison preserves the documented A tie-break.
    elif 'B' in valid and ('A' not in valid or valid['B']['generation'] > valid['A']['generation']):
        selected = 'B'
    # an absent valid bank leaves the CPU held in reset.
    else:
        selected = 'A' if 'A' in valid else None
    return {'selected': selected, 'valid': valid, 'rejected': rejected, 'force_a': force_a}


def next_generation(a, b, rom_crc):
    """advance only from validated generation values and reject integer exhaustion."""
    selected = select_bank(a, b, rom_crc)
    require('A' in selected['valid'], 'golden A required before normal update')
    highest = max(item['generation'] for item in selected['valid'].values())
    require(highest < MAX_GENERATION, 'generation exhausted; service reprovision required')
    return highest + 1


def elf_images(raw):
    """reconstruct physical load bytes independently of the supplied word-image files."""
    require(len(raw) >= 52, 'ELF header length')
    values = struct.unpack_from('<16sHHIIIIIHHHHHH', raw)
    ident, kind, machine, version, entry, phoff, _, flags, size, phsize, phnum, _, _, _ = values
    require(ident[:7] == b'\x7fELF\x01\x01\x01' and (kind, machine, version, entry, flags, size, phsize) ==
            (2, 243, 1, 0, 1, 52, 32), 'ELF profile or entry')
    require(phoff + phnum * phsize <= len(raw), 'ELF program table')
    rom = bytearray(b'\xff' * ROM_SIZE); payload = bytearray(b'\xff' * PAYLOAD_SIZE)
    used = set()
    # BSS has no source bytes and must remain the startup routine's responsibility.
    for number in range(phnum):
        kind, offset, _, address, filesz, memsz, _, _ = struct.unpack_from('<8I', raw, phoff + number * phsize)
        # metadata segments do not initialize CPU storage.
        if kind != 1:
            continue
        require(filesz <= memsz and offset + filesz <= len(raw), 'ELF segment bounds')
        # zero-length load data cannot manufacture BSS initialization.
        if filesz == 0:
            continue
        require((0 <= address and address + filesz <= ROM_SIZE) or
                (0x10000 <= address and address + filesz <= 0x20000), 'ELF physical load region')
        # overlapping initializers are ambiguous even when repeated bytes happen to agree.
        for index in range(filesz):
            destination = address + index
            require(destination not in used, 'ELF overlapping loads')
            used.add(destination)
            # reset code belongs to the configuration's immutable local ROM.
            if destination < ROM_SIZE:
                rom[destination] = raw[offset + index]
            # ordinary executable and initialized-data load bytes belong to IRAM.
            else:
                payload[destination - 0x10000] = raw[offset + index]
    return bytes(rom), bytes(payload)


def validate_firmware(firmware_dir, expected_rompath, prefix=DEFAULT_PREFIX):
    """bind audited executable bytes and all build artifacts to the configuration's frozen ROM."""
    directory = Path(firmware_dir)
    manifest = json.loads((directory / 'build.json').read_text())
    require((manifest['status'], manifest['profile'], manifest['negative'], manifest['march'], manifest['abi']) ==
            ('built', 'imc', 'none', MARCH, 'ilp32'), 'firmware build profile')
    # manifest paths cannot escape the supplied package directory.
    for name, expected in manifest['artifact_sha256'].items():
        require(Path(name).name == name, 'artifact path')
        require(sha256((directory / name).read_bytes()) == expected, 'artifact hash ' + name)
    rom = read_hex(directory / 'rom.hex', ROM_SIZE)
    payload = read_hex(directory / 'iram.hex', PAYLOAD_SIZE)
    expected_rom = read_hex(expected_rompath, ROM_SIZE)
    require(rom == expected_rom, 'configuration ROM differs; FPGA configuration update required')
    require(elf_images((directory / 'firmware.elf').read_bytes()) == (rom, payload), 'ELF and word images differ')
    spec = importlib.util.spec_from_file_location('programming_isa_audit', ROOT / 'microcontroller/tests/audit_firmware.py')
    audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
    inspection = audit.audit(directory / 'firmware.elf', 'imc', prefix)
    return rom, payload, {'manifest_sha256': sha256((directory / 'build.json').read_bytes()),
                          'elf_sha256': sha256((directory / 'firmware.elf').read_bytes()), 'ISA_audit': inspection}


def from_firmware(firmware_dir, expected_rompath, generation, committed=True, prefix=DEFAULT_PREFIX):
    """create a bank only after checking its actual ELF, ISA, ABI and frozen ROM bytes."""
    rom, payload, _ = validate_firmware(firmware_dir, expected_rompath, prefix)
    return make_bank(payload, rom, generation, committed)


def main():
    """emit committed and staged images plus a separate independently erasable commit sector."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--rom', type=Path, required=True)
    parser.add_argument('--generation', type=lambda value: int(value, 0), required=True)
    parser.add_argument('--prefix', default=DEFAULT_PREFIX)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    rom, payload, audit = validate_firmware(args.firmware, args.rom, args.prefix)
    artifacts = {'bank.bin': make_bank(payload, rom, args.generation),
                 'staged.bin': make_bank(payload, rom, args.generation, False), 'commit-sector.bin': commit_sector()}
    # raw images are deterministic; reports retain the exact inputs and validation result.
    for name, data in artifacts.items():
        (args.output / name).write_bytes(data)
    report = {'schema': 'DRG5-FLASH-IMAGE-1', 'rom_crc32': crc32(rom), 'rom_sha256': sha256(rom),
              'generation': args.generation, 'slots': SLOTS, 'bank_size': BANK_SIZE,
              'commit_sector_offset': COMMIT_SECTOR_OFFSET, 'audit': audit,
              'artifacts': {name: sha256(data) for name, data in artifacts.items()},
              'security': 'CRC checks accidental corruption; no authentication or malicious-rollback protection'}
    (args.output / 'package.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(inspect_bank(artifacts['bank.bin'], crc32(rom))))


# importing image helpers performs no programming or filesystem writes.
if __name__ == '__main__':
    main()

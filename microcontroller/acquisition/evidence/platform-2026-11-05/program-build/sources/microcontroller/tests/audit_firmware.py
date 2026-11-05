#!/usr/bin/env python3
"""inspect actual executable bytes and per-object ISA attributes before simulation."""
from collections import Counter
import importlib.util
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]


# bounds checks prevent malformed images from weakening instruction inspection.
def require(condition, message):
    """reject an instruction or binary that exceeds the selected profile."""
    # every failed check has a stable detector diagnostic.
    if not condition:
        raise ValueError('FIRMWARE_AUDIT_FAILED ' + message)


# sections and symbols are read directly instead of trusting disassembler mnemonics.
def read_elf(path):
    """parse little-endian ELF32 headers, executable sections and named symbols."""
    raw = Path(path).read_bytes()
    require(len(raw) >= 52 and raw[:7] == b'\x7fELF\x01\x01\x01', 'ELF32 little endian')
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', raw)
    _, kind, machine, version, entry, _, shoff, flags, size, _, _, shsize, count, strings = header
    require(kind in (1, 2) and machine == 243 and version == 1 and size == 52, 'RV32 object or executable')
    require(shsize == 40 and count and strings < count and shoff + count * 40 <= len(raw), 'section table')
    sections = [struct.unpack_from('<IIIIIIIIII', raw, shoff + index * 40) for index in range(count)]
    names = sections[strings]
    string_table = raw[names[4]:names[4] + names[5]]
    decoded = []
    # section offsets must describe retained file bytes, except explicit NOBITS storage.
    for index, item in enumerate(sections):
        name, section_type, attributes, address, offset, length, link, info, alignment, stride = item
        require(section_type == 8 or offset + length <= len(raw), 'section outside file')
        end = string_table.find(b'\0', name)
        require(0 <= name < len(string_table) and end >= name, 'section name')
        decoded.append({'index': index, 'name': string_table[name:end].decode(), 'type': section_type,
                        'flags': attributes, 'address': address, 'offset': offset, 'size': length,
                        'link': link, 'stride': stride, 'bytes': raw[offset:offset + length] if section_type != 8 else b''})
    symbols = []
    # deliberate illegal probes require exact named symbols in their containing section.
    for section in decoded:
        # ordinary symbol tables are sufficient for these static bare-metal images.
        if section['type'] == 2:
            require(section['stride'] == 16 and section['size'] % 16 == 0 and section['link'] < count, 'symbol table')
            names = decoded[section['link']]['bytes']
            # each symbol retains its section index, including relocatable zero-based sections.
            for offset in range(0, section['size'], 16):
                name, value, length, info, other, index = struct.unpack_from('<IIIBBH', section['bytes'], offset)
                end = names.find(b'\0', name)
                require(0 <= name < len(names) and end >= name, 'symbol name')
                symbols.append({'name': names[name:end].decode(), 'value': value, 'section': index, 'size': length})
    return {'kind': kind, 'flags': flags, 'entry': entry, 'sections': decoded, 'symbols': symbols}


# these legality rules are independent of the production decoder and disassembler aliases.
def standard(word, m_enabled):
    """classify supported 32-bit integer, machine and synchronization encodings."""
    opcode = word & 127
    funct3 = (word >> 12) & 7
    funct7 = word >> 25
    # immediate and direct-jump formats have no additional encoding restrictions.
    if opcode in (0x37, 0x17, 0x6f):
        return 'I'
    # reserved branch, load and store widths are not implemented instructions.
    if opcode == 0x67 and funct3 == 0 or opcode == 0x63 and funct3 in (0, 1, 4, 5, 6, 7):
        return 'I'
    # load and store encodings have independent width allowlists.
    if opcode == 3 and funct3 in (0, 1, 2, 4, 5) or opcode == 0x23 and funct3 in (0, 1, 2):
        return 'I'
    # RV32 shift immediates reserve the sixth shift bit and all unsupported prefixes.
    if opcode == 0x13 and (funct3 not in (1, 5) or funct3 == 1 and funct7 == 0 or funct3 == 5 and funct7 in (0, 32)):
        return 'I'
    # M operations are admitted only by an explicitly matching profile.
    if opcode == 0x33:
        # base register arithmetic excludes reserved SUB and SRA prefix combinations.
        if funct7 == 0 or funct7 == 32 and funct3 in (0, 5):
            return 'I'
        # multiplication and division never enter the I-only profile.
        if funct7 == 1 and m_enabled:
            return 'M'
    # this core strengthens all base FENCE variants to a full ordered barrier.
    if opcode == 0x0f and funct3 in (0, 1):
        return 'Zifencei' if funct3 else 'I'
    # all six CSR operations are separate from the exact machine SYSTEM encodings.
    if opcode == 0x73 and funct3 in (1, 2, 3, 5, 6, 7):
        address = word >> 20
        source = (word >> 15) & 31
        present = {0x300, 0x301, 0x304, 0x305, 0x310, 0x320, 0x340, 0x341, 0x342, 0x343, 0x344,
                   0xb00, 0xb80, 0xb02, 0xb82, *range(0x323, 0x340), *range(0xb03, 0xb20),
                   *range(0xb83, 0xba0), *range(0xf11, 0xf16)}
        writes = funct3 in (1, 5) or source != 0
        # absent counter aliases and privilege/debug CSRs are not provided by Zicsr alone.
        if address in present and not (address >> 10 == 3 and writes):
            return 'Zicsr'
    # unsupported privilege operations cannot hide behind the SYSTEM opcode.
    if word in (0x73, 0x100073, 0x30200073, 0x10500073):
        return 'Sm'
    return None


# use the already qualified semantic RV32C encoder table, without invoking RTL tools.
def compressed_oracle():
    """load the independent exhaustive compressed-encoding oracle."""
    spec = importlib.util.spec_from_file_location('compressed_semantics', ROOT / 'microcontroller/tests/run_decompress.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.oracle()


# inspect every executable byte, including library code that the linker later discards.
def audit(path, profile, prefix, oracle=None):
    """check encoding legality, ABI flags and attributes for one object or image."""
    image = read_elf(path)
    compressed = profile == 'imc'
    require(image['flags'] & ~1 == 0 and bool(image['flags'] & 1) == compressed, 'ILP32 soft-float flags')
    attributes = subprocess.check_output([str(prefix) + 'readelf', '-A', str(path)], text=True)
    match = re.search(r'Tag_RISCV_arch: "([^"]+)"', attributes)
    require(match is not None, 'missing ISA attribute')
    extensions = match[1].split('_')
    expected = {'rv32i2p1', 'zicsr2p0', 'zifencei2p0'}
    # compiler-implied subsets cannot introduce instructions outside their parent extensions.
    if compressed:
        expected |= {'m2p0', 'c2p0'}
    optional = {'zca1p0', 'zmmul1p0'} if compressed else set()
    require(expected <= set(extensions) <= expected | optional, 'object ISA extensions')
    require('Tag_RISCV_stack_align: 16-bytes' in attributes, 'stack alignment attribute')
    table = oracle if oracle is not None else compressed_oracle()
    counts = Counter()
    exceptions = []
    # only one fixed, named illegal instruction belongs to the exception-recovery test.
    for section in image['sections']:
        # non-executable data cannot be mistaken for an unsupported instruction stream.
        if not section['flags'] & 4:
            continue
        require(section['type'] == 1, 'executable section has no file bytes')
        offset = 0
        # raw bytes establish instruction length independently of objdump formatting.
        while offset < section['size']:
            address = section['address'] + offset
            require(offset + 2 <= section['size'], 'truncated instruction parcel')
            halfword = int.from_bytes(section['bytes'][offset:offset + 2], 'little')
            length = 2 if halfword & 3 != 3 else 4
            require(offset + length <= section['size'], 'truncated wide instruction')
            word = int.from_bytes(section['bytes'][offset:offset + length], 'little')
            deliberate = any(item['name'] == 'fault_illegal' and item['section'] == section['index'] and
                             item['value'] == address for item in image['symbols'])
            # the intentional illegal probe must retain its exact original encoding.
            if deliberate:
                require(word == 0xffffffff and length == 4, 'illegal probe changed')
                exceptions.append({'section': section['name'], 'address': address, 'encoding': word})
                counts['deliberate_illegal'] += 1
            # C-disabled objects cannot contain even a legal compressed instruction.
            elif length == 2:
                require(compressed and table[halfword][0] in (1, 2), f'unsupported halfword at {section["name"]}+{offset:#x}')
                counts['C'] += 1
            # the final linked image and every pre-link object share the same whitelist.
            else:
                family = standard(word, compressed)
                require(family is not None, f'unsupported instruction {word:#010x} at {section["name"]}+{offset:#x}')
                counts[family] += 1
            offset += length
    require(sum(counts.values()) > 0, 'no executable instructions inspected')
    # gas omits privilege attributes for objects containing no privileged or CSR instructions.
    has_privilege = 'Tag_RISCV_priv_spec:' in attributes
    require(has_privilege or not (counts['Sm'] or counts['Zicsr']), 'missing machine architecture attribute')
    # a present version must match even when the object itself does not use those instructions.
    if has_privilege:
        require(re.search(r'Tag_RISCV_priv_spec: 1\b', attributes) and
                re.search(r'Tag_RISCV_priv_spec_minor: 13\b', attributes), 'machine architecture attribute')
    return {'file': str(path), 'profile': profile, 'isa': match[1], 'elf_flags': image['flags'],
            'instructions': dict(counts), 'intentional_exceptions': exceptions, 'attributes': attributes}

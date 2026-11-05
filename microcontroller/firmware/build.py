#!/usr/bin/env python3
"""build local boot firmware and a matching private runtime without prebuilt libraries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
DEFAULT_PREFIX = '/tmp/drg5-arch-tools/gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-'
PROFILES = {'imc': 'rv32i2p1_m2p0_c2p0_zicsr2p0_zifencei2p0',
            'i': 'rv32i2p1_zicsr2p0_zifencei2p0'}
NEGATIVES = {'none': None, 'skip-data': 'NEG_SKIP_DATA', 'skip-bss': 'NEG_SKIP_BSS',
             'drop-t0': 'NEG_DROP_T0_RESTORE'}


# hashes bind exact source, executable and target-image bytes.
def digest(path):
    """fingerprint a complete file."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# a command log retains the real invocation and all diagnostics before returning.
def command(argv, directory, commands, label):
    """run one compiler or inspection phase without a shell."""
    result = subprocess.run([str(part) for part in argv], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False, timeout=120)
    log = directory / (label + '.log')
    log.write_text('$ ' + shlex.join([str(part) for part in argv]) + '\n' + result.stdout)
    commands.append({'command': [str(part) for part in argv], 'exit_code': result.returncode, 'log': log.name})
    # compiler failure must not leave a plausible successful firmware manifest.
    if result.returncode:
        raise RuntimeError('firmware phase failed: ' + str(log))
    return result.stdout


# only initialized physical ROM/IRAM bytes are emitted; DRAM is deliberately untouched.
def images(elf, directory):
    """extract ELF load bytes by physical address without manufacturing BSS zeros."""
    raw = elf.read_bytes()
    ident, kind, machine, version, entry, phoff, _, flags, header_size, phsize, phnum, _, _, _ = struct.unpack_from('<16sHHIIIIIHHHHHH', raw)
    # this platform boots a little-endian RV32 executable at ROM address zero.
    if ident[:7] != b'\x7fELF\x01\x01\x01' or (kind, machine, version, entry, header_size, phsize) != (2, 243, 1, 0, 52, 32):
        raise ValueError('unexpected boot ELF format')
    memory = {}; loads = []
    # a NOLOAD BSS segment has no physical bytes to preload.
    for index in range(phnum):
        ptype, offset, vaddr, paddr, filesz, memsz, pflags, alignment = struct.unpack_from('<IIIIIIII', raw, phoff + index * phsize)
        # ignore non-load metadata while retaining every load segment descriptor.
        if ptype != 1:
            continue
        loads.append({'vaddr': vaddr, 'paddr': paddr, 'filesz': filesz, 'memsz': memsz, 'flags': pflags, 'align': alignment})
        # initialized data may have a DRAM VMA only when its load image is in IRAM.
        if filesz > memsz or offset + filesz > len(raw):
            raise ValueError('invalid load segment size')
        # a zero-length BSS image must remain absent from the generated memory files.
        if filesz == 0:
            continue
        # reject memory expansion, DRAM preload and wrapped addresses.
        if not any(low <= paddr and paddr + filesz <= high for low, high in [(0, 0x2000), (0x10000, 0x20000)]):
            raise ValueError('initialized segment outside local ROM/IRAM')
        # overlapping initializers are rejected even if their values happen to match.
        for position in range(filesz):
            address = paddr + position
            # no earlier segment may own the same physical byte.
            if address in memory:
                raise ValueError('overlapping load images')
            memory[address] = raw[offset + position]
    paths = {}
    # unused words are illegal instructions, so stray execution cannot silently look useful.
    for name, low, length in [('rom', 0, 0x2000), ('iram', 0x10000, 0x10000)]:
        data = bytes(memory.get(address, 0xff) for address in range(low, low + length))
        path = directory / (name + '.hex')
        path.write_text(''.join(f'{struct.unpack_from("<I", data, index)[0]:08x}\n' for index in range(0, length, 4)))
        paths[name] = str(path)
    return {'entry': entry, 'elf_flags': flags, 'loads': loads, 'initialized_bytes': len(memory), **paths}


# every object and archive member is built with one explicit profile and ABI.
def build(output, profile='imc', prefix=DEFAULT_PREFIX, negative='none'):
    """return the ELF, word images, symbols and source-bound build manifest."""
    directory = Path(output).resolve()
    # an earlier manifest can never stand in for a failed new build attempt.
    if directory.exists() and any(directory.iterdir()):
        raise ValueError('firmware output directory must be fresh and empty')
    directory.mkdir(parents=True, exist_ok=True)
    march = PROFILES[profile]; define = NEGATIVES[negative]; commands = []
    sources = [SOURCE / name for name in ['platform.h', 'link.ld', 'start.S', 'trap.S', 'probes.S', 'main.c', 'runtime.c', 'build.py']]
    before = {str(path.relative_to(ROOT)): digest(path) for path in sources}
    flags = ['-march=' + march, '-mabi=ilp32', '-mstrict-align', '-mno-relax', '-mcmodel=medany',
             '-msmall-data-limit=0', '-Wa,-mpriv-spec=1.13,-mcsr-check', '-ffreestanding', '-fno-builtin',
             '-fno-pic', '-fno-common', '-fno-stack-protector', '-fno-tree-loop-distribute-patterns',
             '-fno-omit-frame-pointer', '-fno-optimize-sibling-calls', '-ffunction-sections', '-fdata-sections',
             '-O2', '-g3', '-Wall', '-Wextra', '-Werror', '-DFW_COMPRESSED=' + str(int(profile == 'imc')),
             '-I' + str(SOURCE)]
    # deliberate startup/context defects compile as separately named detector builds.
    if define:
        flags.append('-D' + define + '=1')
    objects = []
    # assembly, application and runtime translation units share every target option.
    for name in ['start.S', 'trap.S', 'probes.S', 'main.c', 'runtime.c']:
        obj = directory / (Path(name).stem + '.o')
        command([prefix + 'gcc', *flags, '-c', SOURCE / name, '-o', obj], directory, commands, 'compile-' + Path(name).stem)
        objects.append(obj)
    archive = directory / 'libdrg5rt.a'
    # replace only this build's archive so stale members cannot become hidden inputs.
    if archive.exists():
        archive.unlink()
    command([prefix + 'ar', 'rcsD', archive, objects[-1]], directory, commands, 'archive')
    members = command([prefix + 'ar', 't', archive], directory, commands, 'archive-members').splitlines()
    # the private library contains exactly the freshly compiled runtime object.
    if members != ['runtime.o']:
        raise ValueError('unexpected runtime archive members')
    elf = directory / 'firmware.elf'; linker_map = directory / 'firmware.map'
    linker_script = directory / 'link-profile.ld'
    command([prefix + 'gcc', '-E', '-P', '-x', 'c', '-DFW_COMPRESSED=' + str(int(profile == 'imc')),
             SOURCE / 'link.ld', '-o', linker_script], directory, commands, 'link-script')
    command([prefix + 'gcc', *flags, '-nostdlib', '-nostartfiles', '-nodefaultlibs',
             '-Wl,--no-relax,--gc-sections,--no-undefined,-Map=' + str(linker_map),
             '-T', linker_script, *objects[:-1], archive, '-o', elf], directory, commands, 'link')
    undefined = command([prefix + 'nm', '-u', elf], directory, commands, 'undefined')
    # unresolved functions cannot be supplied silently by a simulator or host library.
    if undefined.strip():
        raise ValueError('unresolved firmware symbol')
    attribute_records = {}; disassembly = {}
    # inspect even unlinked sections and every archive member, not just the final image.
    for path in [*objects, archive, elf]:
        text = command([prefix + 'readelf', '-h', '-A', path], directory, commands, 'attributes-' + path.name)
        attribute_records[path.name] = text
        # every input must advertise the soft-float 32-bit ABI and 16-byte stack alignment.
        expected_arch = march + ('_zmmul1p0_zca1p0' if profile == 'imc' else '')
        architecture = re.findall(r'Tag_RISCV_arch: "([^"]+)"', text)
        elf_flags = [int(value, 16) for value in re.findall(r'Flags:\s+(0x[0-9a-f]+)', text)]
        priv_major = re.findall(r'Tag_RISCV_priv_spec: (\d+)', text)
        priv_minor = re.findall(r'Tag_RISCV_priv_spec_minor: (\d+)', text)
        decoded = command([prefix + 'objdump', '-d', '-M', 'no-aliases,numeric', path], directory, commands, 'disassembly-' + path.name)
        disassembly[path.name] = decoded
        uses_system = bool(re.search(r'\s(?:csrr\w*|mret|wfi|ecall|ebreak|c\.ebreak)\s*(?:\n|\s)', decoded))
        # implied subsets are allowed only in the matching final instruction profile.
        if ('ELF32' not in text or 'Tag_RISCV_stack_align: 16-bytes' not in text or
                architecture != [expected_arch] or elf_flags != [int(profile == 'imc')] or
                (priv_major, priv_minor) not in [(['1'], ['13']), ([], [])] or
                (uses_system and not priv_major)):
            raise ValueError('firmware ABI attributes mismatch: ' + path.name)
    symbols_text = command([prefix + 'nm', '-n', '--defined-only', elf], directory, commands, 'symbols')
    symbols = {}
    # named recovery PCs and initialization ranges are independent host-checker inputs.
    for line in symbols_text.splitlines():
        fields = line.split()
        # retain only complete address, type and symbol records.
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    image = images(elf, directory)
    map_text = linker_map.read_text()
    # link maps must show extraction from this archive and never an implicit hosted runtime.
    if 'libdrg5rt.a(runtime.o)' not in map_text or 'libgcc' in map_text or 'libc.a' in map_text:
        raise ValueError('unexpected linked library provenance')
    versions = {}; tool_hashes = {}
    # executable fingerprints include compiler subprocesses, not just the driver banner.
    for name in ['gcc', 'ar', 'readelf', 'objdump', 'nm']:
        path = Path(prefix + name).resolve()
        versions[name] = command([path, '--version'], directory, commands, 'version-' + name).splitlines()[0]
        tool_hashes[str(path)] = digest(path)
    # GCC exposes the actual private compiler, assembler and linker it selected.
    for name in ['cc1', 'as', 'ld', 'collect2']:
        path = Path(command([prefix + 'gcc', '-print-prog-name=' + name], directory, commands, 'tool-' + name).strip()).resolve()
        tool_hashes[str(path)] = digest(path)
    # source drift invalidates a build even if the resulting image happens to run.
    if before != {str(path.relative_to(ROOT)): digest(path) for path in sources}:
        raise ValueError('firmware source changed during build')
    (directory / 'symbols.json').write_text(json.dumps(symbols, indent=2) + '\n')
    record = {'status': 'built', 'profile': profile, 'negative': negative, 'march': march, 'abi': 'ilp32',
              'flags': flags, 'commands': commands, 'source_sha256': before, 'tool_sha256': tool_hashes,
              'versions': versions, 'elf': str(elf), 'map': str(linker_map), 'linker_script': str(linker_script), 'symbols': symbols,
              'objects': [str(path) for path in objects], 'archive': str(archive), 'archive_members': members,
              'image': image, 'attributes': attribute_records,
              'artifact_sha256': {path.name: digest(path) for path in [*objects, archive, elf, linker_map, linker_script,
                                      directory / 'rom.hex', directory / 'iram.hex', directory / 'symbols.json']},
              'contract': 'ROM/IRAM initialization only; startup copies data and clears BSS; no external memory or default libraries'}
    manifest = directory / 'build.json'; manifest.write_text(json.dumps(record, indent=2) + '\n')
    return {'manifest': str(manifest), 'elf': str(elf), 'map': str(linker_map), 'rom': image['rom'],
            'iram': image['iram'], 'symbols': symbols, 'profile': profile, 'negative': negative}


# command-line builds retain the same explicit profile controls as the reusable API.
def main():
    """compile a firmware variant and print its retained artifact paths."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', choices=PROFILES, default='imc')
    parser.add_argument('--prefix', default=DEFAULT_PREFIX)
    parser.add_argument('--negative', choices=NEGATIVES, default='none')
    args = parser.parse_args()
    print(json.dumps(build(args.output, args.profile, args.prefix, args.negative), indent=2))


# imports expose the build API without invoking tools or writing target images.
if __name__ == '__main__':
    main()

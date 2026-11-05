#!/usr/bin/env python3
"""compile the admitted synthetic kernel and leaf interrupt handler with one pinned ISA and ABI."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'microcontroller/tests'))
from audit_firmware import audit


def build(output):
    """reuse image extraction and tool journaling, without copying any production firmware source."""
    spec = importlib.util.spec_from_file_location('synthetic_build_helpers', SOURCE.parent / 'build.py')
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    output = Path(output).resolve(); output.mkdir(parents=True, exist_ok=False)
    prefix = helper.DEFAULT_PREFIX
    commands = []
    flags = ['-march=' + helper.PROFILES['imc'], '-mabi=ilp32', '-mstrict-align', '-mno-relax',
             '-mcmodel=medany', '-msmall-data-limit=0', '-Wa,-mpriv-spec=1.13,-mcsr-check',
             '-ffreestanding', '-fno-builtin', '-fno-pic', '-fno-common', '-fno-stack-protector',
             '-ffunction-sections', '-fdata-sections', '-O2', '-g3', '-Wall', '-Wextra', '-Werror',
             '-DFW_COMPRESSED=1', '-I' + str(SOURCE)]
    sources = [SOURCE.parent / 'start.S', SOURCE / 'trap.S', SOURCE / 'main.c']
    retained = sources + [SOURCE / 'kernel.h', SOURCE / 'build.py', SOURCE.parent / 'build.py', SOURCE.parent / 'link.ld',
                          ROOT / 'microcontroller/tests/audit_firmware.py']
    before = {str(path.relative_to(ROOT)): helper.digest(path) for path in retained}
    objects = []
    # every translation unit uses the same explicit machine architecture, extensions and soft-float ABI.
    for source in sources:
        target = output / (source.stem + '.o')
        helper.command([prefix + 'gcc', *flags, '-c', source, '-o', target], output, commands, 'compile-' + source.stem)
        objects.append(target)
    script = output / 'link.ld'
    helper.command([prefix + 'gcc', '-E', '-P', '-x', 'c', '-DFW_COMPRESSED=1', SOURCE.parent / 'link.ld', '-o', script], output, commands, 'link-script')
    elf = output / 'firmware.elf'
    helper.command([prefix + 'gcc', *flags, '-nostdlib', '-nostartfiles', '-nodefaultlibs',
                    '-Wl,--no-relax,--gc-sections,--no-undefined,-Map=' + str(output / 'firmware.map'),
                    '-T', script, *objects, '-o', elf], output, commands, 'link')
    undefined = helper.command([prefix + 'nm', '-u', elf], output, commands, 'undefined')
    assert not undefined.strip(), 'unexpected runtime dependency'
    # inspect every compiled object, including the actual privileged assembly and final linked instructions.
    for path in [*objects, elf]:
        attributes = helper.command([prefix + 'readelf', '-h', '-A', path], output, commands, 'attributes-' + path.name)
        assert helper.PROFILES['imc'] in attributes and 'ELF32' in attributes and 'soft-float ABI' in attributes
        helper.command([prefix + 'objdump', '-d', '-M', 'no-aliases,numeric', path], output, commands, 'instructions-' + path.name)
    inspection = audit(elf, 'imc', prefix)
    image = helper.images(elf, output)
    symbols_text = helper.command([prefix + 'nm', '-n', '--defined-only', elf], output, commands, 'symbols')
    symbols = {line.split()[2]: int(line.split()[0], 16) for line in symbols_text.splitlines() if len(line.split()) == 3}
    (output / 'symbols.json').write_text(json.dumps(symbols, indent=2) + '\n')
    assert before == {str(path.relative_to(ROOT)): helper.digest(path) for path in retained}, 'firmware source changed'
    result = {'schema': 'DRG5-SYNTHETIC-FIRMWARE-1', 'status': 'built', 'profile': 'SYNTH80',
              'march': helper.PROFILES['imc'], 'abi': 'ilp32', 'flags': flags, 'commands': commands,
              'source_sha256': before, 'ISA_audit': inspection, 'images': image,
              'artifact_sha256': {path.name: helper.digest(path) for path in [*objects, elf, output / 'rom.hex', output / 'iram.hex', output / 'symbols.json']},
              'tool_sha256': {name: helper.digest(prefix + name) for name in ['gcc', 'as', 'ld', 'objdump', 'readelf', 'nm']},
              'scope': 'compiled simulation workload; no physical 80 MHz or production aperture qualification'}
    (output / 'build.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    """retain one fresh compiled workload and its complete audit manifest."""
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); print(build(args.output)['status'])


# imports never compile firmware or touch an existing output directory.
if __name__ == '__main__':
    main()

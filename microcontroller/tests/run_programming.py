#!/usr/bin/env python3
"""boot and recover the complete CPU through independent pin-level persistent flash models."""
import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite')


def module(name, path):
    """load a repository helper without invoking its command interface."""
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


def digest(path):
    """bind each consumed source and artifact to exact bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    """retain every boot attempt and compare completed architectural and serial effects."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    build = args.build.resolve(); build.mkdir(parents=True, exist_ok=True)
    image = module('flash_image', 'microcontroller/programming/image.py')
    helper = module('elf_runner', 'microcontroller/verification/execution/run_elf.py')
    rom, payload, inspection = image.validate_firmware(args.firmware, ROOT / 'microcontroller/programming/boot-rom.hex', image.DEFAULT_PREFIX)
    schema = helper.schema(build)
    # all terminal fields are derived from the same production package.
    with (build / 'arch_trace_fields.h').open('a') as header:
        header.write('#define TRACE_NEXT_PC_LSB ' + str(schema['fields']['next_pc']['lsb']) + '\n')
    (output / 'trace-schema.json').write_text(json.dumps(schema, indent=2) + '\n')
    good_a = image.make_bank(payload, rom, 1); good_b = image.make_bank(payload, rom, 2)
    damaged = bytearray(good_b); damaged[image.HEADER_SIZE + 17] ^= 1
    hung = bytearray(payload); struct.pack_into('<I', hung, 0, 0x0000006f)
    banks = {'a': good_a, 'b': good_b, 'repaired': image.make_bank(payload, rom, 3),
             'damaged': bytes(damaged), 'staged': image.make_bank(payload, rom, 2, False),
             'hang': image.make_bank(bytes(hung), rom, 2), 'empty': b'\xff' * image.BANK_SIZE}
    # each fixture preserves full physical banks, including erased regions and commit sectors.
    for name, data in banks.items():
        (output / (name + '.bin')).write_bytes(data)
    shutil.copy2(ROOT / 'microcontroller/programming/boot-rom.hex', output / 'rom.hex')
    rng = random.Random(0x46ad2)
    (output / 'poison.hex').write_text(''.join(f'{rng.getrandbits(32) | 1:08x}\n' for _ in range(8192)))
    sources = [ROOT / f'microcontroller/rtl/{name}.sv' for name in helper.NAMES]
    sources += [ROOT / f'microcontroller/rtl/{name}.sv' for name in
                ['drg5_local_fabric', 'drg5_boot_soc', 'drg5_uart_tx', 'drg5_spi_read', 'drg5_spi_boot', 'drg5_programmable_system']]
    cpp = ROOT / 'microcontroller/tests/programming_sim.cpp'
    attributed = sources + [cpp, Path(__file__), ROOT / 'microcontroller/programming/image.py',
        ROOT / 'microcontroller/programming/boot-rom.hex', ROOT / 'microcontroller/verification/execution/run_elf.py',
        ROOT / 'microcontroller/tests/replay_counter_trace.py', ROOT / 'microcontroller/rtl/drg5_datapath_defs.svh']
    before = {str(path.relative_to(ROOT)): digest(path) for path in attributed}
    # source snapshots prevent a later revision from changing what a failed attempt means.
    for path in attributed:
        target = output / 'sources' / path.relative_to(ROOT); target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    command = [str(TOOLS / 'bin/verilator'), '--cc', '--exe', '--build', '--assert', '-Wall', '-j', '2',
               '--x-initial', 'unique', '--x-assign', 'unique', '-CFLAGS', '-O1 -I' + str(build),
               '-I' + str(ROOT / 'microcontroller/rtl'), '--top-module', 'drg5_programmable_system', '--Mdir', str(build),
               '-GCLOCK_HZ=25000000', f'-GROM_FILE="{output / "rom.hex"}"', f'-GDRAM_FILE="{output / "poison.hex"}"',
               *map(str, sources), str(cpp)]
    result = {'source_sha256': before, 'firmware': inspection, 'firmware_elf_sha256': digest(args.firmware / 'firmware.elf'),
              'command': command, 'runs': [], 'scope': 'full RTL SPI boot, local-memory CPU, UART and reset recovery; physical configuration and flash programming unverified'}
    # warnings are build failures; there is no hidden initialized-IRAM shortcut.
    with (output / 'build.log').open('w') as log:
        compiled = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False)
    passed = compiled.returncode == 0 and '%Warning' not in (output / 'build.log').read_text()
    # only a complete strict build can supply evidence for executable recovery.
    if passed:
        cases = [('golden', 'a', 'empty', 'good', 0), ('updated', 'a', 'b', 'good', 1),
                 ('payload-fallback', 'a', 'damaged', 'good', 0), ('torn-commit', 'a', 'staged', 'good', 0),
                 ('forced-golden', 'a', 'b', 'force-a', 0), ('damaged-hang-recovery', 'a', 'hang', 'recover-hang', 1),
                 ('empty-repair', 'empty', 'empty', 'repair-empty', 1)]
        # all expected banks are independently classified before the RTL sees a bit.
        for name, a, b, mode, bank in cases:
            oracle = image.select_bank(banks[a], banks[b], image.crc32(rom), mode == 'force-a')
            # repair begins with no executable image; every other case has one expected initial bank.
            if mode != 'repair-empty':
                assert oracle['selected'] == ('B' if bank else 'A')
            seeds = [1, 305419896] if name in ['golden', 'updated'] else [1]
            # unreset register contents must not decide whether valid firmware can boot.
            for seed in seeds:
                label = name + '-' + str(seed); trace = output / (label + '.jsonl')
                invocation = [str(build / 'Vdrg5_programmable_system'), str(output / (a + '.bin')),
                    str(output / (b + '.bin')), str(trace), str(seed), mode, str(bank),
                    str(output / ('a.bin' if mode == 'repair-empty' else 'repaired.bin'))]
                run = subprocess.run(invocation, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, check=False, timeout=120)
                (output / (label + '.log')).write_text(run.stdout)
                rows = [json.loads(line.split(' ', 1)[1]) for line in run.stdout.splitlines() if line.startswith('PROGRAMMING_EPOCH_PASS ')]
                expected_epochs = 3 if mode == 'recover-hang' else 2 if mode == 'repair-empty' else 1
                ok = run.returncode == 0 and run.stdout.count('PROGRAMMING_SIM_PASS') == 1 and len(rows) == expected_epochs
                item = {'case': name, 'seed': seed, 'exit': run.returncode, 'passed': ok, 'epochs': rows, 'command': invocation}
                # complete failed traces remain inspectable alongside successful ones.
                if trace.exists():
                    item['trace_sha256'] = digest(trace)
                    packed = gzip.compress(trace.read_bytes(), mtime=0)
                    assert hashlib.sha256(gzip.decompress(packed)).hexdigest() == item['trace_sha256']
                    trace.with_suffix('.jsonl.gz').write_bytes(packed); trace.unlink()
                result['runs'].append(item); passed &= ok
                print(('PASS ' if ok else 'FAIL ') + label, flush=True)
    result['source_stable'] = before == {str(path.relative_to(ROOT)): digest(path) for path in attributed}
    passed &= result['source_stable']
    result['status'] = 'passed' if passed else 'failed'
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    # a failed case cannot be replaced by a later successful repair without preserving its status.
    if not passed:
        raise RuntimeError('programming integration verification failed: ' + str(output))
    print('PROGRAMMING_INTEGRATION_PASS')


# importing the runner does not rebuild firmware or alter a device.
if __name__ == '__main__':
    main()

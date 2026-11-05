#!/usr/bin/env python3
"""execute the actual board subsystem at a selected clock and UART divider."""
import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite')


def digest(path):
    """bind sources and executable artifacts to exact bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    """retain each clock-profile execution without replacing earlier failed attempts."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--mhz', type=int, required=True)
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--forwarding', type=int, choices=[0, 1], default=1)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    build = args.build.resolve(); build.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('elf_runner', ROOT / 'microcontroller/verification/execution/run_elf.py')
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    schema = helper.schema(build)
    # derive the additional PC field from the same packed production declaration.
    with (build / 'arch_trace_fields.h').open('a') as header:
        header.write('#define TRACE_NEXT_PC_LSB ' + str(schema['fields']['next_pc']['lsb']) + '\n')
    sources = [ROOT / f'microcontroller/rtl/{name}.sv' for name in helper.NAMES]
    sources += [ROOT / f'microcontroller/rtl/{name}.sv' for name in
                ['drg5_local_fabric', 'drg5_soc', 'drg5_uart_tx', 'drg5_board_system']]
    cpp = ROOT / 'microcontroller/tests/board_sim.cpp'
    bound = sources + [cpp, Path(__file__), ROOT / 'microcontroller/rtl/drg5_datapath_defs.svh']
    before = {str(path.relative_to(ROOT)): digest(path) for path in bound}
    # snapshots preserve the exact candidate even when a later review changes active sources.
    for source in bound:
        target = output / 'sources' / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
    # initialize executable storage only from the inspected compiled firmware.
    for name in ['rom.hex', 'iram.hex', 'firmware.elf', 'build.json']:
        shutil.copy2(args.firmware / name, output / name)
    rng = random.Random(0x72616d)
    (output / 'poison.hex').write_text(''.join(f'{rng.getrandbits(32) | 1:08x}\n' for _ in range(8192)))
    verilator = str(TOOLS / 'bin/verilator')
    command = [verilator, '--cc', '--exe', '--build', '--assert', '-Wall', '-j', '2',
               '--x-initial', 'unique', '--x-assign', 'unique', '-CFLAGS', '-O0 -I' + str(build),
               '-I' + str(ROOT / 'microcontroller/rtl'), '--top-module', 'drg5_board_system', '--Mdir', str(build),
               '-GCLOCK_HZ=' + str(args.mhz * 1000000), '-GFORWARDING=' + str(args.forwarding),
               f'-GROM_FILE="{output / "rom.hex"}"', f'-GIRAM_FILE="{output / "iram.hex"}"',
               f'-GDRAM_FILE="{output / "poison.hex"}"', *map(str, sources), str(cpp)]
    result = {'clock_hz': args.mhz * 1000000, 'forwarding': args.forwarding, 'sources': before,
              'firmware_sha256': digest(output / 'firmware.elf'), 'build_command': command, 'runs': [],
              'scope': 'portable board subsystem RTL; physical PLL, pins and hardware remain unverified'}
    # strict compilation rejects every HDL warning before runtime checks can count.
    with (output / 'build.log').open('w') as log:
        process = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False)
    passed = process.returncode == 0 and '%Warning' not in (output / 'build.log').read_text()
    # different seeds vary unreset registers while identical images preserve program semantics.
    if passed:
        executable = build / 'Vdrg5_board_system'
        result['executable_sha256'] = digest(executable)
        # positive seeds and the named detector calibration have distinct required outcomes.
        for seed, mutation in [(1, ''), (305419896, ''), (1, 'repeat-loopback')]:
            label = str(seed) + ('-' + mutation if mutation else '')
            trace = output / f'trace-{label}.jsonl'
            invocation = [str(executable), str(trace), str(args.mhz * 1000000), str(seed)]
            # inject only the requested latch failure, never change production RTL.
            if mutation:
                invocation.append(mutation)
            run = subprocess.run(invocation, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, check=False, timeout=120)
            (output / f'run-{label}.log').write_text(run.stdout)
            markers = [line.split(' ', 1)[1] for line in run.stdout.splitlines() if line.startswith('BOARD_SIM_PASS ')]
            row = {'seed': seed, 'mutation': mutation, 'command': invocation, 'exit': run.returncode,
                   'observed': json.loads(markers[0]) if len(markers) == 1 else None}
            row['passed'] = (run.returncode != 0 and not markers and
                'BOARD_SIM_FAILURE diagnostic event duplicated or masked button lost' in run.stdout) if mutation else (
                run.returncode == 0 and len(markers) == 1)
            passed &= row['passed']
            # lossless compressed captures keep complete terminal histories reviewable.
            if trace.exists():
                row['trace_sha256'] = digest(trace)
                compressed = trace.with_suffix('.jsonl.gz')
                compressed.write_bytes(gzip.compress(trace.read_bytes(), mtime=0))
                # keep the original capture unless decompression preserves its exact bytes.
                if hashlib.sha256(gzip.decompress(compressed.read_bytes())).hexdigest() != row['trace_sha256']:
                    raise RuntimeError('trace compression mismatch')
                trace.unlink()
            result['runs'].append(row)
    result['source_stable'] = before == {str(path.relative_to(ROOT)): digest(path) for path in bound}
    passed &= result['source_stable']
    result['status'] = 'passed' if passed else 'failed'
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    # a partial build or run has no positive qualification marker.
    if not passed:
        raise RuntimeError('board subsystem verification failed: ' + str(output))
    print('BOARD_QUALIFICATION_SIM_PASS ' + str(output))


# importing the runner performs no builds or filesystem writes.
if __name__ == '__main__':
    main()

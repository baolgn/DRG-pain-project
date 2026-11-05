#!/usr/bin/env python3
"""run a bounded real-RTL CPU workload alongside synthetic acquisition and retained ownership."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'microcontroller/tests'))
from replay_counter_trace import make_schema


def digest(path):
    """bind code, tools and resulting artifacts to exact bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    """retain strict build diagnostics and independent result evidence for each reproducible seed."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--seed', type=int, action='append')
    parser.add_argument('--skip-negative', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    build = args.build.resolve(); build.mkdir(parents=True, exist_ok=True)
    helper_spec = importlib.util.spec_from_file_location('synthetic_firmware', ROOT / 'microcontroller/firmware/synthetic/build.py')
    helper = importlib.util.module_from_spec(helper_spec); helper_spec.loader.exec_module(helper)
    firmware = helper.build(output / 'firmware')
    rtl = [ROOT / 'microcontroller/rtl/drg5_control_pkg.sv'] + [path for path in sorted((ROOT / 'microcontroller/rtl').glob('*.sv')) if path.name != 'drg5_control_pkg.sv']
    extra = [ROOT / 'microcontroller/tests/synthetic/drg5_synthetic_debug.sv', ROOT / 'microcontroller/tests/synthetic_cpu_sim.cpp']
    names = rtl + extra + [ROOT / 'microcontroller/rtl/drg5_datapath_defs.svh', Path(__file__), ROOT / 'microcontroller/tests/replay_counter_trace.py']
    before = {str(path.relative_to(ROOT)): digest(path) for path in names}
    # retain the simulation-only permission change separately from unchanged production core sources.
    for path in names:
        destination = output / 'sources' / path.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, destination)
    schema = make_schema(ROOT / 'microcontroller/rtl/drg5_control_pkg.sv')
    fields = {key.removeprefix('terminal.'): value.copy() for key, value in schema['fields'].items() if key.startswith('terminal.')}
    base = min(value['lsb'] for value in fields.values())
    # offsets describe the packed public terminal packet, not private internal hierarchy.
    for value in fields.values():
        value['lsb'] -= base
    width = max(value['lsb'] + value['width'] for value in fields.values())
    header = '/* these offsets describe the retained public retirement record. */\n'
    # only framing, retirement and MRET detection need host-decoded fields.
    for macro, name in [('VALID', 'valid'), ('INSN', 'packet.raw')]:
        header += f'#define TRACE_{macro}_LSB {fields[name]["lsb"]}\n'
    header += f'#define TRACE_WORDS {(width + 31) // 32}\n'
    (build / 'synthetic_trace_fields.h').write_text(header)
    (output / 'trace-schema.json').write_text(json.dumps({'schema': 'DRG5-SYNTHETIC-TERMINAL-1', 'encoding': 'gzip stream of little-endian uint64 cycle, then low-word-first packed uint32 terminal words', 'words': (width + 31) // 32, 'fields': fields}, indent=2) + '\n')
    verilator = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator')
    command = [str(verilator), '--cc', '--exe', '--build', '--assert', '-Wall', '-j', '2', '--x-initial', 'unique', '--x-assign', 'unique',
               '-CFLAGS', '-O2 -I' + str(build), '-LDFLAGS', '-lz', '-I' + str(ROOT / 'microcontroller/rtl'),
               '--top-module', 'drg5_synthetic_debug', '--Mdir', str(build), *map(str, rtl + extra)]
    report = {'schema': 'DRG5-SYNTHETIC-CPU-1', 'status': 'running', 'source_sha256': before, 'firmware': firmware,
              'command': command, 'runs': [], 'negative_controls': [], 'hardware_tested': False,
              'scope': 'bounded real RTL CPU/debug/guard execution; synthetic memory and capture/transport models; no physical80MHz, production external memory, or1800sRTL claim'}
    # every failure retains its partial report and complete compiler/simulator diagnostics.
    try:
        # strict diagnostics remain available even if elaboration stops before execution.
        with (output / 'build.log').open('w') as log:
            built = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=900, check=False)
        assert built.returncode == 0 and '%Warning' not in (output / 'build.log').read_text(), 'strict synthetic CPU build failed'
        runs = [(str(seed), seed, None) for seed in (args.seed or [1, 305419896])]
        runs.append(('active-reset', 1, 'active-reset'))
        # corrupted DSP output must trigger its specific independent result detector.
        if not args.skip_negative:
            runs.append(('wrong-result', 1, 'wrong-result'))
        # each run starts a fresh process, CPU reset and independently poisoned data memory.
        for name, seed, mutation in runs:
            directory = output / name; directory.mkdir()
            # every process consumes its own frozen firmware images.
            for image in ['rom.hex', 'iram.hex']:
                shutil.copy2(output / 'firmware' / image, directory / image)
            invocation = [str(build / 'Vdrg5_synthetic_debug'), str(directory), str(seed)] + ([mutation] if mutation else [])
            # retain ordinary assertion failures and negative-control diagnostics verbatim.
            with (directory / 'run.log').open('w') as log:
                process = subprocess.run(invocation, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=900, check=False)
            text = (directory / 'run.log').read_text()
            # negative controls succeed only through the intended ordinary checker.
            if mutation == 'wrong-result':
                assert process.returncode != 0 and 'DSP independent result mismatch' in text, text[-3000:]
                report['negative_controls'].append({'name': name, 'detected': True, 'detector': 'DSP independent result mismatch'})
            # normal success requires complete firmware, bus and hardware-monitor checks.
            else:
                assert process.returncode == 0 and 'SYNTHETIC_CPU_PASS' in text, text[-3000:]
                metrics = json.loads((directory / 'result.json').read_text()); assert metrics['status'] == 'pass'
                report['runs'].append({'seed': seed, 'name': name, 'metrics': metrics, 'trace_sha256': digest(directory / 'retirement.bin.gz'), 'events_sha256': digest(directory / 'events.jsonl')})
                print(text.strip(), flush=True)
        assert before == {str(path.relative_to(ROOT)): digest(path) for path in names}, 'RTL or test source changed during run'
        report['status'] = 'pass'
    # a failed run cannot leave an apparently successful qualification manifest.
    finally:
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')


# importing the runner never launches a simulator or modifies existing evidence.
if __name__ == '__main__':
    main()

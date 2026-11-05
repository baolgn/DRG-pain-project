#!/usr/bin/env python3
"""qualify real fetch/control execution with independent instruction synchronization program semantics."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess


# every invocation retains exact source and diagnostics before running tools.
def main():
    """run strict elaborations, reproducible schedules and calibrated negative controls."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-fence-execution'))
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    evidence = (args.evidence_dir or root / 'microcontroller/tests/evidence/fence-execution-2026-11-04').resolve()
    build.mkdir(parents=True, exist_ok=True)
    revisions = evidence / 'revisions'
    revisions.mkdir(parents=True, exist_ok=True)
    revision = max([int(p.name.split('-')[0]) for p in revisions.iterdir() if p.is_dir()] + [0]) + 1
    attempt = revisions / f'{revision:02d}-qualification'
    attempt.mkdir()
    names = ['drg5_control_pkg', 'drg5_immediate', 'drg5_decoder', 'drg5_branch', 'drg5_lsu',
             'drg5_shifter', 'drg5_alu', 'drg5_forward', 'drg5_decompress', 'drg5_fetch_guard',
             'drg5_fetch_buffer', 'drg5_fetch', 'drg5_frontend', 'drg5_csr', 'drg5_muldiv', 'drg5_control']
    sources = ['microcontroller/rtl/' + name + '.sv' for name in names]
    sources.append('microcontroller/tests/drg5_fence_execution_tb.sv')
    attributed = sources + ['microcontroller/rtl/drg5_datapath_defs.svh',
                            'microcontroller/tests/run_fence_execution.py', 'microcontroller/tests/Makefile']
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in attributed}
    # failure evidence remains bound to the exact pre-build source.
    for name in attributed:
        target = attempt / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    (attempt / 'source-sha256.json').write_text(json.dumps(before, indent=2) + '\n')
    profiles = [(1, 1, 0, 1)] if args.smoke else [(1, 1, 0, 1), (1, 1, 0, 0),
                (1, 1, 1, 1), (0, 1, 0, 1), (1, 0, 0, 1), (0, 0, 0, 1)]
    seeds = [1] if args.smoke else [0, 1, 305419896]
    results = []
    logs = []
    # each separately elaborated configuration has its own real production frontend.
    for c_enabled, fi_enabled, diagnostic, forwarding in profiles:
        profile = f'c{c_enabled}-fi{fi_enabled}-d{diagnostic}-f{forwarding}'
        directory = build / profile
        directory.mkdir(exist_ok=True)
        command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2',
                   '-CFLAGS', '-O0', '-Imicrocontroller/rtl', '--top-module', 'drg5_fence_execution_tb',
                   f'-GC_ENABLED={c_enabled}', f'-GZIFENCEI_ENABLED={fi_enabled}',
                   f'-GDIAGNOSTIC={diagnostic}', f'-GFORWARDING={forwarding}', '--Mdir', str(directory), *sources]
        log = directory / 'build.log'
        # complete commands and tool diagnostics are retained for every attempt.
        with log.open('w') as stream:
            stream.write('$ ' + shlex.join(command) + '\n'); stream.flush()
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=600, check=False)
        logs.append(log)
        shutil.copyfile(log, attempt / f'{profile}-build.log')
        # strict HDL warnings are failures rather than waived qualification exceptions.
        if result.returncode or '%Warning' in log.read_text():
            raise RuntimeError(f'fence build failed: {log}')
        # fixed local LCG seeds reproduce program data, stage holds and independent bus latencies.
        for seed in seeds:
            command = [str(directory / 'Vdrg5_fence_execution_tb'), '+verilator+seed+1', f'+seed={seed}']
            result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=180, check=False)
            log = directory / f'seed-{seed}.log'
            log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
            logs.append(log); shutil.copyfile(log, attempt / f'{profile}-seed-{seed}.log')
            marker = f'FENCE_EXEC_PASS C={c_enabled} FI={fi_enabled} diagnostic={diagnostic} forwarding={forwarding} seed={seed} '
            # a zero exit without the exact final coverage marker cannot qualify.
            if result.returncode or result.stdout.count(marker) != 1:
                raise RuntimeError(f'fence simulation failed: {log}')
            terminal = next(line for line in result.stdout.splitlines() if line.startswith(marker))
            results.append({'profile': profile, 'seed': seed, 'command': command, 'exit_code': result.returncode,
                            'terminal': terminal})
            print(terminal, flush=True)
    # occupancy modes build identical instruction streams; DMA polls may legitimately differ.
    if not args.smoke:
        # compare program construction only, never timing-dependent polling retirement counts.
        for seed in seeds:
            peers = [item for item in results if item['seed'] == seed and item['profile'] in
                     {'c1-fi1-d0-f1', 'c1-fi1-d0-f0', 'c1-fi1-d1-f1'}]
            digests = [re.search(r'program_digest=([0-9a-f]+)', item['terminal']).group(1) for item in peers]
            # differing construction would invalidate the occupancy comparison.
            if len(peers) != 3 or len(set(digests)) != 1:
                raise RuntimeError(f'fence program construction differs for seed {seed}: {digests}')
    detectors = [('mutate_raw', 'current executable image and original length'),
                 ('mutate_redirect', 'current executable image and original length'),
                 ('mutate_stale', 'stale I response disposition'),
                 ('mutate_dma', 'current executable image and original length'),
                 ('mutate_effect', 'physical effects match permitted retirement')]
    # the smoke attempt establishes functionality before final detector qualification.
    if not args.smoke:
        # corrupt observations or physical effects only; reference expectations remain unchanged.
        for mutation, label in detectors:
            command = [str(build / 'c1-fi1-d0-f1/Vdrg5_fence_execution_tb'), '+verilator+seed+1',
                       '+seed=1', '+' + mutation]
            result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=180, check=False)
            log = build / (mutation + '.log')
            log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
            logs.append(log); shutil.copyfile(log, attempt / log.name)
            marker = 'FENCE_EXEC_CHECK_FAILED ' + label
            # an unrelated assertion, timeout or successful terminal does not calibrate the detector.
            if result.returncode == 0 or marker not in result.stdout or 'FENCE_EXEC_PASS ' in result.stdout:
                raise RuntimeError(f'fence detector failed: {log}')
            results.append({'negative_control': mutation, 'command': command, 'exit_code': result.returncode,
                            'detector': marker})
    # any concurrent edit invalidates attribution instead of silently blessing final bytes.
    after = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in attributed}
    # fail explicitly when an input changed during tool execution.
    if before != after:
        raise RuntimeError('fence execution source changed during qualification')
    summary = {'status': 'passed', 'scope': 'real frontend and packet controller; finite instruction synchronization simulation',
               'profiles': profiles, 'seeds': seeds, 'smoke': args.smoke, 'results': results,
               'source_sha256': after, 'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
               'assumptions': ['I snapshots captured at acceptance; executable D writes visible at response; independent acceptance and response delays',
                               'I and D stress deadlines128clocks; no production latency claim',
                               'one outstanding transaction per port; no response reordering or unsafe reset',
                               'independent program and service LCG streams preserve identical images across occupancy profiles',
                               'reserved instruction image holes fault or fail the independent PC oracle'],
               'limits': ['finite seeded simulations, not all-input proof or ACT4/Sail conformance',
                          'no firmware compiler, FPGA timing, programming, acquisition or debug qualification']}
    (attempt / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    # only a complete passing attempt updates the primary qualification record.
    if not args.smoke:
        shutil.copyfile(attempt / 'summary.json', evidence / 'summary.json')
        shutil.copytree(attempt / 'sources', evidence / 'sources', dirs_exist_ok=True)
        # final evidence excludes generated compiler objects and executable products.
        for log in logs:
            target = evidence / 'logs' / log.relative_to(build)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(log, target)
    print('PASS fence execution qualification: ' + str(attempt / 'summary.json'), flush=True)


# importing the runner cannot launch builds or modify archived evidence.
if __name__ == '__main__':
    main()

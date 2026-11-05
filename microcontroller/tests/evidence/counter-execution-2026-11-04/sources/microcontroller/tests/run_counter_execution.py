#!/usr/bin/env python3
"""qualify real fetch/control execution with independent machine counter clock and architectural execution records."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
from replay_counter_trace import decode, make_schema, replay


# every invocation retains exact source and diagnostics before running tools.
def main():
    """run strict elaborations, reproducible schedules and calibrated negative controls."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-counter-execution'))
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    evidence = (args.evidence_dir or root / 'microcontroller/tests/evidence/counter-execution-2026-11-04').resolve()
    build.mkdir(parents=True, exist_ok=True)
    revisions = evidence / 'revisions'
    revisions.mkdir(parents=True, exist_ok=True)
    revision = max([int(p.name.split('-')[0]) for p in revisions.iterdir() if p.is_dir()] + [0]) + 1
    attempt = revisions / f'{revision:02d}-qualification'
    attempt.mkdir()
    names = ['drg5_control_pkg'] + [p.stem for p in sorted((root / 'microcontroller/rtl').glob('*.sv')) if p.stem != 'drg5_control_pkg']
    sources = ['microcontroller/rtl/' + name + '.sv' for name in names]
    sources.append('microcontroller/tests/drg5_counter_execution_tb.sv')
    attributed = sources + ['microcontroller/rtl/drg5_datapath_defs.svh',
                            'microcontroller/tests/run_counter_execution.py', 'microcontroller/tests/replay_counter_trace.py', 'microcontroller/tests/Makefile']
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in attributed}
    # failure evidence remains bound to the exact pre-build source.
    for name in attributed:
        target = attempt / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    (attempt / 'source-sha256.json').write_text(json.dumps(before, indent=2) + '\n')
    profiles = [(1, 0, 1)] if args.smoke else [(1, 0, 1), (1, 0, 0), (1, 1, 1), (0, 0, 1)]
    seeds = [1] if args.smoke else [0, 1, 305419896]
    results = []
    logs = []
    schema = make_schema(root / 'microcontroller/rtl/drg5_control_pkg.sv')
    (attempt / 'schema.json').write_text(json.dumps(schema, indent=2) + '\n')
    first_trace = None
    # each separately elaborated configuration has its own real production frontend.
    for c_enabled, diagnostic, forwarding in profiles:
        profile = f'c{c_enabled}-d{diagnostic}-f{forwarding}'
        directory = build / profile
        directory.mkdir(exist_ok=True)
        command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2',
                   '-CFLAGS', '-O0', '-Imicrocontroller/rtl', '--top-module', 'drg5_counter_execution_tb',
                   f'-GC_ENABLED={c_enabled}',
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
            raise RuntimeError(f'counter build failed: {log}')
        # fixed xorshift seeds vary stage holds and independent bus latencies.
        for seed in seeds:
            trace_path = directory / f'seed-{seed}.trace.jsonl'
            command = [str(directory / 'Vdrg5_counter_execution_tb'), '+verilator+seed+1', f'+seed={seed}', f'+trace_file={trace_path}']
            result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=180, check=False)
            log = directory / f'seed-{seed}.log'
            log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
            logs.append(log); shutil.copyfile(log, attempt / f'{profile}-seed-{seed}.log')
            # even incomplete failing captures remain available beside their source and log.
            if trace_path.exists():
                trace_copy = attempt / f'{profile}-seed-{seed}.trace.jsonl.gz'
                trace_copy.write_bytes(gzip.compress(trace_path.read_bytes(), mtime=0))
            marker = f'COUNTER_EXEC_PASS C={c_enabled} diagnostic={diagnostic} forwarding={forwarding} seed={seed} '
            # a zero exit without the exact final coverage marker cannot qualify.
            if result.returncode or result.stdout.count(marker) != 1:
                raise RuntimeError(f'counter simulation failed: {log}')
            terminal = next(line for line in result.stdout.splitlines() if line.startswith(marker))
            replay_result = replay(trace_path, schema)
            # retain the first complete capture for independent loss and corruption calibration.
            if first_trace is None:
                first_trace = trace_path
            results.append({'profile': profile, 'seed': seed, 'command': command, 'exit_code': result.returncode,
                            'terminal': terminal, 'trace': str(trace_copy.name),
                            'trace_archive_sha256': hashlib.sha256(trace_copy.read_bytes()).hexdigest(), 'replay': replay_result})
            print(terminal, flush=True)
        # completed generated compiler products can be removed after their logs and traces are archived.
        for cache in directory.rglob('*'):
            # retain executable binaries, exact commands and raw captures for detector checks.
            if cache.is_file() and cache.suffix in {'.o', '.a', '.cpp', '.h', '.d', '.gch'}:
                cache.unlink()
    # occupancy modes build identical instruction streams; counter-read values may legitimately differ.
    if not args.smoke:
        # compare program construction only, never timing-dependent counter read values.
        for seed in seeds:
            peers = [item for item in results if item['seed'] == seed and item['profile'] in
                     {'c1-d0-f1', 'c1-d0-f0', 'c1-d1-f1'}]
            digests = [re.search(r'program_digest=([0-9a-f]+)', item['terminal']).group(1) for item in peers]
            # differing construction would invalidate the occupancy comparison.
            if len(peers) != 3 or len(set(digests)) != 1:
                raise RuntimeError(f'counter program construction differs for seed {seed}: {digests}')
    detectors = [('mutate_cycle', 'cycle counter agrees with independent clock ledger'),
                 ('mutate_compressed', 'retired counter agrees with independent execution ledger'),
                 ('mutate_trap', 'retired counter agrees with independent execution ledger')]
    # the smoke attempt establishes functionality before final detector qualification.
    if not args.smoke:
        # corrupt observations or physical effects only; reference expectations remain unchanged.
        for mutation, label in detectors:
            command = [str(build / 'c1-d0-f1/Vdrg5_counter_execution_tb'), '+verilator+seed+1',
                       '+seed=1', '+' + mutation]
            result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=180, check=False)
            log = build / (mutation + '.log')
            log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
            logs.append(log); shutil.copyfile(log, attempt / log.name)
            marker = 'COUNTER_EXEC_CHECK_FAILED ' + label
            # an unrelated assertion, timeout or successful terminal does not calibrate the detector.
            if result.returncode == 0 or marker not in result.stdout or 'COUNTER_EXEC_PASS ' in result.stdout:
                raise RuntimeError(f'counter detector failed: {log}')
            results.append({'negative_control': mutation, 'command': command, 'exit_code': result.returncode,
                            'detector': marker})
    # offline corruption must be rejected independently of the simulator's own assertions.
    if not args.smoke:
        original_lines = first_trace.read_text().splitlines()
        mutations = [('missing_record', 'edge discontinuity'), ('missing_footer', 'missing terminal footer'),
                     ('overflow_record', 'observation overflow'), ('counter_record', 'counter update replay'),
                     ('csr_return_record', 'counter CSR returned old value')]
        # every mutated stream retains all other original records and metadata.
        for mutation, reason in mutations:
            lines = original_lines.copy()
            # remove a complete middle record without changing footer expectations.
            if mutation == 'missing_record':
                del lines[3]
            # remove the footer at a valid line boundary to test silent truncation.
            elif mutation == 'missing_footer':
                lines.pop()
            # corrupt an actual counter CSR destination without changing its independent CSR old field.
            elif mutation == 'csr_return_record':
                # the first eligible terminal keeps unrelated architectural state out of the detector path.
                for index, line in enumerate(lines[1:-1], 1):
                    row = json.loads(line); rec = decode(row, schema)
                    # encoded destination and address identify a completed nonzero counter read.
                    if (rec['terminal.valid'] and not rec['terminal.trap'] and rec['terminal.rd_write'] and
                        rec['terminal.csr_read'] and rec['terminal.packet.csr_addr'] in {0xb00, 0xb80, 0xb02, 0xb82, 0x320}):
                        field = schema['fields']['terminal.value']
                        row['packed'] = format(int(row['packed'], 16) ^ (1 << field['lsb']), 'x')
                        lines[index] = json.dumps(row, separators=(',', ':'))
                        break
                # a missing target is a fixture error, never a passing negative control.
                else:
                    raise RuntimeError('counter CSR return mutation found no eligible terminal')
            # mutate one packed field while preserving valid JSON syntax.
            else:
                row = json.loads(lines[2])
                field = schema['fields']['overflow' if mutation == 'overflow_record' else 'cycle_after']
                row['packed'] = format(int(row['packed'], 16) ^ (1 << field['lsb']), 'x')
                # readable metadata must agree so the counter model itself rejects this corruption.
                if mutation == 'counter_record':
                    row['cycle_after'] = f"{int(row['cycle_after'], 16) ^ 1:016x}"
                lines[2] = json.dumps(row, separators=(',', ':'))
            path = attempt / (mutation + '.trace.jsonl.gz')
            path.write_bytes(gzip.compress(('\n'.join(lines) + '\n').encode(), mtime=0))
            observed = None
            # exactly the intended replay error must identify the corrupted stream.
            try:
                replay(path, schema)
            # a named replay failure is expected only for the injected corruption.
            except ValueError as error:
                observed = str(error)
            # success or an unrelated error cannot calibrate the intended detector.
            if observed != 'TRACE_REPLAY_FAILED ' + reason:
                raise RuntimeError(f'counter replay detector failed: {mutation}: {observed}')
            results.append({'negative_replay': mutation, 'trace': path.name, 'detector': observed})
    # any concurrent edit invalidates attribution instead of silently blessing final bytes.
    after = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in attributed}
    # fail explicitly when an input changed during tool execution.
    if before != after:
        raise RuntimeError('counter execution source changed during qualification')
    summary = {'status': 'passed', 'scope': 'real frontend and packet controller; finite counter and execution simulation',
               'profiles': profiles, 'seeds': seeds, 'smoke': args.smoke, 'results': results,
               'trace_directory': str(attempt.relative_to(evidence)),
               'source_sha256': after, 'verilator': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
               'assumptions': ['I snapshots captured at acceptance; independent acceptance and response delays',
                               'I and D stress deadlines128clocks; no production latency claim',
                               'one outstanding transaction per port; no response reordering or unsafe reset',
                               'fixed instruction corpus; service xorshift varies stalls without changing program images',
                               'reserved instruction image holes fault or fail the independent PC oracle'],
               'limits': ['finite seeded simulations, not all-input proof or ACT4/Sail conformance',
                          'no firmware compiler, FPGA timing, programming, acquisition or integrated debug qualification']}
    (attempt / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    # only a complete passing attempt updates the primary qualification record.
    if not args.smoke:
        shutil.copyfile(attempt / 'summary.json', evidence / 'summary.json')
        shutil.copytree(attempt / 'sources', evidence / 'sources', dirs_exist_ok=True)
        shutil.copyfile(attempt / 'schema.json', evidence / 'schema.json')
        # final evidence excludes generated compiler objects and executable products.
        for log in logs:
            target = evidence / 'logs' / log.relative_to(build)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(log, target)
    print('PASS counter execution qualification: ' + str(attempt / 'summary.json'), flush=True)


# importing the runner cannot launch builds or modify archived evidence.
if __name__ == '__main__':
    main()

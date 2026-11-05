#!/usr/bin/env python3
"""retain scoped production-controller proofs, witnesses and deliberate RTL failures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def digest(path):
    """identify the exact bytes used by every formal job."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """never replace an earlier evidence directory or silently accept a timeout."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=False)
    snapshot = build / 'sources'
    snapshot.mkdir()
    names = ['drg5_control_pkg', 'drg5_control', 'drg5_csr', 'drg5_decoder',
             'drg5_decompress', 'drg5_immediate', 'drg5_branch', 'drg5_lsu',
             'drg5_shifter', 'drg5_alu', 'drg5_forward', 'drg5_muldiv']
    originals = [root / 'microcontroller' / 'rtl' / (name + '.sv') for name in names]
    originals += sorted((root / 'microcontroller' / 'rtl').glob('*.svh'))
    originals += [here / 'drg5_pipeline_formal.sv', Path(__file__).resolve()]
    # archive original RTL before applying the narrow frontend adapter.
    for path in originals:
        shutil.copyfile(path, snapshot / path.name)
    original = (snapshot / 'drg5_control.sv').read_text()
    start = original.index('  /* a stalled offer survives hart reset')
    end = original.index('\nendmodule', start)
    removed = original[start:end]
    assert removed.count('assert property') == 1 and original.count('assert property') == 1
    adapted = original[:start] + '  /* the harness checks the unsupported concurrent assertion equivalently. */\n' + original[end:]
    (snapshot / 'unsupported-sva.txt').write_text(removed)
    (snapshot / 'drg5_control_formal.sv').write_text(adapted)
    environment = os.environ.copy()
    environment['PATH'] = str(args.tools.resolve() / 'bin') + os.pathsep + environment['PATH']
    tools = {}
    # record the actual formal runner and solver identities.
    for name, option in [('yosys', '-V'), ('sby', '--version'), ('yices-smt2', '--version')]:
        command = [str(args.tools.resolve() / 'bin' / name), option]
        result = subprocess.run(command, capture_output=True, text=True, env=environment, check=False)
        tools[name] = {'command': command, 'version': result.stdout.strip(), 'stderr': result.stderr.strip()}
    jobs = [('overlap_safety', 'bmc', 16, False, None),
            ('overlap_cover', 'cover', 20, False, None),
            ('single_progress', 'bmc', 40, True, None),
            ('single_progress_cover', 'cover', 40, True, None),
            ('negative_uid', 'bmc', 12, False, 'uid'),
            ('negative_offer', 'bmc', 14, False, 'offer'),
            ('negative_killed_write', 'bmc', 16, False, 'killed_write'),
            ('negative_progress', 'bmc', 40, True, 'progress')]
    summary = {'tools': tools, 'results': {}, 'source_hashes': {str(p): digest(p) for p in originals},
               'adapter': 'remove only unsupported concurrent SVA; equivalent harness assertion and all immediate production assertions retained',
               'snapshot_hashes': {p.name: digest(p) for p in snapshot.iterdir()},
               'scope': 'bounded checks only; overlapping trusted-packet controller safety and isolated finite-service progress; no full ISA or unbounded liveness proof'}
    # execute each proof against immutable snapshots and retain every status and counterexample.
    for name, mode, depth, progress, mutation in jobs:
        core = adapted
        # each negative control changes real RTL and must fail a production or independent assertion.
        if mutation == 'uid':
            core = core.replace('trace_o.uid <= slot_q[W].uid;', "trace_o.uid <= slot_q[W].uid + 1'b1;")
        # corrupt a descriptor with source data unrelated to its retained owner.
        elif mutation == 'offer':
            core = core.replace('assign d_req_addr_o = owner_q.p.mem_addr;', 'assign d_req_addr_o = owner_q.p.mem_addr ^ in_packet_i.result;')
        # make a discarded instruction visibly change the register file.
        elif mutation == 'killed_write':
            core = core.replace('    valid_q <= valid_d;', "    /* deliberately corrupt architectural state on discard. */\n    if (|kill) begin regs_q[1] <= 32'hbad; defined_q[1] <= 1; end\n    valid_q <= valid_d;")
        # preserve ownership while preventing terminal progress.
        elif mutation == 'progress':
            core = core.replace('assign w_done = w_eligible && !debug_ebreak_candidate;', "assign w_done = w_eligible && !debug_ebreak_candidate && 1'b0;")
        # an unchanged mutation would provide no meaningful detector evidence.
        if mutation:
            assert core != adapted
        core_path = build / (name + '_control.sv')
        core_path.write_text(core)
        sources = [snapshot / (n + '.sv') for n in names if n != 'drg5_control']
        sources += [core_path, snapshot / 'drg5_pipeline_formal.sv']
        parameters = '-G PROGRESS=1 -G SINGLE=1 ' if progress else ''
        engine = 'smtbmc --nopresat yices' if progress else 'smtbmc yices'
        timeout = 600 if progress else 150
        config = build / (name + '.sby')
        config.write_text(f'[options]\nmode {mode}\ndepth {depth}\ntimeout {timeout}\n\n[engines]\n{engine}\n\n[script]\nplugin -i slang\n' +
                          'read_slang --top drg5_pipeline_formal ' + parameters + '-I ' + str(snapshot) + ' ' + ' '.join(map(str, sources)) +
                          '\nprep -top drg5_pipeline_formal -flatten\nasync2sync\nchformal -lower\n\n')
        command = [str(args.tools.resolve() / 'bin' / 'sby'), '-d', str(build / name), str(config)]
        started = time.monotonic()
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, env=environment, check=False)
        (build / (name + '.log')).write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
        status_path = build / name / 'status'
        status = status_path.read_text().split()[0] if status_path.exists() else 'NO_STATUS'
        expected = 'FAIL' if mutation else 'PASS'
        correct = status == expected and (result.returncode != 0 if mutation else result.returncode == 0)
        failures = [line for line in result.stdout.splitlines() if 'Assert failed' in line]
        model_path = build / name / 'model/design.il'
        model = model_path.read_text() if model_path.exists() else ''
        formal_cells = {kind: len(re.findall(r'cell \$' + kind + r'\b', model)) for kind in ['assert', 'assume', 'cover']}
        correct = correct and formal_cells['assert'] > 0 and formal_cells['assume'] > 0 and formal_cells['cover'] > 0
        # compile errors and unrelated infrastructure failures are never detector evidence.
        if mutation:
            correct = correct and bool(failures)
        summary['results'][name] = {'mode': mode, 'depth': depth, 'progress_profile': progress,
                                    'mutation': mutation, 'status': status, 'expected': expected, 'timeout_seconds': timeout,
                                    'expected_outcome_seen': correct, 'exit_code': result.returncode,
                                    'assertion_failures': failures,
                                    'formal_cells_before_engine_lowering': formal_cells,
                                    'seconds': round(time.monotonic() - started, 3),
                                    'command': command, 'core_sha256': digest(core_path)}
        (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
        print(name, status, 'EXPECTED' if correct else 'UNEXPECTED', flush=True)
    # one failing or timed-out positive prevents a qualification success result.
    if not all(item['expected_outcome_seen'] for item in summary['results'].values()):
        raise SystemExit(1)


# importing the runner never starts external formal tools.
if __name__ == '__main__':
    main()

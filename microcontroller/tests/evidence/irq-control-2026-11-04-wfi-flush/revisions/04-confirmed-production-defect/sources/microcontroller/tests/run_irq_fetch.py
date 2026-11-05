#!/usr/bin/env python3
"""qualify actual fetch ownership, interrupt entry and handler decode under bounded service."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


def execute(command, log, root):
    """retain complete commands and diagnostics for both passing and detector runs."""
    result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=300, check=False)
    log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
    return result


def main():
    """bind the bounded-I4 and separate 32-cycle stress profiles to exact source snapshots."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-irq-fetch-tests'))
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    names = ['drg5_control_pkg', 'drg5_immediate', 'drg5_decoder', 'drg5_branch',
             'drg5_lsu', 'drg5_shifter', 'drg5_alu', 'drg5_forward', 'drg5_fetch_guard',
             'drg5_fetch_buffer', 'drg5_fetch', 'drg5_csr', 'drg5_control']
    sources = ['microcontroller/rtl/' + name + '.sv' for name in names]
    sources.append('microcontroller/tests/drg5_irq_fetch_tb.sv')
    attributed = sources + ['microcontroller/rtl/drg5_datapath_defs.svh',
                            'microcontroller/tests/run_irq_fetch.py']
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in attributed}
    results = {}
    # each separately elaborated manager has its actual deadline parameter, not a mocked busy signal.
    for limit in [4, 32]:
        obj = build / f'obj-{limit}'
        command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2',
                   '-CFLAGS', '-O0', '-Imicrocontroller/rtl', '--top-module', 'drg5_irq_fetch_tb',
                   f'-GI_LIMIT={limit}', '--Mdir', str(obj), *sources]
        result = execute(command, build / f'build-{limit}.log', root)
        # no lint warning is waived for the bridge or participating production modules.
        if result.returncode or '%Warning' in result.stdout:
            raise RuntimeError(f'IRQ fetch build failed: {build / f"build-{limit}.log"}')
        result = execute([str(obj / 'Vdrg5_irq_fetch_tb'), '+verilator+seed+1'],
                         build / f'positive-{limit}.log', root)
        terminal = f'IRQ_FETCH_PASS limit={limit} cases=2 '
        # a zero exit without both conserved ownership scenarios does not qualify.
        if result.returncode or terminal not in result.stdout:
            raise RuntimeError(f'IRQ fetch simulation failed: {build / f"positive-{limit}.log"}')
        line = next(line for line in result.stdout.splitlines() if line.startswith(terminal))
        results[f'I{limit}'] = {'exit': result.returncode, 'terminal': line}
        print(line, flush=True)
    result = execute([str(build / 'obj-4/Vdrg5_irq_fetch_tb'), '+verilator+seed+1', '+mutate_epc'],
                     build / 'detector-epc.log', root)
    terminal = 'IRQ_FETCH_CHECK_FAILED precise IRQ boundary and trap state'
    # a deliberate observation corruption must fail its exact ordinary boundary comparator.
    if result.returncode == 0 or terminal not in result.stdout or 'IRQ_FETCH_PASS ' in result.stdout:
        raise RuntimeError('IRQ fetch boundary detector failed')
    results['detector'] = {'exit': result.returncode,
                           'terminal': next(line for line in result.stdout.splitlines() if terminal in line)}
    after = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in attributed}
    # source changes during execution invalidate the run instead of silently changing attribution.
    if before != after:
        raise RuntimeError('IRQ fetch sources changed during execution')
    # preserve the full transitive RTL and fixture source set, including the runner.
    for name in attributed:
        target = build / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    summary = {'scope': 'non-C verification fetch/control bridge; no production frontend qualification',
               'results': results, 'source_sha256': after,
               'version': subprocess.check_output([args.verilator, '--version'], text=True).strip(),
               'assumptions': ['I4 profile: each instruction transaction completes within four exposed edges',
                               'I32 profile: independent acceptance/response stress; not an F80 timing claim',
                               'synchronous instruction RAM; data-store response one edge after acceptance',
                               'retained external interrupt level; CPU and platform clock continue',
                               'raw instruction bytes enter the real machine decoder through a verification bridge'],
               'limits': ['no formal proof, physical FPGA timing, division or debug implementation',
                          'handler-D is the first handler instruction entering decode, not a full register-save sequence']}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    # preserve this re-audit separately from the original sealed IRQ qualification.
    evidence = (args.evidence_dir.resolve() if args.evidence_dir else
                root / 'microcontroller/tests/evidence/irq-fetch-2026-11-04-reaudit')
    evidence.mkdir(parents=True, exist_ok=True)
    for log in build.glob('*.log'):
        shutil.copyfile(log, evidence / log.name)
    shutil.copyfile(build / 'summary.json', evidence / 'summary.json')
    shutil.copytree(build / 'sources', evidence / 'sources', dirs_exist_ok=True)
    print('IRQ_FETCH_QUALIFICATION_PASS profiles=2 scenarios=9 detectors=1')


# importing the runner does not launch tools or write evidence.
if __name__ == '__main__':
    main()

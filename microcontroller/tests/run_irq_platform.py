#!/usr/bin/env python3
"""qualify persistent platform sources and accepted MMIO commands independently of CPU control."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


def digest(path):
    """identify the exact source or tool bytes used by this run."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, log, root):
    """retain exact arguments and complete output, including intended detector failures."""
    result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=300, check=False)
    log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
    return result


def main():
    """bind three seeds, seven detector checks and optional structural synthesis to one source set."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--yosys')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-irq-platform-tests'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    sources = ['microcontroller/rtl/drg5_irq_platform.sv',
               'microcontroller/tests/drg5_irq_platform_tb.sv',
               'microcontroller/tests/run_irq_platform.py']
    before = {name: digest(root / name) for name in sources}
    results = {}
    versions = {}
    tools = {}
    # record executable identity and version without assuming a particular installation layout.
    for name, executable in [('verilator', args.verilator), ('yosys', args.yosys)]:
        # synthesis is an explicit optional check, never inferred from a simulation pass.
        if executable is None:
            continue
        resolved = Path(shutil.which(executable) or executable).resolve()
        version = execute([str(resolved), '--version' if name == 'verilator' else '-V'],
                          build / (name + '-version.log'), root)
        # an inaccessible or unidentifiable tool cannot support qualification.
        if version.returncode:
            raise RuntimeError(f'cannot identify {name}')
        versions[name] = version.stdout.strip()
        tools[name] = {'path': str(resolved), 'sha256': digest(resolved)}
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2',
               '-CFLAGS', '-O0', '--top-module', 'drg5_irq_platform_tb',
               '--Mdir', str(build / 'obj'), *sources[:2]]
    result = execute(command, build / 'build.log', root)
    # the executable qualification waives no HDL warning.
    if result.returncode or '%Warning' in result.stdout:
        raise RuntimeError(f'IRQ platform build failed: {build / "build.log"}')
    # each seed repeats boundary cases and independently generated random input vectors.
    for seed in [0, 1, 305419896]:
        name = f'seed-{seed}'
        result = execute([str(build / 'obj/Vdrg5_irq_platform_tb'), '+verilator+seed+1', f'+seed={seed}'],
                         build / (name + '.log'), root)
        terminal = f'PASS irq-platform seed={seed} '
        # a clean exit without the coverage-guarded terminal is insufficient.
        if result.returncode or terminal not in result.stdout:
            raise RuntimeError(f'IRQ platform simulation failed: {name}')
        line = next(line for line in result.stdout.splitlines() if line.startswith(terminal))
        results[name] = {'exit': result.returncode, 'terminal': line}
        print(line, flush=True)
    cases = {'error': 'MMIO permission mismatch', 'read': 'MMIO read snapshot mismatch',
             'timer': 'timer edge mismatch', 'pending': 'external pending mismatch',
             'count': 'notification count mismatch', 'irq': 'interrupt level mismatch',
             'overflow': 'overflow containment mismatch'}
    # each single corrupted observation must fail its corresponding ordinary comparator.
    for mutation, terminal in cases.items():
        name = f'detector-{mutation}'
        result = execute([str(build / 'obj/Vdrg5_irq_platform_tb'), '+verilator+seed+1',
                          '+seed=1', f'+mutate_{mutation}'], build / (name + '.log'), root)
        # unrelated crashes and accidentally passing mutations invalidate detector evidence.
        if result.returncode == 0 or terminal not in result.stdout or 'PASS irq-platform ' in result.stdout:
            raise RuntimeError(f'IRQ platform detector failed: {name}')
        line = next(line for line in result.stdout.splitlines() if terminal in line)
        results[name] = {'exit': result.returncode, 'terminal': line}
        print(name + ': expected comparator failure', flush=True)
    # structural synthesis establishes supported constructs, never device timing or formal equivalence.
    if args.yosys:
        script = (f'read_verilog -sv -D SYNTHESIS {sources[0]}; hierarchy -check -top drg5_irq_platform; '
                  'proc; check -assert; select -assert-none t:$dlatch t:$adlatch; '
                  'synth -top drg5_irq_platform; check -assert; '
                  'select -assert-none t:$dlatch t:$adlatch; stat')
        result = execute([args.yosys, '-Q', '-T', '-p', script], build / 'structure.log', root)
        # no warning waiver is permitted in this generic structural check.
        if result.returncode or 'Warning:' in result.stdout:
            raise RuntimeError('IRQ platform structural synthesis failed')
        results['structure'] = {'exit': result.returncode, 'scope': 'generic synthesis; default capacity 64; no latches'}
    after = {name: digest(root / name) for name in sources}
    # a concurrent edit invalidates attribution even if every simulation happened to pass.
    if before != after:
        raise RuntimeError('IRQ platform qualification sources changed during execution')
    # retain the exact source set beside logs for reproducible review.
    for name in sources:
        target = build / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    summary = {'scope': 'accepted MMIO pulse, timer and retained source platform only',
               'profiles': {'capacities': [1, 4, 64], 'seeds': [0, 1, 305419896],
                            'random_vectors_per_seed': 12000},
               'results': results, 'source_sha256': after, 'versions': versions, 'tools': tools,
               'limits': ['two-state simulation; no formal proof',
                          'caller supplies synchronous events and one pulse per accepted physical transaction',
                          'no CPU, CDC, acquisition descriptor memory, DMA or bus-response bridge is implemented here',
                          'overflow explicitly reports an unretained notification and requires hardware stop',
                          'generic synthesis, when requested, establishes no FPGA timing or physical qualification']}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('IRQ_PLATFORM_QUALIFICATION_PASS seeds=3 capacities=3 detectors=7 structure=' + str(bool(args.yosys)).lower())


# importing the runner has no tool or evidence side effects.
if __name__ == '__main__':
    main()

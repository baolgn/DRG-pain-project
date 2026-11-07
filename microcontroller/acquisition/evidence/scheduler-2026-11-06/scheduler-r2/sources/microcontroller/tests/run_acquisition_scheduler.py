#!/usr/bin/env python3
"""exercise fixed-grid scheduling and retained stop decisions."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess


# identify source and tool bytes without importing project implementations.
def digest(path):
    """return the SHA-256 of an existing file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# each subprocess has its own wall-clock deadline and complete retained output.
def execute(command, log, cwd, timeout=300):
    """capture a bounded tool invocation, including expected detector failures."""
    # preserve partial diagnostics if the subprocess exceeds its deadline.
    try:
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
    # timed-out builds remain reviewable even though no success summary is produced.
    except subprocess.TimeoutExpired as error:
        partial = error.stdout or ''
        # subprocess may retain bytes despite text mode when interrupted.
        if isinstance(partial, bytes):
            partial = partial.decode(errors='replace')
        log.write_text('$ ' + shlex.join(command) + '\n' + partial + '\nTIMEOUT\n')
        raise
    log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
    return result


# fresh output directories prevent an earlier result from being mistaken for this run.
def main():
    """compile independent checks and retain source-bound simulation evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--iverilog', default='iverilog')
    parser.add_argument('--vvp', default='vvp')
    parser.add_argument('--yosys', default='yosys')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sources = ['microcontroller/rtl/drg5_acquisition_scheduler.sv',
               'microcontroller/tests/drg5_acquisition_scheduler_tb.sv',
               'microcontroller/tests/run_acquisition_scheduler.py',
               'microcontroller/acquisition/slot-scheduler.md',
               'microcontroller/rtl/drg5_acquisition_timebase.sv']
    before = {name: digest(root / name) for name in sources}
    # failed revisions retain their exact pre-build inputs, not later edited working files.
    for name in sources:
        target = output / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    tools = {}
    results = {}
    # resolve exact executable identities before compiling any design.
    for name in ['verilator', 'iverilog', 'vvp', 'yosys']:
        executable = Path(shutil.which(getattr(args, name)) or getattr(args, name)).resolve()
        version = execute([str(executable), '--version' if name == 'verilator' else '-V'],
                          output / (name + '-version.log'), root)
        # failed version commands invalidate claims about the tool used.
        if version.returncode:
            raise RuntimeError('cannot identify ' + name)
        tools[name] = {'path': str(executable), 'sha256': digest(executable),
                       'version': version.stdout.strip()}
    rtl, bench = [str(root / name) for name in sources[:2]]
    timebase = str(root / sources[4])
    timescale = output / 'timescale.sv'
    timescale.write_text('`timescale 1ns/1ps\n')
    build = execute([args.verilator, '--binary', '--timing', '--assert', '--trace', '--timescale-override', '1ns/1ps', '-Wall',
                     '-j', '2', '-CFLAGS', '-O0', '--top-module', 'drg5_acquisition_scheduler_tb',
                     '--Mdir', str(output / 'obj'), timebase, rtl, bench], output / 'build.log', root)
    # Verilator lint warnings are failures rather than globally suppressed diagnostics.
    if build.returncode or '%Warning' in build.stdout:
        raise RuntimeError('scheduler build failed: ' + str(output / 'build.log'))
    seeds = [1, 305419896, 3735928559]
    # every seed repeats directed boundaries and adds deterministic randomized stress.
    for seed in seeds:
        name = f'verilator-seed-{seed}'
        result = execute([str(output / 'obj/Vdrg5_acquisition_scheduler_tb'),
                          '+verilator+seed+1', f'+seed={seed}', f'+wave={name}.vcd'],
                         output / (name + '.log'), output)
        match = re.search(r'^PASS acquisition-scheduler seed=\d+ checks=\d+ cases=\d+ random=\d+$',
                          result.stdout, re.MULTILINE)
        # success requires the coverage-guarded terminal as well as a clean exit.
        if result.returncode or not match:
            raise RuntimeError('scheduler simulation failed: ' + name)
        wave = output / (name + '.vcd')
        # a header-only or missing waveform does not establish signal capture.
        if not wave.is_file() or wave.stat().st_size < 1000:
            raise RuntimeError('missing waveform: ' + name)
        results[name] = {'exit': result.returncode, 'terminal': match.group(),
                         'wave_sha256': digest(wave), 'wave_bytes': wave.stat().st_size}
        print(match.group(), flush=True)
    detectors = {'grid': 'grid comparator', 'pulse': 'pulse comparator',
                 'decision': 'decision comparator', 'terminal': 'terminal comparator'}
    # corrupt one sampled observation; ordinary comparators must reject the corruption.
    for mutation, label in detectors.items():
        name = 'detector-' + mutation
        result = execute([str(output / 'obj/Vdrg5_acquisition_scheduler_tb'),
                          '+verilator+seed+1', '+seed=1', '+mutate_' + mutation],
                         output / (name + '.log'), output)
        # a crash elsewhere or a terminal pass is not a successful detector control.
        if result.returncode == 0 or label not in result.stdout or 'PASS acquisition-scheduler' in result.stdout:
            raise RuntimeError('scheduler detector failed: ' + name)
        results[name] = {'exit': result.returncode, 'expected_comparator': label}
        print(name + ': expected comparator failure', flush=True)
    four = execute([args.iverilog, '-g2012', '-D', 'SYNTHESIS', '-s', 'drg5_acquisition_scheduler_tb',
                    '-o', str(output / 'four-state.vvp'), str(timescale), timebase, rtl, bench],
                   output / 'four-state-build.log', root)
    # SYNTHESIS selects hardware logic; procedural test checks remain active.
    if four.returncode:
        raise RuntimeError('four-state build failed')
    run = execute([args.vvp, str(output / 'four-state.vvp'), '+seed=1', '+wave=four-state.vcd'],
                  output / 'four-state.log', output)
    match = re.search(r'^PASS acquisition-scheduler seed=\d+ checks=\d+ cases=\d+ random=\d+$',
                      run.stdout, re.MULTILINE)
    # four-state comparisons reject X/Z in every sampled result checked by the bench.
    if run.returncode or not match:
        raise RuntimeError('four-state simulation failed')
    wave = output / 'four-state.vcd'
    # four-state traces receive the same identity binding as Verilator traces.
    if not wave.is_file() or wave.stat().st_size < 1000:
        raise RuntimeError('missing four-state waveform')
    results['four-state'] = {'exit': run.returncode, 'terminal': match.group(),
                             'wave_sha256': digest(wave), 'wave_bytes': wave.stat().st_size}
    unknown = execute([args.vvp, str(output / 'four-state.vvp'), '+seed=1', '+mutate_unknown'],
                      output / 'detector-unknown.log', output)
    # injecting X into a sampled decision must fail its existing four-state comparator.
    if unknown.returncode == 0 or 'decision comparator' not in unknown.stdout:
        raise RuntimeError('unknown-value detector failed')
    results['detector-unknown'] = {'exit': unknown.returncode, 'expected_comparator': 'decision comparator'}
    small = execute([args.iverilog, '-g2012', '-D', 'SYNTHESIS',
                     '-Pdrg5_acquisition_scheduler_tb.TEST_COUNTER_LIMIT=7',
                     '-s', 'drg5_acquisition_scheduler_tb', '-o', str(output / 'small.vvp'), str(timescale), timebase, rtl, bench],
                    output / 'small-build.log', root)
    # a reduced elaborated limit reaches saturation through ordinary scheduled slots.
    if small.returncode:
        raise RuntimeError('small-counter build failed')
    small_run = execute([args.vvp, str(output / 'small.vvp'), '+small', '+seed=1'],
                        output / 'small.log', output)
    small_match = re.search(r'^PASS acquisition-scheduler-small checks=\d+ cases=\d+$',
                            small_run.stdout, re.MULTILINE)
    # internal force/deposit operations are not needed to reach the reduced limit.
    if small_run.returncode or not small_match:
        raise RuntimeError('small-counter simulation failed')
    results['small-counter'] = {'exit': small_run.returncode, 'terminal': small_match.group(), 'limit': 7}
    script = (f'read_verilog -sv -D SYNTHESIS {timebase} {rtl}; hierarchy -check -top drg5_acquisition_scheduler; '
              'proc; check -assert; select -assert-none t:$dlatch t:$adlatch; '
              'synth -top drg5_acquisition_scheduler; check -assert; '
              'select -assert-none t:$dlatch t:$adlatch; stat')
    structure = execute([args.yosys, '-Q', '-T', '-p', script], output / 'structure.log', root, timeout=600)
    # generic structure excludes inferred latches; it proves no target timing or CDC property.
    if structure.returncode:
        raise RuntimeError('scheduler structural synthesis failed')
    warnings = [line for line in structure.stdout.splitlines() if line.startswith('Warning:')]
    # register-array flattening is expected; all other structural warnings fail the run.
    unexpected = [line for line in warnings if not re.fullmatch(
        r'Warning: Replacing memory \\?[A-Za-z0-9_]+ with list of registers\..*', line)]
    # unresolved or surprising warnings need review before this result is publishable.
    if unexpected:
        raise RuntimeError('unexpected synthesis warnings: ' + repr(unexpected))
    results['structure'] = {'exit': structure.returncode, 'reviewed_warnings': warnings,
                            'scope': 'default-parameter generic scheduler synthesis and no inferred latches'}
    helper_script = (f'read_verilog -sv -D SYNTHESIS {timebase}; '
                     'hierarchy -check -top drg5_acquisition_timebase; proc; check -assert; '
                     'select -assert-none t:$dlatch t:$adlatch; '
                     'synth -top drg5_acquisition_timebase; check -assert; '
                     'select -assert-none t:$dlatch t:$adlatch; stat')
    helper_structure = execute([args.yosys, '-Q', '-T', '-p', helper_script],
                               output / 'timebase-structure.log', root)
    helper_warnings = [line for line in helper_structure.stdout.splitlines() if 'Warning:' in line]
    expected_abc = 'ABC: Warning: The network is combinational (run "fraig" or "fraig_sweep").'
    # ABC sees the counter's combinational next-state cone after flip-flop extraction.
    if helper_structure.returncode or any(line != expected_abc for line in helper_warnings):
        raise RuntimeError('timebase structural synthesis failed')
    results['timebase-structure'] = {'exit': helper_structure.returncode,
                                    'reviewed_warnings': helper_warnings,
                                    'scope': 'default zero-origin timebase synthesis and no inferred latches'}
    after = {name: digest(root / name) for name in sources}
    # concurrent edits invalidate attribution to the compiled source set.
    if after != before:
        raise RuntimeError('scheduler sources changed during verification')
    summary = {'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'scope': 'single-clock acquisition timebase and slot scheduler RTL',
               'seeds': seeds, 'results': results, 'tools': tools, 'source_sha256': after,
               'limits': ['capture idle, record credit and qualification are modeled integration inputs',
                          'no ADC capture, DMA, physical CDC, board programming or pin timing closure',
                          'directed and seeded simulation are not exhaustive formal verification',
                          'nominal 1600-tick grid and 8-tick pulse are exercised; physical marker-to-pin offset is not measured',
                          'detectors validate selected comparators, not every possible implementation mutation']}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('ACQUISITION_SCHEDULER_PASS seeds=3 four_state=true detectors=5 structure=true', flush=True)


# importing the runner performs no build or device operation.
if __name__ == '__main__':
    main()

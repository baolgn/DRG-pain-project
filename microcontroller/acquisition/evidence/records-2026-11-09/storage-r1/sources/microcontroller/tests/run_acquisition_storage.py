#!/usr/bin/env python3
"""verify scheduler reservations and synthetic complete-record ownership."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess


def digest(path):
    """identify exact source, executable or waveform bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, log, cwd, timeout=300):
    """retain complete bounded invocations, including partial timeout diagnostics."""
    # each build and simulator run has an independent wall-clock deadline.
    try:
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
    # preserve diagnostic evidence even when a process never reaches its terminal result.
    except subprocess.TimeoutExpired as error:
        partial = error.stdout or ''
        # interrupted subprocess output may be bytes despite text mode.
        if isinstance(partial, bytes):
            partial = partial.decode(errors='replace')
        log.write_text('$ ' + shlex.join(command) + '\n' + partial + '\nTIMEOUT\n')
        raise
    log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
    return result


def main():
    """check the storage interface with two simulators and scoped structural checks."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    # tool paths are explicit overrides rather than assumed installation locations.
    for name in ['verilator', 'iverilog', 'vvp', 'yosys']:
        parser.add_argument('--' + name, default=name)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    rtl_names = ['drg5_acquisition_timebase.sv', 'drg5_acquisition_records.sv',
                 'drg5_acquisition_scheduler.sv', 'drg5_acquisition_storage.sv']
    sources = ['microcontroller/rtl/' + name for name in rtl_names] + [
        'microcontroller/tests/drg5_acquisition_storage_tb.sv',
        'microcontroller/tests/run_acquisition_storage.py']
    before = {name: digest(root / name) for name in sources}
    # failed attempts retain the exact source revision that entered the tools.
    for name in sources:
        target = output / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    tool_info = {}
    # record exact tool versions and executable hashes for reproduction.
    for name in ['verilator', 'iverilog', 'vvp', 'yosys']:
        executable = Path(shutil.which(getattr(args, name)) or getattr(args, name)).resolve()
        result = execute([str(executable), '--version' if name == 'verilator' else '-V'],
                         output / (name + '-version.log'), root)
        # an unknown tool identity cannot support a qualified result.
        if result.returncode:
            raise RuntimeError('cannot identify ' + name)
        tool_info[name] = {'path': str(executable), 'sha256': digest(executable),
                           'version': result.stdout.strip()}
    rtl = [str(root / name) for name in sources[:4]]
    bench = str(root / sources[4])
    timescale = output / 'timescale.sv'
    timescale.write_text('`timescale 1ns/1ps\n')
    build = execute([args.verilator, '--binary', '--timing', '--assert', '--trace',
                     '--timescale-override', '1ns/1ps', '-Wall', '-j', '2', '-CFLAGS', '-O0',
                     '--top-module', 'drg5_acquisition_storage_tb', '--Mdir', str(output / 'obj'),
                     *rtl, bench], output / 'build.log', root)
    # no blanket warning waiver hides integration errors.
    if build.returncode or '%Warning' in build.stdout:
        raise RuntimeError('storage integration build failed')
    pattern = r'^PASS acquisition-storage cases=7 checks=\d+$'
    results = {}
    binary = str(output / 'obj/Vdrg5_acquisition_storage_tb')
    simulation = execute([binary, '+verilator+seed+1', '+wave=verilator.vcd'],
                         output / 'verilator.log', output)
    match = re.search(pattern, simulation.stdout, re.MULTILINE)
    # a successful process without the coverage-guarded terminal is insufficient.
    if simulation.returncode or not match:
        raise RuntimeError('storage integration simulation failed')
    results['verilator'] = {'exit': simulation.returncode, 'terminal': match.group()}
    print(match.group(), flush=True)
    # deliberate sampled-value corruption must fail its ordinary semantic comparator.
    for name, poison, comparator in [('payload', 1, 'payload comparator'), ('credit', 2, 'credit comparator')]:
        result = execute([binary, '+verilator+seed+1', '+poison=' + str(poison), '+wave=detector-' + name + '.vcd'],
                         output / ('detector-' + name + '.log'), output)
        # unrelated crashes and unexpected passes are not successful negative controls.
        if result.returncode == 0 or comparator not in result.stdout or 'PASS acquisition-storage' in result.stdout:
            raise RuntimeError('storage detector failed: ' + name)
        results['detector-' + name] = {'exit': result.returncode, 'expected_comparator': comparator}
    four = execute([args.iverilog, '-g2012', '-D', 'SYNTHESIS', '-s', 'drg5_acquisition_storage_tb',
                    '-o', str(output / 'four-state.vvp'), str(timescale), *rtl, bench],
                   output / 'four-state-build.log', root)
    # the hardware branch retains every procedural four-state testbench predicate.
    if four.returncode:
        raise RuntimeError('four-state storage build failed')
    simulation = execute([args.vvp, str(output / 'four-state.vvp'), '+wave=four-state.vcd'],
                         output / 'four-state.log', output)
    match = re.search(pattern, simulation.stdout, re.MULTILINE)
    # all sampled outputs reject unknown values in the four-state simulation.
    if simulation.returncode or not match:
        raise RuntimeError('four-state storage simulation failed')
    results['four-state'] = {'exit': simulation.returncode, 'terminal': match.group()}
    # trace hashes identify actual captured transitions, not merely simulator invocation.
    for name in ['verilator', 'four-state']:
        wave = output / (name + '.vcd')
        # a missing or header-only trace cannot substantiate waveform generation.
        if not wave.is_file() or wave.stat().st_size < 1000:
            raise RuntimeError('missing storage waveform: ' + name)
        results[name].update(wave_sha256=digest(wave), wave_bytes=wave.stat().st_size)
    unknown = execute([args.vvp, str(output / 'four-state.vvp'), '+poison=3', '+wave=unknown.vcd'],
                      output / 'detector-unknown.log', output)
    # a four-state payload corruption must fail the exact-byte comparator.
    if unknown.returncode == 0 or 'payload comparator' not in unknown.stdout:
        raise RuntimeError('unknown-value detector failed')
    results['detector-unknown'] = {'exit': unknown.returncode, 'expected_comparator': 'payload comparator'}
    # preserve default memories; full generic mapping uses the reduced verification depth.
    for name, commands in [
        ('structure', 'hierarchy -check -top drg5_acquisition_storage; proc; opt; memory_collect; '),
        ('small-synthesis', 'chparam -set DEPTH 4 drg5_acquisition_storage; hierarchy -check -top drg5_acquisition_storage; '
         'proc; opt; synth -top drg5_acquisition_storage; ')
    ]:
        script = ('read_verilog -sv -D SYNTHESIS ' + ' '.join(rtl) + '; ' + commands +
                  'check -assert; select -assert-none t:$dlatch t:$adlatch; stat')
        structure = execute([args.yosys, '-Q', '-T', '-p', script], output / (name + '.log'), root, timeout=600)
        warnings = [line for line in structure.stdout.splitlines() if line.startswith('Warning:')]
        unexpected = [line for line in warnings if not re.fullmatch(
            r'Warning: Replacing memory \\?(?:state_q|state_d) with list of registers\..*', line)]
        # only explicit ledger-state register flattening is expected.
        if structure.returncode or unexpected:
            raise RuntimeError('storage structure failed: ' + repr(unexpected))
        results[name] = {'exit': structure.returncode, 'reviewed_warnings': warnings,
                         'scope': 'default memory-preserving structural check' if name == 'structure'
                         else 'DEPTH=4 full generic synthesis; no inferred latches'}
    after = {name: digest(root / name) for name in sources}
    # concurrent source changes cannot be attributed to the compiled revision.
    if before != after:
        raise RuntimeError('storage integration sources changed during verification')
    summary = {'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'scope': 'single-clock scheduler, reservations and complete-record storage',
               'seed': 1, 'randomness': 'no random stimulus; fixed public-interface scenarios',
               'results': results, 'tools': tool_info, 'source_sha256': after,
               'limits': ['capture results and positive DMA completions are synthetic inputs',
                          'CPU reset is an input stimulus, not CPU-core execution',
                          'no ADC, actual DMA writes, asynchronous FIFO, board programming or routed timing qualification',
                          'generic synthesis and directed simulation are not exhaustive formal proof',
                          'default memory-preserving structural checks do not establish device mapping or timing',
                          'sampled-value negative controls validate selected comparators only']}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('ACQUISITION_STORAGE_PASS cases=7 four_state=true detectors=3 structure=true small_synthesis=true', flush=True)


# importing this runner never builds, writes evidence or accesses a device.
if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""verify connected acquisition command, timebase and slot ownership."""
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
    """check public-interface behavior with two simulators and generic wrapper synthesis."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    # tool paths are explicit overrides rather than assumed installation locations.
    for name in ['verilator', 'iverilog', 'vvp', 'yosys']:
        parser.add_argument('--' + name, default=name)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    rtl_names = ['drg5_acquisition_timebase.sv', 'drg5_acquisition_control.sv',
                 'drg5_acquisition_scheduler.sv', 'drg5_acquisition_timing.sv']
    sources = ['microcontroller/rtl/' + name for name in rtl_names] + [
        'microcontroller/tests/drg5_acquisition_timing_tb.sv',
        'microcontroller/tests/run_acquisition_timing.py']
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
                     '--top-module', 'drg5_acquisition_timing_tb', '--Mdir', str(output / 'obj'),
                     *rtl, bench], output / 'build.log', root)
    # no blanket warning waiver hides integration errors.
    if build.returncode or '%Warning' in build.stdout:
        raise RuntimeError('timing integration build failed')
    pattern = r'^PASS acquisition-timing cases=10 checks=\d+ bindings=\d+ launches=\d+$'
    results = {}
    binary = str(output / 'obj/Vdrg5_acquisition_timing_tb')
    simulation = execute([binary, '+verilator+seed+1', '+wave=verilator.vcd'],
                         output / 'verilator.log', output)
    match = re.search(pattern, simulation.stdout, re.MULTILINE)
    # a successful process without the coverage-guarded terminal is insufficient.
    if simulation.returncode or not match:
        raise RuntimeError('timing integration simulation failed')
    results['verilator'] = {'exit': simulation.returncode, 'terminal': match.group()}
    print(match.group(), flush=True)
    # deliberate sampled-value corruption must fail its ordinary semantic comparator.
    for name, comparator in [('binding', 'binding comparator'), ('closure', 'closure comparator')]:
        result = execute([binary, '+verilator+seed+1', '+mutate_' + name],
                         output / ('detector-' + name + '.log'), output)
        # unrelated crashes and unexpected passes are not successful negative controls.
        if result.returncode == 0 or comparator not in result.stdout or 'PASS acquisition-timing' in result.stdout:
            raise RuntimeError('timing detector failed: ' + name)
        results['detector-' + name] = {'exit': result.returncode, 'expected_comparator': comparator}
    four = execute([args.iverilog, '-g2012', '-D', 'SYNTHESIS', '-s', 'drg5_acquisition_timing_tb',
                    '-o', str(output / 'four-state.vvp'), str(timescale), *rtl, bench],
                   output / 'four-state-build.log', root)
    # the hardware branch retains every procedural four-state testbench predicate.
    if four.returncode:
        raise RuntimeError('four-state timing build failed')
    simulation = execute([args.vvp, str(output / 'four-state.vvp'), '+wave=four-state.vcd'],
                         output / 'four-state.log', output)
    match = re.search(pattern, simulation.stdout, re.MULTILINE)
    # all sampled outputs reject unknown values in the four-state simulation.
    if simulation.returncode or not match:
        raise RuntimeError('four-state timing simulation failed')
    results['four-state'] = {'exit': simulation.returncode, 'terminal': match.group()}
    # trace hashes identify actual captured transitions, not merely simulator invocation.
    for name in ['verilator', 'four-state']:
        wave = output / (name + '.vcd')
        # a missing or header-only trace cannot substantiate waveform generation.
        if not wave.is_file() or wave.stat().st_size < 1000:
            raise RuntimeError('missing timing waveform: ' + name)
        results[name].update(wave_sha256=digest(wave), wave_bytes=wave.stat().st_size)
    script = ('read_verilog -sv -D SYNTHESIS ' + ' '.join(rtl) +
              '; hierarchy -check -top drg5_acquisition_timing; proc; check -assert; '
              'select -assert-none t:$dlatch t:$adlatch; synth -top drg5_acquisition_timing; '
              'check -assert; select -assert-none t:$dlatch t:$adlatch; stat')
    structure = execute([args.yosys, '-Q', '-T', '-p', script], output / 'structure.log', root, timeout=600)
    warnings = [line for line in structure.stdout.splitlines() if line.startswith('Warning:')]
    unexpected = [line for line in warnings if not re.fullmatch(
        r'Warning: Replacing memory \\?[A-Za-z0-9_]+ with list of registers\..*', line)]
    # snapshot-array register flattening is the only expected synthesis diagnostic.
    if structure.returncode or unexpected:
        raise RuntimeError('timing wrapper structural synthesis failed: ' + repr(unexpected))
    results['structure'] = {'exit': structure.returncode, 'reviewed_warnings': warnings,
                            'scope': 'default-parameter generic wrapper synthesis; no inferred latches'}
    after = {name: digest(root / name) for name in sources}
    # concurrent source changes cannot be attributed to the compiled revision.
    if before != after:
        raise RuntimeError('timing integration sources changed during verification')
    summary = {'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'scope': 'connected single-clock control, timebase and slot scheduler',
               'seed': 1, 'randomness': 'no random stimulus; fixed public-interface scenarios',
               'results': results, 'tools': tool_info, 'source_sha256': after,
               'limits': ['capture and qualification backends are modeled attestations',
                          'CPU activity is MMIO stimulus, not execution of the RISC-V core',
                          'no ADC, DMA, physical CDC, board programming or routed pin-delay qualification',
                          'generic synthesis and directed simulation are not exhaustive formal proof',
                          'configuration and closure timers use reduced test parameters',
                          'sampled-value negative controls validate selected comparators only']}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('ACQUISITION_TIMING_PASS cases=10 four_state=true detectors=2 structure=true', flush=True)


# importing this runner never builds, writes evidence or accesses a device.
if __name__ == '__main__':
    main()

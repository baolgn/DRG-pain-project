#!/usr/bin/env python3
"""verify ordered record reservations with independent synthetic transactions."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess


# identify the exact bytes used by each retained campaign.
def digest(path):
    """return the SHA-256 of an existing artifact."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# every tool invocation has bounded wall time and retains its command and diagnostics.
def execute(command, log, cwd, timeout=300):
    """run one tool and preserve partial output if it times out."""
    # timeouts must leave their evidence available for review.
    try:
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
    # a partial build is never converted into a successful result.
    except subprocess.TimeoutExpired as error:
        partial = error.stdout or ''
        # subprocess may supply bytes even when text mode was requested.
        if isinstance(partial, bytes):
            partial = partial.decode(errors='replace')
        log.write_text('$ ' + shlex.join(command) + '\n' + partial + '\nTIMEOUT\n')
        raise
    log.write_text('$ ' + shlex.join(command) + '\n' + result.stdout)
    return result


# exact warning classes need explicit review before synthesis can pass.
def reviewed_warnings(output):
    """accept only named array expansion and the extracted ABC cone warning."""
    warnings = [line for line in output.splitlines() if 'Warning:' in line]
    expected_abc = 'ABC: Warning: The network is combinational (run "fraig" or "fraig_sweep").'
    # small metadata arrays may flatten; payload memory must remain collected in the default check.
    for line in warnings:
        allowed = re.fullmatch(r'Warning: Replacing memory \\?(state_q|state_d) with list of registers\..*', line)
        # any additional warning requires a deliberate investigation.
        if not allowed and line != expected_abc:
            raise RuntimeError('unexpected synthesis warning: ' + line)
    return warnings


# a fresh output directory prevents stale binaries or logs from supplying a result.
def main():
    """compile the bench, run bounded checks and retain source-bound results."""
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
    sources = ['microcontroller/rtl/drg5_acquisition_records.sv',
               'microcontroller/tests/drg5_acquisition_records_tb.sv',
               'microcontroller/tests/run_acquisition_records.py']
    before = {name: digest(root / name) for name in sources}
    # snapshots identify both passing and failed revisions before any tool runs.
    for name in sources:
        target = output / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    tools = {}
    results = {}
    # resolve and identify every executable used in the campaign.
    for name in ['verilator', 'iverilog', 'vvp', 'yosys']:
        executable = Path(shutil.which(getattr(args, name)) or getattr(args, name)).resolve()
        version = execute([str(executable), '--version' if name == 'verilator' else '-V'],
                          output / (name + '-version.log'), root)
        # failed version discovery invalidates attribution to a tool build.
        if version.returncode:
            raise RuntimeError('cannot identify ' + name)
        tools[name] = {'path': str(executable), 'sha256': digest(executable), 'version': version.stdout.strip()}
    rtl, bench = [str(root / name) for name in sources[:2]]
    timescale = output / 'timescale.sv'
    timescale.write_text('`timescale 1ns/1ps\n')
    build = execute([args.verilator, '--binary', '--timing', '--assert', '--trace',
                     '--timescale-override', '1ns/1ps', '-Wall', '-j', '2', '-CFLAGS', '-O0',
                     '--top-module', 'drg5_acquisition_records_tb', '--Mdir', str(output / 'obj'), rtl, bench],
                    output / 'build.log', root)
    # lint warnings are failures, with no blanket suppression.
    if build.returncode or '%Warning' in build.stdout:
        raise RuntimeError('records build failed: ' + str(output / 'build.log'))
    seeds = [1, 305419896, 3735928559]
    terminal = r'^PASS acquisition-records seed=\d+ checks=\d+ cases=\d+ random=\d+$'
    # every seed runs all directed cases before deterministic transaction stress.
    for seed in seeds:
        name = f'verilator-seed-{seed}'
        result = execute([str(output / 'obj/Vdrg5_acquisition_records_tb'), '+verilator+seed+1',
                          f'+seed={seed}', f'+wave={name}.vcd'], output / (name + '.log'), output)
        match = re.search(terminal, result.stdout, re.MULTILINE)
        wave = output / (name + '.vcd')
        # success requires both the coverage guard and a nonempty signal trace.
        if result.returncode or not match or not wave.is_file() or wave.stat().st_size < 1000:
            raise RuntimeError('records simulation failed: ' + name)
        results[name] = {'exit': result.returncode, 'terminal': match.group(),
                         'depth': 4, 'wave_sha256': digest(wave), 'wave_bytes': wave.stat().st_size}
        print(match.group(), flush=True)
    detectors = {'ledger': 'ledger comparator', 'record': 'record comparator', 'order': 'order comparator'}
    # corrupted sampled observations must fail their ordinary comparisons.
    for mutation, label in detectors.items():
        name = 'detector-' + mutation
        run = execute([str(output / 'obj/Vdrg5_acquisition_records_tb'), '+verilator+seed+1',
                       '+seed=1', '+mutate_' + mutation], output / (name + '.log'), output)
        # unrelated crashes or successful terminals cannot count as detector evidence.
        if run.returncode == 0 or label not in run.stdout or 'PASS acquisition-records' in run.stdout:
            raise RuntimeError('records detector failed: ' + name)
        results[name] = {'exit': run.returncode, 'expected_comparator': label}
    profiles = [('four-state', [], ['+seed=1', '+wave=four-state.vcd'], terminal, 4),
                ('default-depth', ['-Pdrg5_acquisition_records_tb.TEST_DEPTH=256'],
                 ['+seed=1', '+wave=default-depth.vcd'], terminal, 256),
                ('small-counter', ['-Pdrg5_acquisition_records_tb.TEST_COUNTER_LIMIT=7'],
                 ['+small', '+seed=1'], r'^PASS acquisition-records-small checks=\d+ cases=\d+$', 4)]
    # four-state checks exercise real full capacity, pointer wrap and token exhaustion.
    for name, parameters, runtime, pattern, depth in profiles:
        binary = output / (name + '.vvp')
        build = execute([args.iverilog, '-g2012', '-D', 'SYNTHESIS', *parameters,
                         '-s', 'drg5_acquisition_records_tb', '-o', str(binary), str(timescale), rtl, bench],
                        output / (name + '-build.log'), root)
        # SYNTHESIS excludes elaboration assertions, not procedural bench comparisons.
        if build.returncode:
            raise RuntimeError(name + ' build failed')
        run = execute([args.vvp, str(binary), *runtime], output / (name + '.log'), output)
        match = re.search(pattern, run.stdout, re.MULTILINE)
        # unknown signal values fail the same case-equality checks as incorrect bits.
        if run.returncode or not match:
            raise RuntimeError(name + ' simulation failed')
        results[name] = {'exit': run.returncode, 'terminal': match.group(), 'depth': depth}
        # waveform-free reduced-counter checks still retain complete logs and sources.
        if name != 'small-counter':
            wave = output / (name + '.vcd')
            # every requested waveform must contain more than just its header.
            if not wave.is_file() or wave.stat().st_size < 1000:
                raise RuntimeError(name + ' waveform missing')
            results[name].update({'wave_sha256': digest(wave), 'wave_bytes': wave.stat().st_size})
        print(match.group(), flush=True)
    unknown = execute([args.vvp, str(output / 'four-state.vvp'), '+seed=1', '+mutate_unknown'],
                      output / 'detector-unknown.log', output)
    # a sampled X must fail the unmodified complete-record byte comparator.
    if unknown.returncode == 0 or 'record comparator' not in unknown.stdout:
        raise RuntimeError('unknown-value detector failed')
    results['detector-unknown'] = {'exit': unknown.returncode, 'expected_comparator': 'record comparator'}
    memory_script = (f'read_verilog -sv -D SYNTHESIS {rtl}; hierarchy -check -top drg5_acquisition_records; '
                     'proc; opt; memory_collect; check -assert; select -assert-none t:$dlatch t:$adlatch; '
                     'select -assert-count 2 t:$mem_v2; stat')
    structure = execute([args.yosys, '-Q', '-T', '-p', memory_script], output / 'memory-structure.log', root, 600)
    # default-depth structure retains payload memories instead of mapping 14 KiB into generic flip-flops.
    if structure.returncode:
        raise RuntimeError('default-depth memory structure failed')
    results['memory-structure'] = {'exit': structure.returncode, 'reviewed_warnings': reviewed_warnings(structure.stdout),
                                   'scope': 'default depth 256 process lowering, memory collection and no inferred latches'}
    small_script = (f'read_verilog -sv -D SYNTHESIS {rtl}; chparam -set DEPTH 4 drg5_acquisition_records; '
                    'hierarchy -check -top drg5_acquisition_records; synth -top drg5_acquisition_records; '
                    'check -assert; select -assert-none t:$dlatch t:$adlatch; stat')
    small_structure = execute([args.yosys, '-Q', '-T', '-p', small_script], output / 'small-structure.log', root, 600)
    # full generic synthesis uses the same logic with a reduced ring; it proves no device timing or CDC.
    if small_structure.returncode:
        raise RuntimeError('reduced-depth synthesis failed')
    results['small-structure'] = {'exit': small_structure.returncode,
                                  'reviewed_warnings': reviewed_warnings(small_structure.stdout),
                                  'scope': 'depth 4 generic synthesis and no inferred latches'}
    after = {name: digest(root / name) for name in sources}
    # a source change during execution requires a new campaign rather than rewritten attribution.
    if after != before:
        raise RuntimeError('records sources changed during verification')
    summary = {'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'scope': 'single-clock complete-record reservations with synthetic producer and DMA backend',
               'seeds': seeds, 'results': results, 'tools': tools, 'source_sha256': after,
               'limits': ['single clock only; no asynchronous FIFO or physical CDC qualification',
                          'synthetic opaque 48-byte complete payloads test byte transport, not ADC validity or CRC computation',
                          'DMA completion is modeled positive retirement, not implemented memory writes or publication',
                          'reset assumes prior external isolation and containment',
                          'simulation and generic structure checks are not exhaustive formal proof or routed device timing',
                          'negative controls validate selected comparators, not every possible implementation mutation']}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print('ACQUISITION_RECORDS_PASS seeds=3 four_state=true default_depth=256 detectors=4 structure=true', flush=True)


# importing the module never builds hardware or programs a device.
if __name__ == '__main__':
    main()

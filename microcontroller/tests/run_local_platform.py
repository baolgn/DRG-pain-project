#!/usr/bin/env python3
"""compile boot firmware, inspect every object and execute the complete local RTL platform."""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import shlex
import shutil
import subprocess
import sys

from audit_firmware import audit, compressed_oracle, read_elf

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path('/tmp/drg5-control-tools-20260301/oss-cad-suite')
EVIDENCE = ROOT / 'microcontroller/verification/evidence/local-platform-2026-11-04'


# imported helpers expose parsers and builders without running their command interfaces.
def module(name, relative):
    """load one source-local helper with an unambiguous module identity."""
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


# exact hashes identify all source and evidence bytes.
def digest(path):
    """hash a complete file."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# retain the real invocation and all diagnostics, including failed attempts.
def execute(command, log, timeout=600):
    """run one tool without shell interpolation."""
    # flush the command before a failing subprocess can interrupt logging.
    with Path(log).open('w') as stream:
        stream.write('$ ' + shlex.join([str(value) for value in command]) + '\n');stream.flush()
        result = subprocess.run([str(value) for value in command], cwd=ROOT, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    return result.returncode


# images vary between detector runs while simulator inputs and source hashes remain fixed.
def simulator(directory, verilator, profile, diagnostic, forwarding, elf_runner):
    """build a strict real-memory SoC model with randomized unreset state."""
    directory.mkdir(parents=True, exist_ok=True)
    sources = [f'microcontroller/rtl/{name}.sv' for name in elf_runner.NAMES]
    sources += ['microcontroller/rtl/drg5_local_fabric.sv', 'microcontroller/rtl/drg5_soc.sv']
    schema = elf_runner.schema(directory)
    c = m = int(profile == 'imc')
    command = [verilator, '--cc', '--exe', '--build', '--assert', '-Wall', '-j', '2',
               '--x-initial', 'unique', '--x-assign', 'unique', '-CFLAGS', '-O0 -I' + str(directory),
               '-Imicrocontroller/rtl', '--top-module', 'drg5_soc', '--Mdir', directory,
               f'-GC_ENABLED={c}', f'-GM_ENABLED={m}', f'-GDIAGNOSTIC={diagnostic}', f'-GFORWARDING={forwarding}',
               f'-GROM_FILE="{directory / "rom.hex"}"', f'-GIRAM_FILE="{directory / "iram.hex"}"',
               f'-GDRAM_FILE="{directory / "poison.hex"}"', *sources,
               ROOT / 'microcontroller/tests/local_platform_sim.cpp']
    attributed = sources + ['microcontroller/rtl/drg5_datapath_defs.svh',
                            'microcontroller/tests/local_platform_sim.cpp',
                            'microcontroller/verification/execution/run_elf.py',
                            'microcontroller/tests/replay_counter_trace.py']
    inputs = {'sources': {name: digest(ROOT / name) for name in attributed},
              'command': [str(value) for value in command],
              'verilator': subprocess.check_output([verilator, '--version'], text=True).strip()}
    executable = directory / 'Vdrg5_soc'; fingerprint = directory / 'build-inputs.json'
    # a cache is reusable only when every source, option and executable is still present.
    if not (executable.is_file() and fingerprint.is_file() and json.loads(fingerprint.read_text()) == inputs):
        code = execute(command, directory / 'build.log')
        # HDL warnings and compiler failures remain qualification failures.
        if code or '%Warning' in (directory / 'build.log').read_text():
            raise RuntimeError('strict SoC build failed: ' + str(directory / 'build.log'))
        fingerprint.write_text(json.dumps(inputs, indent=2) + '\n')
    return executable, inputs, schema


# startup layout is supplied from the actually linked variant, including detector variants.
def prepare_image(firmware, simulator_directory, seed):
    """load only ROM/IRAM and fill every DRAM word with explicit nonzero poison."""
    # the loader never initializes data objects at their DRAM virtual addresses.
    for name in ('rom', 'iram'):
        shutil.copy2(firmware[name], simulator_directory / (name + '.hex'))
    rng = random.Random(seed ^ 0x72564132)
    (simulator_directory / 'poison.hex').write_text(''.join(f'{rng.getrandbits(32) | 1:08x}\n' for _ in range(8192)))
    symbols = firmware['symbols']
    names = ['startup_complete', '__data_start', '__data_end', '__data_load', '__bss_start', '__bss_end', 'boot_initialized']
    (simulator_directory / 'layout.txt').write_text(' '.join(f'{symbols[name]:08x}' for name in names) + '\n')


# full trace replay checks bus ownership independently of firmware's self-test verdict.
def run_case(executable, directory, firmware, output, seed, mode, schema, comparison, expected=None):
    """execute one immutable image and timing schedule, retaining successful or failed captures."""
    output.mkdir(parents=True, exist_ok=True)
    prepare_image(firmware, directory, seed)
    # save exact initialization and layout inputs beside the actual trace.
    for name in ['rom.hex', 'iram.hex', 'poison.hex', 'layout.txt']:
        shutil.copy2(directory / name, output / name)
    trace = output / 'trace.jsonl'
    command = [executable, directory / 'rom.hex', directory / 'iram.hex', directory / 'poison.hex',
               trace, str(seed), '3000000', mode, directory / 'layout.txt']
    code = execute(command, output / 'execution.log', 300)
    text = (output / 'execution.log').read_text()
    markers = [line.removeprefix('LOCAL_PLATFORM_PASS ') for line in text.splitlines() if line.startswith('LOCAL_PLATFORM_PASS ')]
    result = {'seed': seed, 'mode': mode, 'negative': expected, 'exit_code': code,
              'command': [str(value) for value in command], 'firmware_sha256': digest(firmware['elf']),
              'observed': json.loads(markers[0]) if len(markers) == 1 else None}
    problem = None
    # a detector must fail its own ordinary invariant, not just any process error.
    if expected:
        result['expected_failure_seen'] = code != 0 and not markers and 'LOCAL_PLATFORM_FAILURE ' + expected in text
        # an unrelated assertion cannot qualify this injected defect.
        if not result['expected_failure_seen']:
            problem = 'negative detector did not fail intended check: ' + expected
    # ordinary execution requires complete output and independently valid trace records.
    else:
        # require the application text as well as the retired success store.
        if code or len(markers) != 1 or 'CONSOLE RDRG5 firmware pass\n' not in text:
            problem = 'compiled firmware execution failed: ' + str(output / 'execution.log')
        # replay only complete positive captures; failing captures remain diagnostic evidence.
        else:
            # preserve a rejected replay as a failed capture, with its original bytes.
            try:
                terminals, footer = comparison.read_dut(trace, schema)
                result['replay'] = footer
                expected_traps = 8 if firmware['profile'] == 'imc' else 7
                # named synchronous probes and all four source services must actually occur.
                if footer['traps'] != expected_traps or footer['irqs'] != 4:
                    problem = 'missing exception or interrupt exercise'
                result['terminal_records'] = len(terminals)
            # parser failures are separate from the application result.
            except Exception as error:
                problem = 'trace replay failed: ' + str(error)
    # all traces survive independently of temporary build directories, including failures.
    if trace.is_file():
        plain_hash = digest(trace)
        # compression is lossless and does not discard a failing trace.
        with trace.open('rb') as source, gzip.open(output / 'trace.jsonl.gz', 'wb') as target:
            shutil.copyfileobj(source, target)
        # verify bytes before removing the redundant plain capture.
        if hashlib.sha256(gzip.decompress((output / 'trace.jsonl.gz').read_bytes())).hexdigest() != plain_hash:
            raise RuntimeError('trace compression mismatch')
        trace.unlink();result['trace_sha256'] = plain_hash;result['trace_archive_sha256'] = digest(output / 'trace.jsonl.gz')
    result['status'] = 'failed' if problem else 'passed'
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    # failure reports survive before execution stops at the first unresolved defect.
    if problem:
        raise RuntimeError(problem)
    print('LOCAL_CASE_PASS ' + output.name + ' ' + mode + ' seed=' + str(seed), flush=True)
    return result


# the ISA audit must reject an accidentally compiled M instruction in an I-only object.
def audit_detector(directory, firmware, prefix, oracle):
    """reject unsupported instructions even when ELF attributes still claim the valid profile."""
    source = Path(firmware['elf']); image = read_elf(source)
    section = next(item for item in image['sections'] if item['name'] == '.boot')
    results = {}
    # M, floating point and absent Zicntr aliases need distinct ordinary rejection paths.
    for name, encoding in [('m', 0x02000033), ('float', 0x00000553), ('time', 0xc0102573)]:
        damaged = bytearray(source.read_bytes())
        damaged[section['offset']:section['offset'] + 4] = encoding.to_bytes(4, 'little')
        path = directory / ('unsupported-' + name + '.elf');path.write_bytes(damaged)
        reason = None
        # only the exact unsupported-opcode diagnostic qualifies this control.
        try:
            audit(path, 'i', prefix, oracle)
        # retain the exact rejected encoding diagnostic.
        except ValueError as error:
            reason = str(error)
        # a malformed header or unrelated failure does not qualify instruction inspection.
        if not reason or f'unsupported instruction {encoding:#010x}' not in reason:
            raise RuntimeError('ISA audit detector failed')
        results[name] = {'status': 'passed', 'input_sha256': digest(path), 'expected_failure': reason}
    return results


# a full campaign covers separately compiled ISA profiles, timing schedules and occupancy modes.
def main():
    """retain every attempt and never modify the earlier sealed verification campaign."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-local-platform'))
    parser.add_argument('--verilator', default=str(TOOLS / 'bin/verilator'))
    parser.add_argument('--evidence', type=Path, default=EVIDENCE)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args();build = args.build.resolve();build.mkdir(parents=True, exist_ok=True)
    evidence = args.evidence.resolve();evidence.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    revision = evidence / 'revisions' / stamp;revision.mkdir(parents=True)
    firmware_builder = module('local_firmware_build', 'microcontroller/firmware/build.py')
    elf_runner = module('local_elf_helpers', 'microcontroller/verification/execution/run_elf.py')
    comparison = module('local_trace_compare', 'microcontroller/verification/execution/comparison.py')
    sources = sorted({*ROOT.glob('microcontroller/rtl/*.*'), *ROOT.glob('microcontroller/firmware/*.*'),
                      *(ROOT / name for name in ['microcontroller/tests/run_local_platform.py',
                         'microcontroller/tests/audit_firmware.py', 'microcontroller/tests/local_platform_sim.cpp',
                         'microcontroller/tests/run_decompress.py', 'microcontroller/tests/replay_counter_trace.py',
                         'microcontroller/verification/execution/run_elf.py', 'microcontroller/verification/execution/comparison.py'])})
    before = {str(path.relative_to(ROOT)): digest(path) for path in sources if path.is_file()}
    # snapshot inputs before tools can execute or another edit can occur.
    for name in before:
        target = revision / 'sources' / name;target.parent.mkdir(parents=True, exist_ok=True);shutil.copy2(ROOT / name, target)
    report = {'status': 'running', 'smoke': args.smoke, 'source_sha256': before, 'runs': [], 'firmware': {},
              'tool_sha256': {args.verilator: digest(args.verilator)},
              'scope': 'real local SoC and compiled firmware simulation; no ADC, external memory, physical FPGA or WCET qualification'}
    failure = None
    # retain all generated objects, compiler logs and images before running the first program.
    try:
        oracle = compressed_oracle()
        profiles = ['imc'] if args.smoke else ['imc', 'i']
        # every linked translation unit, archive member and final image is inspected independently.
        for profile in profiles:
            program = firmware_builder.build(revision / ('firmware-' + profile), profile)
            manifest = json.loads(Path(program['manifest']).read_text())
            archived_runtime = subprocess.check_output([firmware_builder.DEFAULT_PREFIX + 'ar', 'p', manifest['archive'], 'runtime.o'])
            # audit the actual archive member by requiring exact identity with its inspected object.
            if archived_runtime != Path(manifest['objects'][-1]).read_bytes():
                raise RuntimeError('runtime archive member differs from inspected object')
            inspected = [audit(path, profile, firmware_builder.DEFAULT_PREFIX, oracle)
                         for path in [*manifest['objects'], program['elf']]]
            report['firmware'][profile] = {'build': program, 'instruction_audit': inspected}
        # each configuration is a distinct hardware elaboration with matching firmware ISA.
        configurations = [('imc-forwarded', 'imc', 0, 1)] if args.smoke else [
            ('imc-forwarded', 'imc', 0, 1), ('imc-interlocked', 'imc', 0, 0),
            ('imc-diagnostic', 'imc', 1, 1), ('i-forwarded', 'i', 0, 1)]
        simulators = {}
        # preserve a separate executable and fingerprint for every occupancy and ISA profile.
        for name, profile, diagnostic, forwarding in configurations:
            directory = build / name
            executable, inputs, schema = simulator(directory, args.verilator, profile, diagnostic, forwarding, elf_runner)
            simulators[name] = (executable, directory, schema)
            target = revision / name;target.mkdir()
            shutil.copy2(directory / 'build.log', target / 'build.log')
            (target / 'build-inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
            (target / 'trace-schema.json').write_text(json.dumps(schema, indent=2) + '\n')
            schedules = [(1, 'local')] if args.smoke else [(1, 'local'), (1, 'stress'), (305419896, 'stress')]
            # seeds vary poison RAM, unreset registers, target latencies and pipeline holds.
            for seed, mode in schedules:
                run = run_case(executable, directory, report['firmware'][profile]['build'],
                               target / (mode + '-' + str(seed)), seed, mode, schema, comparison)
                report['runs'].append({'configuration': name, **run})
        # separately compiled defects demonstrate that startup and trap preservation matter.
        if not args.smoke:
            executable, directory, schema = simulators['imc-forwarded']
            # the ordinary startup and handler checks must catch each separately built defect.
            for variant, expected in [('skip-data', 'startup data initialization'), ('skip-bss', 'startup BSS initialization'),
                                      ('drop-t0', 'firmware result 3 console=DRG5 firmware fail 00000402')]:
                firmware = firmware_builder.build(revision / ('firmware-' + variant), 'imc', negative=variant)
                run = run_case(executable, directory, firmware, revision / ('negative-' + variant),
                               1, 'stress', schema, comparison, expected)
                report['runs'].append({'configuration': 'imc-forwarded', **run})
            report['isa_detector'] = audit_detector(revision, report['firmware']['i']['build'], firmware_builder.DEFAULT_PREFIX, oracle)
        # no passing result may cite sources edited while tools were running.
        if before != {name: digest(ROOT / name) for name in before}:
            raise RuntimeError('source changed during local platform qualification')
        report['status'] = 'passed'
    # failures retain their logs and source cohort instead of overwriting prior attempts.
    except Exception as error:
        failure = error;report['status'] = 'failed';report['failure'] = str(error)
    # write the outcome even after compiler, simulator or independent checker failure.
    finally:
        # an edited source never replaces the snapshot retained before execution.
        report['source_drift'] = {name: digest(ROOT / name) for name, value in before.items() if digest(ROOT / name) != value}
        (revision / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        shutil.copy2(revision / 'summary.json', evidence / 'summary.json')
    # the command's outcome distinguishes smoke evidence from a full matrix.
    if failure:
        raise failure
    print('LOCAL_PLATFORM_CAMPAIGN_PASS ' + str(revision), flush=True)


# imports never compile firmware, invoke simulation or overwrite evidence.
if __name__ == '__main__':
    main()

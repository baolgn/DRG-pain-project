#!/usr/bin/env python3
"""snapshot, synthesize, route and pack one exact ULX3S CPU candidate."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


def digest(path):
    """hash files without duplicating large netlists in memory."""
    value = hashlib.sha256()
    # bounded reads also handle embedded nextpnr device databases.
    with path.open('rb') as stream:
        # consume the file in order until its exact end.
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def save_json(path, value):
    """write deterministic evidence for later comparison."""
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def execute(command, destination, cwd, environment):
    """stream diagnostics to disk and preserve failures without relabeling them."""
    started = datetime.now(timezone.utc).isoformat()
    # logs survive a failed or interrupted tool invocation.
    with destination.open('w') as stream:
        stream.write('$ ' + shlex.join(command) + '\n')
        stream.flush()
        result = subprocess.run(command, cwd=cwd, env=environment, stdout=stream,
                                stderr=subprocess.STDOUT, check=False)
    return {'command': command, 'exit': result.returncode, 'started_utc': started,
            'finished_utc': datetime.now(timezone.utc).isoformat(),
            'log': destination.name, 'log_sha256': digest(destination)}


def primitive_summary(netlist, top):
    """retain native memory and DSP configuration, excluding large initialization strings."""
    design = json.loads(netlist.read_text())['modules'][top]
    counts = Counter(cell['type'] for cell in design['cells'].values())
    native = {}
    # preserve each hard primitive's modes and hierarchy name.
    for name, cell in design['cells'].items():
        # initialization has a separate digest and remains in the sealed netlist.
        if cell['type'] in {'DP16KD', 'PDPW16KD', 'MULT18X18D', 'MULT9X9D', 'ALU54B', 'EHXPLLL'}:
            parameters = cell.get('parameters', {})
            init = {key: value for key, value in parameters.items() if key.startswith('INITVAL')}
            native[name] = {'type': cell['type'],
                            'parameters': {key: value for key, value in parameters.items()
                                           if not key.startswith('INITVAL')},
                            'initialization_sha256': hashlib.sha256(
                                json.dumps(init, sort_keys=True).encode()).hexdigest()}
    return {'cells': dict(sorted(counts.items())), 'native_primitives': native,
            'ports': design['ports'], 'netlist_sha256': digest(netlist)}


def main():
    """use one immutable input snapshot and a matching generated PLL per candidate."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--board', type=Path, required=True)
    parser.add_argument('--extra-source', type=Path, action='append', default=[])
    parser.add_argument('--lpf', type=Path, required=True)
    parser.add_argument('--top', default='drg5_ulx3s')
    parser.add_argument('--mhz', type=float, required=True)
    parser.add_argument('--stage', type=int, choices=(0, 1, 2), default=2)
    parser.add_argument('--guard-percent', type=float, default=10)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--synthesis-only', action='store_true')
    args = parser.parse_args()
    # guardband tightens the implementation constraint without changing the PLL frequency.
    if not 0 <= args.guard_percent < 100:
        parser.error('--guard-percent must be at least zero and below 100')
    route_mhz = args.mhz / (1 - args.guard_percent / 100)
    root = Path(__file__).resolve().parents[2]
    tools, output = args.tools.resolve(), args.output.resolve()
    # a candidate can never overwrite earlier successes or failures.
    output.mkdir(parents=True, exist_ok=False)
    snapshot = output / 'inputs'
    snapshot.mkdir()
    env = os.environ.copy()
    env.update(XDG_CONFIG_HOME=str(output / 'config'), XDG_CACHE_HOME=str(output / 'cache'),
               XDG_DATA_HOME=str(output / 'data'), QT_QPA_PLATFORM='offscreen')
    loader = [str(tools / 'lib/ld-linux-x86-64.so.2'), '--inhibit-cache',
              '--inhibit-rpath', '', '--library-path', str(tools / 'lib')]
    commands = {name: loader + [str(tools / 'libexec' / name)]
                for name in ('nextpnr-ecp5', 'ecppack', 'ecppll')}
    commands['yosys'] = [str(tools / 'bin/yosys')]
    paths = list((root / 'microcontroller/rtl').glob('*.sv'))
    paths += list((root / 'microcontroller/rtl').glob('*.svh'))
    paths += [args.board.resolve(), args.lpf.resolve(), Path(__file__).resolve()]
    paths += [source.resolve() for source in args.extra_source]
    source_identity = {}
    copied = {}
    # the compiler only reads copied inputs, never files that an editor can change mid-run.
    for source in sorted(set(paths)):
        relative = source.relative_to(root)
        destination = snapshot / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        source_identity[str(relative)] = digest(destination)
        copied[source] = destination
    firmware_identity = {}
    # carry executable images and their original build metadata into the new evidence.
    for name in ('rom.hex', 'iram.hex', 'firmware.elf', 'build.json', 'symbols.json'):
        source = args.firmware.resolve() / name
        # optional diagnostic metadata is recorded when present.
        if source.exists():
            shutil.copy2(source, output / name)
            firmware_identity[name] = digest(output / name)
    # reject missing initialization rather than synthesize an empty program.
    if not {'rom.hex', 'iram.hex', 'firmware.elf'} <= firmware_identity.keys():
        raise RuntimeError('firmware requires rom.hex, iram.hex and firmware.elf')
    identities = {}
    # include the embedded routing database and every target mapping or packing database file.
    tool_inputs = [tools / 'libexec' / name for name in
                   ('yosys', 'yosys-abc', 'nextpnr-ecp5', 'ecppack', 'ecppll')]
    tool_inputs += [tools / 'bin/yosys', tools / 'lib/ld-linux-x86-64.so.2']
    tool_inputs += [path for folder in ('share/trellis/database', 'share/yosys')
                    for path in (tools / folder).rglob('*') if path.is_file()]
    # hash database bytes before starting either synthesis or routing.
    for source in sorted(set(tool_inputs)):
        identities[str(source.relative_to(tools))] = digest(source)
    save_json(output / 'tool-and-database-sha256.json', identities)
    result = {'target': 'LFE5U-85F-6BG381C', 'board': 'ULX3S v3.1.7 D&M',
              'clock_mhz': args.mhz, 'seed': args.seed, 'top': args.top,
              'stage': args.stage, 'route_clock_mhz': route_mhz,
              'guard_percent': args.guard_percent,
              'created_utc': datetime.now(timezone.utc).isoformat(),
              'source_sha256': source_identity, 'firmware_sha256': firmware_identity,
              'tool_database_manifest_sha256': digest(output / 'tool-and-database-sha256.json'),
              'routing_database': 'ECP5 chipdb embedded in hashed nextpnr-ecp5 executable',
              'assertions': 'ignored by synthesis only; simulation retains them',
              'hardware_tested': False, 'stages': {}, 'status': 'started'}
    save_json(output / 'summary.json', result)
    # versions supplement executable hashes; they never substitute for them.
    for name, arguments in (('yosys', ['-V']), ('nextpnr-ecp5', ['--version']),
                            ('ecppack', ['--help']), ('ecppll', ['--help'])):
        execute(commands[name] + arguments, output / (name + '-version.log'), output, env)
    pll = output / 'drg5_board_pll.v'
    command = commands['ecppll'] + ['-i', '25', '-o', str(args.mhz), '-n', 'drg5_board_pll',
               '--clkin_name', 'clk25_i', '--clkout0_name', 'clk_cpu_o', '-f', str(pll)]
    result['stages']['pll'] = execute(command, output / 'pll.log', output, env)
    # preserve generated settings while normalizing only their comment style and lock port name.
    if result['stages']['pll']['exit'] == 0:
        pll_text = pll.read_text().replace('locked', 'locked_o')
        pll_text = re.sub(r'(?m)^//[^\n]*\n', '', pll_text)
        pll_text = re.sub(r'//[^\n]*', lambda match: match.group().lower().replace('mhz', 'MHz'), pll_text)
        pll_text = pll_text.replace('EHXPLLL #(', '/* preserve the generated feedback and divider configuration. */\nEHXPLLL #(')
        pll.write_text('/* generate the requested clock from the 25 MHz oscillator. */\n' + pll_text)
        result['generated_pll_sha256'] = digest(pll)
    # a failed PLL search cannot supply a routable frequency candidate.
    else:
        result['status'] = 'pll-failed'
        save_json(output / 'summary.json', result)
        return 1
    rtl = snapshot / 'microcontroller/rtl'
    sources = [rtl / 'drg5_control_pkg.sv']
    sources += sorted(path for path in rtl.glob('*.sv') if path not in sources)
    sources += [copied[args.board.resolve()]] + [copied[path.resolve()] for path in args.extra_source]
    netlist = output / 'mapped.json'
    script = (f'read_verilog -lib +/ecp5/cells_bb.v; read_verilog {pll}; '
              f'read_slang --extern-modules --ignore-assertions --top {args.top} '
              f'-G CLOCK_HZ={round(args.mhz * 1000000)} -G STAGE={args.stage} -I {rtl} '
              + ' '.join(str(path) for path in sources)
              + '; hierarchy -check; proc; opt; check -assert; '
              'select -assert-none t:$dlatch t:$adlatch; '
              f'synth_ecp5 -noabc9 -top {args.top}; check -assert; stat; '
              f'write_json {netlist}')
    (output / 'synthesis.ys').write_text(script + '\n')
    result['stages']['synthesis'] = execute(commands['yosys'] + ['-Q', '-T', '-m', 'slang',
        '-s', str(output / 'synthesis.ys')], output / 'synthesis.log', output, env)
    # failed synthesis is a completed negative result, never a route candidate.
    if result['stages']['synthesis']['exit'] != 0:
        result['status'] = 'synthesis-failed'
        save_json(output / 'summary.json', result)
        return 1
    result['mapping'] = primitive_summary(netlist, args.top)
    result['synthesis_warnings'] = [line for line in (output / 'synthesis.log').read_text().splitlines()
                                    if 'Warning:' in line]
    result['status'] = 'synthesized'
    save_json(output / 'summary.json', result)
    # standalone mapping can diagnose memories before a complete board route.
    if args.synthesis_only:
        return 0
    report = output / 'route.json'
    config = output / 'route.config'
    mapped = json.loads(netlist.read_text())['modules'][args.top]
    clock_bits = {cell['connections']['CLKOP'][0] for cell in mapped['cells'].values()
                  if cell['type'] == 'EHXPLLL'}
    # constrain the actual PLL output net explicitly; --freq alone cannot override a derived clock.
    if len(clock_bits) != 1:
        raise RuntimeError('exactly one PLL output clock is required')
    clock_bit = next(iter(clock_bits))
    aliases = [name for name, net in mapped['netnames'].items() if net['bits'] == [clock_bit]]
    clock_name = min(aliases, key=len)
    lpf = output / 'route.lpf'
    lpf.write_text(copied[args.lpf.resolve()].read_text() +
                   f'\n# reserve {args.guard_percent:g}% of the CPU period for implementation margin.\n'
                   f'FREQUENCY NET "{clock_name}" {route_mhz:.9f} MHZ;\n')
    result['clock_constraint_net'] = clock_name
    result['route_lpf_sha256'] = digest(lpf)
    command = commands['nextpnr-ecp5'] + ['--85k', '--package', 'CABGA381', '--speed', '6',
        '--seed', str(args.seed), '--freq', str(route_mhz), '--json', str(netlist),
        '--lpf', str(lpf), '--report', str(report),
        '--write', str(output / 'route-design.json'),
        '--detailed-timing-report', '--textcfg', str(config)]
    result['stages']['route'] = execute(command, output / 'route.log', output, env)
    result['route_diagnostics'] = [line for line in (output / 'route.log').read_text().splitlines()
                                  if any(word in line.lower() for word in ('warning:', 'error:', 'clock', 'mhz'))]
    # retain reports even when timing fails; never pack a failed route.
    if report.exists():
        timing = json.loads(report.read_text())
        result['routing'] = {key: value for key, value in timing.items()
                             if key in ('utilization', 'fmax', 'critical_paths')}
        result['route_report_sha256'] = digest(report)
        constraints = [clock['constraint'] for clock in timing.get('fmax', {}).values()]
        result['guard_constraint_verified'] = any(abs(value - route_mhz) < 0.001 for value in constraints)
        # a successful route must actually have analyzed the requested CPU guardband.
        if result['stages']['route']['exit'] == 0 and not result['guard_constraint_verified']:
            result['status'] = 'clock-constraint-mismatch'
            save_json(output / 'summary.json', result)
            return 1
    # timing or placement failure never proceeds to bitstream packing.
    if result['stages']['route']['exit'] != 0:
        result['status'] = 'route-failed'
        save_json(output / 'summary.json', result)
        return 1
    bitstream = output / 'drg5.bit'
    result['stages']['pack'] = execute(commands['ecppack'] + ['--db', str(tools / 'share/trellis/database'),
        '--compress', str(config), str(bitstream)],
                                       output / 'pack.log', output, env)
    # a packed configuration remains a candidate until actual board testing succeeds.
    if result['stages']['pack']['exit'] == 0:
        result['status'] = 'routed-and-packed-hardware-unverified'
        result['route_config_sha256'] = digest(config)
        result['bitstream_sha256'] = digest(bitstream)
        result['route_design_sha256'] = digest(output / 'route-design.json')
    # retain an unsuccessful pack as an explicit failure.
    else:
        result['status'] = 'pack-failed'
    save_json(output / 'summary.json', result)
    return result['stages']['pack']['exit']


# importing the driver never launches tools.
if __name__ == '__main__':
    sys.exit(main())

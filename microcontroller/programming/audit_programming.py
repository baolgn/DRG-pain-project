#!/usr/bin/env python3
"""audit final programming evidence without accessing hardware or changing artifacts."""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
ROM_SHA256 = 'ada6dda5a9c97670c226d04390773f3a3ad6ab62ed2681f1785342778501eb7f'
ROM_CRC32 = 0x7309d786
ROUTE = 'route-final25-r2'


def require(condition, reason):
    """stop on missing or inconsistent evidence."""
    # absent evidence never receives a passing result.
    if not condition:
        raise ValueError(reason)


def digest(path):
    """bind an existing artifact to its exact bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    """read one required structured record."""
    return json.loads(Path(path).read_text())


def sources(mapping, snapshot=None):
    """check active sources and any recorded build snapshots."""
    require(bool(mapping), 'empty source attribution')
    # snapshots must match both the recorded digest and the active implementation.
    for name, expected in mapping.items():
        require(digest(ROOT / name) == expected, 'changed source: ' + name)
        # only cohorts with snapshots claim a preserved source copy.
        if snapshot is not None:
            require(digest(snapshot / name) == expected, 'changed snapshot: ' + name)


def artifacts(directory, mapping):
    """check every named immutable artifact."""
    require(bool(mapping), 'empty artifact attribution')
    # hashing uses the file contents, never a summary's pass label.
    for name, expected in mapping.items():
        require(digest(directory / name) == expected, 'changed artifact: ' + str(directory / name))


def rom_bytes(path):
    """decode the fixed little-endian ROM word image independently."""
    words = Path(path).read_text().split()
    require(len(words) == 2048 and all(re.fullmatch('[0-9a-fA-F]{8}', word) for word in words), 'ROM shape')
    data = b''.join(struct.pack('<I', int(word, 16)) for word in words)
    require(hashlib.sha256(data).hexdigest() == ROM_SHA256 and zlib.crc32(data) == ROM_CRC32, 'canonical ROM ABI')
    return data


def bank(data, generation):
    """independently validate a complete committed application bank."""
    require(len(data) == 0x20000, 'bank size')
    words = struct.unpack('<64I', data[:256])
    require(words[:6] == (0x35475244, 1, 65536, 0x10000, 0x10000, generation), 'bank fixed fields')
    require(words[7:9] == (ROM_CRC32, 1) and not any(words[9:62]) and words[63] == 0, 'bank ABI/reserved fields')
    require(words[62] == zlib.crc32(data[:248]), 'header CRC')
    require(words[6] == zlib.crc32(data[256:65792]), 'payload CRC')
    require(data[65792:-4] == b'\xff' * (len(data) - 65796), 'bank erased padding')
    require(data[-4:] == b'CMIT', 'bank commit')
    return data[256:65792]


def route_audit(evidence):
    """bind the exact routed target, constraints, memory contents and bitstream."""
    directory = evidence / ROUTE
    record = read(directory / 'summary.json')
    require(record['status'] == 'routed-and-packed-hardware-unverified' and not record['hardware_tested'], 'route scope')
    require(record['target'] == 'LFE5U-85F-6BG381C' and record['board'] == 'ULX3S v3.1.7 D&M', 'exact target')
    require(record['top'] == 'drg5_ulx3s_programmable' and record['stage'] == 2 and record['clock_mhz'] == 25, 'route profile')
    require(record['guard_percent'] == 10 and record['guard_constraint_verified'], 'timing guard')
    sources(record['source_sha256'], directory / 'inputs')
    artifacts(directory, {'drg5.bit': record['bitstream_sha256'], 'mapped.json': record['mapping']['netlist_sha256'],
        'route.json': record['route_report_sha256'], 'route-design.json': record['route_design_sha256'],
        'route.config': record['route_config_sha256'], 'route.lpf': record['route_lpf_sha256'],
        'drg5_board_pll.v': record['generated_pll_sha256'],
        'tool-and-database-sha256.json': record['tool_database_manifest_sha256'], **record['firmware_sha256']})
    # each stage retains its own successful command and unmodified diagnostic log.
    for name, stage in record['stages'].items():
        require(stage['exit'] == 0, 'failed route stage: ' + name)
        artifacts(directory, {stage['log']: stage['log_sha256']})
    command = record['stages']['route']['command']
    require('--85k' in command and command[command.index('--package') + 1] == 'CABGA381' and
            command[command.index('--speed') + 1] == '6', 'exact routing device')
    require(not any(flag in command for flag in ['--timing-allow-fail', '--lpf-allow-unconstrained']), 'routing bypass')
    require(abs(float(command[command.index('--freq') + 1]) - 25 / 0.9) < 0.0001, 'routing frequency')
    routed = read(directory / 'route.json')
    require(all(value == routed[key] for key, value in record['routing'].items()) and
            len(routed['fmax']) == 1, 'route report attribution')
    clock = next(iter(routed['fmax'].values()))
    require(abs(clock['constraint'] - 25 / 0.9) < 0.0001 and clock['achieved'] >= clock['constraint'], 'guarded timing failed')
    script = (directory / 'synthesis.ys').read_text()
    require('-G CLOCK_HZ=25000000 -G STAGE=2' in script and '--top drg5_ulx3s_programmable' in script, 'synthesis profile')
    # every compiled repository source must come from the checked private snapshots.
    for name in record['source_sha256']:
        # include headers, constraints and the driver are attributed separately.
        if name.endswith('.sv'):
            require(str(directory / 'inputs' / name) in script, 'unattributed synthesis source: ' + name)
    mapped = read(directory / 'mapped.json')['modules']['drg5_ulx3s_programmable']
    cells = mapped['cells']; counts = dict(Counter(cell['type'] for cell in cells.values()))
    require(counts == record['mapping']['cells'], 'native cell attribution')
    require(all(counts.get(kind) == count for kind, count in
                {'DP16KD': 48, 'MULT18X18D': 4, 'EHXPLLL': 1, 'USRMCLK': 1}.items()), 'required native primitives')
    pll = next(cell['parameters'] for cell in cells.values() if cell['type'] == 'EHXPLLL')
    frequency = 25 * int(pll['CLKFB_DIV'], 2) / int(pll['CLKI_DIV'], 2)
    require(pll['FEEDBK_PATH'] == 'CLKOP' and frequency == 25 and
            400 <= frequency * int(pll['CLKOP_DIV'], 2) <= 800, 'physical PLL frequency')
    iram = [cell for name, cell in cells.items() if 'fabric.iram.' in name and cell['type'] == 'DP16KD']
    require(len(iram) == 32, 'IRAM native mapping')
    # actual mapped initialization must contain no application instructions.
    for cell in iram:
        initial = [value for key, value in cell['parameters'].items() if key.startswith('INITVAL_')]
        require(len(initial) == 64 and all(set(value) <= {'0'} for value in initial), 'embedded IRAM application')
    system = (ROOT / 'microcontroller/rtl/drg5_programmable_system.sv').read_text()
    require('.IRAM_FILE("")' in system, 'IRAM source initialization')
    require(not any('debug_module' in name or 'debug_transport' in name for name in cells), 'unexpected debug integration')
    require(set(mapped['ports']) == {'clk25_i', 'reset_btn_i', 'event_btn_i', 'flash_miso_i',
            'led_o', 'uart_tx_o', 'flash_cs_n_o', 'flash_mosi_o', 'flash_hold_n_o', 'flash_wp_n_o'}, 'board interface scope')
    rom_bytes(directory / 'rom.hex')
    return {'directory': ROUTE, 'bitstream_sha256': record['bitstream_sha256'],
            'firmware_sha256': record['firmware_sha256'], 'actual_clock_mhz': 25,
            'constraint_mhz': clock['constraint'], 'achieved_mhz': clock['achieved'],
            'utilization': routed['utilization'], 'native_cells': counts, 'iram_initialized_to_zero': True}


def trace_audit(directory, run, schema):
    """recount ordered retirement, traps and interrupts in each reset epoch."""
    label = run['case'] + '-' + str(run['seed'])
    data = gzip.decompress((directory / (label + '.jsonl.gz')).read_bytes())
    require(hashlib.sha256(data).hexdigest() == run['trace_sha256'], 'trace hash: ' + label)
    log = (directory / (label + '.log')).read_text()
    epochs = [json.loads(line.split(' ', 1)[1]) for line in log.splitlines() if line.startswith('PROGRAMMING_EPOCH_PASS ')]
    require(epochs == run['epochs'] and log.count('PROGRAMMING_SIM_PASS') == 1, 'epoch log: ' + label)
    observed = {}; ended = set(); current = None; last_cycle = -1
    # reset markers separate architectural order spaces without hiding a hung epoch.
    for line in data.splitlines():
        row = json.loads(line)
        # each epoch starts exactly once and resets the retirement index.
        if 'epoch' in row:
            current = row['epoch']; require(current not in observed, 'duplicate epoch')
            observed[current] = {'retired': 0, 'traps': 0, 'irqs': 0}; last_cycle = -1
        # retirement records include trapping instructions but count them separately.
        elif 'packed' in row:
            require(current is not None and current not in ended and row['cycle'] > last_cycle, 'trace cycle order')
            last_cycle = row['cycle']; value = int(row['packed'], 16)
            fields = {name: (value >> definition['lsb']) & ((1 << definition['width']) - 1)
                      for name, definition in schema['fields'].items()}
            counts = observed[current]
            require(fields['valid'] == 1 and fields['order'] == counts['retired'] + counts['traps'], 'retirement order')
            counts['traps' if fields['trap'] else 'retired'] += 1
        # interrupt observations are independent of ordinary retirement records.
        elif 'irq_cycle' in row:
            require(current is not None and current not in ended, 'interrupt outside epoch')
            observed[current]['irqs'] += 1
        # an empty-flash failure must retain reset before any architectural event.
        elif 'boot_fault' in row:
            require(current is not None and row['boot_fault'] == 1 and not any(observed[current].values()), 'boot fault trace')
        # successful epochs end normally; failed epochs are terminated by the next reset marker.
        elif 'end_epoch' in row:
            require(row['end_epoch'] == current and current not in ended, 'epoch end')
            ended.add(current)
        # reject unrecognized event formats rather than silently dropping them.
        else:
            raise ValueError('unknown trace row: ' + label)
    require(set(observed) == {epoch['epoch'] for epoch in epochs} and
            ended == {epoch['epoch'] for epoch in epochs if epoch['outcome'] == 'firmware-pass'}, 'trace epoch coverage')
    # successful firmware claims must agree with independently counted trace events.
    for epoch in epochs:
        require(epoch['boot_cycles'] < 9000000, 'boot completion bound')
        counts = observed[epoch['epoch']]
        # a rejected application must execute no instructions at all.
        if epoch['outcome'] == 'reset-held':
            require(not any(counts.values()), 'rejected application executed')
        # successful execution must match its published event counts.
        elif epoch['outcome'] == 'firmware-pass':
            require(all(counts[key] == epoch[key] for key in counts), 'trace count mismatch')
            require(epoch['boot_words'] in [16384, 32768] and epoch['bank'] in [0, 1], 'boot write count')
        # a CRC-valid semantic failure remains executable until recovery reset.
        else:
            require(epoch['outcome'] == 'damaged-app-hang' and counts['retired'] > 0, 'hung fixture did not execute')
    return observed


def simulation_audit(evidence, route):
    """review boot, image corruption and executable recovery campaigns."""
    boot = read(evidence / 'boot-final/summary.json')
    require(boot['status'] == 'passed' and boot['source_stable'] and boot['build_exit'] == boot['run_exit'] == 0, 'boot campaign')
    sources(boot['source_sha256'], evidence / 'boot-final/sources')
    text = (evidence / 'boot-final/run.log').read_text()
    cases = re.findall(r'^BOOT_CASE_PASS (\S+) clocks=(\d+) writes=(\d+) transactions=(\d+) reason=(\d+)$', text, re.M)
    require(len(cases) == len({case[0] for case in cases}) == 24 and text.count('SPI_BOOT_PASS cases=24') == 1, 'boot fixture coverage')
    require(all(int(case[1]) < 9000000 for case in cases), 'boot fixture bound')
    images = read(evidence / 'image-final-r2/summary.json')
    require(images['status'] == 'passed' and images['checks'] == sum(images['groups'].values()) == 72959, 'image campaign')
    sources(images['source_sha256'])
    require(set(images['artifacts']) == {'golden.bin', 'application.bin', 'corrupt-application.bin',
            'hung-application.bin', 'repaired-application.bin', 'staged.bin', 'commit-sector.bin'}, 'image artifact coverage')
    artifacts(evidence / 'image-final-r2', images['artifacts'])
    require(images['rom_crc32'] == ROM_CRC32 and images['firmware_audit']['elf_sha256'] == route['firmware_sha256']['firmware.elf'], 'image firmware attribution')
    directory = evidence / 'integration-final'; integration = read(directory / 'summary.json')
    require(integration['status'] == 'passed' and integration['source_stable'], 'integration campaign')
    sources(integration['source_sha256'], directory / 'sources')
    require(integration['firmware_elf_sha256'] == route['firmware_sha256']['firmware.elf'], 'integration firmware')
    require('-GCLOCK_HZ=25000000' in integration['command'] and not any('IRAM_FILE' in arg for arg in integration['command']), 'integration profile')
    # both compiled simulations retained assertions and treated warnings as failures.
    for name, record in [('boot-final', boot), ('integration-final', integration)]:
        require('--assert' in record['command'] and '-Wall' in record['command'] and
                not any(arg.startswith('-Wno') for arg in record['command']), 'simulation warning policy')
        require('%Warning' not in (evidence / name / 'build.log').read_text(), 'simulation warnings')
    runs = integration['runs']
    require(len(runs) == 9 and sum(len(run['epochs']) for run in runs) == 12 and
            all(run['passed'] and run['exit'] == 0 for run in runs), 'integration coverage')
    require(Counter(run['case'] for run in runs) == Counter({'golden': 2, 'updated': 2, 'payload-fallback': 1,
            'torn-commit': 1, 'forced-golden': 1, 'damaged-hang-recovery': 1, 'empty-repair': 1}), 'recovery scenarios')
    identities = {(run['case'], run['seed']) for run in runs}
    expected = {(name, seed) for name in ['golden', 'updated'] for seed in [1, 305419896]}
    expected |= {(name, 1) for name in ['payload-fallback', 'torn-commit', 'forced-golden', 'damaged-hang-recovery', 'empty-repair']}
    require(identities == expected and len(identities) == len(runs), 'recovery seed coverage')
    schema = read(directory / 'trace-schema.json')
    require(schema['schema'] == 'DRG5-ARCH1' and schema['packed_bits'] == 700 and
            schema['package_sha256'] == digest(ROOT / 'microcontroller/rtl/drg5_control_pkg.sv'), 'trace schema attribution')
    traces = {run['case'] + '-' + str(run['seed']): trace_audit(directory, run, schema) for run in runs}
    rom_bytes(directory / 'rom.hex')
    return {'boot_cases': len(cases), 'image_checks': images['checks'], 'image_groups': images['groups'],
            'integration_runs': len(runs), 'integration_epochs': 12, 'trace_counts': traces}


def host_audit(evidence, route):
    """check host safety fixtures, fixed build guards and concrete unexecuted plans."""
    host = read(evidence / 'host-tool-service-r5/summary.json')
    require(host['schema'] == 'DRG5-HOST-PROGRAMMING-TEST-1' and host['status'] == 'pass' and
            host['count'] == len(host['cases']) == 36 and all(case['status'] == 'pass' for case in host['cases']), 'host suite')
    require(len({case['name'] for case in host['cases']}) == len(host['cases']), 'host fixture uniqueness')
    sources(host['source_sha256'])
    require(any(case['name'] == 'self-consistent-alternate-ROM-rejected' and case['error_detected'] for case in host['cases']), 'host canonical ROM guard')
    profile_cases = {'stage-zero-rejected', 'changed-core-clock-rejected', 'missing-clock-guard-rejected',
                     'wrong-route-clock-rejected', 'wrong-guard-percent-rejected'}
    rejected = [case for case in host['cases'] if case['name'] in profile_cases]
    require({case['name'] for case in rejected} == profile_cases and all(case['error_detected'] and
            not case['phases'] for case in rejected), 'host fixed-profile guards')
    guard = read(evidence / 'build-guard-final-r3/summary.json')
    require(guard['status'] == 'passed' and len(guard['cases']) == 3 and all(case['passed'] for case in guard['cases']), 'build guards')
    require({case['case']: case['exit'] for case in guard['cases']} == {'valid': 0, 'alternate-rom': 1, 'stage-override': 2}, 'build rejection coverage')
    sources(guard['source_sha256'])
    preflight_directory = evidence / 'build-guard-final-r3/valid'
    preflight = read(preflight_directory / 'qualification.json')
    require(preflight['status'] == 'preflight-only' and not preflight['hardware_tested'] and
            preflight['profile'] == 'P25-SPI-BOOT-1', 'wrapper scope')
    sources(preflight['source_sha256'], preflight_directory / 'sources')
    require({'microcontroller/tests/audit_firmware.py', 'microcontroller/tests/run_decompress.py'} <=
            set(preflight['source_sha256']), 'nested firmware validator attribution')
    artifacts(Path('/'), preflight['firmware_tool_sha256'])
    command = preflight['route_command']
    require(all(command[command.index(key) + 1] == value for key, value in
                {'--stage': '2', '--mhz': '25', '--guard-percent': '10', '--top': 'drg5_ulx3s_programmable'}.items()), 'wrapper fixed profile')
    require(preflight['rom_byte_sha256'] == ROM_SHA256 and preflight['rom_crc32'] == ROM_CRC32, 'wrapper ROM ABI')
    require(preflight['firmware']['elf_sha256'] == route['firmware_sha256']['firmware.elf'], 'wrapper firmware attribution')
    rom_bytes(preflight_directory / 'firmware/rom.hex')
    payload = None; packages = {}
    # generations one and two use the same independently audited application bytes.
    for name, generation in [('golden-package-final', 1), ('application-package-final', 2)]:
        directory = evidence / name; package = read(directory / 'package.json')
        require(package['schema'] == 'DRG5-FLASH-IMAGE-1' and package['generation'] == generation and
                package['rom_sha256'] == ROM_SHA256 and package['rom_crc32'] == ROM_CRC32, 'package ABI')
        require(package['slots'] == {'A': 0x400000, 'B': 0x420000} and
                package['bank_size'] == 0x20000 and package['commit_sector_offset'] == 0x1f000, 'flash layout')
        require(set(package['artifacts']) == {'bank.bin', 'staged.bin', 'commit-sector.bin'}, 'package artifact coverage')
        artifacts(directory, package['artifacts'])
        require(package['audit']['elf_sha256'] == route['firmware_sha256']['firmware.elf'] and
                package['audit']['manifest_sha256'] == route['firmware_sha256']['build.json'] and
                package['audit']['ISA_audit']['profile'] == 'imc', 'package firmware attribution')
        data = (directory / 'bank.bin').read_bytes(); decoded = bank(data, generation)
        require(payload is None or decoded == payload, 'application payload identity'); payload = decoded
        expected = b''.join(struct.pack('<I', int(word, 16)) for word in (evidence / ROUTE / 'iram.hex').read_text().split())
        require(decoded == expected, 'package payload differs from compiled firmware')
        require((directory / 'staged.bin').read_bytes() == data[:-4096] + b'\xff' * 4096, 'staged image')
        require((directory / 'commit-sector.bin').read_bytes() == b'\xff' * 4092 + b'CMIT', 'commit sector')
        packages[name] = package['artifacts']['bank.bin']
    fixtures = evidence / 'integration-final'
    a = (evidence / 'golden-package-final/bank.bin').read_bytes()
    b = (evidence / 'application-package-final/bank.bin').read_bytes()
    require((fixtures / 'a.bin').read_bytes() == a and (fixtures / 'b.bin').read_bytes() == b, 'integration package identity')
    require(bank((fixtures / 'repaired.bin').read_bytes(), 3) == payload, 'repaired application identity')
    require(bank((fixtures / 'hang.bin').read_bytes(), 2) == struct.pack('<I', 0x6f) + payload[4:], 'hung application fixture')
    damaged = bytearray(b); damaged[273] ^= 1
    require((fixtures / 'damaged.bin').read_bytes() == damaged and
            (fixtures / 'staged.bin').read_bytes() == b[:-4096] + b'\xff' * 4096 and
            (fixtures / 'empty.bin').read_bytes() == b'\xff' * 0x20000, 'recovery input fixtures')
    plans = read(evidence / 'plans-final-r2/summary.json')
    require(plans['host_source_sha256'] == digest(ROOT / 'microcontroller/programming/program_board.py'), 'plan driver identity')
    require(plans['status'] == 'six-concrete-plans-ready-hardware-not-executed' and len(plans['plans']) == 6, 'plan scope')
    modes = {'config-sram', 'config-flash', 'update-firmware', 'restore-golden', 'invalidate-application', 'qualify-corrupt-b'}
    require({item['mode'] for item in plans['plans']} == modes, 'programming paths')
    # plans contain actual candidate files but never impersonate completed device operations.
    for item in plans['plans']:
        directory = evidence / 'plans-final-r2' / item['mode']; operation = read(directory / 'operation.json')
        require(item['status'] == operation['status'] == 'plan-ready' and
                item['executed'] is operation['executed'] is False and not operation['commands'] and
                not operation['persistent_write_launched'] and not operation['hardware_boot_validated'], 'unexecuted plan')
        require(item['configuration_sha256'] == operation['configuration_sha256'] ==
                digest(directory / 'configuration.bit') == route['bitstream_sha256'], 'plan bitstream identity')
        require(digest(directory / 'route-summary.json') == digest(evidence / ROUTE / 'summary.json'), 'plan route attribution')
        rom_bytes(directory / 'boot-rom.hex')
        inventory = read(directory / 'inventory.json')
        require(inventory['physical_inspection_verified'] is False and inventory['part'] == 'LFE5U-85F-6BG381C' and
                inventory['board'] == 'ULX3S v3.1.7 D&M' and inventory['flash_jedec_id'] == '0xef4018', 'inventory scope')
        # bank programming plans must use the validated concrete package for their slot.
        if item['mode'] in ['update-firmware', 'restore-golden']:
            name = 'application-package-final' if item['mode'] == 'update-firmware' else 'golden-package-final'
            require(digest(directory / 'bank.bin') == packages[name] == operation['bank']['sha256'], 'plan bank identity')
    return {'host_cases': 36, 'build_guard_cases': 3, 'wrapper_status': 'preflight-only; final route used generic runner',
            'packages': packages, 'plans': sorted(modes), 'plans_executed': False}


def requirements():
    """separate demonstrated software properties from outstanding physical acceptance."""
    rows = [
        ('CFG-SRAM', 'volatile configuration path', 'host-model-and-plan', ['host-tool-service-r5', 'plans-final-r2/config-sram']),
        ('CFG-FLASH', 'persistent FPGA configuration with protected application banks', 'host-model-and-plan', ['host-tool-service-r5', 'plans-final-r2/config-flash']),
        ('FW-SEPARATE', 'separate IRAM application update without embedding code in the bitstream', 'route-and-simulation', [ROUTE, 'integration-final', 'application-package-final']),
        ('FW-VALIDATE', 'fixed ABI, header/payload CRC, commit and exact ROM compatibility', 'simulation-and-host-model', ['boot-final', 'image-final-r2', 'host-tool-service-r5', 'build-guard-final-r3']),
        ('FW-POWER-CUT', 'commit-last recovery and golden protection under modeled interruption', 'model-only', ['image-final-r2', 'host-tool-service-r5']),
        ('FW-RECOVERY', 'corrupt image fallback, forced golden and hung-program replacement', 'RTL-simulation', ['boot-final', 'integration-final']),
        ('FW-OWNERSHIP', 'one completed IRAM write per request; timeout retains owner without replay', 'RTL-simulation', ['boot-final', 'integration-final']),
        ('FW-BOOT-BOUND', 'completion or fault within 9000000 clocks under specified service bounds', 'review-and-simulation', ['boot-final', 'integration-final']),
        ('TARGET-ROUTE', 'exact 85F BG381 speed-6 target; 25 MHz clock with ten-percent guard', 'route-only', [ROUTE]),
        ('DEBUG-SEPARATION', 'configuration recovery independent of CPU debug; no DM/DTM in this top', 'source-and-netlist', [ROUTE, 'host-tool-service-r5']),
        ('HW-PROGRAM', 'manufacturing programming on the exact inspected board and programmer', 'unverified', ['hardware/discovery.json']),
        ('HW-BOOT', 'power-cycle into valid firmware on physical flash', 'unverified', ['hardware/discovery.json']),
        ('HW-RECOVER', 'recover from intentionally damaged and hung applications on hardware', 'unverified', ['hardware/discovery.json']),
        ('HW-TIMING', 'flash pad/board timing, reset release and clock-domain reliability', 'unverified', ['hardware/discovery.json']),
    ]
    return [{'id': identity, 'requirement': requirement, 'evidence_level': level, 'artifacts': paths,
             'physical_pass': False} for identity, requirement, level, paths in rows]


def audit(evidence):
    """review the frozen campaign without launching tools or modifying evidence."""
    evidence = Path(evidence).resolve()
    rom_bytes(ROOT / 'microcontroller/programming/boot-rom.hex')
    route = route_audit(evidence)
    simulations = simulation_audit(evidence, route)
    host = host_audit(evidence, route)
    discovery = read(evidence / 'hardware/discovery.json')
    require(discovery['status'] == 'hardware_unqualified' and not discovery['configuration_write_attempted'] and
            not discovery['expected_idcode_observed'] and not discovery['physical_board_revision_verified'], 'hardware evidence scope')
    return {'schema': 'DRG5-PROGRAMMING-AUDIT-1', 'artifact_consistency_passed': True, 'overall_pass': False,
            'hardware_unverified': True, 'debug_integrated': False, 'acquisition_integrated': False,
            'evidence_directory': str(evidence), 'source_sha256': {str(Path(__file__).resolve().relative_to(ROOT)): digest(__file__)},
            'route': route, 'simulations': simulations, 'host': host, 'requirements': requirements(),
            'boot_bound': {'clocks': 9000000, 'milliseconds_at_25mhz': 360, 'spi_half_period_clocks': 2,
                'completed_write_limit_clocks': 128, 'uncertain_timeout': 'fault holds CPU reset and retains write owner until response or isolated global reset'},
            'limitations': ['no physical programming, power-cycle or damaged-image recovery evidence',
                'external SPI timing, board identity, reset distribution and CDC remain unqualified',
                'CPU debug DM/DTM, acquisition, DMA and external memory are absent from this top',
                'CRC validates received bytes; no authentication, IRAM readback or ECC claim',
                'boot bound assumes continuous 25 MHz clock and completed local writes within 128 clocks',
                'wrapper preflight is supplemental; it does not claim another synthesis or route']}


def main():
    """write only explicitly requested reports, with no implicit evidence updates."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--matrix-output', type=Path)
    args = parser.parse_args()
    result = audit(args.evidence)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    # a separate matrix is optional; the main report always contains the same rows.
    if args.matrix_output:
        args.matrix_output.parent.mkdir(parents=True, exist_ok=True)
        args.matrix_output.write_text(json.dumps({'schema': 'DRG5-PROGRAMMING-MATRIX-1',
            'hardware_unverified': True, 'requirements': result['requirements']}, indent=2, sort_keys=True) + '\n')
    print('PROGRAMMING_ARTIFACT_AUDIT_PASS hardware_unverified overall_pass=false')


# importing the auditor performs no writes or hardware operations.
if __name__ == '__main__':
    main()

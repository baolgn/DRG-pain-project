#!/usr/bin/env python3
"""audit routed artifacts without promoting simulation into hardware evidence."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    """bind sources and artifacts to exact bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, reason):
    """reject the first missing or inconsistent qualification gate."""
    # incomplete evidence never receives a passing consistency result.
    if not condition:
        raise ValueError(reason)


def read(path):
    """load one required structured record."""
    return json.loads(path.read_text())


def sources(mapping):
    """verify every attributed source against the active implementation."""
    # build and test drivers are checked alongside RTL.
    for name, expected in mapping.items():
        require(digest(ROOT / name) == expected, 'changed source: ' + name)


def main():
    """review the final explicit candidates while retaining the unmet hardware pass condition."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    result = {'schema': 'DRG5-FPGA-AUDIT-1', 'overall_pass': False, 'routes': {}, 'simulations': {},
              'source_sha256': {str(Path(__file__).resolve().relative_to(ROOT)): digest(__file__)},
              'scope': 'P25 local-memory bring-up; no physical hardware or acquisition qualification',
              'open_gates': ['physical programming and simulation reproduction: no accessible target',
                  'F-80 timing failed; P25 cannot admit the 320000-cycle block workload',
                  'external timing, oscillator tolerance, reset recovery/removal and CDC reliability',
                  'debug DM/DTM and SBA physical integration',
                  'acquisition, external memory, payload transport and DSP integration',
                  'fixed generic CPU allocation and complete-system resource/workload acceptance']}
    # names select reviewed final cohorts, never whichever attempt happens to pass.
    for stage, name in enumerate(['final-stage0-r2', 'final-stage1-r2', 'final-stage2-r3']):
        directory = evidence / name
        record = read(directory / 'summary.json')
        require(record['status'] == 'routed-and-packed-hardware-unverified', name + ': route/pack')
        require(record['target'] == 'LFE5U-85F-6BG381C' and record['clock_mhz'] == 25, name + ': target/clock')
        require(record['stage'] == stage and record['guard_constraint_verified'], name + ': stage/guard identity')
        require(not record['hardware_tested'], name + ': unexpected hardware claim')
        sources(record['source_sha256'])
        artifacts = {'drg5.bit': record['bitstream_sha256'], 'mapped.json': record['mapping']['netlist_sha256'],
                     'route.json': record['route_report_sha256'], 'route.config': record['route_config_sha256'],
                     'route.lpf': record['route_lpf_sha256'], 'drg5_board_pll.v': record['generated_pll_sha256']}
        # configuration, netlist, constraints and timing must describe the same recorded candidate.
        for artifact, expected in artifacts.items():
            require(digest(directory / artifact) == expected, name + ': artifact ' + artifact)
        clocks = record['routing']['fmax']
        require(len(clocks) == 1, name + ': timed clock set')
        clock = next(iter(clocks.values()))
        require(abs(clock['constraint'] - 25 / 0.9) < 0.0001 and clock['achieved'] >= clock['constraint'], name + ': guarded timing')
        command = record['stages']['route']['command']
        require('--85k' in command and command[command.index('--package') + 1] == 'CABGA381' and
                command[command.index('--speed') + 1] == '6', name + ': exact P&R target')
        require(not any(value in command for value in ['--timing-allow-fail', '--lpf-allow-unconstrained']), name + ': bypass')
        pll = [value for value in record['mapping']['native_primitives'].values() if value['type'] == 'EHXPLLL']
        require(len(pll) == 1 and pll[0]['parameters']['FEEDBK_PATH'] == 'CLKOP', name + ': PLL feedback')
        parameters = pll[0]['parameters']
        frequency = 25 * int(parameters['CLKFB_DIV'], 2) / int(parameters['CLKI_DIV'], 2)
        require(frequency == 25 and 400 <= frequency * int(parameters['CLKOP_DIV'], 2) <= 800, name + ': PLL/VCO frequency')
        result['routes'][str(stage)] = {'directory': name, 'bitstream_sha256': record['bitstream_sha256'],
            'achieved_mhz': clock['achieved'], 'constraint_mhz': clock['constraint'],
            'utilization': record['routing']['utilization']}
    utilization = result['routes']['2']['utilization']
    # physical limits apply independently, without averaging unrelated resource classes.
    for name in ['TRELLIS_COMB', 'TRELLIS_FF', 'DP16KD', 'MULT18X18D']:
        require(utilization[name]['used'] <= int(0.7 * utilization[name]['available']), 'native capacity: ' + name)
    firmware = read(evidence / 'firmware-regression-final/summary.json')
    require(firmware['status'] == 'passed', 'firmware campaign')
    sources(firmware['source_sha256'])
    positive = [run for run in firmware['runs'] if not run['negative']]
    require(len(positive) == 12 and all(run['status'] == 'passed' for run in firmware['runs']), 'firmware matrix')
    require(len(firmware['isa_detector']) == 3 and all(run['status'] == 'passed' for run in firmware['isa_detector'].values()), 'ISA detector matrix')
    result['simulations']['firmware'] = {'positive_runs': 12, 'runtime_controls': len(firmware['runs']) - 12, 'isa_controls': 3,
        'retired': sum(run['observed']['retired'] for run in positive), 'traps': sum(run['observed']['traps'] for run in positive),
        'interrupts': sum(run['observed']['irqs'] for run in positive)}
    # physical serial decoding and a duplicate-event mutation complement retirement checks.
    for name in ['board-final-forwarded', 'board-final-interlocked']:
        board = read(evidence / name / 'summary.json')
        require(board['status'] == 'passed' and len(board['runs']) == 3 and all(run['passed'] for run in board['runs']), name)
        sources(board['sources'])
        require(board['firmware_sha256'] == read(evidence / 'final-stage2-r3/summary.json')['firmware_sha256']['firmware.elf'], name + ': image')
        result['simulations'][name] = board['runs']
    # endpoint effects and reset diagnostics have independent checkers.
    for name in ['fabric-regression', 'board-diagnostics-attempt2']:
        record = read(evidence / name / 'summary.json')
        require(record['status'] == 'passed', name)
        sources(record['source_sha256'])
        result['simulations'][name] = 'passed'
    uart = read(evidence / 'uart-final/summary.json')
    require(uart['pass'] and len(uart['runs']) == 3, 'UART matrix')
    sources(uart['sources'])
    result['simulations']['uart_checks'] = sum(run['checks'] for run in uart['runs'])
    latency = read(evidence / 'handler-latency.json')
    require(latency['measurement_complete'] and len(latency['runs']) == 4, 'handler measurement')
    sources(latency['source_sha256'])
    result['handler_latency'] = {key: latency[key] for key in ['maxima_cycles', 'finite_isr_800_cycle_limit_met',
                                                           'conservative_ack_640_cycle_limit_met']}
    # a reproducible finite diagnostic run may still fail a production service budget.
    if not latency['finite_isr_800_cycle_limit_met']:
        result['open_gates'].append('diagnostic external ISR reaches 845 cycles, exceeding the 800-cycle production limit')
    discovery = read(evidence / 'hardware/discovery.json')
    require(discovery['status'] == 'hardware_unqualified' and not discovery['configuration_write_attempted'], 'hardware scope')
    result['hardware'] = discovery['status']
    result['artifact_consistency_passed'] = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print('FPGA_ARTIFACT_AUDIT_PASS hardware_unqualified')


# importing the auditor performs no writes or hardware operations.
if __name__ == '__main__':
    main()

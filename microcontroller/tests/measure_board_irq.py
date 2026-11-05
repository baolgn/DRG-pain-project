#!/usr/bin/env python3
"""measure handler work from retained board traces without inferring missing arrival timestamps."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path


def digest(path):
    """identify every consumed trace, symbol map and packed-field schema."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """report exact trap, context-save, acknowledgement-retirement and MRET endpoints."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--schema', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    evidence = args.evidence.resolve()
    schema = json.loads(args.schema.read_text())
    report = {'source_sha256': {str(Path(__file__).resolve().relative_to(root)): digest(Path(__file__))},
              'clock_hz': 25000000, 'runs': [], 'scope': [
                  'finite local-memory firmware runs; no acquisition or hardware WCET proof',
                  'IRQ event marks trap CSR update; source arrival and eligibility are not captured here',
                  'first handler retirement follows decode; it is not the first-D timestamp',
                  'acknowledgement retirement conservatively follows accepted effect and response completion',
                  'software counters remain inhibited; timestamps use independent fabric edges']}
    # each final occupancy mode includes two independent unreset-state seeds.
    for name in ['board-final-forwarded', 'board-final-interlocked']:
        directory = evidence / name
        (directory / 'trace-schema.json').write_text(json.dumps(schema, indent=2) + '\n')
        build = json.loads((directory / 'build.json').read_text())
        symbols = build['symbols']
        # negative controls lack a complete architectural footer and are excluded explicitly.
        for seed in [1, 305419896]:
            path = directory / f'trace-{seed}.jsonl.gz'
            rows = [json.loads(line) for line in gzip.decompress(path.read_bytes()).decode().splitlines()]
            assert rows[-1].get('end'), 'incomplete board capture'
            runs = []; active = None
            # terminal timestamps preserve the original capture order.
            for row in rows[:-1]:
                # nested or abandoned IRQ contexts cannot silently merge their latency measurements.
                if row['event'] == 'irq':
                    assert active is None, 'overlapping IRQ contexts'
                    active = {'cause': row['cause'], 'entry_cycle': row['cycle']}
                # synchronous traps outside IRQ handling are outside this measurement scope.
                elif row['event'] == 'terminal' and active is not None:
                    packed = int(row['packed'], 16)
                    fields = {key: (packed >> item['lsb']) & ((1 << item['width']) - 1)
                              for key, item in schema['fields'].items()}
                    assert not fields['trap'], 'trap inside IRQ handler'
                    elapsed = row['cycle'] - active['entry_cycle']
                    # this endpoint follows fetch, decode and retirement of the first vector instruction.
                    if fields['packet.pc'] == symbols['trap_entry']:
                        active['first_handler_retirement_cycles'] = elapsed
                    # entry into C follows all assembly context stores and ABI setup.
                    if fields['packet.pc'] == symbols['trap_dispatch']:
                        active['assembly_context_saved_cycles'] = elapsed
                    address = fields['packet.mem_addr']
                    value = fields['packet.mem_wdata']
                    cause = active['cause'] & 31
                    # the first write deasserting this interrupt supplies a conservative completion endpoint.
                    if fields['packet.op'] == 2 and 'ack_retirement_cycles' not in active and (
                        (cause == 3 and address == 0x40001010 and value == 0) or
                        (cause == 7 and address == 0x4000100c and value == 0xffffffff) or
                        (cause == 11 and address == 0x40001014 and value in [2, 4])):
                        active['ack_retirement_cycles'] = elapsed
                    # MRET retirement restores eligibility and terminates exactly one handler interval.
                    if fields['packet.raw'] == 0x30200073:
                        active['complete_isr_cycles'] = elapsed
                        assert set(active) == {'cause', 'entry_cycle', 'first_handler_retirement_cycles',
                            'assembly_context_saved_cycles', 'ack_retirement_cycles', 'complete_isr_cycles'}, 'missing IRQ endpoint'
                        runs.append(active); active = None
            assert active is None and len(runs) == 4, 'missing IRQ work'
            report['runs'].append({'configuration': name, 'seed': seed, 'interrupts': runs,
                'trace_sha256': digest(path), 'schema_sha256': digest(directory / 'trace-schema.json'),
                'symbols_sha256': digest(directory / 'build.json')})
    measures = [item for run in report['runs'] for item in run['interrupts']]
    report['maxima_cycles'] = {key: max(item[key] for item in measures) for key in
        ['first_handler_retirement_cycles', 'assembly_context_saved_cycles', 'ack_retirement_cycles', 'complete_isr_cycles']}
    report['maxima_microseconds_nominal'] = {key: value / 25 for key, value in report['maxima_cycles'].items()}
    report['finite_isr_800_cycle_limit_met'] = report['maxima_cycles']['complete_isr_cycles'] <= 800
    report['conservative_ack_640_cycle_limit_met'] = report['maxima_cycles']['ack_retirement_cycles'] <= 640
    report['measurement_complete'] = True
    (evidence / 'handler-latency.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['maxima_cycles']))


# imports do not modify retained evidence.
if __name__ == '__main__':
    main()

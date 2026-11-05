#!/usr/bin/env python3
"""summarize native modes, critical paths and reset fanout from a completed candidate."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re


def digest(path):
    """bind review findings to the actual mapped and routed designs."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """inspect retained evidence without rerunning or modifying implementation tools."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    summary = json.loads((candidate / 'summary.json').read_text())
    mapped = json.loads((candidate / 'mapped.json').read_text())['modules'][summary['top']]
    packed = json.loads((candidate / 'route-design.json').read_text())['modules']['top']
    timing = json.loads((candidate / 'route.json').read_text())
    aliases, sinks = defaultdict(list), defaultdict(list)
    # recover source names for scalar wires and individual packed-register bits.
    for name, net in mapped['netnames'].items():
        # a vector index remains explicit when several fields share the same net.
        for index, bit in enumerate(net['bits']):
            aliases[bit].append(name + (f'[{index}]' if len(net['bits']) > 1 else ''))
    # count actual input-pin loads, excluding constant nets from fanout rankings.
    for name, cell in mapped['cells'].items():
        # each connected input pin consumes one logical load before placement.
        for port, bits in cell['connections'].items():
            # bidirectional and output pins are not sink loads.
            if cell['port_directions'].get(port) == 'input':
                # preserve cell identity so high fanout can be traced back to RTL.
                for bit in bits:
                    # constants have no sequential source and are audited separately by implementation.
                    if isinstance(bit, int):
                        sinks[bit].append({'cell': name, 'port': port, 'type': cell['type']})
    fanout = []
    # retain the largest signal loads without copying every cell from the full netlist.
    for bit, loads in sorted(sinks.items(), key=lambda item: len(item[1]), reverse=True)[:20]:
        fanout.append({'net': min(aliases[bit], key=len), 'loads': len(loads),
                       'types': dict(Counter(load['type'] for load in loads))})
    reset = {}
    # distinguish asynchronous assertion from the synchronized release distributed to the core.
    for name in ('reset_async', 'reset', 'clk_cpu'):
        bit = mapped['netnames'][name]['bits'][0]
        reset[name] = {'loads': len(sinks[bit]),
                       'types': dict(Counter(load['type'] for load in sinks[bit])),
                       'ports': dict(Counter(load['port'] for load in sinks[bit]))}
    synchronizers = {}
    # identify both event stages and both asynchronous-set reset-release stages after packing.
    for name, cell in packed['cells'].items():
        # ordinary synchronous CPU reset flops are excluded from this CDC review.
        if cell['type'] == 'TRELLIS_FF' and (cell['parameters'].get('SRMODE') == 'ASYNC' or
                any(signal in name for signal in ('event_meta_q', 'event_sync_q'))):
            synchronizers[name] = {'parameters': cell['parameters'],
                                    'location': cell['attributes'].get('NEXTPNR_BEL'),
                                    'source': cell['attributes'].get('src'),
                                    'connections': cell['connections']}
    # retain the actual interstage routing and pin-to-pin delay intervals from nextpnr.
    interstage = [entry for entry in timing['detailed_net_timings']
                  if entry['net'] in ('application.system.event_meta_q', 'reset_release_q[0]')]
    attributes = {name: net['attributes'] for name, net in packed['netnames'].items()
                  if name in ('application.system.event_meta_q', 'application.system.event_sync_q',
                              'reset_release_q[0]')}
    paths = []
    # every timing-domain pair remains visible, including asynchronous board endpoints.
    for path in timing['critical_paths']:
        segments = path['path']
        end = segments[-1]['to']['cell']
        entry = {'from': path['from'], 'to': path['to'],
                 'total_ns': sum(segment['delay'] for segment in segments),
                 'delay_by_type_ns': {kind: sum(segment['delay'] for segment in segments
                                               if segment['type'] == kind)
                                      for kind in sorted({segment['type'] for segment in segments})},
                 'start': segments[0]['from'], 'end': segments[-1]['to']}
        # mapped endpoint source locations identify the sequential RTL owner.
        if end in mapped['cells']:
            cell = mapped['cells'][end]
            entry['endpoint_source'] = cell['attributes'].get('src')
            entry['endpoint_q_aliases'] = [alias for bit in cell['connections'].get('Q', [])
                                           for alias in aliases[bit] if '_LUT' not in alias]
        paths.append(entry)
    modes = {}
    # keep final primitive control and clock connections while hashing bulky initial contents.
    for name, cell in packed['cells'].items():
        # macro modes are inspected after nextpnr packing, where tied pins may become mux parameters.
        if cell['type'] in {'DP16KD', 'MULT18X18D', 'EHXPLLL'}:
            parameters = cell.get('parameters', {})
            modes[name] = {'type': cell['type'],
                            'parameters': {key: value for key, value in parameters.items()
                                           if not key.startswith('INITVAL')},
                            'clock_ports': {key: value for key, value in cell['connections'].items()
                                            if key.startswith('CLK')},
                            'location': cell.get('attributes', {}).get('NEXTPNR_BEL')}
    result = {'candidate': str(candidate), 'source_sha256': summary['source_sha256'],
              'inputs_sha256': {name: digest(candidate / name) for name in
                                ('summary.json', 'mapped.json', 'route-design.json', 'route.json')},
              'review_script_sha256': digest(Path(__file__).resolve()),
              'native_cells': dict(Counter(cell['type'] for cell in packed['cells'].values())),
              'fmax': timing['fmax'], 'critical_paths': paths, 'largest_fanout': fanout,
              'reset_and_clock_loads': reset, 'post_pack_native_modes': modes,
              'synchronizer_cells': synchronizers, 'synchronizer_interstage_timing': interstage,
              'synchronizer_net_attributes': attributes,
              'synchronizer_scope': 'stages and routing are retained; async_reg attributes are visible on nets, but placer enforcement and metastability reliability are not certified',
              'hold_diagnostics': [line for line in (candidate / 'route.log').read_text().splitlines()
                                   if re.search(r'\bhold\b', line, re.IGNORECASE)],
              'hold_scope': 'retained nextpnr diagnostics only; not a separate all-corner hold or reset-recovery certificate',
              'physical_scope': 'no board measurements or programming result'}
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


# importing the reviewer never changes evidence.
if __name__ == '__main__':
    main()

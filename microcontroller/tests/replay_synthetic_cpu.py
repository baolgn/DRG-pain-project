#!/usr/bin/env python3
"""independently inspect complete retirement bytes, physical sample reads and synthetic DSP results."""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path


def require(condition, reason):
    """name the exact failed observation rather than accepting a truncated successful prefix."""
    # every malformed or inconsistent record fails replay.
    if not condition:
        raise ValueError('SYNTHETIC_REPLAY_FAILED ' + reason)


def sample(epoch, block, frame):
    """calculate channel-zero source values with unbounded Python integers and explicit truncation."""
    value = ((epoch * 0x9e3779b9) & 0xffffffff) ^ ((block * 0x045d9f3b) & 0xffffffff) ^ ((frame * 0x27d4eb2d) & 0xffffffff)
    value = ((value ^ (value >> 13)) * 0x85ebca6b) & 0xffffffff
    value ^= value >> 16
    return (value & 0x3ffff) - 131072


def replay(directory, schema_path):
    """cross-check immutable code, independent bus events and mathematical output for one completed run."""
    directory = Path(directory)
    result = json.loads((directory / 'result.json').read_text())
    require(result['status'] == 'pass', 'missing completed run')
    schema = json.loads(Path(schema_path).read_text()); fields = schema['fields']; stride = 8 + schema['words'] * 4
    memory = {}
    # instruction bits must come from the actual loaded images, including compressed halfwords.
    for name, base in [('rom.hex', 0), ('iram.hex', 0x10000)]:
        # word-image parsing reconstructs little-endian addressed bytes independently of the C++ loader.
        for index, word in enumerate((directory / name).read_text().splitlines()):
            # every byte has one immutable address in these nonoverlapping code regions.
            for lane, value in enumerate(int(word, 16).to_bytes(4, 'little')):
                memory[base + index * 4 + lane] = value
    rows = [json.loads(line) for line in (directory / 'events.jsonl').read_text().splitlines()]
    require([row['sequence'] for row in rows] == list(range(1, len(rows) + 1)), 'event continuity')
    require(all(a['cycle'] <= b['cycle'] for a, b in zip(rows, rows[1:])), 'event time order')
    reads = [row for row in rows if row['event'] == 'shared-read']
    counts = Counter(); last_cycle = 0; order = 0
    # a fixed record size and successful footer prohibit truncated compressed trace prefixes.
    with gzip.open(directory / 'retirement.bin.gz', 'rb') as stream:
        # consume complete terminals without materializing the whole execution record in memory.
        while raw := stream.read(stride):
            require(len(raw) == stride, 'truncated terminal')
            cycle = int.from_bytes(raw[:8], 'little'); packed = int.from_bytes(raw[8:], 'little')

            def field(name):
                """decode one field solely from the retained packed schema."""
                item = fields[name]
                return (packed >> item['lsb']) & ((1 << item['width']) - 1)

            require(cycle > last_cycle and field('valid') == 1, 'terminal time or validity')
            require(field('order') == order, 'retirement order')
            order += 1; last_cycle = cycle
            pc, length, bits = field('packet.pc'), field('packet.length'), field('packet.raw')
            require(length in (2, 4), 'instruction length')
            require(bits == sum(memory[pc + lane] << (8 * lane) for lane in range(length)), 'original instruction bytes')
            counts['records'] += 1; counts['compressed'] += length == 2; counts['traps'] += field('trap')
            # only the deliberately executed ECALL instructions may trap in this workload.
            if field('trap'):
                require(bits == 0x73 and field('packet.cause') == 11, 'unexpected architectural trap')
            counts['MUL'] += bits & 0xfe00707f == 0x02000033
            counts['DIVU'] += bits & 0xfe00707f == 0x02005033
            counts['MRET'] += bits == 0x30200073
            address = field('packet.mem_addr')
            # successful retiring sample loads must match their separately accepted physical read values.
            if 0x50001000 <= address < 0x50002000:
                index = counts['shared_loads']; require(index < len(reads), 'extra retiring shared load')
                row = reads[index]
                require(address == 0x50001000 + row['frame'] * 4 and field('value') == row['value'] and
                        row['cycle'] < cycle and field('rd_write'), 'shared bus and retirement mismatch')
                counts['shared_loads'] += 1
    require(counts['records'] == result['retirement_records'], 'terminal footer count')
    require(counts['shared_loads'] == len(reads) == sum(block['reads'] for block in result['blocks']), 'shared effect count')
    irq_count = sum(row['event'] == 'IRQ-entry' for row in rows)
    require(counts['MRET'] == irq_count + counts['traps'] and counts['traps'] == 2, 'trap transition count')
    require(counts['DIVU'] == result['blocks_released'] and counts['MUL'] == result['blocks_released'] * 32, 'executed DSP arithmetic count')
    block_count = 0
    # mathematical results are recalculated without using the shared native/RV firmware header.
    for block in result['blocks']:
        # reset-aborted DSP may have a committed prefix of sample loads, but can never release a result.
        if block.get('aborted'):
            prefix = [row for row in reads if row['block'] == block['id']]
            require(not block['DSP_end'] and [row['frame'] for row in prefix] == list(range(0, 16 * len(prefix), 16)), 'aborted sample prefix')
            require(sum(row['event'] == 'CPU-reset-abandon' and row['block'] == block['id'] for row in rows) == 1, 'reset ownership abandonment')
        # incomplete stop tails are transport records, not completed DSP jobs.
        if not block['DSP_end']:
            continue
        last = earlier = 0; energy = signature = 0
        actual_reads = [row for row in reads if row['block'] == block['id']]
        require([row['frame'] for row in actual_reads] == list(range(0, 256, 16)), 'sample identities')
        # each tap uses a widened signed intermediate and an explicitly wrapped accumulator.
        for index, row in enumerate(actual_reads):
            value = sample(block['epoch'], block['ordinal'], index * 16)
            require(row['value'] == value & 0xffffffff, 'physical sample value')
            filtered = value - 2 * last + earlier
            energy = (energy + filtered * filtered) & 0xffffffff
            signature = (signature + filtered * (index + 1)) & 0xffffffff
            earlier = last; last = value
        require((block['energy'], block['signature'], block['quotient']) == (energy, signature, energy // 17), 'independent DSP result')
        releases = [row for row in rows if row['event'] == 'MMIO' and row['offset'] == 24 and row['value'] == block['id']]
        require(len(releases) == 1 and releases[0]['cycle'] == block['DSP_end'], 'physical release count')
        block_count += 1
    require(block_count == result['blocks_released'], 'completed block count')
    return {'schema': 'DRG5-SYNTHETIC-REPLAY-1', 'status': 'pass', 'counts': dict(counts), 'blocks': block_count,
            'inputs_sha256': {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in
                              ['result.json', 'events.jsonl', 'retirement.bin.gz', 'rom.hex', 'iram.hex']},
            'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'limits': 'code/order/bus/result replay; not an independent full privileged ISA interpreter'}


def main():
    """write one independently reproducible observation audit without changing the original run."""
    parser = argparse.ArgumentParser(); parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--schema', type=Path, required=True); parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); require(not args.output.exists(), 'output already exists')
    report = replay(args.run, args.schema)
    args.output.write_text(json.dumps(report, indent=2) + '\n'); print('SYNTHETIC_REPLAY_PASS records=' + str(report['counts']['records']))


# imports never rewrite evidence or start the RTL simulator.
if __name__ == '__main__':
    main()

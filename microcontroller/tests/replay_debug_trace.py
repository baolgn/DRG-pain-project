#!/usr/bin/env python3
"""reconstruct debug-modified execution and bus ownership from a complete event capture."""
import argparse
import gzip
import json
from pathlib import Path


# failures retain a stable detector name for deliberately corrupted captures.
def require(condition, reason):
    """reject the first unsupported or contradictory capture record."""
    # reject inconsistent evidence immediately.
    if not condition:
        raise ValueError('DEBUG_REPLAY_FAILED ' + reason)


# the recorder owns event sequence; independent replay owns expected architectural effects.
def replay(path, schema):
    """check complete event identity, GPR history, PC transitions and physical transactions."""
    opener = gzip.open if path.suffix == '.gz' else open
    registers = [None] * 32; registers[0] = 0
    owners = {'i': None, 'd': None, 'sb': None}
    accepted = {'i': 0, 'd': 0, 'sb': 0}
    halted = False; pc = 0; cycle = 0; sequence = 0; order = 0
    retired = traps = abstracts = irqs = mmio_reads = mmio_writes = 0
    footer = None
    # a terminal record includes all original instruction metadata and committed effects.
    def decode(value):
        """extract named leaves using the archived packed-type schema."""
        bits = int(value, 16)
        require(bits < 1 << schema['packed_bits'], 'terminal width')
        return {name: (bits >> field['lsb']) & ((1 << field['width']) - 1)
                for name, field in schema['fields'].items()}
    # stream raw or compressed captures without changing event order.
    with opener(path, 'rt') as stream:
        header = json.loads(next(stream)); require(header['schema'] == 'DRG5-DEBUG1', 'schema')
        # every event has a unique position, even when several occur on one clock edge.
        for line in stream:
            row = json.loads(line); require(footer is None, 'events after footer')
            # record one footer and reject any later event.
            if row.get('end') is True:
                footer = row; continue
            sequence += 1
            require(row['sequence'] == sequence, 'event sequence')
            require(row['cycle'] >= cycle, 'clock order'); cycle = row['cycle']
            event = row['event']
            # physical effects are tracked independently of the retiring instruction stream.
            if event in ('offer', 'accept', 'response'):
                bus = row['bus']; require(bus in owners, 'bus name')
                owner = owners[bus]
                # first exposure allocates the sole owner for this bus.
                if event == 'offer':
                    require(owner is None, 'duplicate bus offer')
                    owners[bus] = row | {'accepted': False}
                # later events must retain the original address and tag.
                else:
                    require(owner is not None and owner['address'] == row['address'] and owner['tag'] == row['tag'], 'bus owner')
                    # acceptance produces exactly one independently counted effect.
                    if event == 'accept':
                        require(not owner['accepted'], 'duplicate bus effect')
                        owner['accepted'] = True; accepted[bus] += 1
                        # only successful accesses touch the destructive device counters.
                        if row['status'] == 0 and row['address'] == 0x40000000:
                            # writes increment the device write count once.
                            if owner['write']:
                                mmio_writes += 1
                            # reads increment the device read count once.
                            else:
                                mmio_reads += 1
                    # a terminal response releases an accepted owner.
                    else:
                        require(owner['accepted'], 'response before acceptance'); owners[bus] = None
            # an abstract command is an architectural access only after halted-state admission.
            elif event == 'abstract':
                require(halted, 'abstract access while running'); abstracts += 1
                packed = int(row['packed'], 16); require(packed >> 84 == 1, 'abstract width/valid')
                error = (packed >> 81) & 7; write = (packed >> 80) & 1
                address = (packed >> 64) & 0xffff; data = (packed >> 32) & 0xffffffff; result = packed & 0xffffffff
                # successful GPR commands update or inspect architectural history.
                if not error and 0x1000 <= address < 0x1020:
                    reg = address - 0x1000
                    # debug writes define nonzero registers without retiring an instruction.
                    if write and reg:
                        registers[reg] = data
                    # check defined registers and x0; other reset contents remain unspecified.
                    elif not write and registers[reg] is not None:
                        require(registers[reg] == result, 'abstract GPR value')
            # normal retirement and traps retain distinct accounting and precise continuation.
            elif event == 'terminal':
                rec = decode(row['packed'])
                require(not halted and rec['valid'] and rec['order'] == order, 'terminal identity'); order += 1
                require(rec['packet.pc'] == row['pc'] == pc, 'instruction PC')
                require(rec['trap'] == row['trap'], 'trap metadata')
                # compare every consumed operand with the newest recorded register value.
                for operand in ('rs1', 'rs2'):
                    # unused operand fields carry no architectural dependency.
                    if rec['packet.' + operand + '_used']:
                        reg = rec['packet.' + operand]
                        # undefined reset contents cannot supply an independent expected value.
                        if registers[reg] is not None:
                            require(registers[reg] == rec['packet.' + operand + '_value'], 'operand history')
                # trapping instructions commit no ordinary register or CSR write.
                if rec['trap']:
                    traps += 1; require(not rec['rd_write'] and not rec['csr_write'], 'trapping write')
                # successful instructions count once and may define a destination.
                else:
                    retired += 1
                    # x0 never appears as a committed destination.
                    if rec['rd_write']:
                        require(rec['rd'] != 0, 'x0 write'); registers[rec['rd']] = rec['value']
                pc = rec['next_pc']
            # interrupt entry redirects without incrementing instruction counts.
            elif event == 'irq':
                require(not halted and row['pc'] == pc, 'IRQ boundary'); pc = row['next_pc']; irqs += 1
            # reset, halt and resume are separate architectural boundaries.
            elif event == 'state':
                # reset invalidates GPR knowledge and restores the boot PC.
                if row['reset']:
                    registers = [None] * 32; registers[0] = 0; pc = 0
                # halt requires drained CPU buses and the exact continuation.
                if row['halted']:
                    require(owners['i'] is None and owners['d'] is None, 'halt before CPU drain')
                    require(row['dpc'] == pc, 'halt continuation')
                # resume uses the debugger-modified DPC.
                elif halted and not row['reset']:
                    pc = row['dpc']
                halted = bool(row['halted'])
            # unknown event types cannot be silently omitted.
            else:
                require(False, 'unknown event')
    require(footer is not None, 'missing footer')
    require(footer['events'] == sequence and footer['cycles'] >= cycle, 'footer identity')
    require(halted and all(owner is None for owner in owners.values()), 'unfinished ownership')
    require((footer['retired'], footer['traps']) == (retired, traps), 'terminal totals')
    require(all(footer[bus + '_accepts'] == count for bus, count in accepted.items()), 'bus totals')
    require((footer['mmio_reads'], footer['mmio_writes']) == (mmio_reads, mmio_writes), 'MMIO totals')
    return {'events': sequence, 'retired': retired, 'traps': traps, 'abstracts': abstracts, 'irqs': irqs,
            'bus_accepts': accepted, 'mmio_reads': mmio_reads, 'mmio_writes': mmio_writes}


# standalone replay requires the retained capture and its exact packed-type schema.
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('capture', type=Path); parser.add_argument('schema', type=Path)
    args = parser.parse_args()
    print(json.dumps(replay(args.capture, json.loads(args.schema.read_text())), indent=2))

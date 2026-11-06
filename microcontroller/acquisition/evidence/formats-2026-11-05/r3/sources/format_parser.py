"""decode frozen acquisition bytes independently of the producer oracle."""

import hashlib
import math
import struct
from collections.abc import Mapping
from types import MappingProxyType


def require(condition, message):
    """reject malformed bytes even under optimized Python."""
    # no failed predicate may be silently repaired.
    if not condition:
        raise ValueError(message)


_VALIDATION_TOKEN = object()


def _freeze(value):
    """retain immutable nested values in validated parser results."""
    # validated objects already retain immutable values and original bytes.
    if type(value) is _Validated:
        return value
    # internal result dictionaries cannot remain mutable through nested references.
    if isinstance(value, Mapping):
        return MappingProxyType({key: _freeze(item) for key, item in value.items()})
    # samples, statuses and record collections preserve order as tuples.
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(item) for item in value)
    return value


class _Validated(Mapping):
    """expose validated immutable bytes and fields through the mapping API."""

    __slots__ = ('_values',)

    def __init__(self, values, token):
        """allow construction only through this module's validation path."""
        require(token is _VALIDATION_TOKEN, 'unvalidated parser result')
        object.__setattr__(self, '_values', _freeze(values))

    def __getitem__(self, key):
        """read a validated field without exposing mutable storage."""
        return self._values[key]

    def __iter__(self):
        """iterate the frozen field names."""
        return iter(self._values)

    def __len__(self):
        """report the validated field count."""
        return len(self._values)

    def __setattr__(self, key, value):
        """prevent replacing protected fields after validation."""
        raise AttributeError('validated parser results are immutable')


def _result(values):
    """seal checked results within the trusted in-process parser API."""
    return _Validated(values, _VALIDATION_TOKEN)


def _bytes(data):
    """take an immutable snapshot of a byte buffer."""
    require(isinstance(data, (bytes, bytearray, memoryview)), 'expected byte buffer')
    return bytes(data)


def _crc_table():
    """build the reflected CRC32C byte table locally."""
    table = []
    # each entry advances one complete byte independently of message content.
    for byte in range(256):
        value = byte
        # reflected division consumes the least-significant bit first.
        for _ in range(8):
            value = (value >> 1) ^ (0x82F63B78 if value & 1 else 0)
        table.append(value)
    return tuple(table)


_CRC_TABLE = _crc_table()


def crc32c(data):
    """check stored-object integrity using a local table recurrence."""
    value = 0xFFFFFFFF
    # table lookup advances the reflected remainder by one byte.
    for byte in _bytes(data):
        value = _CRC_TABLE[(value ^ byte) & 255] ^ (value >> 8)
    return value ^ 0xFFFFFFFF


def _adc_crc(samples, status):
    """divide the complete sample/status polynomial by the ADC generator."""
    message = 0
    # concatenate eight unpadded 26-bit channel groups.
    for code, raw_status in zip(samples, status):
        message = (message << 26) | ((code & 0x3FFFF) << 8) | raw_status
    remainder = message << 16
    # polynomial long division is independent of the producer's bit recurrence.
    while remainder.bit_length() > 16:
        remainder ^= 0x1755B << (remainder.bit_length() - 17)
    return remainder


def _fixed(data, magic, size):
    """check object framing before reading its fields."""
    data = _bytes(data)
    require(len(data) == size, 'incorrect object length')
    actual_magic, version, actual_size = struct.unpack_from('<4sHH', data)
    require((actual_magic, version, actual_size) == (magic, 1, size),
            'unsupported object framing')
    return data


def _integrity(data, offset):
    """verify the full object's CRC with only its own field zeroed."""
    received, = struct.unpack_from('<I', data, offset)
    calculated = crc32c(data[:offset] + bytes(4) + data[offset + 4:])
    require(received == calculated, 'CRC32C mismatch')
    return received


def _context(context, kind):
    """require the appropriate parsed binding object."""
    require(type(context) is _Validated and context.get('object') == kind,
            'incorrect binding context')
    return context


def _tick(first_tick, slot):
    """check schedule arithmetic before narrowing to its stored width."""
    require(0 <= slot < (1 << 64) - 1, 'unsupported slot index')
    tick = first_tick + slot * 1600
    require(0 <= tick < 1 << 64, 'scheduled tick overflow')
    return tick


def parse_record(data):
    """validate all inferable record predicates without inventing analog masks."""
    data = _bytes(data)
    require(len(data) == 48, 'incorrect record length')
    fields = struct.unpack('<8i8BHBBI', data)
    samples = list(fields[:8])
    status = list(fields[8:16])
    received_crc, present, reserved, flags = fields[16:]
    require(reserved == 0 and flags >> 29 == 0, 'nonzero record reservation')
    require(present in (0, 1, 3, 7, 15, 31, 63, 127, 255), 'nonprefix presence mask')
    require(all(-131072 <= code <= 131071 for code in samples), 'noncanonical signed18 code')
    valid = flags & 255
    rail = (flags >> 8) & 255
    triggered = bool(flags & (1 << 16))
    complete = bool(flags & (1 << 17))
    crc_ok = bool(flags & (1 << 18))
    frame_integrity = bool(flags & (1 << 19))
    settling = bool(flags & (1 << 20))
    missing = bool(flags & (1 << 21))
    truncated = bool(flags & (1 << 22))
    status_fault = bool(flags & (1 << 23))
    reset_seen = bool(flags & (1 << 24))
    digital_error_seen = bool(flags & (1 << 25))
    open_seen = bool(flags & (1 << 26))
    analog_invalid = bool(flags & (1 << 27))
    time_uncertain = bool(flags & (1 << 28))
    expected_rail = 0
    expected_reset = expected_error = expected_open = expected_fault = False
    positional_ok = True
    # only complete received pairs contribute raw evidence and status predicates.
    for channel, (code, raw_status) in enumerate(zip(samples, status)):
        # an absent pair has no retained partial bits or invented code.
        if not present & (1 << channel):
            require(code == 0 and raw_status == 0, 'nonzero absent pair')
            continue
        expected_rail |= int(code in (-131072, 131071)) << channel
        position_ok = (raw_status & 7) == channel and not raw_status & 0x18
        positional_ok &= position_ok
        expected_reset |= bool(raw_status & 0x80)
        expected_error |= bool(raw_status & 0x40)
        expected_open |= bool(raw_status & 0x20)
        expected_fault |= not position_ok or bool(raw_status & 0xE0)
    require(rail == expected_rail, 'inconsistent rail flags')
    require((reset_seen, digital_error_seen, open_seen, status_fault) ==
            (expected_reset, expected_error, expected_open, expected_fault),
            'inconsistent status flags')
    require(missing == (not complete), 'inconsistent missing flag')
    require(not complete or (triggered and present == 255 and not truncated),
            'inconsistent complete frame')
    require(not truncated or (triggered and not complete), 'inconsistent truncation')
    require(complete or received_crc == 0, 'incomplete CRC trailer must be zero')
    require(crc_ok == (complete and received_crc == _adc_crc(samples, status)),
            'inconsistent CRC_OK')
    require(frame_integrity == (complete and crc_ok and positional_ok),
            'inconsistent frame integrity')
    require(not settling or analog_invalid, 'settling without analog invalidity')
    # an incomplete nontruncated frame records zero captured bits.
    if not complete and not truncated:
        require(present == 0, 'pairs without captured bits')
    # untriggered intervals may carry analog/time annotations but no captured data.
    if not triggered:
        require(present == 0 and received_crc == 0 and not truncated and not complete,
                'captured evidence without trigger')
    electronically_valid = triggered and frame_integrity and not status_fault and not time_uncertain
    # host checks all inferable analog-permission consequences without guessing a mask.
    if electronically_valid:
        available = 255 ^ rail
        require(valid & ~available == 0, 'valid endpoint or absent channel')
        # an absent analog permission may coincide with an already invalid rail.
        if analog_invalid:
            require(valid != 255, 'analog invalidity with all channels valid')
        # all permissions are present when the summary flag is clear.
        else:
            require(valid == available, 'inconsistent valid mask')
    # global electronic failure invalidates every channel.
    else:
        require(valid == 0, 'valid channel in invalid frame')
    return _result({'object': 'record', 'samples': samples, 'status': status,
            'received_crc': received_crc, 'present': present, 'flags': flags,
            'valid': valid, 'rail': rail, 'complete': complete,
            'time_uncertain': time_uncertain, 'raw': data})


def parse_configuration(data, manifest):
    """bind the exact manifest bytes without claiming their physical validity."""
    data = _fixed(data, b'ACF1', 128)
    checksum = _integrity(data, 120)
    config_id, session_id = struct.unpack_from('<Q16s', data, 8)
    profile = struct.unpack_from('<4H4BI', data, 32)
    numerator, denominator, timebase_id = struct.unpack_from('<3Q', data, 48)
    manifest_hash, manifest_length, flags = struct.unpack_from('<32sII', data, 72)
    require(config_id != 0 and timebase_id != 0 and session_id != bytes(16), 'zero configuration identity')
    require(profile == (4, 1, 1, 1, 0x33, 8, 18, 1, 1600), 'unsupported configuration profile')
    require(flags == 0 and data[112:120] == bytes(8) and data[124:] == bytes(4),
            'nonzero configuration reservation')
    require(numerator > 0 and denominator > 0 and math.gcd(numerator, denominator) == 1,
            'noncanonical frequency fraction')
    require(79_992_000 * denominator <= numerator <= 80_008_000 * denominator,
            'unsupported frequency envelope')
    manifest = _bytes(manifest)
    require(1 <= manifest_length <= 1_048_576 and len(manifest) == manifest_length,
            'manifest length mismatch')
    require(hashlib.sha256(manifest).digest() == manifest_hash, 'manifest SHA-256 mismatch')
    return _result({'object': 'ACF1', 'config_id': config_id, 'session_id': session_id,
            'timebase_id': timebase_id, 'tick_num': numerator, 'tick_den': denominator,
            'manifest_sha256': manifest_hash, 'manifest_bytes': manifest_length,
            'crc32c': checksum, 'bound': True, 'physical_qualified': False, 'raw': data})


def parse_epoch(data, configuration=None):
    """decode an epoch and optionally bind its configuration and session."""
    data = _fixed(data, b'ACE1', 64)
    checksum = _integrity(data, 60)
    epoch_id, config_id, timebase_id, first_tick, session_id, flags = struct.unpack_from('<4Q16sI', data, 8)
    require(epoch_id != 0 and config_id != 0 and timebase_id != 0 and session_id != bytes(16),
            'zero epoch identity')
    require(first_tick != 0, 'zero epoch first tick')
    require(flags == 0, 'nonzero epoch reservation')
    bound = False
    # supplied context must agree even if it is not yet externally qualified.
    if configuration is not None:
        configuration = _context(configuration, 'ACF1')
        require((config_id, timebase_id, session_id) ==
                (configuration['config_id'], configuration['timebase_id'], configuration['session_id']),
                'epoch binding mismatch')
        bound = configuration['bound']
    return _result({'object': 'ACE1', 'epoch_id': epoch_id, 'config_id': config_id,
            'timebase_id': timebase_id, 'first_tick': first_tick, 'session_id': session_id,
            'crc32c': checksum, 'bound': bound, 'physical_qualified': False,
            'tick_frequency': None if configuration is None else (configuration['tick_num'], configuration['tick_den']),
            'configuration_raw': None if configuration is None else configuration['raw'], 'raw': data})


def parse_block(data, configuration=None, epoch=None):
    """check exact block bytes before accepting their session and epoch identity."""
    data = _bytes(data)
    require(112 <= len(data) <= 12352, 'incorrect block length')
    header = struct.unpack_from('<4sHH4QIHHIIQ', data)
    magic, version, header_bytes, epoch_id, sequence, first_slot, first_tick, period, count, flags, payload_bytes, checksum, config_id = header
    require((magic, version, header_bytes) == (b'ACQ1', 1, 64), 'unsupported block framing')
    require(epoch_id != 0 and sequence != 0 and config_id != 0, 'zero block identity')
    require(period == 1600 and 1 <= count <= 256, 'unsupported block period or count')
    require(payload_bytes == count * 48 and len(data) == 64 + payload_bytes, 'block extent mismatch')
    require(flags & ~7 == 0 and (count == 256 or flags & 1), 'invalid block flags or partial block')
    require(first_slot % 256 == 0 and first_slot + count - 1 < (1 << 64) - 1,
            'invalid block slot range')
    require(first_tick - first_slot * 1600 >= 1, 'invalid inferred epoch origin')
    require(first_tick + (count - 1) * period < 1 << 64, 'block tick overflow')
    _integrity(data, 52)
    records = [parse_record(data[start:start + 48]) for start in range(64, len(data), 48)]
    invalid = any(record['valid'] != 255 for record in records)
    uncertain = any(record['time_uncertain'] for record in records)
    require(bool(flags & 2) == invalid and bool(flags & 4) == uncertain,
            'inconsistent block summary flags')
    bound = False
    session_id = None
    # either supplied binding is checked; full acceptance requires both.
    if configuration is not None:
        configuration = _context(configuration, 'ACF1')
        require(config_id == configuration['config_id'], 'block configuration mismatch')
        session_id = configuration['session_id']
    # an epoch binding supplies the schedule origin missing from the block itself.
    if epoch is not None:
        epoch = _context(epoch, 'ACE1')
        require((epoch_id, config_id) == (epoch['epoch_id'], epoch['config_id']), 'block epoch mismatch')
        require(first_tick == _tick(epoch['first_tick'], first_slot), 'block schedule mismatch')
        _tick(epoch['first_tick'], first_slot + count - 1)
        require(session_id is None or session_id == epoch['session_id'], 'block session mismatch')
        session_id = epoch['session_id']
    # complete binding cannot be obtained by omitting an immutable identity object.
    if configuration is not None and epoch is not None:
        require(configuration['timebase_id'] == epoch['timebase_id'], 'block timebase mismatch')
        require(epoch['configuration_raw'] is None or epoch['configuration_raw'] == configuration['raw'],
                'epoch configuration bytes mismatch')
        bound = configuration['bound'] and epoch['bound']
    return _result({'object': 'ACQ1', 'epoch_id': epoch_id, 'sequence': sequence,
            'first_slot': first_slot, 'first_tick': first_tick, 'period': period,
            'count': count, 'flags': flags, 'payload_bytes': payload_bytes,
            'crc32c': checksum, 'config_id': config_id, 'records': records,
            'session_id': session_id, 'bound': bound, 'physical_qualified': False,
            'timebase_id': None if configuration is None else configuration['timebase_id'],
            'tick_frequency': None if configuration is None else (configuration['tick_num'], configuration['tick_den']),
            'epoch_first_tick': None if epoch is None else epoch['first_tick'],
            'configuration_raw': None if configuration is None else configuration['raw'],
            'epoch_raw': None if epoch is None else epoch['raw'], 'raw': data})


def parse_publication(data, block=None, ring_base=None, lease=None):
    """validate a stable leased descriptor without treating PUB1 as an ABA guard."""
    data = _bytes(data)
    require(len(data) == 64, 'incorrect publication length')
    # unpublished descriptors can contain incomplete body bytes and no valid CRC.
    if data[60:64] == bytes(4):
        require(lease is None, 'publication revoked under live lease')
        raise ValueError('NOT_PUBLISHED')
    require(data[60:64] == b'PUB1', 'invalid publication word')
    data = _fixed(data, b'ACD1', 64)
    checksum = _integrity(data, 56)
    epoch_id, sequence, generation, config_id, address, block_bytes, block_crc, ring_index, flags = struct.unpack_from('<4Q3I2H', data, 8)
    require(all(value != 0 for value in (epoch_id, sequence, generation, config_id)), 'zero publication identity')
    require(flags == 0 and ring_index < 64, 'invalid publication reservation or ring index')
    require(address % 64 == 0 and 112 <= block_bytes <= 12352 and (block_bytes - 64) % 48 == 0,
            'invalid publication address or extent')
    require(address + block_bytes <= 1 << 32, 'publication address overflow')
    # even an unbound descriptor must imply a representable complete ring.
    inferred_base = address - ring_index * 12352
    require(inferred_base >= 0 and inferred_base % 64 == 0 and
            inferred_base + 64 * 12352 <= 1 << 32, 'invalid inferred ring allocation')
    # the entire allocation map must fit, not only this one descriptor's span.
    if ring_base is not None:
        require(type(ring_base) is int and 0 <= ring_base < 1 << 32 and ring_base % 64 == 0,
                'invalid ring base')
        require(ring_base + 64 * 12352 <= 1 << 32, 'ring allocation overflow')
        require(address == ring_base + ring_index * 12352, 'publication allocation mismatch')
    # generation alone cannot identify one of many slots in the same session.
    if lease is not None:
        require(type(lease) is tuple and len(lease) == 3, 'invalid publication lease')
        lease_session = _bytes(lease[0])
        lease_index, lease_generation = lease[1:]
        require(len(lease_session) == 16 and lease_session != bytes(16), 'invalid lease session')
        require(type(lease_index) is int and 0 <= lease_index < 64 and
                type(lease_generation) is int and 1 <= lease_generation < 1 << 64,
                'invalid lease allocation identity')
        require((ring_index, generation) == (lease_index, lease_generation), 'stale allocation lease')
        lease = (lease_session, lease_index, lease_generation)
    # a descriptor never substitutes for integrity checking the pointed-to block.
    if block is not None:
        block = _context(block, 'ACQ1')
        require((epoch_id, sequence, config_id, block_bytes, block_crc) ==
                (block['epoch_id'], block['sequence'], block['config_id'], len(block['raw']), block['crc32c']),
                'publication block mismatch')
        # the block's bound session must identify the acquired allocation lease.
        if lease is not None:
            require(block['bound'] and block['session_id'] == lease[0], 'publication lease session mismatch')
    bound = block is not None and block['bound'] and ring_base is not None and lease is not None
    return _result({'object': 'ACD1', 'epoch_id': epoch_id, 'sequence': sequence,
            'generation': generation, 'config_id': config_id, 'address': address,
            'block_bytes': block_bytes, 'block_crc32c': block_crc, 'ring_index': ring_index,
            'flags': flags, 'crc32c': checksum, 'publication_word': 0x31425550,
            'session_id': None if block is None else block['session_id'],
            'lease': lease, 'bound': bound, 'physical_qualified': False, 'raw': data})


def parse_loss(data, epoch=None):
    """distinguish exact loss from uncertain bounds and archive-only gaps."""
    data = _fixed(data, b'ACL1', 64)
    checksum = _integrity(data, 56)
    epoch_id, first, last, first_tick, last_tick, causes, flags, _, reserved = struct.unpack_from('<5Q4I', data, 8)
    require(epoch_id != 0 and reserved == 0 and flags & ~31 == 0, 'invalid loss framing fields')
    require(0 < causes < 1 << 19, 'invalid loss causes')
    first_known = bool(flags & 1)
    last_known = bool(flags & 2)
    exact = bool(flags & 4)
    ticks_known = bool(flags & 8)
    archive = bool(flags & 16)
    require(not causes & (3 << 17) or archive, 'archive cause in producer loss')
    require(first_known or first == 0, 'nonzero unknown first slot')
    require(last_known or last == 0, 'nonzero unknown last slot')
    # every valid epoch origin is positive, even before its binding is supplied.
    maximum_slot = ((1 << 64) - 2) // 1600
    require(not first_known or first <= maximum_slot, 'unsupported first loss slot')
    require(not last_known or last <= maximum_slot, 'unsupported last loss slot')
    require(not (exact or ticks_known) or (first_known and last_known), 'loss requires known endpoints')
    # known endpoints must form an ordered interval even when its extent is uncertain.
    if first_known and last_known:
        require(first <= last and last - first + 1 < 1 << 64, 'invalid loss interval')
    # unknown timestamps never borrow a sentinel from the integer range.
    if not ticks_known:
        require(first_tick == 0 and last_tick == 0, 'nonzero unknown loss ticks')
    # known ticks imply a positive origin and exact spacing before context binding.
    else:
        require(first_tick - first * 1600 >= 1, 'invalid inferred loss origin')
        require(last_tick - first_tick == (last - first) * 1600, 'inconsistent loss tick spacing')
    bound = False
    session_id = None
    # known slot bounds must fit the epoch even when serialized ticks are unknown.
    if epoch is not None:
        epoch = _context(epoch, 'ACE1')
        require(epoch_id == epoch['epoch_id'], 'loss epoch mismatch')
        expected_first = _tick(epoch['first_tick'], first) if first_known else None
        expected_last = _tick(epoch['first_tick'], last) if last_known else None
        # stored scheduled ticks must match both bound endpoints exactly.
        if ticks_known:
            require((first_tick, last_tick) == (expected_first, expected_last), 'loss tick mismatch')
        bound = epoch['bound']
        session_id = epoch['session_id']
    return _result({'object': 'ACL1', 'epoch_id': epoch_id, 'first': first if first_known else None,
            'last': last if last_known else None, 'first_tick': first_tick if ticks_known else None,
            'last_tick': last_tick if ticks_known else None, 'causes': causes, 'flags': flags,
            'exact': exact, 'ticks_known': ticks_known, 'archive': archive,
            'count': last - first + 1 if exact else None, 'crc32c': checksum,
            'session_id': session_id, 'bound': bound, 'physical_qualified': False,
            'config_id': None if epoch is None else epoch['config_id'],
            'timebase_id': None if epoch is None else epoch['timebase_id'],
            'tick_frequency': None if epoch is None else epoch['tick_frequency'],
            'epoch_first_tick': None if epoch is None else epoch['first_tick'],
            'epoch_raw': None if epoch is None else epoch['raw'],
            'configuration_raw': None if epoch is None else epoch['configuration_raw'], 'raw': data})


class StreamLedger:
    """track session publication order without renumbering missing archive data."""

    def __init__(self, session_id):
        """start at sequence one for an explicitly supplied recording session."""
        session_id = _bytes(session_id)
        require(len(session_id) == 16 and session_id != bytes(16), 'invalid ledger session')
        self.session_id = session_id
        self.expected_sequence = 1
        self.last_block = None
        self.configurations = {}
        self.epochs = {}
        self.timebases = {}
        self.last_ticks = {}

    def accept(self, block):
        """commit ledger changes only after all identity and continuity checks pass."""
        block = _context(block, 'ACQ1')
        require(block['bound'] and block['session_id'] == self.session_id, 'unbound ledger block')
        require(self.expected_sequence is not None, 'stream sequence exhausted')
        sequence = block['sequence']
        require(sequence >= self.expected_sequence, 'duplicate or reordered stream block')
        gap_count = sequence - self.expected_sequence
        old_config = self.configurations.get(block['config_id'])
        old_epoch = self.epochs.get(block['epoch_id'])
        old_frequency = self.timebases.get(block['timebase_id'])
        old_tick = self.last_ticks.get(block['timebase_id'])
        require(old_config is None or old_config == block['configuration_raw'], 'configuration identity reused')
        require(old_epoch is None or old_epoch == block['epoch_raw'], 'epoch identity reused')
        require(old_frequency is None or old_frequency == block['tick_frequency'], 'timebase frequency changed')
        chronology_tick = block['epoch_first_tick'] if old_epoch is None else block['first_tick']
        require(old_tick is None or chronology_tick > old_tick, 'timebase tick reused or reversed')
        # subsequent blocks in an epoch cannot follow its already marked final block.
        if self.last_block is not None and block['epoch_id'] == self.last_block['epoch_id']:
            require(not self.last_block['flags'] & 1, 'block after final epoch block')
            expected_slot = self.last_block['first_slot'] + self.last_block['count']
            require(block['first_slot'] == expected_slot + gap_count * 256,
                    'inconsistent within-epoch stream gap')
        # a new epoch starts at slot zero unless archive blocks were skipped explicitly.
        else:
            require(self.last_block is None or block['epoch_id'] > self.last_block['epoch_id'],
                    'reordered epoch')
            only_new_prefix = ((self.last_block is None and block['epoch_id'] == 1) or
                               (self.last_block is not None and self.last_block['flags'] & 1 and
                                block['epoch_id'] == self.last_block['epoch_id'] + 1))
            # no earlier or intervening epoch can explain these missing block sequences.
            if only_new_prefix:
                require(block['first_slot'] == gap_count * 256, 'impossible new-epoch stream gap')
            # unobserved prior-epoch blocks can consume part of a less constrained gap.
            else:
                require(block['first_slot'] <= gap_count * 256, 'missing epoch prefix without stream gap')
        gap = None if gap_count == 0 else (self.expected_sequence, sequence - 1)
        self.configurations[block['config_id']] = block['configuration_raw']
        self.epochs[block['epoch_id']] = block['epoch_raw']
        self.timebases[block['timebase_id']] = block['tick_frequency']
        self.last_ticks[block['timebase_id']] = block['first_tick'] + (block['count'] - 1) * 1600
        self.last_block = block
        self.expected_sequence = None if sequence == (1 << 64) - 1 else sequence + 1
        return _result({'archive_sequence_gap': gap, 'sequence_exhausted': self.expected_sequence is None})


def validate_loss_intervals(entries, published_blocks=()):
    """check canonical interval sets without counting uncertainty as known loss."""
    previous_exact = {}
    previous_uncertain = {}
    totals = {}
    bindings = {}
    configurations = {}
    timebases = {}
    chronology = {}
    published_ranges = []

    def bind_epoch(item, occupied_last=None):
        """retain the exact epoch and configuration bytes for this identity."""
        key = (item['session_id'], item['epoch_id'])
        binding = (item['epoch_raw'], item['configuration_raw'])
        require(key not in bindings or bindings[key] == binding, 'conflicting interval epoch binding')
        config_key = (item['session_id'], item['config_id'])
        require(config_key not in configurations or configurations[config_key] == item['configuration_raw'],
                'conflicting interval configuration binding')
        timebase_key = (item['session_id'], item['timebase_id'])
        frequency = item['tick_frequency']
        require(timebase_key not in timebases or timebases[timebase_key] == frequency,
                'conflicting interval timebase frequency')
        bindings[key] = binding
        configurations[config_key] = item['configuration_raw']
        timebases[timebase_key] = frequency
        epochs = chronology.setdefault(timebase_key, {})
        origin = item['epoch_first_tick']
        previous = epochs.get(item['epoch_id'])
        end = origin if occupied_last is None else occupied_last
        # repeated observations retain the largest known occupied endpoint.
        if previous is not None:
            end = max(end, previous[1])
        epochs[item['epoch_id']] = (origin, end)

    # actual validated blocks preserve provenance that bare range tuples would lose.
    for block in published_blocks:
        block = _context(block, 'ACQ1')
        require(block['bound'], 'unbound published block')
        bind_epoch(block, block['first_tick'] + (block['count'] - 1) * 1600)
        published_ranges.append((block['session_id'], block['epoch_id'], block['first_slot'],
                                 block['first_slot'] + block['count'] - 1))
    # callers provide only context-bound interval objects to this ledger.
    for entry in entries:
        entry = _context(entry, 'ACL1')
        require(entry['bound'], 'unbound loss interval')
        occupied_last = _tick(entry['epoch_first_tick'], entry['last']) if entry['exact'] else None
        bind_epoch(entry, occupied_last)
        key = (entry['session_id'], entry['epoch_id'], entry['archive'])
        # exact intervals are disjoint and adjacent equal-cause intervals are merged.
        if entry['exact']:
            previous = previous_exact.get(key)
            # compare only intervals sharing the same producer/archive namespace.
            if previous is not None:
                require(previous['last'] < entry['first'], 'unsorted or overlapping exact loss')
                require(previous['last'] + 1 != entry['first'] or
                        (previous['causes'], previous['flags']) != (entry['causes'], entry['flags']),
                        'unmerged adjacent loss intervals')
            total = totals.get(key, 0) + entry['count']
            require(total < 1 << 64, 'exact loss count overflow')
            # producer loss excludes records already published, including invalid records.
            if not entry['archive']:
                # published ranges carry session, epoch and inclusive slot endpoints.
                for session_id, epoch_id, first, last in published_ranges:
                    require(not (session_id == entry['session_id'] and epoch_id == entry['epoch_id'] and
                                 first <= entry['last'] and entry['first'] <= last),
                            'producer loss overlaps published records')
            totals[key] = total
            previous_exact[key] = entry
        # uncertainty annotations preserve ordering but contribute no exact count.
        else:
            order = (entry['first'] is not None, entry['first'] or 0,
                     entry['last'] is not None, entry['last'] or 0, entry['flags'], entry['causes'])
            previous = previous_uncertain.get(key)
            require(previous is None or previous < order, 'unsorted or duplicate uncertainty intervals')
            require(previous is None or previous[:-1] != order[:-1], 'unmerged uncertainty causes')
            previous_uncertain[key] = order
    # unavailable timestamps still have known scheduled endpoints for exact loss.
    for epochs in chronology.values():
        previous_end = None
        # epoch identifiers order intervals sharing one unchanged timebase.
        for epoch_id in sorted(epochs):
            origin, occupied_end = epochs[epoch_id]
            require(previous_end is None or origin > previous_end, 'overlapping or reversed epoch chronology')
            previous_end = occupied_end
    return MappingProxyType(totals)

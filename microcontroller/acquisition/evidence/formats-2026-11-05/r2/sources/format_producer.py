"""produce canonical ACQ-R1 bytes independently of the host parser."""

import hashlib
import math


def _require(condition, message):
    """reject invalid inputs even under optimized Python."""
    # no rejected value reaches a narrowing write.
    if not condition:
        raise ValueError(message)


def _uint(value, bits, name):
    """validate an unsigned integer without accepting booleans."""
    _require(type(value) is int and 0 <= value < (1 << bits), name + ' out of range')
    return value


def _identity(value, name):
    """reserve zero in each identity namespace."""
    _uint(value, 64, name)
    _require(value != 0, name + ' must be nonzero')
    return value


def _boolean(value, name):
    """keep flag inputs distinct from arbitrary integers."""
    _require(type(value) is bool, name + ' must be boolean')
    return value


def _bytes(value, name):
    """copy byte inputs before deriving integrity fields."""
    _require(isinstance(value, (bytes, bytearray)), name + ' must be bytes')
    return bytes(value)


def _channels(samples, status):
    """validate eight signed18 codes and eight raw status bytes."""
    _require(isinstance(samples, (list, tuple)) and len(samples) == 8,
             'samples must contain eight values')
    _require(isinstance(status, (list, tuple)) and len(status) == 8,
             'status must contain eight values')
    # absent source pairs are validated before their bytes are discarded.
    for value in samples:
        _require(type(value) is int and -131072 <= value <= 131071,
                 'sample outside signed18 range')
    # status bytes preserve all received bits, including diagnostic evidence.
    for value in status:
        _uint(value, 8, 'status')
    return list(samples), list(status)


def _put(output, offset, width, value):
    """write one checked little-endian integer at its explicit offset."""
    _uint(value, width * 8, 'stored field')
    output[offset:offset + width] = value.to_bytes(width, 'little')


def _get(data, offset, width):
    """read an oracle input without importing host parsing helpers."""
    return int.from_bytes(data[offset:offset + width], 'little')


def crc32c(data):
    """compute reflected CRC32C with the frozen seed and final XOR."""
    data = _bytes(data, 'CRC32C input')
    state = 0xffffffff
    # process each stored byte least-significant bit first.
    for byte in data:
        state ^= byte
        # apply the reflected polynomial once per input bit.
        for _ in range(8):
            state = (state >> 1) ^ (0x82f63b78 if state & 1 else 0)
    return state ^ 0xffffffff


def adc_crc16(samples, status):
    """compute the MSB-first CRC over eight unpadded sample/status pairs."""
    samples, status = _channels(samples, status)
    state = 0
    # pair boundaries do not insert byte padding into the 208-bit stream.
    for sample, raw_status in zip(samples, status):
        pair = ((sample & 0x3ffff) << 8) | raw_status
        # consume sample bit17 through status bit0 in wire order.
        for position in range(25, -1, -1):
            feedback = ((state >> 15) ^ (pair >> position)) & 1
            state = (state << 1) & 0xffff
            # the received trailer is excluded from this recurrence.
            if feedback:
                state ^= 0x755b
    return state


def _seal(output, crc_offset):
    """cover the actual object, substituting zero for its own CRC32C."""
    output[crc_offset:crc_offset + 4] = bytes(4)
    _put(output, crc_offset, 4, crc32c(output))
    return bytes(output)


def make_record(samples, status, received_crc, captured_bits, triggered=True,
                analog_valid=255, settling=0, time_uncertain=False):
    """derive canonical evidence and flags from one scheduled conversion outcome."""
    samples, status = _channels(samples, status)
    _uint(received_crc, 16, 'received CRC')
    _uint(captured_bits, 8, 'captured bits')
    _require(captured_bits <= 224, 'too many captured bits')
    _boolean(triggered, 'triggered')
    _boolean(time_uncertain, 'time uncertainty')
    _uint(analog_valid, 8, 'analog-valid mask')
    _uint(settling, 8, 'settling mask')
    _require(not settling & analog_valid, 'settling channel cannot be analog-valid')
    _require(triggered or captured_bits == 0, 'untriggered slot cannot contain captured bits')
    pairs = min(captured_bits // 26, 8)
    present = (1 << pairs) - 1
    complete = captured_bits == 224
    output = bytearray(48)
    rail = observed = 0
    positional_ok = True
    status_fault = False
    # preserve only complete pairs at their original channel positions.
    for channel in range(pairs):
        sample = samples[channel]
        raw_status = status[channel]
        _put(output, 4 * channel, 4, sample & 0xffffffff)
        output[32 + channel] = raw_status
        rail |= int(sample in (-131072, 131071)) << channel
        observed |= raw_status & 0xe0
        positional_ok &= (raw_status & 0x1f) == channel
        status_fault |= bool(raw_status & 0xf8) or (raw_status & 7) != channel
    crc_ok = complete and received_crc == adc_crc16(samples, status)
    integrity = complete and crc_ok and positional_ok
    valid = 0
    # raw ADC errors invalidate every channel even when transport integrity passes.
    if triggered and integrity and not status_fault and not time_uncertain:
        valid = present & analog_valid & ~rail
    flags = valid | (rail << 8) | (int(triggered) << 16) | (int(complete) << 17)
    flags |= int(crc_ok) << 18
    flags |= int(integrity) << 19
    flags |= int(bool(settling)) << 20
    flags |= int(not complete) << 21
    flags |= int(0 < captured_bits < 224) << 22
    flags |= int(status_fault) << 23
    flags |= int(bool(observed & 0x80)) << 24
    flags |= int(bool(observed & 0x40)) << 25
    flags |= int(bool(observed & 0x20)) << 26
    flags |= int(analog_valid != 255) << 27
    flags |= int(time_uncertain) << 28
    _put(output, 40, 2, received_crc if complete else 0)
    output[42] = present
    _put(output, 44, 4, flags)
    return bytes(output)


def _record_flags(record):
    """reject noncanonical record bytes before enclosing them in a valid block."""
    record = _bytes(record, 'record')
    _require(len(record) == 48, 'record length must be 48')
    samples = [int.from_bytes(record[4 * c:4 * c + 4], 'little', signed=True)
               for c in range(8)]
    status = list(record[32:40])
    _channels(samples, status)
    present = record[42]
    _require(present & (present + 1) == 0, 'PRESENT must be a low-bit prefix')
    _require(record[43] == 0, 'reserved record byte must be zero')
    flags = _get(record, 44, 4)
    _require(flags & 0xe0000000 == 0, 'reserved record flags must be zero')
    complete = bool(flags & (1 << 17))
    triggered = bool(flags & (1 << 16))
    truncated = bool(flags & (1 << 22))
    missing = bool(flags & (1 << 21))
    _require(missing == (not complete), 'MISSING must equal not COMPLETE')
    _require(not complete or (triggered and present == 255 and not truncated),
             'complete record has contradictory capture flags')
    _require(not truncated or (triggered and not complete), 'invalid truncated record')
    _require(complete or truncated or present == 0, 'zero-bit record has present pairs')
    _require(triggered or (not complete and not truncated and present == 0),
             'untriggered record contains capture evidence')
    received_crc = _get(record, 40, 2)
    _require(complete or received_crc == 0, 'incomplete trailer must be zero')
    rail = observed = 0
    positional_ok = True
    status_fault = False
    # absent slots must not leak partial sample or status bytes.
    for channel in range(8):
        # only present pairs contribute status, endpoint and identity evidence.
        if present & (1 << channel):
            rail |= int(samples[channel] in (-131072, 131071)) << channel
            observed |= status[channel] & 0xe0
            positional_ok &= (status[channel] & 0x1f) == channel
            status_fault |= bool(status[channel] & 0xf8) or (status[channel] & 7) != channel
        # a missing pair has one canonical byte representation.
        else:
            _require(samples[channel] == 0 and status[channel] == 0,
                     'absent pair must be zero')
    crc_ok = complete and received_crc == adc_crc16(samples, status)
    integrity = complete and crc_ok and positional_ok
    _require(bool(flags & (1 << 18)) == crc_ok, 'CRC_OK mismatch')
    _require(bool(flags & (1 << 19)) == integrity, 'FRAME_INTEGRITY mismatch')
    _require(((flags >> 8) & 255) == rail, 'RAIL mismatch')
    _require(bool(flags & (1 << 23)) == status_fault, 'STATUS_FAULT mismatch')
    _require(bool(flags & (1 << 24)) == bool(observed & 0x80), 'RESET_SEEN mismatch')
    _require(bool(flags & (1 << 25)) == bool(observed & 0x40), 'DIGITAL_ERROR_SEEN mismatch')
    _require(bool(flags & (1 << 26)) == bool(observed & 0x20), 'OPEN_SEEN mismatch')
    analog_invalid = bool(flags & (1 << 27))
    _require(not flags & (1 << 20) or analog_invalid, 'SETTLING requires ANALOG_INVALID')
    valid = flags & 255
    eligible = 255 & ~rail
    # validity is constrained without inventing an unrecorded analog mask.
    if triggered and integrity and not status_fault and not flags & (1 << 28):
        _require(valid & ~eligible == 0, 'VALID exceeds electronically eligible channels')
        # missing analog permission must prevent an all-valid record.
        if analog_invalid:
            _require(valid != 255, 'analog-invalid record cannot mark all channels valid')
        # all eligible channels must be valid when analog permission is complete.
        else:
            _require(valid == eligible, 'VALID disagrees with full analog permission')
    # failed global prerequisites invalidate every channel.
    else:
        _require(valid == 0, 'invalid frame has VALID channels')
    return flags


def make_block(records, epoch_id, sequence, first_slot, epoch_first_tick, config_id,
               final=False):
    """assemble actual records after checking their canonical flag relationships."""
    _require(isinstance(records, (list, tuple)) and 1 <= len(records) <= 256,
             'block must contain 1..256 records')
    _identity(epoch_id, 'epoch ID')
    _identity(sequence, 'block sequence')
    _identity(config_id, 'configuration ID')
    _uint(first_slot, 64, 'first slot')
    _identity(epoch_first_tick, 'epoch first tick')
    _boolean(final, 'final')
    _require(first_slot % 256 == 0, 'first slot must align to 256-record blocks')
    count = len(records)
    _require(count == 256 or final, 'partial block must be FINAL')
    last_slot = first_slot + count - 1
    _require(last_slot < (1 << 64) - 1, 'slot count exceeds u64 accounting')
    first_tick = epoch_first_tick + 1600 * first_slot
    _uint(epoch_first_tick + 1600 * last_slot, 64, 'last scheduled tick')
    payload = bytearray()
    summary = int(final)
    # block summaries are exact reductions over the serialized records.
    for record in records:
        snapshot = _bytes(record, 'record')
        flags = _record_flags(snapshot)
        payload.extend(snapshot)
        summary |= int((flags & 255) != 255) << 1
        summary |= int(bool(flags & (1 << 28))) << 2
    output = bytearray(64) + payload
    output[0:4] = b'ACQ1'
    _put(output, 4, 2, 1)
    _put(output, 6, 2, 64)
    _put(output, 8, 8, epoch_id)
    _put(output, 16, 8, sequence)
    _put(output, 24, 8, first_slot)
    _put(output, 32, 8, first_tick)
    _put(output, 40, 4, 1600)
    _put(output, 44, 2, count)
    _put(output, 46, 2, summary)
    _put(output, 48, 4, len(payload))
    _put(output, 56, 8, config_id)
    return _seal(output, 52)


def make_publication(block, generation, ring_index, ring_base):
    """bind a canonical block to one generation-tagged physical allocation."""
    block = _bytes(block, 'block')
    _require(112 <= len(block) <= 12352, 'invalid block size')
    _require(block[0:4] == b'ACQ1' and _get(block, 4, 2) == 1 and
             _get(block, 6, 2) == 64, 'unsupported block header')
    count = _get(block, 44, 2)
    _require(len(block) == 64 + 48 * count, 'block length disagrees with record count')
    first_slot = _get(block, 24, 8)
    epoch_first_tick = _get(block, 32, 8) - 1600 * first_slot
    _require(epoch_first_tick >= 0, 'block first tick precedes its epoch origin')
    records = [block[64 + 48 * i:112 + 48 * i] for i in range(count)]
    expected = make_block(records, _get(block, 8, 8), _get(block, 16, 8),
                          first_slot, epoch_first_tick, _get(block, 56, 8),
                          final=bool(_get(block, 46, 2) & 1))
    _require(block == expected, 'block is not canonical or has bad integrity')
    _identity(generation, 'allocation generation')
    _uint(ring_index, 16, 'ring index')
    _require(ring_index < 64, 'ring index outside 64-slot ring')
    _uint(ring_base, 32, 'ring base')
    _require(ring_base % 64 == 0, 'ring base must be 64-byte aligned')
    _require(ring_base + 64 * 12352 <= 1 << 32, 'ring map exceeds physical address space')
    address = ring_base + ring_index * 12352
    _require(address + len(block) <= 1 << 32, 'block address span overflows')
    output = bytearray(64)
    output[0:4] = b'ACD1'
    _put(output, 4, 2, 1)
    _put(output, 6, 2, 64)
    _put(output, 8, 8, _get(block, 8, 8))
    _put(output, 16, 8, _get(block, 16, 8))
    _put(output, 24, 8, generation)
    _put(output, 32, 8, _get(block, 56, 8))
    _put(output, 40, 4, address)
    _put(output, 44, 4, len(block))
    _put(output, 48, 4, _get(block, 52, 4))
    _put(output, 52, 2, ring_index)
    output[60:64] = b'PUB1'
    return _seal(output, 56)


def _session(session_id):
    """preserve a nonzero session identifier as sixteen opaque bytes."""
    session_id = _bytes(session_id, 'session ID')
    _require(len(session_id) == 16 and any(session_id), 'invalid session ID')
    return session_id


def make_configuration(config_id, session_id, timebase_id, manifest,
                       tick_num=80000000, tick_den=1):
    """bind exact manifest bytes to the fixed profile and calibrated timebase."""
    _identity(config_id, 'configuration ID')
    _identity(timebase_id, 'timebase ID')
    session_id = _session(session_id)
    manifest = _bytes(manifest, 'manifest')
    _require(1 <= len(manifest) <= 1048576, 'manifest length outside profile')
    _identity(tick_num, 'tick frequency numerator')
    _identity(tick_den, 'tick frequency denominator')
    _require(math.gcd(tick_num, tick_den) == 1, 'tick frequency must be reduced')
    _require(79992000 * tick_den <= tick_num <= 80008000 * tick_den,
             'tick frequency outside 100 ppm envelope')
    output = bytearray(128)
    output[0:4] = b'ACF1'
    _put(output, 4, 2, 1)
    _put(output, 6, 2, 128)
    _put(output, 8, 8, config_id)
    output[16:32] = session_id
    _put(output, 32, 2, 4)
    _put(output, 34, 2, 1)
    _put(output, 36, 2, 1)
    _put(output, 38, 2, 1)
    output[40:44] = bytes((0x33, 8, 18, 1))
    _put(output, 44, 4, 1600)
    _put(output, 48, 8, tick_num)
    _put(output, 56, 8, tick_den)
    _put(output, 64, 8, timebase_id)
    output[72:104] = hashlib.sha256(manifest).digest()
    _put(output, 104, 4, len(manifest))
    return _seal(output, 120)


def make_epoch(epoch_id, config_id, timebase_id, epoch_first_tick, session_id):
    """bind one recording epoch to its immutable configuration and origin."""
    _identity(epoch_id, 'epoch ID')
    _identity(config_id, 'configuration ID')
    _identity(timebase_id, 'timebase ID')
    _identity(epoch_first_tick, 'epoch first tick')
    session_id = _session(session_id)
    output = bytearray(64)
    output[0:4] = b'ACE1'
    _put(output, 4, 2, 1)
    _put(output, 6, 2, 64)
    _put(output, 8, 8, epoch_id)
    _put(output, 16, 8, config_id)
    _put(output, 24, 8, timebase_id)
    _put(output, 32, 8, epoch_first_tick)
    output[40:56] = session_id
    return _seal(output, 60)


def make_loss(epoch_id, first, last, causes, epoch_first_tick, exact=True,
              ticks_known=True, archive=False):
    """encode inclusive loss or uncertainty without unknown-value sentinels."""
    _identity(epoch_id, 'epoch ID')
    _uint(causes, 32, 'loss causes')
    _require(0 < causes < (1 << 19), 'unknown or empty loss causes')
    _identity(epoch_first_tick, 'epoch first tick')
    _boolean(exact, 'exact')
    _boolean(ticks_known, 'ticks known')
    _boolean(archive, 'archive scope')
    _require(archive or not causes & ((1 << 17) | (1 << 18)),
             'transport causes require archive scope')
    # absent endpoints are represented by flags, not a maximum integer sentinel.
    for value in (first, last):
        # known slots must leave room for the epoch's scheduled-count representation.
        if value is not None:
            _uint(value, 64, 'loss endpoint')
            _require(value < (1 << 64) - 1, 'loss endpoint exceeds count range')
            _uint(epoch_first_tick + value * 1600, 64, 'loss endpoint schedule')
    both_known = first is not None and last is not None
    _require(not exact or both_known, 'exact loss requires both endpoints')
    _require(not ticks_known or both_known, 'known ticks require both endpoints')
    # uncertainty envelopes with two known bounds are ordered too.
    if both_known:
        _require(first <= last, 'loss endpoints are reversed')
        _uint(last - first + 1, 64, 'inclusive loss count')
    first_tick = last_tick = 0
    # unknown timing stays zero instead of extrapolating an unqualified model.
    if ticks_known:
        first_tick = epoch_first_tick + first * 1600
        last_tick = epoch_first_tick + last * 1600
        _uint(first_tick, 64, 'loss first tick')
        _uint(last_tick, 64, 'loss last tick')
    flags = int(first is not None) | (int(last is not None) << 1)
    flags |= int(exact) << 2
    flags |= int(ticks_known) << 3
    flags |= int(archive) << 4
    output = bytearray(64)
    output[0:4] = b'ACL1'
    _put(output, 4, 2, 1)
    _put(output, 6, 2, 64)
    _put(output, 8, 8, epoch_id)
    _put(output, 16, 8, first if first is not None else 0)
    _put(output, 24, 8, last if last is not None else 0)
    _put(output, 32, 8, first_tick)
    _put(output, 40, 8, last_tick)
    _put(output, 48, 4, causes)
    _put(output, 52, 4, flags)
    return _seal(output, 56)

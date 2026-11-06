#!/usr/bin/env python3
"""compare independent producer and host formats with retained failure controls."""

import argparse
from collections.abc import Mapping
import hashlib
import json
from pathlib import Path
import random
import struct
import sys

sys.dont_write_bytecode = True
import format_producer as producer
import format_parser as host


def digest(path):
    """identify every tested source and retained artifact."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """retain fresh interoperability results without exercising hardware."""
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--output', type=Path, required=True)
    args = cli.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    sources = [Path(__file__).resolve(), Path(producer.__file__), Path(host.__file__),
               root / 'microcontroller/acquisition/formats.md']
    result = {'schema': 'DRG5-FORMAT-CONFORMANCE-1', 'status': 'started',
              'physical_qualified': False, 'hardware_exercised': False,
              'checks': [], 'source_sha256': {str(p.relative_to(root)): digest(p) for p in sources}}
    snapshots = args.output / 'sources'
    snapshots.mkdir()
    # preserve each attempt's actual definitions and independently authored codecs.
    for path in sources:
        (snapshots / path.name).write_bytes(path.read_bytes())

    def check(name, condition):
        """record each predicate before stopping on a failed comparison."""
        result['checks'].append({'name': name, 'passed': bool(condition)})
        # checks must remain active with Python optimization enabled.
        if not condition:
            raise ValueError(name)

    def reject(name, operation):
        """require a defined rejection rather than an unrelated runtime failure."""
        # malformed bytes and unsupported values must raise the public error type.
        try:
            operation()
        # preserve the actual reason for every negative control.
        except ValueError as error:
            result['checks'].append({'name': name, 'passed': True, 'rejection': str(error)})
            return
        raise ValueError('negative control accepted: ' + name)

    def mutate(data, offset, replacement, crc_offset=None):
        """repair outer integrity when testing a deeper semantic predicate."""
        changed = bytearray(data)
        changed[offset:offset + len(replacement)] = replacement
        # use the producer CRC only to construct malformed semantic test inputs.
        if crc_offset is not None:
            changed[crc_offset:crc_offset + 4] = bytes(4)
            changed[crc_offset:crc_offset + 4] = producer.crc32c(changed).to_bytes(4, 'little')
        return bytes(changed)

    def save(name, data):
        """retain small golden objects rather than every generated test block."""
        (args.output / name).write_bytes(data)

    code = 0
    # one failure leaves the exact source snapshots and completed checks available.
    try:
        check('producer CRC32C check string', producer.crc32c(b'123456789') == 0xe3069283)
        check('host CRC32C check string', host.crc32c(b'123456789') == 0xe3069283)
        samples = [-86838, 89285, -89286, 86837, 51884, 50524, -50525, -51885]
        status = list(range(8))
        check('producer ADC known pattern CRC', producer.adc_crc16(samples, status) == 0x3ee1)
        record = producer.make_record(samples, status, 0x3ee1, 224)
        golden = bytes.fromhex('caacfeffc55c01003aa3feff35530100acca00005cc50000a33affff5335ffff'
                               '0001020304050607e13eff00ff000f00')
        check('literal 48-byte record golden', record == golden and len(record) == 48)
        decoded = host.parse_record(golden)
        check('host independently decodes literal record', tuple(decoded['samples']) == tuple(samples) and
              tuple(decoded['status']) == tuple(status) and decoded['valid'] == 255)
        save('record.bin', record)

        # every truncation boundary preserves complete pairs and discards partial ones.
        for bits in range(225):
            encoded = producer.make_record(samples, status, 0x3ee1, bits)
            parsed = host.parse_record(encoded)
            pairs = min(bits // 26, 8)
            check(f'capture length {bits}', parsed['present'] == (1 << pairs) - 1 and
                  parsed['received_crc'] == (0x3ee1 if bits == 224 else 0) and
                  tuple(parsed['samples'][pairs:]) == (0,) * (8 - pairs))
        # the host checks every inferable analog-mask combination without inventing provenance.
        for mask in range(256):
            encoded = producer.make_record(samples, status, 0x3ee1, 224, analog_valid=mask,
                                           settling=(~mask) & 255)
            parsed = host.parse_record(encoded)
            check(f'analog permission mask {mask}', parsed['valid'] == mask and
                  bool(parsed['flags'] & (1 << 27)) == (mask != 255))
        # raw rail flags remain canonical even when integrity is unavailable.
        rails = [-131072, 131071, 0, 1, -1, 65536, -65536, 123]
        rail_crc = producer.adc_crc16(rails, status)
        rail_record = producer.make_record(rails, status, rail_crc, 224)
        check('signed endpoints and rail validity', host.parse_record(rail_record)['rail'] == 3 and
              host.parse_record(rail_record)['valid'] == 252)
        invalid = producer.make_record(samples, status, 0x3ee0, 224)
        check('bad ADC CRC is retained invalid evidence', host.parse_record(invalid)['valid'] == 0 and
              not host.parse_record(invalid)['flags'] & (1 << 18))
        # a complete zero trailer is distinct from an absent trailer despite identical CRC bytes.
        zero_crc = producer.make_record([0] * 8, [0] * 8, 0, 224)
        check('complete zero CRC trailer', host.parse_record(zero_crc)['flags'] & (1 << 18) and
              host.parse_record(zero_crc)['present'] == 255)
        placeholder = producer.make_record(samples, status, 0x3ee1, 0, triggered=False)
        check('untriggered placeholder bytes', placeholder[:44] == bytes(44) and
              host.parse_record(placeholder)['flags'] == 1 << 21)
        uncertain_record = producer.make_record(samples, status, 0x3ee1, 224, time_uncertain=True)
        # each status error has good transport integrity but still forbids usable samples.
        for bit in (5, 6, 7, 3, 0):
            raw_status = status.copy()
            raw_status[0] ^= 1 << bit
            encoded = producer.make_record(samples, raw_status, producer.adc_crc16(samples, raw_status), 224)
            parsed = host.parse_record(encoded)
            check(f'status bit {bit}', parsed['valid'] == 0 and parsed['flags'] & (1 << 23) and
                  bool(parsed['flags'] & (1 << 19)) == (bit >= 5))
        # all single-bit changes to this healthy record violate integrity or canonical flags.
        for offset in range(48):
            # exercise every bit, including high signed-extension and reserved bits.
            for bit in range(8):
                bad = mutate(record, offset, bytes([record[offset] ^ (1 << bit)]))
                reject(f'record mutation {offset}:{bit}', lambda bad=bad: host.parse_record(bad))

        session = bytes.fromhex('00112233445566778899aabbccddeeff')
        manifest = b'{"source":"synthetic-format-fixture","physical_qualified":false}\n'
        first_tick = 0x0102030405060708
        config_raw = producer.make_configuration(9, session, 11, manifest)
        config = host.parse_configuration(config_raw, manifest)
        epoch_raw = producer.make_epoch(7, 9, 11, first_tick, session)
        epoch = host.parse_epoch(epoch_raw, config)
        check('configuration and epoch exact sizes and binding', len(config_raw) == 128 and
              len(epoch_raw) == 64 and config['bound'] and epoch['bound'])
        save('configuration.bin', config_raw)
        save('epoch.bin', epoch_raw)
        save('qualification-manifest.bin', manifest)
        # independently lay out the header prefix with struct, separate from producer offsets.
        single = producer.make_block([record], 7, 1, 0, first_tick, 9, final=True)
        parsed_single = host.parse_block(single, config, epoch)
        expected_header = struct.pack('<4sHHQQQQIHHIIQ', b'ACQ1', 1, 64, 7, 1, 0,
                                      first_tick, 1600, 1, 1, 48, parsed_single['crc32c'], 9)
        check('independent header field packing', single == expected_header + golden)
        check('minimum block size', len(single) == 112 and parsed_single['bound'])
        save('partial-block.bin', single)
        # every legal actual record count must agree byte-for-byte and reject allocation padding.
        for count in range(1, 257):
            block = producer.make_block([record] * count, 7, 1, 0, first_tick, 9, final=count != 256)
            parsed = host.parse_block(block, config, epoch)
            check(f'block count {count}', len(block) == 64 + 48 * count and parsed['count'] == count and
                  b''.join(bytes(item['raw']) for item in parsed['records']) == block[64:])
        full = producer.make_block([record] * 256, 7, 1, 0, first_tick, 9)
        full_parsed = host.parse_block(full, config, epoch)
        save('full-block.bin', full)
        mixed = producer.make_block([record, invalid, uncertain_record, placeholder], 7, 1, 0,
                                    first_tick, 9, final=True)
        check('exact block summary reductions', host.parse_block(mixed, config, epoch)['flags'] == 7)
        check('structural block stays unbound', not host.parse_block(single)['bound'])
        # repaired block CRCs force the parser to inspect semantic fields, not only integrity.
        bad_headers = [(0, b'BAD!'), (4, b'\x02\x00'), (6, b'\x30\x00'),
                       (8, bytes(8)), (16, bytes(8)), (24, (1).to_bytes(8, 'little')),
                       (32, (first_tick + 1).to_bytes(8, 'little')), (40, (1599).to_bytes(4, 'little')),
                       (44, bytes(2)), (46, bytes(2)), (46, (9).to_bytes(2, 'little')),
                       (48, (49).to_bytes(4, 'little')), (56, (10).to_bytes(8, 'little'))]
        # each mutation preserves length and outer CRC while violating its declared field.
        for index, (offset, value) in enumerate(bad_headers):
            bad = mutate(single, offset, value, 52)
            reject(f'header semantic mutation {index}', lambda bad=bad: host.parse_block(bad, config, epoch))
        reject('block short payload', lambda: host.parse_block(single[:-1], config, epoch))
        reject('block allocation padding', lambda: host.parse_block(single + bytes(48), config, epoch))
        reject('block damaged CRC', lambda: host.parse_block(mutate(single, 52, b'\x00\x00\x00\x00'), config, epoch))

        ring_base = 0x80000000
        descriptor = producer.make_publication(single, 23, 5, ring_base)
        lease = (session, 5, 23)
        publication = host.parse_publication(descriptor, parsed_single, ring_base, lease)
        check('publication identity and byte extent', len(descriptor) == 64 and publication['bound'] and
              publication['address'] == ring_base + 5 * 12352 and publication['generation'] == 23)
        save('publication.bin', descriptor)
        check('publication without lease stays unbound', not host.parse_publication(descriptor)['bound'])
        # each component of the acquired lease key must be checked independently.
        for name, bad_lease in [('session', (bytes.fromhex('11' * 16), 5, 23)),
                                ('slot', (session, 6, 23)), ('generation', (session, 5, 24))]:
            reject('lease ' + name, lambda bad_lease=bad_lease:
                   host.parse_publication(descriptor, parsed_single, ring_base, bad_lease))
        zero_pub = mutate(descriptor, 60, bytes(4))
        reject('unpublished descriptor', lambda: host.parse_publication(zero_pub))
        reject('lost publication under live lease', lambda:
               host.parse_publication(zero_pub, parsed_single, ring_base, lease))
        bad_descriptors = [(24, bytes(8)), (40, (ring_base + 1).to_bytes(4, 'little')),
                           (44, (113).to_bytes(4, 'little')), (48, bytes(4)),
                           (52, (64).to_bytes(2, 'little')), (54, b'\x01\x00'), (60, b'BAD!')]
        # descriptor CRC coverage includes the final publication word.
        for index, (offset, value) in enumerate(bad_descriptors):
            bad = mutate(descriptor, offset, value, 56)
            reject(f'descriptor semantic mutation {index}', lambda bad=bad:
                   host.parse_publication(bad, parsed_single, ring_base, lease))
        reject('allocation map overflow', lambda: producer.make_publication(single, 1, 0, 0xffff0000))

        # metadata reservations and references must survive valid outer checksums.
        for offset in [32, 34, 36, 38, 40, 41, 42, 43, 44, 108, 112, 119, 124, 127]:
            bad = mutate(config_raw, offset, bytes([config_raw[offset] ^ 1]), 120)
            reject(f'configuration field {offset}', lambda bad=bad: host.parse_configuration(bad, manifest))
        reject('manifest byte mismatch', lambda: host.parse_configuration(config_raw, manifest + b' '))
        reject('configuration zero session', lambda:
               host.parse_configuration(mutate(config_raw, 16, bytes(16), 120), manifest))
        reject('unreduced tick frequency', lambda: producer.make_configuration(9, session, 11, manifest, 160000000, 2))
        reject('unsupported tick frequency', lambda: producer.make_configuration(9, session, 11, manifest, 80008001, 1))
        reject('epoch binding mismatch', lambda: host.parse_epoch(producer.make_epoch(7, 10, 11, first_tick, session), config))
        reject('zero epoch origin cannot follow ARM', lambda: producer.make_epoch(7, 9, 11, 0, session))
        reject('host rejects zero epoch origin', lambda:
               host.parse_epoch(mutate(epoch_raw, 32, bytes(8), 60), config))
        reject('forged configuration mapping', lambda: host.parse_epoch(epoch_raw, dict(config)))
        reject('forged epoch mapping', lambda: host.parse_block(single, config, dict(epoch)))
        reject('forged block mapping', lambda: host.parse_publication(descriptor, dict(parsed_single), ring_base, lease))
        # ordinary context assignment must fail instead of altering already validated bindings.
        try:
            config['config_id'] = 10
        # immutable mappings reject public field assignment.
        except TypeError:
            check('configuration context is immutable', config['config_id'] == 9)
        else:
            check('configuration context is immutable', False)

        loss_raw = producer.make_loss(7, 256, 258, 1 << 12, first_tick)
        loss = host.parse_loss(loss_raw, epoch)
        unknown = host.parse_loss(producer.make_loss(7, None, None, 1 << 7, first_tick,
                                                    exact=False, ticks_known=False), epoch)
        check('inclusive exact loss count', loss['count'] == 3 and loss['first_tick'] == first_tick + 256 * 1600)
        check('unknown loss is not zero count', unknown['count'] is None and unknown['first'] is None)
        save('loss.bin', loss_raw)
        totals = host.validate_loss_intervals([loss, unknown], published_blocks=[full_parsed])
        check('loss ledger excludes uncertainty', sum(totals.values()) == 3)
        reject('published-invalid records are not producer loss', lambda:
               host.validate_loss_intervals([host.parse_loss(producer.make_loss(7, 0, 0, 1 << 12, first_tick), epoch)],
                                            published_blocks=[parsed_single]))
        archive = host.parse_loss(producer.make_loss(7, 0, 0, 1 << 17, first_tick, archive=True), epoch)
        check('archive gap preserves producer publication', sum(host.validate_loss_intervals([archive],
              published_blocks=[parsed_single]).values()) == 1)
        adjacent = host.parse_loss(producer.make_loss(7, 259, 260, 1 << 12, first_tick), epoch)
        reject('unmerged adjacent exact loss', lambda: host.validate_loss_intervals([loss, adjacent]))
        reject('duplicate uncertainty', lambda: host.validate_loss_intervals([unknown, unknown]))
        reject('forged loss mapping', lambda: host.validate_loss_intervals([dict(loss)]))
        other_epoch = host.parse_epoch(producer.make_epoch(7, 9, 11, first_tick + 1, session), config)
        conflicting_loss = host.parse_loss(producer.make_loss(7, 300, 301, 1 << 12, first_tick + 1), other_epoch)
        reject('conflicting loss epoch binding', lambda: host.validate_loss_intervals([loss, conflicting_loss]))
        reject('conflicting published epoch binding', lambda:
               host.validate_loss_intervals([conflicting_loss], published_blocks=[full_parsed]))
        bad_losses = [(48, bytes(4)), (48, (1 << 19).to_bytes(4, 'little')),
                      (52, (32).to_bytes(4, 'little')), (60, (1).to_bytes(4, 'little')),
                      (32, (1).to_bytes(8, 'little'))]
        # loss timestamps and reserved values remain checked after recomputing integrity.
        for index, (offset, value) in enumerate(bad_losses):
            bad = mutate(loss_raw, offset, value, 56)
            reject(f'loss semantic mutation {index}', lambda bad=bad: host.parse_loss(bad, epoch))
        reject('loss reserved slot maximum', lambda: producer.make_loss(7, (1 << 64) - 1,
               (1 << 64) - 1, 1, 1, ticks_known=False))
        reject('known loss schedule overflow even without ticks', lambda:
               producer.make_loss(7, (1 << 64) - 2, (1 << 64) - 2, 1, 1, ticks_known=False))

        # ledger continuity uses sequence, epoch and generation as different identities.
        ledger = host.StreamLedger(session)
        check('first stream block', ledger.accept(full_parsed)['archive_sequence_gap'] is None)
        next_raw = producer.make_block([record], 7, 2, 256, first_tick, 9, final=True)
        next_block = host.parse_block(next_raw, config, epoch)
        check('partial final stream block', ledger.accept(next_block)['archive_sequence_gap'] is None)
        reject('duplicate stream block', lambda: ledger.accept(next_block))
        next_epoch = host.parse_epoch(producer.make_epoch(8, 9, 11, first_tick + 1_000_000, session), config)
        next_epoch_block = host.parse_block(producer.make_block([record], 8, 3, 0,
                                           next_epoch['first_tick'], 9, final=True), config, next_epoch)
        check('new epoch keeps stream sequence', ledger.accept(next_epoch_block)['archive_sequence_gap'] is None)
        gap_ledger = host.StreamLedger(session)
        gap = gap_ledger.accept(host.parse_block(producer.make_block([record], 7, 2, 256,
                               first_tick, 9, final=True), config, epoch))
        check('archive sequence gap is explicit', gap['archive_sequence_gap'] == (1, 1))
        new_config = host.parse_configuration(producer.make_configuration(10, session, 11, manifest, 80000001, 1), manifest)
        bad_epoch = host.parse_epoch(producer.make_epoch(9, 10, 11, first_tick + 2_000_000, session), new_config)
        bad_model = host.parse_block(producer.make_block([record], 9, 4, 0, bad_epoch['first_tick'],
                                                       10, final=True), new_config, bad_epoch)
        reject('timebase frequency cannot change under same ID', lambda: ledger.accept(bad_model))
        # rejected identity updates must not poison a later correct sequence.
        good_epoch = host.parse_epoch(producer.make_epoch(9, 9, 11, first_tick + 2_000_000, session), config)
        good_next = host.parse_block(producer.make_block([record], 9, 4, 0, good_epoch['first_tick'],
                                                       9, final=True), config, good_epoch)
        check('ledger rejection is atomic', ledger.accept(good_next)['archive_sequence_gap'] is None)
        origin_epoch = host.parse_epoch(producer.make_epoch(1, 9, 11, first_tick, session), config)
        impossible_prefix = host.parse_block(producer.make_block([record], 1, 3, 0,
                                              first_tick, 9, final=True), config, origin_epoch)
        reject('first epoch cannot hide earlier epochs in sequence gap', lambda:
               host.StreamLedger(session).accept(impossible_prefix))
        possible_prefix = host.parse_block(producer.make_block([record], 1, 3, 512,
                                            first_tick, 9, final=True), config, origin_epoch)
        check('first epoch gap has full prefix blocks',
              host.StreamLedger(session).accept(possible_prefix)['archive_sequence_gap'] == (1, 2))
        finalized = host.StreamLedger(session)
        finalized.accept(parsed_single)
        missing_prefix = host.parse_block(producer.make_block([record], 8, 3, 0,
                                           next_epoch['first_tick'], 9, final=True), config, next_epoch)
        reject('gap after FINAL belongs to immediate next epoch prefix', lambda: finalized.accept(missing_prefix))
        backwards_ledger = host.StreamLedger(session)
        backwards_ledger.accept(full_parsed)
        backwards_epoch = host.parse_epoch(producer.make_epoch(8, 9, 11, first_tick + 10, session), config)
        backwards = host.parse_block(producer.make_block([record], 8, 2, 0,
                                       backwards_epoch['first_tick'], 9, final=True), config, backwards_epoch)
        reject('same timebase cannot overlap prior ticks', lambda: backwards_ledger.accept(backwards))
        reset_config = host.parse_configuration(producer.make_configuration(10, session, 12, manifest), manifest)
        reset_epoch = host.parse_epoch(producer.make_epoch(8, 10, 12, 1, session), reset_config)
        reset_block = host.parse_block(producer.make_block([record], 8, 2, 0, 1, 10, final=True),
                                       reset_config, reset_epoch)
        check('new timebase permits tick restart', backwards_ledger.accept(reset_block)['archive_sequence_gap'] is None)
        max_generation = producer.make_publication(single, (1 << 64) - 1, 63, ring_base)
        check('final generation is represented without wrap', host.parse_publication(max_generation,
              parsed_single, ring_base, (session, 63, (1 << 64) - 1))['generation'] == (1 << 64) - 1)
        max_sequence = (1 << 64) - 1
        exhausted = host.StreamLedger(session)
        terminal_sequence = host.parse_block(producer.make_block([record], 7, max_sequence, 0,
                                            first_tick, 9, final=True), config, epoch)
        check('final u64 sequence does not wrap', exhausted.accept(terminal_sequence)['sequence_exhausted'])
        reject('stream cannot continue after sequence exhaustion', lambda: exhausted.accept(terminal_sequence))
        reject('timestamp overflow', lambda: producer.make_block([record] * 256, 7, 1, 0,
                                                                 (1 << 64) - 2, 9))
        reject('producer rejects empty block', lambda: producer.make_block([], 7, 1, 0, first_tick, 9))
        reject('producer rejects nonfinal partial block', lambda: producer.make_block([record], 7, 1, 0, first_tick, 9))
        reject('producer rejects unsupported sample width', lambda: producer.make_record([131072] * 8, status, 0, 224))
        reject('producer rejects untriggered captured data', lambda: producer.make_record(samples, status, 0x3ee1, 1, triggered=False))

        rng = random.Random(0xAC010001)
        # deterministic randomized payloads exercise signed values and all analog permissions.
        for index in range(256):
            codes = [rng.randrange(-131072, 131072) for _ in range(8)]
            mask = rng.randrange(256)
            trailer = producer.adc_crc16(codes, status)
            encoded = producer.make_record(codes, status, trailer, 224, analog_valid=mask)
            parsed = host.parse_record(encoded)
            rail_mask = sum(1 << c for c, value in enumerate(codes) if value in (-131072, 131071))
            check(f'random payload {index}', tuple(parsed['samples']) == tuple(codes) and
                  parsed['valid'] == (mask & ~rail_mask & 255))
        check('source stability', all(digest(path) == result['source_sha256'][str(path.relative_to(root))]
                                      for path in sources))
        result['status'] = 'independent-format-conformance-pass'
    # report implementation mismatches without erasing earlier evidence.
    except Exception as error:
        result.update({'status': 'failed', 'error_type': type(error).__name__, 'error': str(error)})
        code = 1
    result['checks_passed'] = sum(item['passed'] for item in result['checks'])
    result['artifacts_sha256'] = {str(path.relative_to(args.output)): digest(path)
                                  for path in sorted(args.output.rglob('*')) if path.is_file()}
    (args.output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'status': result['status'], 'checks_passed': result['checks_passed'],
                      'error': result.get('error')}))
    return code


# run the offline conformance campaign without programming or ADC access.
if __name__ == '__main__':
    sys.exit(main())

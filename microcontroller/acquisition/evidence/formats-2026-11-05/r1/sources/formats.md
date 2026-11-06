# ACQ-R1 binary formats

ACQ-R1 revision 4 freezes the following version-1 byte formats. They are a producer/host interoperability target, not an implemented ADC/DMA/MMIO binding. All multibyte integers are **little-endian**, signed fields use two's complement, and there is no compiler padding, implicit alignment, compression or floating-point value. Offsets are decimal bytes from the beginning of the named object. Opaque byte strings preserve their listed byte order. Unknown magic/version/size, reserved bits, inconsistent fields, failed integrity or unchecked arithmetic are rejected; a parser never repairs them silently.

## Objects and context

| Object | Magic | Exact bytes | Integrity field |
| --- | --- | ---: | --- |
| Sample record | None; embedded in ACQ1 | 48 | Received ADC CRC16 and canonical validity flags; protected by enclosing block CRC32C |
| Data block | `ACQ1` | `64 + 48*N`, N=1..256 | CRC32C at byte 52 |
| Publication/allocation descriptor | `ACD1` | 64 | CRC32C at byte 56 |
| Immutable configuration binding | `ACF1` | 128 | CRC32C at byte 120; SHA-256 binds external qualification-manifest bytes |
| Epoch binding | `ACE1` | 64 | CRC32C at byte 60 |
| Loss/uncertainty interval | `ACL1` | 64 | CRC32C at byte 56 |

ASCII magic bytes are literal, not an integer spelling. The publication descriptor is the **64-byte per-block memory metadata** in the timing budget. Configuration/epoch bindings and loss intervals are control/archive metadata, not extra bytes appended to every raw block. The complete analog/board/clock qualification manifest can be larger than 128 bytes; ACF1 is its exact immutable binding, not a claim that all qualification evidence fits into a small hardware descriptor.

Each archive/lease context supplies a nonzero, externally unique **16-byte recording_session_id**, the matching ACF1 and ACE1 objects, the exact referenced manifest bytes, and an approved allocation map when memory addresses are used. Session bytes are opaque: text displays exactly 32 lowercase hexadecimal digits in byte order, with no UUID mixed-endian transformation. A block or publication descriptor without this context can be inspected as bytes but cannot be accepted as an identified recording. CRCs detect accidental corruption; neither CRC nor SHA-256 alone authenticates the producer or establishes physical qualification.

All CRC32C fields use reflected polynomial `0x82f63b78`, initial register `0xffffffff`, and final XOR `0xffffffff`; process bytes in increasing address order, least-significant bit first within each byte. Store the final numeric value little-endian. `123456789` gives `0xe3069283`. For each object, cover its **entire actual byte extent**, substituting four zero bytes for its own CRC32C field. No allocation padding, transport framing or other object is included. ACD1 coverage includes the final `PUB1` word; ACF1 additionally binds the separate manifest by SHA-256. ADC CRC16 is a different, MSB-first wire check.

## The 48-byte record

| Offset | Width/type | Meaning |
| ---: | --- | --- |
| 0,4,8,12,16,20,24,28 | Eight i32 | V1..V8 raw signed18 codes, sign-extended without scaling; range −131072..131071 |
| 32..39 | Eight u8 | Raw status bytes in V1..V8 wire position; never reordered from their IDs |
| 40 | u16 | Received ADC CRC16 numeric trailer; zero unless all 224 bits arrived |
| 42 | u8 | PRESENT mask; bit c marks a complete sample18/status8 pair in position c |
| 43 | u8 | Reserved, must be zero |
| 44 | u32 | Flags below |

The total is `8*4 + 8 + 2 + 1 + 1 + 4 = 48`. PRESENT must be one of `00,01,03,07,0f,1f,3f,7f,ff`: a single serial lane cannot create holes. An absent pair has sample=0 and status=0. A partial pair and a partial CRC trailer are discarded, not zero-padded into apparently received evidence. Raw present bytes remain even when their integrity fails. A complete trailer equal to zero is distinguishable from no trailer by COMPLETE.

| Flag bit(s) | Name | Canonical meaning |
| --- | --- | --- |
| 0..7 | VALID[c] | Producer's per-channel electronic-valid result, constrained below |
| 8..15 | RAIL[c] | Exactly PRESENT[c] and sample[c] in {−131072,131071}; raw indication remains even if CRC is bad |
| 16 | TRIGGERED | Scheduled CONVST pulse was emitted for this slot |
| 17 | COMPLETE | Exactly 224 bits from the matching conversion were received; implies TRIGGERED and PRESENT=ff |
| 18 | CRC_OK | Exactly COMPLETE and received CRC16 equals the recomputed 208-bit CRC |
| 19 | FRAME_INTEGRITY | Exactly COMPLETE and CRC_OK and all eight positional IDs/reserved status bits pass |
| 20 | SETTLING | At least one channel is within a declared settling/recovery interval; implies ANALOG_INVALID |
| 21 | MISSING | Exactly NOT COMPLETE, including untriggered placeholders |
| 22 | TRUNCATED | TRIGGERED and 1..223 bits received; implies MISSING |
| 23 | STATUS_FAULT | Any present status has wrong positional ID, nonzero reserved bits, reset, digital error or open flag |
| 24 | RESET_SEEN | OR of raw status bit7 over present pairs |
| 25 | DIGITAL_ERROR_SEEN | OR of raw status bit6 over present pairs |
| 26 | OPEN_SEEN | OR of raw status bit5 over present pairs; unexpected in R1 |
| 27 | ANALOG_INVALID | At least one producer analog-valid permission is absent |
| 28 | TIME_UNCERTAIN | Scheduled-marker/aperture association is unqualified; VALID must be zero |
| 29..31 | Reserved | Must be zero |

Status bits7/6/5 are reset/error/open, bits4..3 are reserved zero, and bits2..0 must equal the wire position c. FRAME_INTEGRITY does **not** test the high error bits: a correctly transported reset status can have FRAME_INTEGRITY=1 and STATUS_FAULT=1. Its VALID bits are still all zero. CRC_OK and FRAME_INTEGRITY must be checked independently by the host, not trusted from stored flags.

Reconstruct the 208 CRC input bits as `(sample[c] & 0x3ffff)` bit17..0 followed by status[c] bit7..0, for c=0..7, with no padding between pairs. Starting at zero, for each bit XOR it with old CRC bit15, shift the 16-bit CRC left and XOR `0x755b` when that feedback is one. No reflection, appended zero pass or final XOR. The fixed profile vector has CRC `3ee1`; mathematical bytes `06 4e` give `2137`. The received trailer itself is excluded. [The ADC profile](adc-profile.md) supplies the vector and original wire convention.

Producer rule: `VALID = PRESENT & analog_valid_mask & ~RAIL` only if TRIGGERED, FRAME_INTEGRITY, no STATUS_FAULT and no TIME_UNCERTAIN; otherwise VALID=0. SETTLING's channel mask is a subset of the absent analog permissions. The record does not contain the analog-permission/settling masks: their cause/onset/channel provenance belongs to the immutable configuration and retained events/quality amendments. The host treats VALID as the producer's authoritative mask, while enforcing every inferable constraint. With good frame/status/time and ANALOG_INVALID=0, VALID must equal `ff & ~RAIL`; with ANALOG_INVALID=1, VALID must be a subset of that mask and cannot be ff. The host cannot infer a unique analog mask from an invalid record. It must not invent one.

Untriggered placeholders have samples/status/trailer/PRESENT/VALID/RAIL/COMPLETE/CRC_OK/FRAME_INTEGRITY/TRUNCATED/status-derived flags all zero, with MISSING=1. SETTLING, ANALOG_INVALID and TIME_UNCERTAIN may still describe the scheduled interval. Triggered, incomplete, nontruncated records mean zero bits received and also have no present pairs. For a truncated frame with k present pairs, the captured-bit range is 1..25 for k=0, 26*k..26*k+25 for k=1..7, and 208..223 for k=8. The exact discarded-bit count is not recoverable from this record and is not fabricated by the parser.

## The 64-byte block header

| Offset | Width/type | Required value/meaning |
| ---: | --- | --- |
| 0 | 4 bytes | `ACQ1` |
| 4 / 6 | u16 / u16 | Format version 1 / header bytes 64 |
| 8 | u64 | Recording epoch ID, nonzero |
| 16 | u64 | Session-wide stream block sequence, nonzero |
| 24 | u64 | First slot index within this epoch |
| 32 | u64 | First scheduled acquisition tick |
| 40 | u32 | Period ticks, exactly 1600 |
| 44 | u16 | Actual record count N, 1..256 |
| 46 | u16 | Block flags: bit0 FINAL, bit1 HAS_INVALID, bit2 HAS_TIME_UNCERTAIN; bits3..15 zero |
| 48 | u32 | Payload bytes, exactly 48*N |
| 52 | u32 | CRC32C of header with this field zero plus exactly N records |
| 56 | u64 | Configuration ID, nonzero |

Every byte 0..63 is assigned once. Record i occupies bytes `64+48*i .. 111+48*i`, i=0..N−1. Its slot is `first_slot+i` and scheduled tick is `first_tick+1600*i`, checked without overflow. ACE1 requires `first_tick = epoch_first_tick + 1600*first_slot`. A producer begins at slot zero, publishes full 256-record blocks in order, then at most one final partial block. Therefore first_slot is a multiple of 256. There are no hidden gaps, empty data blocks or mixed epoch/configuration blocks.

HAS_INVALID is exactly the OR of `record.VALID != ff`; HAS_TIME_UNCERTAIN is exactly the OR of record.TIME_UNCERTAIN. N=1..255 requires FINAL=1. A full block may set FINAL if closure was known at publication; an already published full block is never rewritten to add it. Terminal metadata identifies the last block even if its FINAL bit is clear. A zero-slot epoch has an ACE1/terminal outcome and no ACQ1 block. Full size is **12,352 bytes**; minimum partial size is **112 bytes**; payload max 12,288 fits u32 and N=256 fits u16. Bytes after actual length in a 12,352-byte allocation are neither serialized nor CRC-covered and must not be exported as padding.

## The 64-byte publication descriptor

| Offset | Width/type | Required value/meaning |
| ---: | --- | --- |
| 0 | 4 bytes | `ACD1` |
| 4 / 6 | u16 / u16 | Version 1 / descriptor bytes 64 |
| 8 / 16 / 24 | u64 each | epoch_id / stream_block_sequence / allocation_generation; all nonzero |
| 32 | u64 | config_id, nonzero |
| 40 | u32 | Physical byte address of ACQ1 header |
| 44 | u32 | Actual block byte length, exactly `64+48*N` |
| 48 | u32 | Duplicate of the block's CRC32C numeric field |
| 52 | u16 | Ring index, 0..63 |
| 54 | u16 | Reserved flags, exactly zero |
| 56 | u32 | Descriptor CRC32C; coverage includes the final PUB1 word |
| 60 | 4 bytes / aligned u32 | Publication word `PUB1`, integer `0x31425550`; zero means unpublished |

This totals 64 bytes and matches the publication-metadata limit. Epoch, sequence, configuration, actual length and block CRC must match the block. An approved session allocation map gives a 64-byte-aligned u32 ring base and fixed 12,352-byte slot stride. Require `address=base+index*12352`; check the entire 64-slot map and actual address+length with wider arithmetic before narrowing to u32. The exclusive end may equal 2^32, but no accessed byte may exceed `0xffffffff`. Examples use synthetic addresses, not an approved physical RAM map. Allocation generation is checked against the acquired lease, never guessed from the ring index or block sequence.

Publication order is payload/header completion and global visibility, descriptor bytes0..59 containing CRC computed for final PUB1, then an aligned atomic 32-bit release publication-word store. Lease grants additionally require the allocation manager's PUBLISHED state and matching full 64-bit generation. Consumers acquire that lease before reading; while held, descriptor and block bytes are immutable. A double-read of PUB1 alone is **not** an ABA-safe snapshot and does not make the other 64-bit fields atomic on RV32. A transport copy must be made under such a lease and retain its session context.

On retirement, revoke publication, write zero to the publication word and make it visible before any descriptor-body reuse, but only after all leases/accesses are retired or positively contained. Capture publication writes exactly 60+4 bytes; transport reads at most 64 descriptor bytes. The additional **4-byte retirement store belongs to the allocation-control master**, within its separately qualified 4 MB/s service reservation, with normal acknowledgement ≤80 µs and timeout/fault action by 100 µs. At +100 ppm it adds at most 781.328125 bytes/s. It is not free capture/transport traffic; failure retains the allocation as nonfree. Drain does not wait for consumer retirement. Generation changes only on fully retired return to FREE. An unpublished/mid-write descriptor is `NOT_PUBLISHED`, never a valid empty block. Once PUB1 is visible, any structural/CRC/identity mismatch is corruption/fault; no retries that silently reinterpret mixed generations. No memory ordering or coherence primitive is presumed implemented by this format specification.

The 64 publication descriptors require **4096 bytes** outside the 790,528-byte raw ring, with an independently approved, aligned and nonoverlapping allocation. Raw slots plus descriptor table total **794,624 bytes (776 KiB)**. These metadata objects do not consume hidden tail bytes of partial blocks.

Descriptor decode precedence is exact 64-byte length, then publication word. Zero returns `NOT_PUBLISHED` without interpreting an in-progress body only when no live PUBLISHED lease is asserted. Zero under an acquired published lease is corruption. PUB1 requires all structural, CRC and contextual checks; any other publication word is rejected. The offline parser's lease argument is the complete `(session_id, ring_index, allocation_generation)` acquired key; all three must match. Generation alone is insufficient because different slots may simultaneously have generation 1.

## Configuration and epoch bindings

ACF1 binds the entire external qualification manifest by exact length and SHA-256 of its original bytes; no JSON reordering, newline normalization or implicit default changes are allowed before hashing. The manifest is opaque to the byte-layout codec: its complete supported profile and physical qualification are separately checked under the contract before ARM. A digest match proves only byte identity. Keeping that scope explicit prevents a structural parser from claiming that analog evidence has been verified.

| ACF1 offset | Width/type | Meaning |
| ---: | --- | --- |
| 0 / 4 / 6 | magic4 / u16 / u16 | `ACF1` / version 1 / bytes 128 |
| 8 | u64 | config_id, nonzero |
| 16 | 16 bytes | recording_session_id, nonzero opaque bytes |
| 32 / 34 / 36 / 38 | u16 each | ACQ-R1 contract revision 4 / record version 1 / block version 1 / publication descriptor version 1 |
| 40 / 41 / 42 / 43 | u8 each | ADC ID 33 hex / 8 channels / 18 sample bits / 1 status byte per channel |
| 44 | u32 | Period 1600 ticks |
| 48 / 56 | u64 each | Calibrated tick frequency numerator / denominator in Hz; positive, reduced fraction, within 80 MHz ±100 ppm |
| 64 | u64 | timebase_id, nonzero |
| 72 | 32 bytes | SHA-256 digest of manifest, ordinary digest byte order |
| 104 | u32 | Manifest byte length, 1..1,048,576 |
| 108 | u32 | Reserved flags, zero |
| 112 | 8 bytes | Reserved zero |
| 120 | u32 | CRC32C of all 128 bytes with this field zero |
| 124 | 4 bytes | Reserved zero |

| ACE1 offset | Width/type | Meaning |
| ---: | --- | --- |
| 0 / 4 / 6 | magic4 / u16 / u16 | `ACE1` / version 1 / bytes 64 |
| 8 / 16 / 24 | u64 each | epoch_id / config_id / timebase_id, nonzero |
| 32 | u64 | Epoch's nonzero first scheduled tick, including a zero-slot epoch's intended first tick; ARM tick A gives A+1 without wrap |
| 40 | 16 bytes | recording_session_id, identical to ACF1/context |
| 56 | u32 | Reserved flags, zero |
| 60 | u32 | CRC32C of all 64 bytes with this field zero |

All ACF1 bytes and the manifest are immutable for config_id within a session. ACE1 is immutable for epoch_id. A new epoch can reuse the same configuration/timebase binding after explicit requalification if the contract permits; it cannot change the old binding. The config_id/timebase_id/session fields must agree across context; ACQ1/ACD1 must select that epoch/configuration. Session/ACF1/manifest metadata is archived before ARM. Successful ARM atomically creates and retains ACE1 with its newly allocated epoch and first tick; admission reserves a separate 64-byte metadata delivery slot, independent of data/event queues. ACE1 is archived before the host accepts that epoch's blocks, without delaying the first scheduled slot for host acknowledgement. Retain that delivery slot through closure and release it with matching ACK_TERMINAL after the recorder has archived the binding and terminal evidence; the session registry keeps its immutable identity thereafter. Missing metadata means `UNBOUND`, not a guessed session or clock. The format does not allocate an MMIO address or imply external RAM is present.

Within a session, timebase_id also binds the immutable reduced frequency numerator/denominator. Another configuration may reuse it only with the same frequency tuple. Subsequent accepted blocks/epochs on that timebase must start strictly after its last accepted scheduled tick; resetting or overlapping ticks requires a new timebase ID. Equality of the entire physical clock/uncertainty/marker-delay model remains a pre-ARM qualification obligation of the external manifest; the layout codec cannot establish it from an opaque digest. Session ledgers bind configuration, epoch and numeric timebase identities across both blocks and loss entries, rejecting conflicting bytes/models before changing ledger state.

## Three independent identifiers and exhaustion

| Identifier | Scope and progression | Never use it as |
| --- | --- | --- |
| Recording epoch | Nonzero u64; new recording interval after ARM; slot numbering restarts at zero | Stream order or allocation lifetime |
| Stream block sequence | Nonzero u64; starts at 1 per session, advances only on successful publication, across epoch boundaries | Epoch ID, slot index or ring index |
| Allocation generation | Nonzero u64 per ring position; begins at 1 and advances only after fully retired reuse | Stream order or configuration identity |

The memory lease key is `(session_id, ring_index, allocation_generation)` with the published epoch/sequence/config binding checked as well. Two blocks can have the same generation in different slots, and a reused slot can have a different generation while stream sequence remains monotonic. Physical ring indices wrap 63→0; identities do not wrap.

Zero is reserved for IDs, not an unknown sentinel inside a published object. U64_MAX may appear as a final valid identity/counter value, but no successor is allocated in that session. Reaching that limit inhibits further acquisition admission; previously accepted work may finish with its reserved identity. Close/contain, archive terminal evidence and require a new externally unique session before reinitializing counters; merely draining an old session does not authorize reuse. Generation exhaustion quarantines the exhausted allocation until this new-session recovery. CPU reset/debug resume never resets these namespaces.

Slot index U64_MAX is forbidden: an epoch containing it would need 2^64 scheduled slots in a u64 count. Last slot is at most U64_MAX−1, and the timestamp formula usually imposes a much smaller bound. Check slot addition, inclusive count `last−first+1`, epoch-first plus slot*1600, record/header byte lengths, allocation multiplication and address end in wider arithmetic. Saturation/ACCOUNTING_INEXACT is a fault outcome, never an on-wire modulo value. Stream parsers reject duplicate/reordered sequence identities and report a forward gap as missing transport/archive evidence; they do not infer that producer sequence allocation skipped or renumber later blocks. Standalone structural decoding is distinct from this session-ledger check.

A stream sequence gap also constrains possible history. Within one observed epoch, each skipped block must have been full, so the next first_slot advances by 256 for each missing sequence in addition to the preceding observed count. For the first observed block of epoch 1, every skipped sequence is an epoch-1 prefix. Likewise, after an observed FINAL block in epoch E, skipped blocks before observed epoch E+1 are prefixes of that next epoch. Those cases require `first_slot=missing_sequences*256`; where unobserved earlier/intervening epochs are possible, only `first_slot≤missing_sequences*256` is justified. The ledger reports gaps but does not certify terminal/archive completeness.

The offline descriptor check proves equality with the supplied trusted lease key and decoded block binding. It does not reconstruct hardware retirement history. The allocation manager must bind that lease to the published epoch/sequence/configuration and provide an immutable snapshot from the currently owned allocation; CRC-valid self-consistency alone is not evidence of authorized reuse.

## Exact loss and uncertainty intervals

Loss is a **missing record**, not a stored record with VALID=0. Every interval is scoped by the enclosing session and its epoch_id. Endpoints are **inclusive**. Exact producer-loss ranges cover scheduled slots that were never published and participate once in `scheduled = published + lost`. They must not overlap published slot ranges. Archive-gap ranges describe blocks/records unavailable to that archive even if the producer published them; they never change producer counters. A corrupt block's unchecked header cannot establish an exact loss interval; use independently validated context or retain unknown bounds.

| ACL1 offset | Width/type | Meaning |
| ---: | --- | --- |
| 0 / 4 / 6 | magic4 / u16 / u16 | `ACL1` / version 1 / bytes 64 |
| 8 | u64 | epoch_id, nonzero and bound by ACE1 |
| 16 / 24 | u64 each | First / last inclusive slot, or zero when its known bit is clear |
| 32 / 40 | u64 each | First / last scheduled tick, or zero when TICKS_KNOWN is clear |
| 48 | u32 | Nonzero cause bitmap below |
| 52 | u32 | bit0 FIRST_KNOWN; bit1 LAST_KNOWN; bit2 EXACT; bit3 TICKS_KNOWN; bit4 ARCHIVE_SCOPE; bits5..31 zero |
| 56 | u32 | CRC32C of all 64 bytes with this field zero |
| 60 | u32 | Reserved zero |

EXACT requires both endpoints known and a checked u64 count. Every known endpoint is at most U64_MAX−1; whenever both are known, require first≤last even if EXACT=0. With ACE1 context, each known endpoint's schedule formula must fit u64 regardless of TICKS_KNOWN. TICKS_KNOWN additionally requires both endpoints known and the two serialized ticks to equal those formulas; ticks describe scheduled markers, not measured apertures. Unknown fields store zero with their known bit clear; a known endpoint may legitimately equal zero. With EXACT=0, known endpoints bound a **possible unavailable interval** rather than declaring every slot lost; unknown first/last leaves that side unbounded by this entry. An all-unknown uncertain interval is valid and does not invent counts. Uncertain intervals never add to exact lost counters or erase already-published evidence. They describe availability/accounting uncertainty, not the separate quality-amendment format for invalidating samples that remain present.

Cause bits: 0 BUSY_RISE_TIMEOUT; 1 BUSY_FALL_TIMEOUT; 2 FRAME_TIMEOUT; 3 SYNC_FAULT; 4 ADC_FAULT; 5 ANALOG_FAULT; 6 TIMEBASE_FAULT; 7 POWER_OR_ENGINE_RESET; 8 EXPLICIT_STOP; 9 CPU_HALT; 10 CPU_RESET; 11 NO_CAPACITY; 12 MEMORY_FAULT; 13 DRAIN_TIMEOUT; 14 EVENT_OVERFLOW; 15 COUNTER_EXHAUSTED; 16 INTERNAL_FAULT; 17 TRANSPORT_CORRUPTION; 18 HOST_MISSING_BLOCK. Bits19..31 are reserved zero. Bits17/18 require ARCHIVE_SCOPE. Producer-loss entries have ARCHIVE_SCOPE=0; an untriggered published placeholder is not a loss entry even when its stop cause matches.

For each `(session,epoch,ARCHIVE_SCOPE)`, exact intervals are sorted by first slot and disjoint. Adjacent intervals with identical cause/flag sets are merged; split at cause boundaries and OR cause bits on intersections before merging, rather than double-counting overlap. Their counts add with overflow checks. Uncertain envelopes may overlap exact ranges as uncertainty annotations but contribute zero exact count. Retain them separately, sorted by `(FIRST_KNOWN, first_or_zero, LAST_KNOWN, last_or_zero, flags, causes)`, with false before true. Identical bounds/flags merge their cause bits; duplicate or unmerged copies are rejected. No uncertainty envelope upgrades a record's VALID bit. Terminal/archive status remains `CLOSED_CLEAN`, `CLOSED_LOSS`, `CLOSED_UNCERTAIN` or `INCOMPLETE` as defined in the contract; an ACL1 entry alone is not a terminal record or proof of archive completeness.

## Independent producer and host acceptance

The producer starts each object from zero bytes, writes only the listed fields, computes record flags from captured evidence/qualified permissions, computes block reductions/CRC, and emits actual lengths. It never dumps a native structure or allocation padding. The host independently validates exact lengths and reserved values before dereferencing fields, checks integrity, validates all record predicates, binds configuration/epoch/lease context, and then applies session sequence/loss ledgers. Parsed context is immutable and retains the validated raw bindings; arbitrary dictionaries or edited field copies cannot assert bound=True. No field is silently truncated to its storage width. The Python API protects ordinary context use, not arbitrary hostile Python execution within the same process.

The [producer oracle](format_producer.py) and [host parser](format_parser.py) must share no packing helpers, offset constants or CRC implementation. A separate conformance runner checks hand-constructed golden bytes, signed endpoints, all complete-pair prefixes, invalid/status/CRC combinations, partial/full blocks, descriptor addresses/generations, context bindings, counter limits and malformed objects. Round-tripping through one implementation alone is insufficient. [Retained format review](evidence/formats-2026-11-05/review.json) records revisions and the actual independent results. These tools model the format; they do not qualify ADC capture, concurrent RV32 publication or physical memory ordering.

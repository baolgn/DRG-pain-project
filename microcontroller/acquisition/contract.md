# First acquisition implementation contract

Contract **ACQ-R1, revision 4**, 2026-11-05. MUST, MUST NOT and REJECT are normative. Revision 4 freezes the [binary formats](formats.md), canonical validity predicates, publication/configuration/epoch descriptors, loss intervals and independent host interpretation. It preserves the 48-byte record, 64-byte block header and version-1 record/block encoding. Revision 3's [timing budget](timing-budget.md), nominal 14 µs deadline and revision 2's electrical restrictions remain. This is the implementation target, not a claim that the complete engine exists. [The implementation boundary](#existing-implementation-and-release-gates) identifies the current synthetic guard. This contract, its [ADC profile](adc-profile.md), formats and timing budget decide ACQ-R1 behavior where older architecture diagrams show alternatives.

The normative [ACQ-R1-CDC1 lifecycle supplement](clock-reset-lifecycle.md) defines fixed clock domains, coherent crossings, retained ownership and distinct reset scopes. It preserves revision 4's byte encoding; qualification metadata additionally binds the supplement and implemented crossing/reset design. Reset release and link readiness never imply ARM, completion or free storage.

## Input boundary and supported profile

**Conditioned analog voltages enter the ADC.** The digital engine begins at the ADC control/data pins. The source, protection, amplification, reference arrangement, DC management, anti-alias filtering and ADC drive belong to the qualified external analog chain. A digital-valid record is not proof of electrode continuity, biological meaning, analog headroom or safe biological connection. The undecided Abbott connection supplies **no assumed recording interface, sample stream, connector, protocol or timing source**. Initial qualification uses synthetic electrical sources.

ACQ-R1 supports exactly the following recording tuple, as a whole. There is no negotiation to a subset and no nearest-rate rounding.

| Property | Only accepted recording value |
| --- | --- |
| ADC | AD7606C-18; exact qualified ID `0x33` (part code 3, silicon revision 3) |
| Control | Software mode, `OS[2:0]=111`, `PAR/SER=1`; sequencer owns all ADC pins |
| Input/reference | All eight channels, bipolar single-ended ±2.5 V, low bandwidth; internal 2.5 V reference, `REFSELECT=1` |
| Calibration | ADC gain correction zero, offset code `0x80`, phase correction zero on every channel; external measured calibration is metadata only |
| Conversion | Normal power, simultaneous channels, oversampling and padding off; internal conversion clock; external CONVST from scheduler |
| Serial | One DOUTA lane; MSB first; sample18/status8 pairs in V1 through V8 order, then CRC16; 224 bits per conversion |
| Serial clock | 20 MHz nominal, idle high, falling-edge capture; SDI zero during conversion-data reads |
| Acquisition clock | Independent qualified 80 MHz nominal, ±100 ppm including environmental drift, fixed throughout an epoch; separate jitter/skew and supervisor requirements in the timing budget; direct-interface VDRIVE and ECP5 VCCIO 3.135–3.465 V with paired-rail, sequencing and pin-limit qualification |
| Cadence | Exactly 1600 acquisition ticks per slot: nominal 20 µs and 50 kSPS **per channel** |
| Recording mode | External analog inputs; interface test, diagnostic mux, open-circuit detection and ADC self-test acquisition are service-only or disabled as specified in the profile |
| Data path | Mandatory raw retention; 48-byte records, up to 256 records/block, 64-byte header; no decimation, channel suppression or DSP substitution |

REJECT hardware control mode, other ADC parts/revisions, parallel or byte interfaces, 2/4/8 output lanes, missing status or CRC, other ranges, differential/unipolar selection, mixed channel settings, enabled oversampling/padding, phase shifts, standby/shutdown recording, external reference, other clocks/rates, external triggers, burst/on-demand recording, and channel subsets/reordering. Rejection preserves the current configuration, state, epoch and schedule. An unsupported request during RUN does not stop a valid recording. Actual unsolicited hardware changes are faults and do stop it.

Physical qualification is a required capability, initially false. A build with a 25 MHz CPU may qualify a separate 80 MHz acquisition domain in the future; the existing 25 MHz CPU image does not qualify this profile. No physical profile may be advertised available until all release gates below pass.

## Configuration and commands

An immutable configuration descriptor contains the complete tuple, exact ADC image, board/FPGA/firmware identities, ADC ID, physical pin/reference settings, channel-to-connector map, source identity, analog-chain revision and measured gain/filter/calibration identities, clock identity and frequency/tolerance calibration, marker-to-pin delay and uncertainty, analog settling/recovery qualification, and the bounded memory/closure service qualification. Unknown required fields mean `UNQUALIFIED`, never a default that implies measurement. For synthetic qualification the source is explicitly synthetic.

Revision 3 requires every phase/path/service limit in the [timing budget](timing-budget.md), including the independent supervisor, ≤250 ms analog-settling admission, guaranteed capture bandwidth and bounded transaction/publication latency. Reject a descriptor that exceeds any allocation or lacks its qualification evidence. A bounded timeout supplies a defined failure outcome; it does not establish successful service or physical qualification.

Each descriptor receives a session-local, monotonically allocated nonzero 64-bit `config_id`, mapped to the immutable descriptor and its SHA-256 digest. A distinct descriptor cannot reuse an ID. Digital configuration and physical qualification are separate: successful register readback does not establish analog settling. ACQ-R1 admits only prequalified static analog configurations. An analog change is made while stopped and requalified; an unannounced change during capture is a fault.

The 128-byte ACF1 configuration binding identifies the session, exact frequency/timebase and the length/SHA-256 of the full qualification manifest. It is distinct from the 64-byte ACD1 memory publication descriptor. Session/ACF1/manifest metadata is archived before ARM. ARM reserves a separate 64-byte ACE1 delivery slot, atomically retains the new epoch ID and first scheduled tick, and does not wait for host archival before its first slot. The host must obtain that binding before accepting blocks. Matching ACK_TERMINAL releases its delivery reservation after archival; immutable session-registry bindings remain available.

The logical control-command interface uses one active operation and one separate retained final-completion slot, tagged with a monotonically increasing, nonwrapping 64-bit command sequence within the recording session. Admission is a separate request/acknowledgement handshake returning the sequence and `ACCEPTED` or the rejection code; the requester holds its request stable until that handshake. The admission reply does not consume the final-completion slot, so an occupied slot can still return `COMMAND_BUSY`. Accepted work reserves that slot until final completion is acknowledged. Queries, event/IRQ/terminal acknowledgements, lease release and emergency STOP have independent service paths; they remain operable while a control operation/completion occupies the slot. The [control foundation](control-foundation.md) defines a component MMIO binding for lifecycle, configuration and evidence. Its offsets are not mapped into the current CPU fabric, and it does not implement memory leases or the full engine. An integrated binding must preserve these semantics:

| Request | Permitted state and result |
| --- | --- |
| `CONFIGURE(descriptor)` | SAFE, READY or CLOSED only, with old capture ownership fully resolved and any prior terminal record archived/acknowledged. Validate the whole descriptor before pin writes. Accepted request enters CONFIGURING; success atomically publishes the descriptor and enters READY. No epoch starts. |
| `ARM(config_id)` | READY only; active descriptor matches, all qualification gates true, CPU running, queues empty, no old capture owner, no pending fault and at least 24 truly free ring blocks. Accept creates one new epoch, enters RUN; first slot is the next acquisition edge. |
| `STOP` | RUN: inhibit new triggers and close. STOPPING/DRAINING: join the existing closure, no second epoch or boundary. READY/SAFE/CLOSED: `ALREADY_STOPPED`, no changes. CONFIGURING: cancel service safely, enter SAFE, return `CANCELLED` for the active CONFIGURE or RECOVER operation and `ALREADY_STOPPED` on the STOP path once pins are idle. FAULT: `FAULT_LATCHED`, no recovery. |
| `RECOVER` | FAULT or CLOSED only, after old work is contained and any prior terminal record archived/acknowledged. Run full startup/configuration qualification with the last validated supported descriptor; success enters READY, failure FAULT. Missing descriptor returns `UNQUALIFIED`. Never arms automatically. |
| `READ_STATUS`, `READ_EVENT` | Any accessible state: coherent snapshot or oldest retained event. Empty queue returns `EMPTY`, not an invented event. Reads do not release blocks, clear faults or restart. |
| `ACK_EVENT`, `ACK_IRQ(mask)` | Acknowledge only the identified event/current pending causes. Missing/mismatched event sequence returns `STALE_COMMAND`; unknown IRQ-mask bits return `INVALID_REQUEST`; neither changes state. ACK_IRQ of a supported but clear cause succeeds as a no-op. Same-edge new causes dominate clearing. Lifetime and epoch evidence remain. |
| `ACK_TERMINAL(epoch_id)` | Acknowledge an existing terminal record only after the recorder has durably archived it and all preceding quality amendments. Wrong/duplicate identity returns `STALE_COMMAND`; no state, ownership or counters change. Hardware retains the last terminal summary after releasing its archive-delivery slot. |
| `ACK_COMPLETION(sequence)` | Release only the matching final-completion slot; absent/stale sequence returns `STALE_COMMAND`. Does not acknowledge events, terminal records or blocks. |
| `RELEASE(block, generation)` | Only matching current consumer lease with all its reads completed. Release that lease once; absent/stale/duplicate release returns `STALE_LEASE`, no ownership change. |

Control-request precedence is: malformed/unknown opcode or nonzero reserved input → `INVALID_REQUEST`; old/duplicate sequence → `STALE_COMMAND`; occupied operation/completion slot → `COMMAND_BUSY`; unsupported tuple → `UNSUPPORTED_PROFILE`; wrong state → `INVALID_STATE`; absent qualification/capacity → `UNQUALIFIED`/`NO_CAPACITY`; otherwise accept. All unlisted command/state combinations return `INVALID_STATE`. A well-formed new control sequence is consumed on admission acknowledgement, including rejection, except `COMMAND_BUSY` permits retry with the same sequence. Service paths use their stated object identities, not the control sequence allocator. REJECT has no operational side effects; its tagged admission reply is the observable result. Rejections do not consume acquisition event capacity. Completion backpressure cannot stall autonomous STOP or fault handling. Emergency STOP has its own retained request/acknowledgement and is accepted independently of the ordinary command slot; repeated STOP joins that acknowledgement rather than allocating another closure.

Admission and completion are different. `ACCEPTED` acknowledges ownership of the command; final completion is `OK`, `CANCELLED`, `CONFIGURATION_FAILED`, `CLOSED_CLEAN`, `CLOSED_LOSS` or `CLOSED_UNCERTAIN`. Successful ARM completes `OK` when the epoch and first tick are published, without waiting for a conversion. STOP completes with the epoch closure outcome on its independent path; no-epoch STOP uses the immediate outcomes in the table. Configuration failure after pin writes invalidates the active qualification and enters FAULT; it does not pretend the previous ADC image survived. There are no automatic retries. Configuration, including startup and interface test, has a three-second independent-supervisor deadline from acceptance; expiration is `CONFIGURATION_FAILED`. Response/event transport disappears on total power loss; the archive rules below define that outcome.

## States and transitions

| State | Invariant, outputs and exits |
| --- | --- |
| SAFE | No epoch, no conversion; `CONVST=0`, `CS=1`, `SCLK=1`, `SDI=0` when powered. Unqualified after initial/reset isolation. CONFIGURE may start qualification. |
| CONFIGURING | Exclusive service owner; reset, register transfers and bounded interface-test conversions allowed. These are never recording slots/records. Success → READY; cancellation → SAFE; mismatch/timeout/qualification loss → FAULT. |
| READY | Qualified immutable configuration, disarmed; safe-idle pins. ARM → RUN. Qualification loss → FAULT. |
| RUN | Fixed-grid slots; at most one outstanding conversion and one reserved outcome per slot. Hardware owns cadence and capture. STOP/fatal condition → STOPPING or directly DRAINING if no frame remains. |
| STOPPING | No new triggers or slots after the acceptance edge; finish the already emitted legal pulse and resolve the pending conversion by its original deadline. Then → DRAINING. |
| DRAINING | Freeze producer watermark; no new enqueues after it. Resolve FIFO, staging, DMA and final block. Successful containment/publication → CLOSED; uncontained work or uncertain clock/reset recovery → FAULT. |
| CLOSED | Epoch terminal outcome sealed; published blocks and consumer leases persist. No automatic restart. CONFIGURE or RECOVER can reach READY; ARM directly returns `INVALID_STATE`. |
| FAULT | Recording inhibited; preserve available evidence and quarantine uncertain owners. Pins idle once electrically safe. RECOVER requires positively contained old work and explicit requalification. Invalid/unencoded hardware states force this state with `INTERNAL_FAULT`. |

Supervisor-detected power/clock/reset faults can preempt every state. A powered controller inhibits CONVST immediately on qualification loss without waiting for an IRQ. If power is absent, pin voltage levels cannot be guaranteed by logic; board isolation must be qualified. Acquisition-clock loss must be detected and isolated within 10 µs by an independent qualified supervisor. Total power loss may prevent a final event or block from being written; it never implies clean closure.

Global edge priority is physical isolation/reset fault, then CPU reset/debug halt or emergency STOP, then ordinary command completion/admission. A simultaneous STOP vetoes ARM/CONFIGURE/RECOVER admission with `STOP_ACTIVE`: no new epoch, pin write or transient READY-to-RUN transition. If service completion and STOP coincide, cancel that service instead of publishing READY. Fault wins over cancellation and returns `CONFIGURATION_FAILED`. CPU halt/reset in CONFIGURING cancels the active service, invalidates qualification and returns to SAFE after bounded safe pin termination; a termination failure enters FAULT. In SAFE/READY/CLOSED it leaves the engine disarmed and preserves observations, with ARM vetoed for the entire asserted level. In STOPPING/DRAINING it continues hardware closure without CPU assistance. In FAULT it does not clear or recover the fault. An inaccessible CPU may read the retained result after resuming; total engine reset uses the new-session rules.

Safe service termination has a 14 µs independent-supervisor bound from cancellation: finish a legal RESET/CONVST pulse or the current bounded serial transaction, then idle. If that cannot be confirmed, isolate and enter FAULT. Physical fault isolation always takes priority over continuing service.

On a RUN edge the ordering is: latch all synchronized faults/stop requests; accept already offered downstream handshakes; resolve a matching conversion (qualification loss overrides its validity); account a due slot; decide trigger admission; enter stop/closure; then expose events and response snapshots. Capacity/qualification admission uses the pre-edge coherent snapshot: same-edge FIFO dequeue or ring release does not rescue a high-water/no-credit stop. A record staging register handed off on this edge may accept a replacement outcome; that is not new FIFO/ring admission credit. A matching complete frame on its exact deadline wins over timeout. If a slot is due on the stop edge, that slot exists but its trigger is suppressed: retain an invalid placeholder or loss-account it. No later slots exist. If a previous frame was still outstanding at the start of a due edge, the new trigger is suppressed even if that frame completes on the edge. Reset/clock uncertainty overrides these exact-order promises and uses uncertain closure.

## Epochs and identity

An **epoch is a recording interval with one consistent configuration and timing model**. It begins when ARM is accepted, before its first possible slot, and ends at trigger inhibition; closure may finish later. Its immutable header binds the configuration, timebase, initial scheduled tick and identity. Because the first slot is on the next acquisition edge, an ordinary synchronous STOP has no intervening edge: STOP on that first edge accounts one untriggered slot. A zero-slot epoch occurs only if independent reset/isolation prevents the first due edge; report zero only if that fact is known, otherwise report an uncertain boundary. It has terminal metadata if recoverable and no data block.

The archive key is `(recording_session_id, epoch_id, slot_index)`. A new recorder session obtains an externally recorded, unique nonzero 128-bit session ID before enabling recording. The recorder must reject reuse against its session registry; an unverified ID inhibits ARM. Within a session, epoch IDs begin at 1 and increase on each successful ARM; rejected ARM does not consume one. Slot indices begin at zero per epoch and never wrap; slot U64_MAX is reserved because its zero-based count would require 65 bits. Epoch/config/block/generation/command IDs and counters must stop before wrap or ambiguous reuse. Ring indices may wrap normally with a new generation. Recording epoch, session-wide stream block sequence and per-ring-slot allocation generation are separate namespaces; the formats define their exact stored widths and lifetime rules.

| Boundary cause | Required meaning |
| --- | --- |
| Explicit stop, debug halt or CPU-only reset | End epoch via controlled stop; preserve acquisition tick, counters, identities and old ownership. CPU reset is never permission to clear the engine. |
| ADC full or partial reset, acquisition reset, FPGA reconfiguration, power interruption | End epoch. Partial ADC reset is not an ACQ-R1 command. Unexpected reset invalidates the in-flight frame; full requalification required. Lost retained identity requires a new session ID and timebase ID. |
| Requested rate or timebase change | Unsupported ACQ-R1 values are rejected without changing an epoch. A future supported change must close first; no in-epoch changes. |
| Actual oscillator/PLL/reference-clock change, relock, loss, tick correction or discontinuity | End epoch with timing fault. New timebase ID and measured model required; do not extrapolate across the gap. |
| Gain, filter, coupling, reference, range, source/channel wiring, calibration or analog power change | End epoch before an intentional physical change. Unannounced changes revoke analog validity and fault-close; a descriptor edit alone cannot assert the hardware is settled. |
| Settling or recoverable overload within the same qualified analog configuration | May remain in epoch only with qualified recovery/observation ≤249 ms from known onset, independent timeout/fault action by 250 ms, and per-slot invalid interval. Timeout, unknown onset or changed transfer/timing model ends epoch. |

If a fault discovered late may affect earlier samples, publish an immutable epoch quality amendment containing the affected inclusive slot range, cause and uncertainty. If onset is unknown, it covers the whole epoch. Consumers apply amendments on top of record flags; raw published blocks are not rewritten. An archive missing the terminal record or a required amendment stream is `INCOMPLETE`, never certified valid. Qualification cannot depend on a monitor that does not physically exist.

## Cadence and timestamp meaning

The 64-bit tick counts acquisition edges at nominal 80 MHz, independent of CPU execution. Tick value `T` identifies that edge before increment. If ARM is accepted at tick `A`, `first_tick=A+1`; due slot `n` is `first_tick + 1600*n`, with checked integer arithmetic. ARM rejects an unrepresentable first tick. An epoch closes before its next scheduled tick or identity would overflow; no modulo ordering is used. The [implemented scheduler](slot-scheduler.md) checks a future binding and its frame horizon before admission. The [timing wrapper](timing-integration.md) connects its same-edge ARM and timestamp to control. The old guard remains a separate synthetic prototype.

The record timestamp is the **scheduled CONVST rising-edge marker**, not BUSY fall, serial completion, DMA completion, IRQ service, host arrival or UTC. `TRIGGERED=1` means that the pulse was actually emitted on that marker. When zero, the same timestamp locates a missing scheduled conversion, not a measured aperture. All eight channels share that slot marker; serial order adds no channel time offsets. Physical aperture time includes measured FPGA/board marker-to-pin delay and ADC aperture behavior. Analog/filter delay is a separate calibration; it is not silently subtracted from stored ticks.

The descriptor stores the rational calibrated tick frequency, calibration uncertainty and qualification limits. Nominal elapsed time is `(T-first_tick)/80,000,000` seconds; calibrated elapsed time uses the frozen rational frequency. Absolute/UTC mapping is absent unless a separate mapping with uncertainty is archived. A new calibration applied to timing interpretation requires a new epoch/timebase model, never a retroactive tick rewrite.

CONVST is high for 8 ticks (100 ns nominal) and then low. At most one conversion is active; read only after its matched BUSY rise and fall. Rise must be observed by trigger+20 ticks; fall by trigger+160 ticks; complete serial frame, checks and stable staged record by trigger+1120 ticks. These are nominal tick-domain deadlines including synchronization; at ±100 ppm, 1120 ticks spans 13.998600–14.001400 µs. Independent hard wall-time limits are separately allocated in the [timing budget](timing-budget.md). A matching event at the deadline is on time; an event after it is late. A slot is never shifted to wait for BUSY, memory, CPU or host. No catch-up pulses, timestamp relabeling, repeated samples or rate throttling are allowed. The [ADC profile](adc-profile.md) defines serial edges; the timing budget defines their composed qualification margins and bounded downstream handoff.

## Conversion outcomes and validity

Each scheduled slot resolves once: a published valid/partly invalid/invalid record, or explicit lost interval in closure. A record may be offered to a FIFO before publication; that handshake is not archive durability. No interval is hidden by compacting sample indices. After a deadline/abort resolves a slot, subsequent data is discarded and logged as stale; it can never upgrade its placeholder, change its flags or satisfy a new slot. Receiver capture stops at the specified frame length; unexpected additional transfer/ownership activity is a synchronization fault.

| Observation | Slot result | Continue epoch? |
| --- | --- | --- |
| On-time complete expected frame, good CRC/status, qualified analog channel | Preserve signed codes/status; corresponding channels valid | Yes |
| Complete matched frame with CRC mismatch, wrong channel ID or reserved status bits | Preserve wire-position evidence, clear all channel-valid bits, report integrity cause | Yes, only while framing ownership and all qualification remain intact |
| Missing BUSY rise, BUSY fall timeout, truncated/no frame by deadline | Invalid record with only complete sample/status pairs retained; missing pairs zero and marked absent | No; timeout, quarantine late edges/results, full requalification |
| BUSY high before trigger, unsolicited BUSY edge, overlapping frame or stale/duplicate completion | Do not trigger/reuse data; account due slot if any and log offending identity | No; synchronization lost |
| Stop/halt/reset request exactly on due edge, or no record reservation/capacity | Untriggered placeholder if credit exists; otherwise explicit lost slot | No |
| ADC reset status, ADC digital-error status, unexpected open-circuit flag, actual configuration drift | Clear all valid bits, preserve status/evidence, latch cause | No; open detector is disabled, so an asserted open flag is unexpected |
| Known settling/recovery interval, qualified per-channel analog-invalid permission | Preserve raw frame, clear affected channel-valid bits; cause describes settling/analog condition | Yes within the frozen bounded policy; timeout or lost qualification stops |
| Signed code at either exact ADC endpoint | Set that channel's rail flag and clear its valid bit; preserve code | Yes; no invented upstream saturation detector |
| Memory write/error/deadline, lease failure, FIFO high water, ring exhaustion, event overflow | Preserve published data; stop and account uncommitted tail | No |

Unknown or contradictory input/status combinations are `INTERNAL_FAULT`: no valid record, stop and quarantine affected work. A frame with a bad CRC cannot make its status trustworthy; any captured reset/digital-error/open flag still mandates stop, and is labeled untrusted evidence. Failure causes accumulate; one cause must not mask another. For repeated invalid-but-complete frames there is no silent retry or automatic recovery; each gets its own slot result and event. Exhausted event capacity stops capture.

For channel `c`, `VALID[c] = TRIGGERED AND PRESENT[c] AND FRAME_INTEGRITY AND analog_valid[c] AND NOT rail[c] AND NOT reset_or_digital_or_unexpected_open_fault AND NOT TIME_UNCERTAIN`. `FRAME_INTEGRITY` requires exact 224-bit framing, expected IDs 0..7, reserved status bits zero, and CRC match. Service/test captures never enter the recording stream. `VALID=0` always forbids treating the code as a usable measurement, even if its number looks plausible. `VALID=1` is only the defined electronic qualification; it does not certify biology or absence of an unmonitored fault.

## Records and block publication

All multibyte stored fields are little-endian; this does not change MSB-first ADC wire order. No compiler struct padding is allowed. Unknown format versions, nonzero reserved bits, invalid lengths, inconsistent identities or CRC32C mismatch are rejected by consumers as corrupt blocks, never partially decoded as valid data. The archive preserves the corruption event and unavailable slot range; it must not call corrupt bytes successfully archived measurements.

The [binary format specification](formats.md) is the complete byte-level authority, including exact flag implications, context binding, reserved values, integrity coverage and parser rejection. The tables here summarize the same version-1 layout. A CRC-valid but internally contradictory object is still rejected. A canonical record describing a failed ADC CRC remains validly encoded evidence with sample-valid bits clear.

| Record byte offset | Width | Meaning |
| --- | --- | --- |
| 0..31 | 8 × signed32 | V1..V8; sign-extend the 18-bit two's-complement wire code without scaling (−131072..131071) |
| 32..39 | 8 × u8 | Raw status in the same wire positions; channel ID is checked, never used to silently reorder |
| 40..41 | u16 | Received CRC trailer; zero if trailer not fully received |
| 42 | u8 | `PRESENT` bitmap: each bit means its complete 18+8-bit pair arrived at the expected position; does not imply integrity |
| 43 | u8 | Reserved zero |
| 44..47 | u32 | Flags below |

An absent pair has sample=0, status=0, PRESENT=0, VALID=0. PRESENT is a contiguous low-bit prefix. Partial pairs are discarded, not padded into a sample. An untriggered placeholder has all data/status/CRC/presence zero, MISSING=1 and TRIGGERED=0. MISSING is exactly NOT COMPLETE; incomplete trailers store zero. CRC failure preserves received evidence with VALID=0; a zero code alone cannot distinguish a measured zero from a placeholder. Analog-permission masks are producer provenance in events/metadata, not secretly reconstructible from the record's summary flags.

| Flag bits | Meaning when set |
| --- | --- |
| 0..7 | Per-channel VALID as defined above |
| 8..15 | Per-channel exact endpoint/rail indicator from a present raw code; trustworthy only when frame integrity passes |
| 16 | TRIGGERED: actual scheduled pulse emitted |
| 17 | COMPLETE: exactly 224 wire bits captured for the matching conversion |
| 18 | CRC_OK: complete frame CRC matches the fixed convention |
| 19 | FRAME_INTEGRITY: COMPLETE, CRC_OK, IDs/order/reserved bits all pass |
| 20 | SETTLING: at least one channel within a declared settling/recovery interval |
| 21 | MISSING: no complete matching frame, including untriggered slot |
| 22 | TRUNCATED: nonzero but fewer than 224 captured bits |
| 23 | STATUS_FAULT: wrong ID, reserved bit, reset, digital error or unexpected open flag |
| 24 / 25 / 26 | Observed reset / digital error / open flag respectively; evidence may be untrusted if CRC fails |
| 27 | ANALOG_INVALID: at least one channel's analog-valid permission absent |
| 28 | TIME_UNCERTAIN: marker/aperture association cannot be qualified; all VALID bits zero |
| 29..31 | Reserved zero |

Events and terminal metadata provide exact missing/stop causes and affected channel masks when summary flags cannot. A complete received frame can be invalid; a published block can contain invalid records. A FIFO `record_valid` or block-ready signal denotes ownership/availability, never sample validity.

| Header offset | Width | Value/meaning |
| --- | --- | --- |
| 0 | 4 bytes | ASCII `ACQ1` |
| 4 / 6 | u16 / u16 | Format version 1 / header bytes 64 |
| 8 / 16 | u64 / u64 | epoch_id / session-wide block sequence starting at 1 |
| 24 / 32 | u64 / u64 | first slot index / first scheduled tick |
| 40 | u32 | period ticks = 1600 |
| 44 / 46 | u16 / u16 | record count 1..256 / block flags |
| 48 / 52 | u32 / u32 | payload bytes = count×48 / CRC32C |
| 56 | u64 | config_id |

Block flags: bit0 FINAL (last nonempty block of a closed epoch), bit1 HAS_INVALID (exact OR of record VALID!=ff), bit2 HAS_TIME_UNCERTAIN (exact OR of record TIME_UNCERTAIN); bits3..15 zero. CRC32C covers the entire header with bytes52..55 zero plus the actual payload, reflected polynomial `0x82F63B78`, initial/final XOR `0xFFFFFFFF`; check string `123456789` → `0xE3069283`. ADC CRC16 and block CRC32C are different checks. Header IDs resolve through the enclosing session, ACF1 and ACE1 bindings; blocks without those bindings are unbound, not a new guessed session.

Records in a block are consecutive slots from one epoch/configuration. Record ordinal `i` has slot `first_slot+i` and tick `first_tick+1600*i`; first_slot is a multiple of 256 and its tick must match ACE1. No empty data block, mixed epoch, hidden gap or padding record is allowed. Full blocks are 12,352 bytes every 5.12 ms at nominal cadence (2,412,500 B/s); partial blocks have exactly `64+48*count` bytes and must set FINAL. Unused allocation tail bytes are not serialized or CRC-covered. Closure may follow an already published full block, so FINAL is not retroactively set on it: the mandatory terminal record identifies the final block sequence whether or not any block has FINAL.

FIFO capacity is 256 complete records plus their metadata; occupancy ≥192 inhibits the next trigger and requests stop. ARM requires empty ingress and at least 24 truly free blocks in a 64-block ring. A free block has no capture owner, consumer lease, outstanding access or quarantine. The 100 ms host-stall target is conditional on those reserves and qualified DMA service, not a guarantee supplied by capacity alone.

Publication occurs only after every payload/header write succeeds and is globally visible, then an atomic descriptor changes ownership to PUBLISHED with block sequence/generation. A single publisher reserves the next block sequence while building its header and commits that sequence only on successful publication; an unpublished failure consumes no sequence. Thus published sequences are consecutive within the session; an observed gap means missing/corrupt transport or archive data, never an undocumented allocation gap. Generation starts at 1 per ring position and increments only on a fully retired return to FREE; it cannot wrap. Until publication consumers cannot read the block. Published bytes remain immutable. Consumers release their own generation-tagged leases after reads finish; optional DSP may be denied a lease and must not stall raw recording. Publication is memory visibility, not persistent host storage; the host separately acknowledges durable archive storage. Sequence/generation reuse is prohibited until all old accesses are completed or positively contained.

ACD1 is exactly 64 bytes and publishes with its aligned PUB1 word last. Reading that word twice is not an ABA-safe lease: acquisition requires the complete `(session_id, ring_index, generation)` key and the manager's immutable publication binding. The separate descriptor table consumes 4096 bytes. Retirement clears the publication word through the allocation-control master's separately budgeted four-byte write; no byte or traffic is hidden in the raw-block payload. Exhaustion requires a new unique session after containment, never in-session counter reset.

## Stop, loss and restart

Stop inhibits new triggers on the first acquisition edge that observes it, subject to the same-edge rule above. An emitted CONVST pulse finishes its legal width unless power failure prevents this. The pending conversion resolves by its original deadline, never by an extended stop timeout. The producer then freezes its final enqueue watermark and transfers it through a retained closure channel independent of the data FIFO. DMA resolves all records through that watermark and any owned staging; it publishes a nonempty final partial block only if all writes are confirmed.

The independent supervisor allows at most 10 ms from stop acceptance to publication/containment. At deadline it records `DRAIN_TIMEOUT`, isolates the producer and quarantines uncertain writes. If containment is not positively confirmed, state remains FAULT and restart remains inhibited; timeout alone never frees storage. A closure receipt does not claim all consumers have released or all data reached disk.

The mandatory terminal record is retained outside the full data/event queues until the recorder archives it. It contains session/epoch/config/timebase identities; all stop causes; stop-request tick, trigger-inhibition tick and resolved last-slot tick with separate known/unknown indicators; zero-slot indicator; scheduled, triggered, untriggered, published and lost counts; published slot ranges and final block sequence; known lost inclusive slot ranges and causes; any uncertain tail bounds; event-loss count; outstanding/quarantined ownership; and outcome:

| Outcome | Meaning |
| --- | --- |
| `CLOSED_CLEAN` | Every scheduled slot published, no lost records/events, exact accounting, timing model preserved, no fault causes; explicit software stop only. Invalid analog/rail records remain explicitly invalid. |
| `CLOSED_LOSS` | Boundary/counts exact and old writes contained, but faults, known lost records or event loss occurred. The name includes fault closures with zero record loss; cause bits and counts distinguish them. |
| `CLOSED_UNCERTAIN` | Exact boundary/counts/time or containment evidence unavailable. Preserve known lower bounds/ranges; unknown is not zero. Requires fault recovery; no continuity claim. |
| `INCOMPLETE` (archive inference) | No trustworthy terminal record after disconnect, reset or power loss. All preceding committed blocks remain evidence, but end time, final loss and final quality are not known. |

With exact accounting, `scheduled = triggered + untriggered = published + lost`. Published valid and invalid records both count as published. `invalid` is a quality count for resolved invalid slots and may overlap lost; never add it to published/lost. FIFO-accepted (`retained`) and emitted-trigger counters are intermediate observations, not extra terms in the final identity. Records removed from staging after FIFO acceptance but before publication count as lost exactly once. Known losses are represented as ranges; if required range/boundary evidence cannot be retained, stop, preserve known evidence and mark remaining accounting uncertain. Notification-only event overflow with exact slot/boundary evidence instead yields `CLOSED_LOSS` and its counted event loss.

ACL1 intervals use inclusive endpoints, checked counts, explicit known flags and zero in unknown fields. Exact producer-loss ranges are sorted/disjoint and exclude published records; adjacent equal-cause ranges merge. Uncertain availability envelopes contribute no exact count. Archive-gap scope records missing/corrupt transport separately and never changes producer counters. U64_MAX is not an unknown sentinel. The formats specify cause bits, canonical ordering and integrity coverage; an interval alone is not a terminal record.

With a service failure, later frames must not be published past an unretained gap; ACQ-R1 stops and accounts the uncommitted suffix. Already published blocks remain readable. An invalid record and a lost record are distinct: the former preserves position in a block; the latter requires a terminal lost range. Reaching an integer's maximum exactly inhibits further admission with `COUNTER_EXHAUSTED` while preserving exact accounting. An attempted increment beyond it saturates, sets sticky `ACCOUNTING_INEXACT` and yields uncertain closure; counters never roll over or silently clear. Hardware reset that erases counters starts a new session and leaves the old session incomplete unless its terminal evidence was already archived.

Restart is explicit: archive/acknowledge old terminal metadata, contain or retire old operations, retain or release consumer-owned blocks correctly, restore admission reserve, RECOVER/CONFIGURE and requalify, then ARM. Even unchanged settings create a new epoch and slot zero; stopped time contains no scheduled slots. Old results/IRQs/releases cannot satisfy new ownership. A new epoch cannot mix with the prior partial block. CPU reset or debugger resume never automatically restarts capture.

CPU-only reset retains peripheral mailboxes, response sinks and allocation owners. Acquisition reset that destroys timing/accounting starts a new session; system reset and FPGA reconfiguration assume no volatile ownership authority survives. The lifecycle supplement defines their containment and requalification rules. When destructive reset erased the terminal record, explicitly archive the surviving session as INCOMPLETE and establish containment/new-session recovery authority; do not fabricate ACK_TERMINAL or wait indefinitely for an erased object. This does not waive acknowledgment of a terminal that actually survives.

## Events, interrupts and CPU responsibilities

Events contain session/epoch identity when known, event sequence, occurrence tick plus time-known flag, affected slot/range/channel mask, cause set, and offending transaction identity where relevant. Causes include accepted service/configuration failure, BUSY sequence, frame timeout/truncation/CRC/status, ADC reset, analog change/recovery, timebase/power loss, capacity/memory/lease failure, stale result, event overflow, counter exhaustion and internal fault. Command admission rejections use only their admission reply, not this queue. Causes without a slot carry `slot_known=false`, never a fabricated slot zero. Simultaneous causes are retained together; their internal ordering is not inferred from one tick. Event sequence starts at 1 per session and increments per event occurrence, including counted dropped events; gaps identify notification loss. It cannot wrap, and an increment that cannot be represented forces uncertain closure.

The initial event queue holds one event, held stable until acknowledged, with sticky first/latest fault summaries and a saturating lost-event count outside it. If acknowledgement and a new event share an edge, the new event takes the freed entry. Otherwise overflow preserves the older queued event, updates latest/sticky summaries, counts the lost event and requests stop. Overflow evidence cannot depend on space in that queue. Terminal outcome uses uncertain closure only if exact slot/timing accounting was also lost; ordinary counted notification loss is `CLOSED_LOSS`.

Interrupts are level-sensitive pending causes: BLOCK_READY, EVENT_READY, EPOCH_CLOSED and FAULT. R1 uses no coalescing. Pending status remains readable when masks disable the CPU line; sticky faults and direct hardware stop remain active. Clearing BLOCK_READY while unread descriptors remain reasserts it; clearing EVENT_READY while an event remains reasserts it; EPOCH_CLOSED persists until terminal acknowledgement. Fault acknowledgement clears notification only, not the qualification latch. Set wins over same-edge clear. IRQ acknowledgement neither frees a block nor changes the recording state.

| Hardware responsibility | CPU/recorder responsibility |
| --- | --- |
| Drive scheduled CONVST, track BUSY, own serial pins, check CRC/status, assemble/retain slot results | Supply complete supported configuration and physical qualification evidence; never bit-bang or service a sample deadline |
| Maintain tick/epoch/slot identity independently; retain ACE1 on ARM; stop on halt/reset/unsafe conditions | Archive session/configuration metadata before ARM and the retained epoch binding before accepting blocks; request start/stop/recovery explicitly |
| Reserve storage, bound DMA service, protect immutable published blocks and account losses | Service block/event IRQs, archive raw records and quality amendments, release correct leases after use |
| Preserve fault/terminal evidence and stop without firmware assistance | Read coherent RV32 snapshots; acknowledge only processed observations; report missing terminal metadata as incomplete |
| Reject unsupported combinations and unsafe transitions | Check final command results, restore capacity and requalify after faults; never reinterpret rejected settings as active |

The CPU does not generate cadence, timestamp on IRQ arrival, hide invalid samples, clear epoch counters on restart, or keep acquisition alive by promising an ISR latency. Optional analysis overload may drop derived results with its own accounting; it may not alter raw cadence or raw records.

## Existing implementation and release gates

The existing [drg5_acquisition_guard.sv](../rtl/drg5_acquisition_guard.sv) supplies synthetic slot/record/stop accounting only. Its states IDLE/RUN/STOPPING/DRAIN/SEALED are internal prototype states, not the full control API above. It admits the logical 80 MHz/1600-tick profile, accepts synthetic completion metadata, keeps ticks/counters through CPU reset and debug halt, and requires an external closure attestation. It does **not** configure an ADC, sample BUSY/DOUTA, implement this record/header encoding, validate session/descriptor metadata, enforce the 1120-tick frame deadline, implement memory/host persistence, or prove independent clock-loss recovery. Its 1600-tick synthetic frame timeout remains a documented integration gap. Diagnostic 48-byte fixture payloads are not ACQ-R1 records.

The [control peripheral](../rtl/drg5_acquisition_control.sv) implements the lifecycle and retained command/fault mechanisms described in its [component specification](control-foundation.md). The [timing wrapper](../rtl/drg5_acquisition_timing.sv) now connects it to a shared timebase and the fixed-grid slot scheduler. It uses synchronous qualification, service and closure inputs supplied by its surrounding integration. These components do not establish ADC readback, archive durability, memory containment, physical clock supervision or CDC correctness. They do not instantiate the synthetic guard or form a complete acquisition engine. The separate [single-clock record ledger and scheduler adapter](storage-integration.md) now implement preallocated complete-record ownership with synthetic capture and DMA peers. They do not implement the required asynchronous crossing or memory publication. An implementation may advertise `ACQ-R1_AVAILABLE` only after all of these gates pass for the exact build/board:

| Gate | Required positive and failure-control evidence |
| --- | --- |
| Profile admission | Accept exactly the tuple; mutate every field and combined invalid fields; reject atomically with unchanged pins/config/epoch, including during RUN |
| ADC startup/framing | Exact image/readback/device ID; reset timing; initial two-lane to one-lane and register CRC transitions; independent known-pattern/status/CRC vectors, signed18 limits and all channel positions |
| Timing | All timing-budget allocations demonstrated: measured clock tolerance, marker/aperture delay, CONVST/BUSY/CS/SCLK/DOUTA/SDI setup/hold, load, routing/translation, CDC and independent supervision; every worst-case path meets its deadline with margin |
| Lifecycle | Every command/state cell, simultaneous causes, stop-on-due, zero-slot epoch, exact-deadline result, stale/duplicate result, CPU reset/debug halt, normal and abrupt reset/clock/power recovery |
| Validity | Missing/truncated/CRC/status/rail/settling outcomes; unknown analog onset and quality amendments; no missing zero interpreted as measurement |
| Storage/closure | No premature publication or owned overwrite; partial/full/zero-record closure, counter/ID/event overflow, DMA timeout with late writes and quarantine, exact accounting identities and incomplete archive recovery |
| Physical recording | Qualified synthetic analog path and ADC pin captures; sustained thirty-minute recording and 100 ms host stall under admitted reserves; independent replay including metadata and terminal outcomes |

The [review record](review.md) records definition review and comment checks. Passing a specification review closes semantic gaps; it does not close the implementation or physical qualification gates.

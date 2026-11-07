# Acquisition control and fault foundation

This document specifies control ABI **ACQ-CONTROL-1**, implemented by [drg5_acquisition_control.sv](../rtl/drg5_acquisition_control.sv). It binds the command and evidence requirements of [ACQ-R1](contract.md) to a standalone synthesizable register bank and lifecycle controller. It does not change the frozen recording formats.

The module runs entirely on one fixed clock. Its intended acquisition clock is 80 MHz with the previously specified tolerance. MMIO, backend responses and qualification inputs must already be coherent in that domain. No CPU bus decoder, CDC bridge, ADC startup sequencer, serial capture, record scheduler, FIFO, DMA, memory lease manager or physical supervisor is instantiated here. The module is not connected to the existing CPU board image or synthetic guard. Consequently this foundation cannot assert physical ACQ-R1 availability. The input boundary remains conditioned analog voltages at the ADC; no Abbott recording interface is assumed.

## Clock, ownership and backend boundary

All inputs are sampled on `clk_i` rising edges. Drivers establish inputs before that edge and hold them through its setup and hold interval. Backend responses are **one-cycle beats**, not valid levels held until acknowledgment. A backend acts once on each new `(service_command_id_o, service_phase_o)` while `service_valid_o` remains asserted. It must retain its own ownership until its response or independently established containment. Replaying a response is a stale-response fault. No incoming response can authorize a new request.

`service_phase_o=0` requests startup, `1` requests configuration and verification, and `2` requests safe cancellation. `service_config_o` is the immutable 768-bit accepted descriptor. A response must match both the full 64-bit command ID and the current phase. Configuration success additionally requires physical readiness, idle pins, contained old storage and the unchanged candidate qualification binding. A cancellation response must confirm successful termination with idle pins and contained old ownership. An old startup/configuration response arriving after cancellation begins is stale and cannot stand in for phase 2 termination. A startup success at the total deadline cannot extend that deadline.

Service failure deasserts the request and asserts isolation, but it does not revoke the backend lease or prove transaction retirement. The backend must retain its accepted identity and old writes after `service_valid_o` falls, obey isolation independently, and report `ownership_clear_i` only after positive containment. CONFIGURATION_FAILED describes command failure, not safe ownership release. A permitted RECOVER clears isolation only after idle pins, old containment and absent current faults have been attested; it then starts a new explicitly identified service.

`physical_ready_i` is a trusted, continuously monitored attestation of the active physical configuration. Software cannot set it through this register bank. `qualification_valid_i`, `qualification_config_id_i`, `qualification_digest_i`, `qualification_timebase_id_i` and `qualification_manifest_length_i` describe a proposed descriptor already checked against the external qualification registry. That registry must establish the entire manifest, including board identity, exact ADC image, analog measurements, timing, memory and containment bounds. The controller compares every mutable descriptor field to this binding and requires the selected fixed profile. A hash identifies bytes; neither the hash nor this comparison measures the board.

The proposal binding must remain unchanged throughout accepted startup/configuration/cancellation. Once configuration succeeds, `active_valid` and the captured bytes retain that qualification; the proposal inputs may then describe a future configuration. Ongoing active qualification uses `physical_ready_i`, the retained session and `session_verified_i`. Removing active physical readiness, changing the session input or withdrawing verification faults READY or RUNNING. The first accepted configuration binds a nonzero session ID for the entire retained lifetime. A different session requires isolated system reset and externally verified fresh identity.

`ownership_clear_i` attests that old capture/service transactions are contained; idle pins alone do not establish this. `metadata_archived_i` attests that the accepted session/configuration metadata is archived. `free_blocks_i` counts genuinely free ring blocks. These are integration inputs, not implemented memory or archival mechanisms. ARM requires at least 24 free blocks and an empty event queue, in addition to all qualification and ownership gates.

An accepted ARM allocates one epoch, publishes `epoch_o` and `first_tick_o`, and raises `arm_o` for one clock. `first_tick_o` is the next controller tick after acceptance. This pulse delivers an accepted binding, not a physical CONVST pulse. A scheduler must consume it even if STOP arrives before that next edge, then account slot zero as suppressed or invalid according to ACQ-R1. `run_permit_o` separately vetoes triggers combinationally on STOP, external faults and newly generated internal faults, including event overflow. `stop_o` does not depend on CPU execution, IRQ masking, event acknowledgment or completion consumption. The actual ADC timing and record accounting remain integration work.

`close_request_o` stays asserted while an epoch awaits closure. A one-cycle `close_valid_i` response must match `close_epoch_i` to the current epoch and supply `close_result_i=0` for clean, `1` for counted loss or `2` for uncertain. Values 3, stale epoch identities or missing containment/idle attestations cannot certify closure. The controller upgrades a claimed clean result to loss when this epoch accumulated CPU reset/halt or faults; timing uncertainty forces uncertain closure. Old faults from other epochs do not contaminate a later clean closure.

`supervisor_fault_i` is the already coherent indication from a separately clocked supervisor. It also drives the combinational isolation request. A stopped controller clock cannot sample or preserve new evidence, so the external supervisor must retain its own fault and physically isolate unsafe pins independently. This input does not implement that supervisor, its CDC or board isolation. A supervisor fault makes time uncertainty sticky for this lifetime and requires isolated reset with a fresh session/timebase before further configuration. RECOVER cannot silently restore lost time continuity.

## Lifecycle

| Code | State | Meaning and exits |
| --- | --- | --- |
| 0 | UNQUALIFIED | Contract SAFE. No active qualification or epoch. CONFIGURE may start startup. |
| 1 | STARTUP | First phase of contract CONFIGURING. The backend owns startup; one command completion is reserved. |
| 2 | CONFIGURATION | Second phase of CONFIGURING. Verification success publishes the captured candidate and enters READY. |
| 3 | READY | Immutable active descriptor, qualified and disarmed. ARM may allocate an epoch. |
| 4 | RUNNING | Epoch binding active; `run_permit_o` grants trigger eligibility subject to combinational vetoes. |
| 5 | CLOSING | Contract STOPPING/DRAINING combined. Trigger admission is inhibited while the backend resolves capture and storage. |
| 6 | STOPPED | Contract CLOSED. A retained terminal records the sealed epoch. CONFIGURE or RECOVER is required before another ARM. |
| 7 | FAULT | Qualification revoked. Available evidence and owners remain retained. RECOVER requires containment and acknowledgment of any surviving terminal. |

STARTUP and CONFIGURATION retain a cancellation substate. STOP or CPU halt/reset suppresses simultaneous service success, requests phase 2 and invalidates qualification. A positive termination response returns UNQUALIFIED with `CANCELLED`. Faults take precedence and complete the command with `CONFIGURATION_FAILED`. RECOVER uses the last accepted, structurally validated descriptor, including a descriptor whose backend service failed. It never arms. A missing descriptor returns `UNQUALIFIED` in an otherwise permitted state.

An invalid state encoding reports `INTERNAL`, inhibits capture and starts bounded uncertain closure if an epoch remains owned. An ordinary command cannot replace a live epoch. An owned service receives failure completion even if its state encoding became invalid. No reset, fault acknowledgment or completion acknowledgment frees backend memory ownership.

## MMIO acceptance and outcomes

The port accepts a beat when `req_valid_i && req_ready_o` is true. It returns a registered response on the next visible cycle, tagged with `req_tag_i`, and holds that response until `rsp_ready_i`. With a ready response sink it accepts one beat per clock. `req_ready_o` depends only on response capacity and system reset, never the duration of startup/configuration. Backpressure may delay the next bus beat; it cannot delay accepted work, fault processing or hardware STOP.

Addresses below are byte offsets in a 4 KiB region; its system base address is deliberately unassigned. Only aligned 32-bit accesses are accepted. Writes require `req_wstrb_i=0xf`, reads `0`. Bad alignment, strobes, unmapped addresses or direction return `rsp_error_o=1` with `INVALID_REQUEST`. Valid command/service register writes return their semantic outcome in `rsp_rdata_o` with `rsp_error_o=0`. No bus transaction waits for a slow operation to finish.

There is one ordinary operation and one separately retained completion slot. Acceptance reserves that slot until the final completion is acknowledged. Its admission result and ID also remain in status. Bus response loss through CPU reset does not undo acceptance; after resuming, software reads retained status rather than blindly replaying a command. Whole-system reset invalidates outstanding bus and command results only after external isolation and containment.

| Value | Outcome |
| --- | --- |
| 0 | OK |
| 1 | ACCEPTED |
| 2 | INVALID_REQUEST |
| 3 | STALE_COMMAND |
| 4 | COMMAND_BUSY |
| 5 | UNSUPPORTED_PROFILE |
| 6 | INVALID_STATE |
| 7 | UNQUALIFIED |
| 8 | NO_CAPACITY |
| 9 | STOP_ACTIVE |
| 10 | CANCELLED |
| 11 | CONFIGURATION_FAILED |
| 12 | CLOSED_CLEAN |
| 13 | CLOSED_LOSS |
| 14 | CLOSED_UNCERTAIN |
| 15 | ALREADY_STOPPED |
| 16 | FAULT_LATCHED |
| 17 | EMPTY |

The ordinary command doorbell accepts `1=CONFIGURE`, `2=ARM`, `3=RECOVER`; all other values are malformed. The staged command ID is a nonzero monotonically increasing 64-bit sequence. Zero is malformed. A duplicate or older sequence returns STALE_COMMAND. New well-formed requests consume their sequence even when rejected, except COMMAND_BUSY permits retry with that same sequence. Malformed requests, including nonzero reserved descriptor word 23, do not consume the sequence. No ID wraps.

Rejection order is malformed input, stale command sequence, occupied operation/completion slot, unsupported profile, invalid lifecycle state, active STOP barrier, absent qualification/containment and insufficient ARM capacity. A new CONFIGURE descriptor ID must exceed every previously accepted CONFIGURE descriptor ID; reuse returns STALE_COMMAND. RECOVER deliberately uses the retained descriptor identity. All requests not explicitly supported in a state return INVALID_STATE. Rejections do not allocate epochs, mutate active bytes or consume event capacity.

STOP is an independent service. Its first request allocates a nonzero, nonwrapping 64-bit STOP ID. Repeated requests join the same in-progress request or retained result and do not add duplicate events. `ACK_STOP` matches this STOP ID, never the recording epoch. The separate epoch field is zero for no-epoch service. A retained STOP request/result must be acknowledged before another ordinary operation can begin; its historic result does not itself assert the physical `stop_o` level. Exhausted STOP identity rejects a new receipt with UNQUALIFIED while the emergency stop level still inhibits triggers.

CPU reset/halt initiates autonomous cancellation or closure but does not fabricate a STOP receipt without a requester. An asserted emergency STOP port does own a retained STOP result. A fresh STOP in idle states completes ALREADY_STOPPED; in FAULT it completes FAULT_LATCHED. STOP while running joins the eventual closure result. STOP during service reports ALREADY_STOPPED only after positive safe termination, or FAULT_LATCHED if termination fails.

| Offset | Access | Register or operation |
| --- | --- | --- |
| 0x000 | R | Identification `0x41435143`. |
| 0x004 | R | ABI version `0x00010000`. |
| 0x008 | R | Live lifecycle code, one coherent word. |
| 0x010, 0x014 | RW | Ordinary command ID, low/high words. |
| 0x018, 0x01c | RW | Service object ID or ARM config ID, low/high words. Separate from ordinary command staging. |
| 0x020 | W | Ordinary command doorbell, values 1 to 3. |
| 0x024 | W | ACK_COMPLETION, value 1 and matching object ID. |
| 0x028 | RW | Write 1 for STOP; read ACCEPTED while pending, final code while retained, otherwise EMPTY. |
| 0x02c | W | ACK_STOP, value 1 and matching STOP object ID. |
| 0x030 | W | SNAPSHOT, value 1. ACCEPTED reserves a frozen snapshot; occupied slot returns COMMAND_BUSY. |
| 0x034 | W | ACK_EVENT, value 1 and matching event sequence. |
| 0x038 | W | ACK_TERMINAL, value 1 and matching epoch. The recorder must have archived that terminal and preceding amendments. |
| 0x03c | W | ACK_IRQ, low four mask bits; reserved bits reject. |
| 0x040 | RW | IRQ enable mask, low four bits; reset value zero. |
| 0x044 | R | Live IRQ pending bits, one coherent word. |
| 0x048 | W | RELEASE_SNAPSHOT, value 1 and matching snapshot ID. |
| 0x100 to 0x15c | RW | Twenty-four shadow descriptor words. |
| 0x200 to 0x25c | R | Active descriptor from the held snapshot, otherwise EMPTY. |
| 0x300 to 0x4fc | R | Frozen 128-word status bank, otherwise EMPTY. |

Every ACK requires the named object to exist and its full identity to match. Wrong, duplicate or absent identities return STALE_COMMAND with no ownership or evidence change. Non-1 service operands return INVALID_REQUEST. IRQ clearing uses a mask and allows an already clear supported bit. This block has no memory lease-release register; release remains a separate future memory-manager interface.

## Descriptor and configuration publication

Each descriptor is 24 little-word-order 32-bit registers, not an ACF1 or memory publication descriptor. Every 64-bit value stores its low word first. The digest and session are exact bit strings whose least significant 32-bit word is first. Software may edit shadow words while service or capture runs; the accepted candidate and published active bytes never follow those edits. A rejected CONFIGURE preserves active bytes and qualification. An accepted CONFIGURE revokes active qualification until complete backend success, while retaining the old active bytes as evidence.

| Word | Field and accepted value |
| --- | --- |
| 0, 1 | Nonzero config ID, monotonically allocated by the registry. |
| 2 | Profile selector 1, naming the entire exact ACQ-R1 ADC tuple. |
| 3 | Period 1600 acquisition ticks. |
| 4 | Nominal acquisition frequency 80,000,000 Hz. |
| 5 | ADC identity `0x33`. |
| 6 | Channel mask `0xff`, V1 through V8 in fixed order. |
| 7 | Additional feature flags; only zero is supported. |
| 8 to 15 | Nonzero 256-bit qualification manifest digest. |
| 16 to 19 | Nonzero externally verified 128-bit session ID. |
| 20, 21 | Nonzero timebase ID. |
| 22 | Manifest length, 1 to 1,048,576 bytes. |
| 23 | Reserved, must be zero; nonzero is malformed input. |

Profile 1 means software-controlled AD7606C-18, all eight bipolar single-ended ±2.5 V low-bandwidth channels, internal reference, fixed reset calibration values, no oversampling/padding, one DOUTA lane, 18-bit samples with status bytes and CRC16, 224-bit frames and 20 MHz serial clock. No alternate mode is partially applied. The full exact register image and measured qualification belong to the externally bound manifest. Profile selectors other than 1, alternate cadence/clock/ADC/channel values or nonzero feature flags return UNSUPPORTED_PROFILE. A syntactically supported tuple with missing identity, digest, length, timebase or registry binding returns UNQUALIFIED.

## Coherent snapshots and evidence

SNAPSHOT freezes the **pre-edge** values of state, results, evidence and active bytes on its acceptance edge. A fault arriving on that same edge belongs to the next snapshot; its IRQ and retained evidence still update normally. The allocated snapshot ID is the only newly allocated value in the snapshot. Reads never refresh it. Matching RELEASE_SNAPSHOT permits another capture. Snapshot ID exhaustion rejects further captures with UNQUALIFIED rather than reusing an identity; live scalar state, IRQ and retained module evidence still exist. Software must serialize access to the shared staging registers and snapshot slot.

| Snapshot word | Meaning |
| --- | --- |
| 0 | Lifecycle state. |
| 1 | Flags: active valid 0, operation busy 1, completion valid 2, event valid 3, terminal pending 4, STOP busy 5, STOP result valid 6, fault latched 7, counters exhausted 8, cancelling 9, time uncertain 10, epoch loss 11, epoch uncertain 12, isolation request 13, external ownership clear 14, pins idle 15. Other bits zero. |
| 2, 3 | Current tick. |
| 4, 5 | Last allocated epoch. |
| 6, 7 | Its first scheduled tick. |
| 8, 9 | Last consumed ordinary command sequence. |
| 10, 11 | Current or last accepted operation ID. |
| 12, 13 | Retained completion ID. |
| 14 | Completion outcome; meaningful as a result only with completion-valid flag. |
| 15 | IRQ pending bits. |
| 16, 17 | Last event occurrence sequence, including counted dropped events. |
| 18, 19 | Saturating fault occurrence count. |
| 20, 21 | Saturating lost-event count. |
| 22 | Lifetime sticky cause bitmap. |
| 23 | IRQ enable mask. |
| 24, 25 | This snapshot ID. |
| 26, 27 | Last ordinary admission ID. |
| 28 | Last ordinary admission outcome. |
| 29 | Reserved zero. |
| 30, 31 | Highest accepted CONFIGURE descriptor ID. |
| 32 to 47 | First fault evidence. All zero before the first fault. |
| 48 to 63 | Latest fault evidence. All zero before the first fault. |
| 64 to 79 | Oldest retained event; valid only with event-valid flag. |
| 80, 81 | Last sealed terminal epoch. |
| 82 | Terminal outcome. |
| 83 | Terminal ever valid, independent of archive-delivery acknowledgment. |
| 84, 85 | Current or last independent STOP ID. |
| 86 | STOP result code. |
| 87 | STOP result valid. |
| 88 to 91 | Retained session ID. |
| 92, 93 | Active descriptor timebase ID. |
| 94, 95 | STOP epoch context; zero for no epoch. |
| 96 to 119 | Frozen active descriptor bytes. |
| 120 to 127 | Reserved zero. |

Each evidence object contains 16 words: event sequence at 0/1, tick at 2/3, epoch context at 4/5, command context at 6/7, causes at 8, flags at 9, session at 10 through 13, and config ID at 14/15. Flags are session known bit 0, active epoch known bit 1, time known bit 2 and sequence known bit 3. Bit 4 marks an offending backend command ID in the command field; its phase is retained in bits 6/7. Bit 5 changes words 14/15 from config ID to the offending closure epoch. These offending identities are claimed incoming identities, not accepted owners. Both flags can be set when both stale responses coincide, preserving both offending identities and the current local epoch. Bits 6/7 are zero when bit 4 is clear; bits 8 through 31 are zero. When bit 5 is clear, the config ID refers to the accepted candidate during service and otherwise to the retained active descriptor. With no owned service and no offending response, command context is zero.

This is the **control-event subset**. It does not know conversion slots, sample-channel masks, memory transaction identities or analog-onset intervals. It cannot substitute for the complete capture/memory/analog event and amendment schema required by ACQ-R1. Unknown slot identity is not an implied slot zero. A known controller tick does not prove a calibrated physical timestamp.

| Cause bit | Meaning |
| --- | --- |
| 0 to 15 | External critical fault sources assigned by an eventual integrator; each bit rising creates one occurrence. All request hardware stop. |
| 16 | Independent supervisor fault; time continuity is uncertain. |
| 17 | Total configuration timeout. |
| 18 | Backend failure or invalid closure/qualification result. |
| 19 | Stale backend phase/command or closure epoch response. |
| 20 | Cancellation failure or timeout. |
| 21 | Closure timeout. |
| 22 | Event queue overflow. |
| 23 | Event/fault/loss counter or tick exhaustion. |
| 24 | Invalid state or unsupported external fault bit. |
| 25 | Qualification or session-binding loss. |
| 26 | CPU reset assertion. |
| 27 | CPU halt assertion. |
| 28 | First software/emergency STOP ending owned work. |
| 29 to 31 | Reserved zero. |

External `fault_i` bits 16 through 31 are unsupported and report INTERNAL on assertion. A held external fault still vetoes recording but creates no repeated event until it deasserts and reasserts. CPU halt/reset are likewise recorded once per assertion. They are stop observations, not faults by themselves. Bits 0 through 25 are faults and update first/latest fault evidence and the fault count. Simultaneous causes form one occurrence; no order within that tick is inferred.

The one-entry event queue holds its head unchanged until matching acknowledgment. A same-edge acknowledgment and new occurrence replaces the delivered head. Otherwise the old entry stays, the lost-event counter increments, and EVENT_OVERFLOW is included in sticky/latest fault evidence outside the queue. Overflow directly stops capture. Event sequence counts all occurrences, including dropped events. Counters saturate; reaching the configured limit adds COUNTER_FULL, revokes further operation and forces uncertain closure. Once no new sequence can be allocated, later observations update retained summaries without enqueuing an ambiguous reused event identity. Counts then express lower bounds. CPU reset, IRQ acknowledgment, terminal acknowledgment and event acknowledgment cannot erase first/latest evidence or lifetime counters.

IRQ bits are `0=FAULT_NOTIFICATION`, `1=EVENT_READY`, `2=TERMINAL_PENDING`, `3=COMMAND_OR_STOP_COMPLETION`. Bits 1 to 3 reflect retained source levels and reassert after attempted clearing while their objects remain. Bit 0 clears notification only; it does not clear the qualification fault latch or evidence. New faults win over same-edge clearing. The actual CPU interrupt controller and CDC remain outside this module.

## Deadlines, reset and remaining qualification

The default local deadline parameters are CONFIG_CYCLES=239,976,000, CANCEL_CYCLES=1,119 and CLOSE_CYCLES=799,920. At the minimum allowed 79.992 MHz acquisition clock, these correspond to 3 s, about 13.988899 µs and 10 ms. Configuration counts continuously from acceptance across both phases and cancellation. Cancellation and closure count from their initiating decision edge. A matching successful final response exactly at its deadline wins over timeout; faults and STOP retain their higher priority. A timed-out service completes CONFIGURATION_FAILED; a timed-out closure produces CLOSED_UNCERTAIN and preserves the terminal.

These are controller decision-edge bounds. The supervisor, synchronizers and output isolation propagation must fit the complete timing budget independently; these local counters alone do not qualify its end-to-end bounds. Clock disappearance is supervised externally because local counters cannot advance without their clock. Test parameter reductions exercise the same counter comparisons but do not establish the physical three-second or microsecond service limits.

CPU-only reset and halt preserve all configuration bytes, session and command identities, response sinks, snapshots, first/latest faults, counters, events and terminal records. They inhibit ARM for their full asserted level, cancel active service and close active capture autonomously. Releasing them never restarts acquisition. A normal STOPPED state requires acknowledged terminal delivery and explicit CONFIGURE or RECOVER before ARM.

`system_reset_i` is synchronous and destructive. Integration must first isolate pins, fence both ends of every crossing and contain external owners according to [ACQ-R1-CDC1](clock-reset-lifecycle.md). Only then may it clear this block. It clears outstanding MMIO responses, command ownership, snapshots and evidence; their disappearance is not successful completion. The archive must treat interrupted sessions without a valid terminal as incomplete. A fresh, externally verified session and timebase are required before new recording. This module does not implement acquisition-only reset, FPGA reconfiguration sequencing or external memory reclamation; those scopes require the supplement's separate containment procedures.

Generic synthesis and simulated checks establish only the implemented control semantics under these coherent-input and backend-attestation assumptions. They do not prove the backend attestations, full-engine composition, physical CDC, 80 MHz timing closure, board isolation, analog qualification or device programming. Those gates remain open until implemented and measured for the exact board and bitstream.

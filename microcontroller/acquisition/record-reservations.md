# Synthetic record reservations

[drg5_acquisition_records.sv](../rtl/drg5_acquisition_records.sv) implements a single-clock reservation ledger, complete-record assembly stage, ordered FIFO and DMA holding stage. Synthetic conversion results enter as complete 48-byte records. The component preserves those bytes without interpreting ADC status or recomputing CRC. It generates canonical missing records when a conversion is suppressed or an unresolved synthetic conversion is cancelled. This separates storage and ownership checks from the unimplemented serial interface.

Every port belongs to the same fixed acquisition clock. This implementation has no asynchronous FIFO, Gray-pointer crossing or separate reset domains. It therefore does not qualify the future dual-clock path required by [ACQ-R1-CDC1](clock-reset-lifecycle.md). A separate clock requires that path's coordinated binding, reset and pointer implementation rather than independent synchronization of these ports.

## Capacity and ownership

The default ring has 256 physical entries. Each entry holds the frozen 48-byte record and its 64-bit slot index, matching the supplement's 56-byte internal entry. A reservation consumes one entry before slot admission, even though its record bytes are not yet available. That same entry remains charged throughout conversion, placeholder construction, assembly, FIFO waiting and DMA staging. Moving a record between stages never creates a free credit.

| Entry state | Owner and permitted next transition |
| --- | --- |
| FREE | Unowned storage; a successful reserve changes it to RESERVED. |
| RESERVED | The sole unused tail reservation; admission consumes it, or a matching release returns it to FREE. |
| CAPTURE | The sole unresolved triggered conversion; matching completion selects ASSEMBLER, or matching cancellation selects MISSING_TRIGGERED. |
| MISSING | An admitted untriggered slot awaiting its canonical placeholder. |
| MISSING_TRIGGERED | A cancelled triggered slot awaiting its zero-received-bit placeholder. |
| ASSEMBLER | One complete record held for its next-edge ring write. |
| QUEUED | A complete FIFO entry waiting behind the ordered head. |
| DMA | The head record held through request acceptance and positive completion. |

`owned_o` is the sum of `reserved_count_o`, `capture_count_o`, `missing_count_o`, `assembler_count_o`, `fifo_count_o` and `dma_count_o`. The missing count includes both pending-placeholder states. The owned count never exceeds DEPTH. At most one entry occupies each of RESERVED, CAPTURE, ASSEMBLER and DMA. Completed records behind an older unresolved conversion remain queued; only the completed head may enter DMA staging.

Lifetime counters satisfy `allocated_o = unused_released_o + retired_o + owned_o`. Allocation counts successful reservations, unused release counts successful returns before admission, and retirement counts matching positive DMA completions. `admitted_o` is instead the current epoch's accepted-slot count. Apart from system reset, it resets only on an accepted new binding. The lifetime counters do not reset on bind, stop, cancellation, inhibit or backpressure. Internal widened arithmetic checks the conservation relation without truncating a carry.

Only a matching unused release or positive DMA completion returns capacity. A same-edge release or retirement does not contribute to `reserve_ready_o`; full capacity therefore remains nonready until the following edge. This conservative rule also applies when enqueue, completion and retirement occur together.

## Binding, reservation and slot admission

`reserve_i` requests one unused entry. Its accepted edge increments the 64-bit lifetime allocation counter and publishes that new nonzero value as `reservation_id_o`. The token remains unchanged while `reserved_o` is true. Tokens never wrap or repeat after an unused release. The elaboration parameter COUNTER_LIMIT supports reduced exhaustion tests; its production value is U64_MAX. At the limit, otherwise eligible reservation requests return EXHAUSTED; reset, binding, inhibit and existing ownership retain their documented precedence. Existing owners can still complete or release.

Reservation may precede binding, so storage can already be owned when the scheduler accepts ARM. `bind_i` installs a nonzero epoch and first tick. The epoch must exceed every previously bound epoch in this retained lifetime. Binding requires no admitted owners; one unused anonymous reservation may remain. It preserves that reservation and all lifetime counters while resetting the current epoch's admitted count. `bound_o` and the immutable `epoch_o`/`first_tick_o` remain after drain until a permitted newer binding or destructive reset. The upstream controller is responsible for the rest of the session/configuration/timebase binding and for validating that the first tick is the accepted future scheduler edge.

Admission presents the held reservation token together with epoch, slot, scheduled tick and whether CONVST was emitted. The epoch must match the current binding, and the slot must equal `admitted_o`, starting at zero. An 80-bit calculation verifies `first_tick + 1600*slot` before narrowing to the 64-bit supplied tick. Slot U64_MAX is rejected because its accepted count would overflow. A triggered admission also requires capture idle. An untriggered admission may coexist with an older unresolved conversion because its placeholder cannot bypass that older ring entry.

Admission consumes the unused reservation by changing its owner. It does not allocate a second entry or return capacity. The capture backend receives the reservation token associated with a triggered admission and uses it for the completion response. The reservation token, recording epoch and scheduled-slot index have different purposes; none is a memory-allocation generation or stream-block sequence.

`inhibit_i` blocks only new reservations. It does not revoke a held reservation, suppress an admitted missing placeholder, clear a conversion, withdraw a DMA offer or prevent drain. The scheduler remains responsible for trigger inhibition. A CPU-reset or stop path must use that scheduler policy while retaining this component's owned entries.

## Results and simultaneous operations

All request fields must be coherent before the rising sampling edge. Bind, reserve, release, admit, cancel and DMA-done are one-edge request beats. Their combinational result reports the decision on that edge; holding a successful beat asserts another request on the following edge and can produce a stale or busy result. Complete-result input instead uses ready/valid: its token and all 384 record bits must remain stable until `complete_valid_i && complete_ready_o`.

| Result | Meaning |
| --- | --- |
| 0, EMPTY | No request on that interface. |
| 1, ACCEPTED | The requested ownership transition commits on this edge. |
| 2, STALE | The token or epoch/slot identity does not name the required current owner. |
| 3, BUSY | Existing ownership, occupied assembly, capacity or explicit same-edge precedence prevents acceptance. |
| 4, INVALID | Zero binding fields, an unrepresentable slot/tick, or a mismatching scheduled tick. |
| 5, TOO_LATE | The identified slot has already left capture, or DMA completion precedes a previously accepted request. |
| 6, EXHAUSTED | The lifetime allocation identity cannot advance. |
| 7, INHIBITED | System reset prevents acceptance, or new reservation is inhibited. |

Reset prevents every acceptance, deasserts DMA request-valid and deasserts completion-ready. A bind request takes precedence over reserve, release and admit on the same edge, returning BUSY for those competing requests even when bind is rejected. A successful unused release wins over admission of that reservation. Invalid release identity does not release anything or cancel an otherwise valid admission.

Cancellation inspects pre-edge admitted ownership. A matching CAPTURE cancellation wins over a simultaneous matching completion; cancellation succeeds and that consumed completion returns TOO_LATE. Cancellation is a synthetic-peer containment request: the peer attests that it has no independent write path to the reserved storage. Acceptance invalidates its completion token, so any later returned result is consumed as stale without changing the placeholder. This is not qualification of an ADC abort or physical capture containment. Cancellation does not name a slot first admitted on the same edge. Cancellation of a slot already pending a placeholder, in assembly, queued or DMA-owned returns TOO_LATE and preserves its record. An absent or retired identity returns STALE. A duplicate completion likewise returns STALE and cannot consume another entry.

A valid matching completion waits while the pre-edge assembler is occupied. The assembler writes its held record on that edge, but completion acceptance resumes only on the following edge. A stale completion is consumed with STALE even during assembly backpressure. When the assembler is empty, accepted completion takes priority over selecting a pending placeholder. A pending head placeholder has priority; otherwise selection uses the lowest physical entry index. Assembly order cannot change DMA slot order. Each assembler write commits the whole 48-byte record to its reserved ring entry.

## Complete-record DMA transfer

The FIFO loads only its QUEUED head into the DMA holding register. That load changes QUEUED to DMA and keeps the ring entry charged. `dma_valid_o` offers all 384 record bits together with the epoch and 64-bit slot. The tuple remains stable while the consumer stalls. A ready/valid request handshake sets `dma_sent_o` and removes request-valid without changing the record or returning credit. `dma_owned_o` remains asserted.

`dma_done_i` must name that same epoch and slot after a previously accepted request. A completion on the first request-handshake edge returns TOO_LATE because pre-edge `dma_sent_o` is still false. A matching later completion retires the entry exactly once and advances the FIFO head. Wrong, early and duplicate completions cannot change ownership. There is no automatic cancellation of an offered or sent DMA record. A future containment path must preserve an explicit loss disposition; clearing a FIFO or withdrawing an offer is not such a disposition.

Positive completion attests that the backend has completed the record transfer into its reserved destination and retired the associated access ownership. An outstanding DMA stage or write cannot supply this acknowledgment. This component does not implement memory writes, block assembly, publication or archival durability. The DMA backend must not send completion merely because it has observed request-valid.

## Record bytes and remaining supervision

Byte zero occupies bits 7:0 of the record port. Synthetic completion bytes pass unchanged through the assembler, ring and DMA holding register. A missing placeholder zeroes samples, status, CRC trailer, PRESENT and reserved byte, then sets MISSING in flag bit 21. Cancellation after a triggered admission also sets TRIGGERED in flag bit 16. These are respectively flag words `00200000` and `00210000` at bytes 44 through 47 in little-endian order. No valid sample, partial wire data or ADC integrity claim is fabricated. The [format contract](formats.md#the-48-byte-record) defines the corresponding archive interpretation.

This synthetic foundation has no physical analog permissions or uncertainty input. Those quality annotations, complete-frame validation and partial serial capture remain work for the future producer. The synthetic producer must supply any required nonmissing record flags and CRC bytes consistently. Passing bytes through this buffer does not qualify their electronic or physical validity.

Stalled capture and DMA ownership remain visible indefinitely; no timeout erases a reservation. The integration's independent supervision must inhibit further scheduling and resolve or positively contain those owners within the existing timing and closure bounds. A stopped acquisition clock cannot supervise itself. CPU service, software acknowledgment and event-queue capacity are not prerequisites for retaining the entries.

Sticky fault bits are 0 for stale identity, 1 for invalid envelope, 2 for too-late operation, 3 for allocation exhaustion and 4 for an internal ownership/conservation mismatch. Other bits remain zero. Simultaneous causes accumulate. `fault_o` reports each edge with one or more such occurrences, and `sticky_faults_o` retains their union independently of data service. BUSY and INHIBITED are ordinary nonacceptance outcomes. Fault recording does not clear an owner or block drain; the external control path decides the stop response.

## Reset and storage allocation

Only synchronous `system_reset_i` destroys the ledger, identities and evidence. Integration must first isolate and contain old work as required by the lifecycle contract. Reset is not successful retirement, memory reclamation or record publication. The payload RAM is not cleared; initialized states and current ownership prevent reading its stale bytes. CPU-only reset is intentionally not a destructive input.

At DEPTH=256, the record and slot arrays contain `256*(384+64) = 114688` bits, or 14,336 bytes. The registered state contains 768 entry-state bits, 40 pointer bits, six ownership/binding flags, ten 64-bit identity/counter fields, two 384-bit assembly/DMA records, 32 sticky-fault bits and one fault-occurrence bit. That is 2,255 additional bits, rounded to 282 bytes. Total declared storage is 14,618 bytes, leaving 1,766 bytes within the existing 16 KiB ingress allocation for future binding/crossing integration. Combinational counts and next-state expressions do not add stored queues. This logical bit accounting is not an FPGA placement or block-RAM packing result.

The reduced DEPTH parameter admits only powers of two from 2 through 256. Binary head and tail indices wrap modulo DEPTH, while epoch, slot and reservation identities do not wrap. Capacity remains tied to entry states and positive retirement across pointer wrap. No additional prefetch record queue exists, and all staging remains charged to an existing ring entry. The future dual-clock implementation must independently verify Gray pointers, full/empty observations, reset coordination and the supplement's handoff deadlines.

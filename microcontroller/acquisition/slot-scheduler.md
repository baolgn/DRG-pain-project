# Timebase and fixed-grid slot scheduler

The [timebase](../rtl/drg5_acquisition_timebase.sv), [scheduler](../rtl/drg5_acquisition_scheduler.sv) and [connected timing wrapper](../rtl/drg5_acquisition_timing.sv) implement the timing portion of ACQ-R1. The wrapper connects the existing command controller to a scheduler through one clock and one timestamp. It does not instantiate the ADC service sequencer, BUSY monitor, serial receiver, record assembler, FIFO, DMA or physical supervisor. The older synthetic acquisition guard remains a separate prototype.

This implementation preserves the [contract](contract.md): the only recording period is 1,600 acquisition ticks, and ARM accepted at tick A selects first tick A+1. A later arbitrary start, another period or an external trigger is unsupported. The existing record and epoch formats do not change. Conditioned analog voltages remain the ADC input; no recording interface is assumed for the undecided Abbott connection.

## Time, identities and checked ordering

The acquisition clock is fixed at the qualified nominal 80 MHz. The free-running timestamp is an unsigned 64-bit count. Its pre-edge value identifies the current rising acquisition-clock edge. It increments on every acquisition edge, including CPU idle, CPU reset, halted execution, downstream stalls and stopped intervals. Only isolated whole-domain `system_reset_i` clears it. The helper's `RESET_TICK` parameter supports boundary tests; a production build uses zero and obtains a new externally verified timebase/session before recording after destructive reset.

The timestamp saturates at U64_MAX. It never wraps to zero. `exhausted_o` is true at that value. No modulo ordering or signed half-range comparison is used: within one nonwrapping lifetime, ordinary unsigned `<`, `>` and equality are unambiguous, including across bit 63. Every proposed first tick, next scheduled tick and frame deadline uses a 65-bit sum so carry cannot be discarded. The scheduler also checks that adjacent observed timestamp values differ by exactly one. A skip, backward step or unexpected held value makes the timebase uncertain and inhibits future ARM until isolated reset. A physically stopped clock cannot be detected by logic clocked from that same source; the independent supervisor and pin-isolation obligations remain external.

Scheduled-slot count, emitted count, missing count and delivered-notification count are separate unsigned 64-bit registers. Slot n has index n; the count after that slot is n+1. U64_MAX is never a slot index because its count would need 65 bits. The default `COUNTER_LIMIT` is U64_MAX; smaller elaboration values exercise exhaustion. A final representable slot may execute and then end the epoch before another count is needed. Every scheduled decision satisfies `scheduled = emitted + missing`; a missing decision can be retained locally or represented as a lost decision in the end receipt.

Epoch identity is supplied by the command controller, which owns the contiguous allocator. The scheduler requires a nonzero full-width epoch greater than its last accepted epoch. It never allocates or reuses one itself. The component permits a higher externally allocated identity after an intervening control-side epoch whose scheduler binding failed; the wrapper and session registry remain responsible for the complete epoch history.

## ARM admission and the shared edge

The command controller exposes a combinational ARM commit, epoch and first tick before its acceptance edge A. The wrapper presents those to the scheduler on the same edge. This is distinct from the existing registered `arm_o`, which becomes visible after edge A and is only an observation of accepted work. Feeding that registered observation to a sibling scheduler would arrive at A+1, too late to validate a future start.

`arm_ready_o` reports prospective local ownership and qualification readiness. It is independent of the request and deliberately does not depend on STOP, avoiding feedback through the connected controller. It is necessary but not sufficient for acceptance. `arm_result_o` validates the full proposed envelope and STOP state; `arm_accept_o` is true only when `arm_i` is asserted and the result is ACCEPTED. The controller separately vetoes its own STOP conditions before committing ARM. System reset suppresses ready, acceptance and launch rather than exposing a handshake discarded by reset.

| Result | Admission meaning |
| --- | --- |
| 1, ACCEPTED | New epoch, supported envelope, no local owner, all gates satisfied. |
| 2, INVALID_REQUEST | Zero epoch or first tick not strictly later than the current tick. |
| 3, STALE_COMMAND | Epoch is not greater than the last accepted epoch. |
| 4, COMMAND_BUSY | Active epoch, pending end receipt, pulse or outcome still owns local state. |
| 5, UNSUPPORTED_PROFILE | Period differs from 1,600 or future lead differs from exactly one tick. |
| 7, UNQUALIFIED | Reset, timebase/exhaustion failure, invalid qualification, missing capacity or an unrepresentable first-frame horizon. |
| 9, STOP_ACTIVE | STOP, CPU reset or CPU halt is asserted. |

Outside reset, precedence follows the table's malformed, stale, busy, profile, STOP and qualification ordering. Rejection has no effect on an existing grid, held outcome or end receipt. ARM additionally requires capture idle, an existing record reservation, available storage and FIFO occupancy below 192. It cannot assume a same-edge external release will supply those pre-edge conditions.

The first marker plus the 1,120-tick complete-frame deadline must fit in 64 bits. Thus the last accepted first marker is U64_MAX minus 1,120. Reserving only the eight pulse ticks would leave a conversion whose frame deadline could not be represented. After each decision the scheduler checks both the next marker and its frame horizon. If either overflows, the current valid on-time conversion remains valid as a scheduling decision, and the epoch terminates before that impossible successor. Backend capture still owns the current conversion until its deadline or containment.

## One decision at every due tick

The immutable grid is `first_tick + 1600*n`, using checked integer arithmetic. `tick_i == next_tick` is the only trigger opportunity. CPU state, response backpressure, capture readiness and FIFO service do not reload or pause that deadline.

At a due edge the scheduler first observes stop/fault conditions and pre-edge capture/capacity. It then accounts exactly one slot. If qualification, capture idle, credit and storage permit it, `launch_o` and its epoch/slot/tick identity authorize capture on that edge, and the CONVST output register rises on that same edge. There is no extra pipeline cycle between the logical marker and that register transition. Capture hardware must begin BUSY observation and reserve the conversion on this launch edge; it must not wait for the later notification handshake.

If triggering is prohibited, the slot is missing. With reserved credit and available local staging, the scheduler retains a missing-slot decision with its original epoch, slot and scheduled tick. Without that reservation it records an inclusive exact lost-slot interval in the end receipt. Either outcome terminates the epoch. Return of capacity later cannot upgrade a missing slot or cause a catch-up pulse. The scheduler never labels a later pulse with an earlier scheduled tick.

The one-entry notification contains `outcome_triggered_o`, epoch, slot, tick and causes. `outcome_triggered_o=0` means a retained missing decision. It is not a 48-byte ACQ-R1 record, and an all-zero payload would not be a canonical missing record. A future record assembler must construct the required flags and sample/status representation. A triggered notification likewise does not claim successful BUSY behavior, frame integrity or ADC data validity.

A held notification stays stable until ready/valid acceptance. A simultaneous acceptance can free that local staging register for a new decision; this does not create external record credit. Capture idle and record credit are tested at ARM and due edges only, because their deassertion between slots can represent normal in-flight ownership. Qualification loss, storage failure, FIFO high water and explicit stops are continuous conditions that can end the grid between slots.

Notification acceptance is bounded to 80 ticks from its offered decision. A handshake exactly on the inclusive deadline succeeds. Otherwise scheduling stops and the eventual end receipt is uncertain. The old notification remains offered, with its identity unchanged, until the consumer accepts it or a separately qualified destructive reset contains its owner. That handshake is notification delivery, not record publication or archive durability. The deadline does not replace the separate 1,120-tick ADC frame deadline.

If the observed tick passes a due marker without the required sequence of adjacent ticks, the scheduler emits no conversion. It terminates with uncertain time and a loss envelope beginning at the next unresolved slot, with no claimed last slot. It does not reconstruct missed conversions from a discontinuous clock or invent a count for the gap. Counters then describe the known scheduled prefix.

## Pulse completion and end receipts

CONVST is a registered signal, high for eight acquisition intervals: a rise at marker T is followed by its fall at T+8. Ordinary STOP, CPU reset/halt and downstream failure inhibit later triggers but finish an already emitted legal pulse. They do not combinationally AND the pulse with run permission. Independent physical isolation may interrupt a pulse; the coherent isolation/supervisor input then forces the internal register low and marks the boundary uncertain. External isolation must remain asserted until the internal output is known low, so releasing a permit cannot create a hidden rising edge.

STOP exactly on a due edge accounts that slot as missing or lost, then inhibits all later slots. STOP between due edges ends the epoch without inventing the next slot. CPU reset does not reset the timebase or slot ledger. No automatic rearm follows CPU resume, credit recovery or STOP deassertion.

The end receipt is independent of notification capacity. It becomes valid after the legal pulse finishes and the notification is either accepted or has reached its bounded timeout. It describes **scheduler inhibition and decision accounting**, not complete ADC, FIFO, DMA or memory ownership closure. The wrapper still requires an externally attested capture/storage closure before the command controller reports full epoch closure.

| End field | Meaning |
| --- | --- |
| Epoch and end tick | Accepted epoch and the edge on which scheduling was inhibited. |
| Scheduled/emitted/missing | Counts for the known decision prefix; frozen after inhibition. |
| `end_delivered_o` | Notification acceptances observed by the sealing edge, frozen in the receipt. |
| `delivered_o` | Live notification count; it may increase when a timed-out old offer is accepted later. |
| Last-slot known, slot and tick | Final accounted scheduled slot; unknown flag means no slot was accounted. |
| Exact | Known scheduling and notification accounting; timeout or timing/isolation uncertainty clears it. This does not certify ADC data or archive durability. |
| Loss valid, first, last, last known | Inclusive lost-decision interval. A normal no-credit due decision has equal first/last. A timing discontinuity leaves the last endpoint unknown. |
| Causes | Causes accumulated before the receipt's sealing edge. |

The receipt fields remain unchanged while valid. Later fault occurrences update separate retained fault evidence. Matching `end_ack_i`/epoch returns OK only with no held notification or pulse and capture idle. A stale or absent identity returns STALE_COMMAND; a matching receipt with unresolved local owners returns UNQUALIFIED. No ACK returns EMPTY. Reset cannot report a successful ACK. Acknowledgment releases the receipt only and never frees external memory or changes the captured sample validity.

End and fault tick fields retain the observed counter bit pattern at their decision edge. A discontinuous or isolated timebase does not turn that bit pattern into a trustworthy physical timestamp. The cause bits and cleared exact flag require uncertain interpretation; only the previously established prefix retains its earlier timing claim.

New ARM requires the previous receipt acknowledged, local notification and pulse owners retired, current qualification and a new epoch identity. Operational isolation from service-only activity may clear while completely idle only after isolation inputs deassert and qualification plus capture idle are positively true. Timing and counter lifetime faults never clear this way. The connected controller still requires explicit recovery and configuration; clearing local isolation does not arm it.

## Fault evidence and reset scope

`fault_o` is a registered one-cycle occurrence indicating new critical scheduler evidence. The scheduling decision already uses those causes on the offending edge, so propagation through the controller is not needed to veto that trigger. Registering this report prevents a combinational feedback loop through the controller's STOP output. First/latest fault causes and occurrence ticks, together with lifetime sticky causes, survive end acknowledgment and later epochs independently of notification service.

| Cause bit | Meaning |
| --- | --- |
| 0 | Composite control STOP, including requested stop and faults forwarded by the controller. |
| 1 | CPU reset. |
| 2 | CPU halt. |
| 3 | Qualification lost. |
| 4 | Capture was busy on a due edge, including an overlapping pulse. |
| 5 | No pre-edge credit or free local decision stage. |
| 6 | Storage unavailable. |
| 7 | FIFO occupancy reached the 192-entry high-water limit. |
| 8 | Decision notification handoff timed out. |
| 9 | Timestamp discontinuity, missed due marker or exhausted timebase. |
| 10 | Scheduled count or future frame/grid horizon exhausted. |
| 11 | Physical isolation or independent supervisor fault. |
| 12 | Contradictory local ownership. |
| 13 to 31 | Reserved zero. |

Bits 0 to 2 are stop observations; bit 0 does not identify the underlying cause of the controller's composite STOP. That cause remains in the controller's retained evidence. Bits 3 to 12 update first/latest fault evidence and assert the registered fault report. Causes arriving together accumulate; one cause does not conceal another. End acknowledgment cannot clear lifetime evidence. Destructive system reset clears all local ownership and evidence only after the separate reset/CDC contract has isolated pins and contained external transactions. There is no CPU-gated clock or CPU-only reset path in the timebase or scheduler.

## Timestamp to physical ADC pin

The stored marker identifies the acquisition-clock edge that drives the CONVST output register from low to high. Simulation establishes zero additional pipeline cycles and an eight-tick register pulse. It does not establish zero propagation delay at the FPGA pad or ADC input. At 80 MHz plus or minus 100 ppm, the eight ticks span 99.990001 to 100.010001 ns before pin distortion.

For the candidate direct interface, the [timing budget](timing-budget.md#pin-timing-and-capture-closure) allocates at most 2.0 ns from launch register to FPGA pad and 0.75 ns for the forward board/adapter route. The candidate marker-to-ADC-pin path allocation is therefore 2.75 ns before separately budgeted relative uncertainty, with no measured minimum. The relative launch/capture uncertainty allocation is 1.0 ns; the total CONVST pulse-distortion allocation is 3.0 ns. These are design limits, not measured delays or achieved timing closure. No translator is approved; one cannot be assigned zero delay if added later.

The documented [evaluation-board route](board-qualification.md#digital-routes-and-exclusive-owners) is FMC P12 contact D12, `CNVST_SDP`, through R57 100 ohms to `CNVST` and ADC U4 CONVST pin 9; P2 contact 13 exposes the same signal. The actual FPGA pin and adapter route remain unassigned/unqualified. The marker-to-pin offset is the sum of clock-to-output/register routing, I/O-buffer/load response, adapter/connector/trace delay, the series resistor/load response, and any translator delay. Its minimum, maximum, edge asymmetry and uncertainty must be extracted from the routed exact design and measured at the ADC pin with the assembled board over the admitted operating envelope.

No board is available. Consequently the physical offset remains unmeasured and must not be stored as a measured zero or used to advertise ACQ-R1 availability. ADC aperture behavior and analog/filter delay remain separate from this digital marker-to-pin offset. The epoch's qualification manifest must bind the measured offset and uncertainty before physical recording can be accepted.

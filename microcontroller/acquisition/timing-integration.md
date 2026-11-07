# Control and scheduler integration

[drg5_acquisition_timing.sv](../rtl/drg5_acquisition_timing.sv) connects the [control foundation](control-foundation.md) and [slot scheduler](slot-scheduler.md) in one clock domain. The control component instantiates [drg5_acquisition_timebase.sv](../rtl/drg5_acquisition_timebase.sv), and both components observe that single 64-bit counter. CPU reset, halt, MMIO response backpressure and downstream readiness cannot stop or reset it. Only isolated synchronous system reset starts a new timebase lifetime.

This wrapper implements the control-to-scheduler connection. The CPU board wrappers still do not instantiate it. ADC startup, BUSY/DOUT capture, complete records, recording DMA, physical supervision and any crossing from a separate CPU clock remain external integration work. The old synthetic guard is a separate prototype and is not instantiated alongside this scheduler as a second source of triggers.

## Atomic ARM and trigger timing

ACQ-R1 retains its single supported first-slot rule: an ARM accepted at tick A schedules slot zero at A+1. An arbitrary start delay is not a supported mode. The scheduler validates a complete future binding before accepting it, using checked arithmetic without modulo ordering. Past, equal, overflowing or unsupported future ticks are rejected. The controller provides the future binding on the command acceptance edge through `arm_commit_o`, `arm_commit_epoch_o` and `arm_commit_first_tick_o`. Its existing registered `arm_o` is an observation of that accepted operation, not a delayed request to the scheduler.

| Edge | Control and scheduler action |
| --- | --- |
| A | MMIO ARM is accepted. Control and scheduler commit the same epoch and future first tick. No recording pulse is emitted on this edge. |
| A+1 | The scheduler makes the slot-zero decision. If all pre-edge gates permit it, `launch_o` is sampled with the slot identity and the CONVST register rises on this edge. |
| A+9 | The CONVST register returns low after eight ticks, unless a physical isolation fault invalidated the pulse. Ordinary STOP or CPU reset does not shorten it. |
| A+1601 | Slot one is due if the epoch remains active. No CPU or consumer handshake can move this edge. |

The scheduler's `arm_ready_o` expresses prospective ownership, capacity and qualification. It does not depend on the controller's returned STOP signal. Envelope validation and STOP arbitration still determine `arm_accept_o`. This separation prevents a combinational feedback loop through control's fault decision. Control independently rejects ARM when its STOP, fault or qualification gates fail. An unexpected committed binding rejected by the scheduler becomes a registered INTERNAL fault rather than an automatic retry.

The capture backend must observe the combinational `launch_o` and its epoch, slot and tick on the edge that drives CONVST high. The held `outcome_valid_o` tuple reports the scheduling decision to its separate consumer. Its ready/valid handshake is not permission to start capture late, and it is not a completed ADC frame or a published record. The physical marker-to-ADC-pin offset remains the explicitly unmeasured path described in the [scheduler timing characterization](slot-scheduler.md).

## Stop, closure and ownership

The wrapper forwards the controller's composite `stop_o` to the scheduler. Scheduler cause bit zero therefore means a controller or explicit stop request; it does not imply software was the original source. CPU reset/halt and supervisor inputs also reach the scheduler directly. Scheduler fault occurrences return through a registered beat on control `fault_occurrence_i` bit 15. Unlike a level input, that channel counts adjacent beats separately even when the event queue is full. It avoids combinational fault/STOP feedback while the scheduler independently vetoes an unsafe due edge without waiting for that beat. Control lifecycle reporting may therefore lag autonomous scheduler inhibition by one edge; `scheduler_active_o` identifies scheduler activity.

External `fault_i` bits 0 through 14 retain their external-source meaning. Bit 15 is reserved for scheduler faults; an external assertion of that bit reports INTERNAL. Bits 16 through 31 remain unsupported as in the control interface. Detailed scheduler causes and first/latest fault ticks remain separately exposed by the wrapper. External pin isolation must respond to the combined control and scheduler isolation request; no physical isolator is implemented here.

Control cannot accept a backend closure while the scheduler is active, CONVST is high, a decision tuple is still owned, or `capture_idle_i` is false. A closure also needs a valid scheduler end receipt for the same epoch, external `ownership_clear_i` and idle-pin attestation. Premature closure does not silently discard a pulse or tuple: it fails the control backend's containment check and remains observable as a service fault. Control's closure timeout still runs without CPU service.

The scheduler may seal an uncertain end receipt after its 80-tick notification timeout while retaining the unaccepted tuple. `end_delivered_o` is the count at sealing. A later handshake increments live `delivered_o` but cannot rewrite that sealed receipt. The backend must join those retained facts, account the old owner and capture/storage tail, and retain the complete closure metadata before acknowledging it. These counts describe scheduling notifications, not raw-record durability.

An external backend cannot downgrade known scheduler uncertainty: the wrapper promotes a valid clean/loss closure response to CLOSED_UNCERTAIN when `exact_o` is false. The malformed result value 3 remains invalid and is never converted into a successful response. A backend is still responsible for additional losses or uncertainty that only capture, memory or archival logic can observe.

The scheduler end receipt and control terminal are distinct retained objects. The wrapper never automatically acknowledges the scheduler receipt when the controller accepts a close response. `end_ack_i` with a matching epoch releases it only after control positively seals a terminal for that same epoch, local owners have retired, capture is idle, and external containment and idle pins are positively attested. `terminal_sealed_o` excludes an old terminal and an epoch that remains open. Absence of a closure request alone is insufficient during the one-edge scheduler-fault feedback window. An otherwise premature end acknowledgment returns UNQUALIFIED. A permitted wrong or duplicate identity returns STALE_COMMAND through the scheduler. The recorder must archive the full scheduler and backend closure information before issuing this acknowledgment and the separate MMIO ACK_TERMINAL. A retained scheduler receipt blocks new service admission; releasing either object alone cannot authorize another ARM.

## Reset and integration constraints

Every input is coherent in the acquisition domain. A separate CPU clock requires the retained coherent bridge and reset barriers specified by [ACQ-R1-CDC1](clock-reset-lifecycle.md). The wrapper does not make independent multibit input changes coherent merely by connecting them. Backend attestations must identify the current owned work, remain stable for their defined sampling edge, and survive CPU reset.

System reset reaches control, the shared timebase and scheduler together. Integration must isolate pins and contain old transactions before asserting it. Reset cancels local evidence only under that external authority; it is not a successful command, frame, stop or memory-release acknowledgment. The next session needs new externally verified session/timebase identity. CPU reset instead preserves the counter and retained outcomes while requesting a controlled stop.

The MMIO offsets and outcomes remain [ACQ-CONTROL-1](control-foundation.md). The wrapper has no assigned CPU address and no additional MMIO bank for scheduler counters. Scheduler outputs and its held end receipt are an explicit hardware backend interface. Those fields must be captured coherently before crossing domains or being exposed to software. `capture_idle_i`, record credit, storage availability and FIFO occupancy are pre-edge facts, not promises of same-edge downstream progress.

The [integration testbench](../tests/drg5_acquisition_timing_tb.sv) exercises the wrapper through MMIO and modeled backend inputs. Its [runner](../tests/run_acquisition_timing.py) retains source-bound simulation and generic synthesis evidence. These checks do not establish routed 80 MHz timing, ADC pin delay, physical CDC or a programmed board.

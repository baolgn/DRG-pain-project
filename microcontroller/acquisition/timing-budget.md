# ACQ-R1 timing budget

This timing allocation was introduced by **ACQ-R1 revision 3** and remains required by revision 4's [frozen formats](formats.md), before implementation of ADC control state machines. The 20 µs cadence, 100 ns pulse, 250 ns observed BUSY-rise deadline, 2 µs observed BUSY-fall deadline and 20 MHz serial clock are retained as **nominal tick-domain values**. The proposed **13 µs completed-read deadline is rejected**: a BUSY fall accepted at 2 µs cannot complete the specified transfer and checks by 13 µs. R1 retains its **1120-tick, nominal 14 µs** deadline.

The arithmetic fits the allocations below; **physical timing closure has not passed**. There is no inspected board, approved adapter, routed acquisition receiver, characterized translator or independent supervisor. Unknown physical delays are release blockers, not zero-delay paths. `ACQ-R1_AVAILABLE` remains false. No ADC state machine or new hardware behavior is implemented here.

## Contents

| Section |
| --- |
| [ADC requirements](#adc-requirements) |
| [Controller clock and event budget](#controller-clock-and-event-budget) |
| [Exact transfer edges](#exact-transfer-edges) |
| [Pin timing and capture closure](#pin-timing-and-capture-closure) |
| [BUSY synchronization](#busy-synchronization) |
| [Startup and register service](#startup-and-register-service) |
| [Storage and closure](#storage-and-closure) |
| [Independent supervision and every wait](#independent-supervision-and-every-wait) |
| [Acceptance and repeated review](#acceptance-and-repeated-review) |

## ADC requirements

Source: the pinned [AD7606C-18 Rev. B](../../datasheets/ad7606c-18.pdf), SHA-256 `73b8892ab44ca4291b8c145df3e0d5d1abee2149c962be3a88e381c3e3e4f007`; the user's original-workspace PDF has identical bytes. Printed pp. 9–10, Table 3, and p. 12, Table 5/Figure 6 were checked against the [official datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/ad7606c-18.pdf). These are silicon limits, distinct from the controller choices below.

| ADC requirement | Limit used | Applicability |
| --- | --- | --- |
| CONVST high / low width | At least 10 ns each | At ADC pins, including distortion |
| CONVST to BUSY high | At most 22 ns | Table 3; not a 250 ns silicon latency |
| No-oversampling conversion | 0.5–0.65 µs | No phase delay, normal power; R1 profile only |
| Acquisition time | At least 0.35 µs | From completed conversion to next conversion |
| Cycle specification | At least 1 µs | Table 3's serial footnote specifies four DOUT lines; this does not establish one-lane R1 throughput |
| Initial power/reset | At least 10 ms stable power before RESET; power-up plus setup greater than 2 s | First-power requirement differs from ordinary post-reset setup |
| Full RESET / post-reset setup | At least 3.2 µs / 274 µs | Partial reset is unsupported; undefined pulse-width region is forbidden |
| Maximum SCLK | 63.5 MHz at VDRIVE ≥3.1 V | R1 separately requires qualified 3.135–3.465 V rails |
| SCLK high and low width | Each at least 0.4 of the actual period | Must hold at ADC pins; an internal divide-by-four is insufficient |
| CS setup / hold | At least 2 ns each | CS fall to first SCLK fall / final SCLK fall to CS rise |
| DOUT access after SCLK rise | At most 15.7 ns | At qualified voltage and the stated 20 pF interface test load |
| First DOUT after CS fall | At most 18 ns | Separate first-bit path |
| DOUT hold after SCLK rise | At least 5 ns | Also check receiving FPGA minimum-delay/hold paths |
| SDI setup / hold | At least 9 ns / 0 ns | Register requests; ADC samples on SCLK falling edges |
| DOUT high impedance after CS rise | At most 25 ns | Include return path before a pin-lease transition |

Table 5 does not give a separate serial CS-high minimum. R1 chooses its own turnaround guard; the parallel-interface 10 ns value is not substituted. Table 5's 25 ns write/read delay applies above 50 MHz; R1's slower clock and guards already exceed it. ADC timing cannot be extrapolated to arbitrary cable capacitance, level translation, out-of-range rails or unqualified loading. The [ADC profile](adc-profile.md) fixes one DOUTA, mode 2, 18+8 bits per channel, CRC16 and the complete register image; no alternative mode inherits this budget.

## Controller clock and event budget

Admission requires an acquisition clock at **80 MHz ±100 ppm**, including calibrated frequency error, temperature, voltage and aging over the declared operating interval. This is a new required envelope, not a measurement of the present FPGA. Short-term jitter and relative clock skew are charged separately below. A changed timebase, PLL relock or violated envelope ends the epoch. Let `Tmin=12.5/1.0001=12.498750125 ns` and `Tmax=12.5/0.9999=12.501250125 ns`.

Tick deadlines are inclusive edge comparisons in the acquisition domain. A matching event on the deadline wins; a later event fails. They are not exact wall-clock ceilings. Independent deadlines explicitly labelled hard below include supervisor tolerance and propagation. The timestamp remains the scheduled FPGA CONVST rising-edge marker; marker-to-ADC-pin delay and uncertainty belong in the descriptor and are not subtracted from ticks.

| Event | Controller allocation | Tolerance envelope / disposition |
| --- | --- | --- |
| Scheduled interval | 1600 ticks, nominal 20 µs | 19.998000–20.002000 µs; fixed grid, never stretched |
| CONVST high | 8 ticks, nominal 100 ns | 99.990001–100.010001 ns before pin distortion; safely above ADC minimum |
| Observed BUSY rise | By trigger+20 ticks, nominal 250 ns | 249.975002–250.025003 ns; includes CDC |
| Observed BUSY fall | By trigger+160 ticks, nominal 2 µs | 1.999800–2.000200 µs; includes CDC; not normal ADC conversion duration |
| CS dispatch | Within 4 ticks of matched observed fall | At most 50.005001 ns |
| Serial clock | Half-cycle 2 ticks, full period 4 ticks | 20 MHz nominal; 224/20 MHz = 11.2 µs nominal |
| 224-period allowance | 896 ticks | 11.198880–11.201120 µs; exact edge meaning below |
| Proposed complete-read limit | 1040 ticks, nominal 13 µs | **Rejected:** 28 ticks short of exact worst case, 32 short of conservative envelope |
| Accepted complete-read limit | 1120 ticks, nominal 14 µs | 13.998600–14.001400 µs; frame, status/CRC, pins and assembled record resolved |
| Conservative completion | 1072 ticks, nominal 13.4 µs | At most 13.401340 µs; 48-tick margin ≥599.940 ns |
| Deadline to next slot | 480 ticks, nominal 6 µs | At least 5.999400 µs; not permission to accept a late frame |

`completed read` means all 224 bits captured, ordered sample/status pairs and CRC resolved, validity/cause finalized, CS/SCLK high, and one stable record outcome available in reserved staging. It excludes FIFO acceptance, DMA, publication, IRQ and host storage, which have separate bounds. CRC/status work must be incremental during capture; a post-frame 224-bit serial CRC pass is outside this budget and is rejected. No CPU service is in the conversion path.

## Exact transfer edges

Let `F` be the tick recognizing this trigger's matched BUSY fall and `C≤F+4` the CS-assertion tick. All edges are acquisition-clock enables; DOUT is captured on the scheduled falling-SCLK marker.

| Edge or completion | Latest tick |
| --- | --- |
| CS low | `C` |
| First falling capture | `C+4` |
| Capture number k, k=1..224 | `C+4+4*(k−1)` |
| Last falling capture | `C+896` |
| Final SCLK high | `C+898` |
| CS high | `C+900` |
| CRC/status finalization and stable record | `C+904` |
| Earliest next CS assertion | `C+904`, after four high ticks |

There are **223 periods between 224 capture edges**. The CS setup interval plus these periods is already 896 ticks; adding another full 224 periods after setup would count one period twice. Exact dispatch-through-finalization is `4+4+223*4+2+2+4=908` ticks. At `F=160`, exact completion is tick 1068, nominal **13.35 µs**. The existing 1072-tick estimate is retained as an explicitly conservative envelope with four spare ticks, not as the exact edge count.

The 48-tick margin is measured between the conservative envelope and deadline on the **same clock**; do not subtract a slow-clock completion from an unrelated fast-clock deadline. For normal qualified ADC behavior, the BUSY path below fits within 60 ticks and the conservative finish is 972 ticks, at most **12.151215 µs**. That healthy case fits 13 µs, but the supported 160-tick BUSY window does not. Keeping 14 µs avoids a hidden earlier read-admission cutoff or a partially implemented late-conversion case.

## Pin timing and capture closure

The following are **maximum allocations for a candidate direct connection**, not ECP5 measurements. The full acquisition top must demonstrate them at all admitted PVT corners, with actual I/O standard, load, slew, placement, routing and clock network. Analog-board/cable/adapter delays include connectors, trace delay, threshold crossing and the board's series parts.

| Contribution | Required allocation |
| --- | --- |
| FPGA launch register to SCLK, CS, SDI or CONVST pad | ≤2.0 ns |
| Each forward or return board/adapter route | ≤0.75 ns |
| FPGA DOUT/BUSY pad to receiving register, including setup | ≤2.0 ns |
| Relative launch/capture uncertainty | ≤1.0 ns; includes relevant jitter and skew |
| FPGA receiver hold requirement | ≤1.0 ns; demonstrate minimum as well as maximum paths |
| Total SCLK/CONVST half-pulse distortion | ≤3.0 ns, including edge asymmetry and jitter |
| Total SCLK full-period distortion | ≤2.0 ns, including jitter; qualify separately from half-pulse distortion |
| Translators/isolators | 0 ns **only for the direct candidate**; none is selected or approved |

For the repeated DOUT setup path, the complete inequality is:

`2*Tmin − (FPGA SCLK output + forward route + forward translator + ADC access + return route + return translator + FPGA input/setup + relative uncertainty) > 0`.

The ADC alone leaves `24.997500−15.7 = 9.297500 ns` at the fastest clock, approximately the user's nominal **9.3 ns**. The direct-path allocation consumes another `2+.75+.75+2+1=6.5 ns`, leaving **2.797500 ns**. It must be verified in timing reports and pin captures. A translator cannot be silently assigned zero: both directions, propagation asymmetry, loading and minimum delay must be re-budgeted. A combined added delay of 3 ns already fails this allocation. Qualify shared/tracking supplies and unpowered isolation as described in the [board review](board-qualification.md); do not parallel regulator outputs to avoid translation.

| Other path | Conservative inequality and allocated margin |
| --- | --- |
| First DOUT setup | `4*Tmin−(2+.75+18+.75+2+1)` = **25.495001 ns** |
| CS setup at ADC | `4*Tmin−2.75−1−2` = **44.245001 ns**; compare actual paired paths |
| CS hold after final SCLK rise | `2*Tmin−2.75−1−2` = **19.247500 ns**; conservatively covers the specified final-falling-edge hold too |
| SDI setup during register service | `2*Tmin−2.75−1−9` = **12.247500 ns** |
| SDI hold | `2*Tmin−2.75−1−0` = **21.247500 ns** |
| Repeated DOUT hold | `2*Tmin+5−1−1` = **27.997500 ns**, using conservative zero physical minimum delays |
| DOUT hold against CS disable | `4*Tmin−1−1` = **47.995001 ns**; CS must not disable the final sample too early |
| CS-high turnaround through DOUT high impedance | `4*Tmin−(2+.75+25+.75+2+1)` = **18.495001 ns** before next owner/transaction |
| CONVST high minimum | `8*Tmin−3` = **96.990001 ns**, margin **86.990001 ns** over 10 ns |
| CONVST low minimum | `1592*Tmin−3` > **19.895 µs**, well above 10 ns |
| SCLK high/low duty limit | `2*Tmin−3−0.4*(4*Tmax+2)` = **1.195500 ns** margin |
| Minimum SCLK period | `4*Tmin−2` = **47.995001 ns**, still slower than the 63.5 MHz ADC maximum |

Minimum-delay/hold analysis includes clock skew, early CS disable and next-SCLK transition; a positive setup number alone is not closure. Initial SDI must be stable before the first falling edge. SCLK idles high and SDI changes on rising edges. DOUT uses the timed capture register, **not** a generic two-flop data synchronizer, which would change bit identity. FRSTDATA is unused for acceptance; adding it requires its own path and timing budget.

The pinned nextpnr ECP5 flow does not establish general external input/output-delay closure through arbitrary SDC. Required evidence is a reviewed generated-clock/edge relationship, min/max routed FPGA path reports, board/translator measurements or justified bounds, a composed external timing report and physical captures. Unsupported constraints or successful internal Fmax are not substitutes. The existing full P25 CPU route and small 80 MHz primitive smoke do not close these paths.

## BUSY synchronization

BUSY is asynchronous to the acquisition clock. Budget **four acquisition ticks** from the qualified receiving boundary through synchronization and registered edge recognition: two synchronization stages, recognition, and one additional-cycle allowance. This is a CDC design/MTBF admission requirement, not an absolute upper bound on metastability resolution. CDC analysis must establish acceptable failure probability and placement; any delayed/missed/illegal edge is contained by the deadlines and cannot validate a later slot. DOUT capture does not share this synchronizer.

Conservatively budget `2.75 ns CONVST outward + 22 ns ADC BUSY rise + 2.75 ns BUSY return/input + 4*Tmax + 1 ns uncertainty = 78.505001 ns` to observed rise, leaving **171.470002 ns** against the earliest 20-tick deadline. Adding the full 650 ns conversion maximum gives **728.505001 ns** to observed fall, leaving **1271.295019 ns** against the earliest 160-tick deadline. This sum deliberately charges both the rise delay and full conversion duration, even where their specification references overlap. It fits before 60 ticks even at the fastest clock.

Use a matched high then low, never an old low level. The minimum BUSY pulse must survive the crossing: conservatively 500 ns conversion minus 22 ns rise offset and 3 ns distortion leaves 475 ns, greater than four slow acquisition ticks. Normal acquisition time before the next trigger is over 19 µs; the checker also tests the more conservative controller-fall envelope against the ADC's 350 ns requirement. Timeout, illegal sequence, clock/qualification loss or a stale edge invalidates the slot and closes the epoch. No polling loop, retry or clock-stopped timer can extend a deadline.

## Startup and register service

CONFIGURE and RECOVER have a **hard three-second independent deadline from acceptance**, covering every phase. Failure never restarts that timer. The 2.1 s, 10 µs and 1 ms waits below are nominal tick allocations; their fastest-clock values still exceed the ADC minima. A failed phase terminates the attempt, not an automatic retry.

| Operation | Allocation / deadline | Meaning and margin |
| --- | --- | --- |
| Establish stable rails/reference/clocks/ownership | ≤500 ms wall time | Otherwise `CONFIGURATION_FAILED`; no indefinite power-good wait |
| Initial stable-power wait | 168,000,000 ticks, nominal 2.1 s | At least 2.099790 s; exceeds the strict >2 s combined requirement and 10 ms pre-reset minimum |
| Full RESET high | 800 ticks, nominal 10 µs | Minimum 9.999000 µs before 3 ns distortion; exceeds 3.2 µs; clock/power fault invokes isolation |
| Post-reset setup | 80,000 ticks, nominal 1 ms | Minimum 999.900010 µs; exceeds 274 µs |
| One register request, including dispatch, guard and response CRC | ≤160 ticks, nominal 2 µs | 16 bits before CRC enable, 24 after; pipeline response belongs to the preceding request |
| Register transaction service demand | ≤112 ticks for the 24-bit case | Four preparation + 96 through last capture + four tail + four checks + four high guard; 48 ticks spare to timeout; shorter 16-bit case also fits |
| Entire register sequence | At most 512 requests | A static manifest must enumerate all image writes, duplicate read requests, CRC-mode entry and diagnostics; exhaustion fails, no retries |
| Two pattern conversions | Exactly two, 1600 ticks apart; ≤3232 ticks total service reservation | Last result by second trigger+1120; remaining 512 ticks cover mode/ownership handoff, not a third conversion |
| Analog settling/qualification after final configuration | ≤250 ms wall time | Descriptor's measured settling bound must fit; unsupported longer/unknown bounds reject admission |
| Final descriptor/readiness publication | ≤1 ms wall time | READY only after all preceding gates, never from register success alone |

Even charging all 512 register timeouts serially (≤1.024103 ms), both conversion windows and every phase above, the total is **2.853284628 s**; use the checker's unrounded total as authority. The earliest independent configuration expiry below is later than this total by **145.415502 ms**. Qualification monitors may work concurrently, but the budget does not rely on overlap. Exact image semantics, error read/log/W1C handling, CRC transition and two-read association remain in the [ADC profile](adc-profile.md).

## Storage and closure

Storage budgets are **new admission requirements**, not a claim that FIFO/DMA/ring hardware exists. Every CDC, arbitration pause, refresh, header/CRC32C calculation, cache/fence requirement and controller stall must be included. Require ≥4,000,000 bytes/s guaranteed capture service after grant, at most 64 extra bytes of publication metadata per block, and the latency caps below. Measured average bandwidth is insufficient.

Revision 4 fills that capture-metadata allowance with exactly one 64-byte ACD1 descriptor (60-byte body plus final four-byte PUB1 store). Its separate retirement clear is four bytes charged to allocation-control service, not capture or transport's 64-byte metadata allowances. At the fastest admitted clock it consumes ≤781.328125 B/s of the allocation-control master's separately qualified 4 MB/s reservation; normal acknowledgement is ≤80 µs and timeout/action ≤100 µs. It cannot block closure while waiting for a consumer, and failure leaves that allocation nonfree. The numerical capture/drain calculations below remain unchanged; the format review separately checks this added control traffic and the 4096-byte descriptor table.

| Operation | Bound and failure handling |
| --- | --- |
| Resolved record to reserved FIFO/staging handoff | Qualified work ≤64 ticks; timeout at 80 ticks (≤1.000101 µs), leaving ≥199.980 ns normal margin; failure stops with internal/storage fault, retains ownership for closure or accounts loss |
| FIFO to free block builder | Once the sole builder is free, first and subsequent available records each transfer within 80 acquisition ticks; qualified work ≤64 ticks. The transferred record counts within the builder's 256-record bound, not another hidden queue |
| DMA grant / no-progress wait | Qualified response ≤80 µs; timeout/action by 100 µs wall time, leaving 20 µs margin; preserve accepted transaction identities and initiate containment |
| Each accepted memory transaction response | Qualified response ≤80 µs; timeout/action by 100 µs wall time, within the service envelope; timeout does not cancel a potentially live write |
| Full-block writes after grant | `(12352+64)/4,000,000` = **3.104 ms** maximum service time; all stalls after grant must fit this service guarantee |
| Final CRC/header visibility/fence | Qualified work ≤80 µs, timeout/action by 100 µs wall time |
| Atomic publication acknowledgement | Qualified work ≤80 µs, timeout/action by 100 µs wall time; no published descriptor before globally visible successful writes |
| Complete sealed-block publication | ≤4 ms wall time; combined budget **3.404 ms**, margin **596 µs**; maximum arrival rate gives ≥5.119488 ms per full block |
| Closure watermark crossing and record handoff | Combined ≤2 µs wall time; if producer cannot acknowledge, independent containment uses last trustworthy boundary |
| STOP pending frame | Original trigger+1120 deadline; no restart of frame timer |
| Entire stop/drain/containment | Hard ≤10 ms from stop acceptance; independent supervisor acts earlier as below |

Per-transaction deadlines are nested inside the block service guarantee, not 100 µs of extra slack for every word. The 3.404 ms publication envelope conservatively charges the full 100 µs watchdog allocations; normal phase work must meet the smaller 80 µs qualification caps. Block CRC32C must be incremental or otherwise fit the stated visibility phase. A partial block closes immediately on STOP after preceding data resolves; it does not wait for 256 future records. A continuously recording block's fill wait spans at most 256 slot periods plus the bounded frame/handoff phase, and is supervised by slot, record, capacity and memory watchdogs throughout. A permitted transient analog recovery keeps the same cadence and per-slot invalid mask; measured recovery plus observation/validity propagation must be ≤249 ms from known onset, with independently enforced timeout/fault action by 250 ms. This leaves at least 1 ms normal margin to that hard limit. Timeout or unknown onset faults the epoch, rather than waiting indefinitely for analog-valid permission.

Frame deadline plus handoff is at most `1120+80=1200` ticks, leaving **400 ticks (≥4.999500 µs)** before the next slot. Starting with an empty FIFO after a completed block is handed to the sole writer, the conservative 3.404 ms publication envelope accumulates at most **171 new records**, including worst-case frame/handoff latency variation, below the 192-record high-water stop. Moving those 171 records into the next free builder within 171 handoff windows admits at most **10 further records**, even conservatively charging the full frame/handoff variation again: peak occupancy is bounded by **181**, leaving 11 records before high water. Internal FIFO-to-builder movement has its own ≤80-tick bound; it must not consume an unbudgeted second external-memory pass. The 4 MB/s guarantee covers all external capture writes/stalls. If the FIFO was not empty at the publication interval's start, admission uses actual occupancy and may stop sooner. Sustained qualification must demonstrate this repeating service envelope. The 4 ms publication watchdog can outlast high-water capacity; a capacity stop wins rather than extending RUN until the watchdog.

Bound the total unresolved tail to **514 records**: at most 256 FIFO records, 256 records already owned by the single DMA/block builder, one producer-staged record and one pending slot outcome. No additional queue, second writer or speculative owned block is admitted without a new budget. This tail needs at most three headers and three ≤64-byte publication descriptors: `514*48+3*64+3*64 = 25,056 bytes`. At 4 MB/s it needs **6.264 ms**. Conservatively charge all 514 records another `514*80*Tmax` internal handoff time (≤514.051406 µs), even though some already reside in the builder, without assuming overlap with external writes. Adding three 300 µs overhead allocations, original frame completion and 2 µs closure crossing/handoff gives **7.694052806 ms**. It fits before even the earliest 9.899010 ms drain-watchdog expiry with **2.204957293 ms** margin. This is a successful-drain bound only when matching free ring credits and healthy memory exist.

If credits or memory are unavailable, stop and close with explicit loss/uncertainty; do not wait for the host, reuse owned storage or certify a write cancelled merely because its response timed out. The independent path quarantines unconfirmed writes by the hard 10 ms limit. A failed containment acknowledgement leaves FAULT and restart inhibited; it never starts an unbounded active drain. Terminal metadata is retained outside data queues. Event, completion and terminal acknowledgement waits are passive retention, not blockers of hardware stop.

At +100 ppm, raw ingress including block headers is **2,412,741.25 B/s**. Twenty-four free blocks span **122.867713 ms**, conditionally covering the 100 ms host-stall objective with **22.867713 ms** capacity margin; FIFO/memory service must still meet the above bounds. CPU ISR, host archive and consumer lease release have no per-sample deadline. If they stall beyond capacity, hardware stops; it never changes cadence. Recovery/lease retirement is explicit, supervised and disarmed.

## Independent supervision and every wait

Require a **separate 10 MHz ±100 ppm supervisor reference**, independent of the acquisition clock/PLL and CPU halt/reset. These are candidate admission requirements; no such supervisor is implemented or qualified. A timer clocked by the failed acquisition clock cannot enforce clock-loss, cancellation or drain deadlines. Supervisory power loss requires qualified passive isolation; it may leave the archive `INCOMPLETE`.

Local handoff timers run in the acquisition domain. DMA/response/visibility and control-access watchdogs run in a still-live supervising domain independent of the target memory/control clock; their paths must meet their own stated end-to-end bounds even if that target clock stops. A stopped acquisition clock invokes the independent ≤10 µs isolation path instead of pretending the local tick deadline elapsed. Wall-time watchdog programming must round down for the slowest timer and charge all crossing/actuation latency; a nominal counter value alone does not meet a hard bound. Memory/control failure yields access failure or storage fault and quarantine, never a fabricated response.

The 10 MHz supervisor itself requires a **separate retriggered hardware permit watchdog** with an independent analog timebase, held safe without power, whose maximum heartbeat-loss-to-isolation delay is ≤10 µs including tolerance and actuator delay. Its normal heartbeat gap must be ≤1 µs and its earliest expiry ≥2 µs, leaving ≥1 µs normal margin. A stopped supervisor clock with power present therefore removes the permit without requiring software or that clock to run. This is an explicit missing-hardware release gate, not an assumed feature of ULX3S. The claimed fault model covers a single stopped logical/reference clock while the independent watchdog/isolator remains healthy; simultaneous failure of the independent watchdog/isolator is outside that containment claim and cannot be reported as clean closure.

The following counts include slow-clock tolerance. The noncounter allowance includes **all** detector/crossing, timer-arm, actuator/isolation and acknowledgement latency relevant to that row; it is not extra slack per crossing. Prove the complete end-to-end path, including a stale heartbeat already in flight. The supervisor must observe acquisition progress, not a CPU heartbeat.

| Hard end-to-end limit | Counter allocation | Maximum noncounter time | Worst-case action time / minimum margin |
| --- | --- | --- | --- |
| Clock-loss detection and isolation ≤10 µs | 80 supervisor ticks | 1.5 µs | 9.500800 µs / **0.499200 µs** |
| Safe service cancellation or forced isolation ≤14 µs | 135 ticks | 0.4 µs | 13.901350 µs / **0.098650 µs** |
| Drain completion or quarantine ≤10 ms | 99,000 ticks | 0.4 µs | 9.901390 ms / **0.098610 ms** |
| Configuration completion or failure ≤3 s | 29,990,000 ticks | 0.4 µs | 2.999300330 s / **0.699670 ms** |

For clean cancellation, the in-flight operation keeps its original deadline. The largest service operation is the ≤13.401340 µs conservative conversion envelope, smaller than the earliest cancellation watchdog expiry of 13.498650 µs; cancellation recognition/termination overhead must fit the remaining **97.310 ns** for that clean path. RESET and register transactions are shorter. If this clean-path bound is not met or the clock fails, the independent path isolates and reports failure within the hard bound instead. A watchdog cannot promise completion through a physical fault.

| Wait or dwell | Timeout or independent supervision | Observable exit |
| --- | --- | --- |
| Command admission / MMIO crossing | A binding must qualify each accessible request/reply at ≤0.8 µs and bound timeout/access failure to ≤1 µs wall time, with independent supervision of the control clock | Inaccessible transport is an access failure, never a fabricated command rejection or success; accepted-operation watchdog and emergency STOP remain autonomous |
| Power-good, reset, setup, register response, test conversion, analog readiness | Phase budgets above plus independent three-second command watchdog | READY, `CONFIGURATION_FAILED`, or bounded cancellation; no retries |
| Permitted analog recovery while RUN | Qualified work plus observation ≤249 ms from known onset; independent timeout/fault action by 250 ms, preserving ≥1 ms normal margin | Recover channel validity within unchanged configuration, or fault-close; no change to cadence |
| Next scheduled slot | Exactly 1600 ticks; independent progress/clock monitor | Due slot or fault closure; no wait on CPU/capacity |
| BUSY rise / fall | Trigger+20 / +160 ticks plus clock-loss supervisor | Matched edge or invalid slot/epoch closure |
| CS dispatch / transfer / final checks | Four-tick dispatch, bounded edge count, trigger+1120 final watchdog | Stable valid/invalid record or timeout, idle/isolate and close |
| FIFO handoff / block fill / DMA grant / memory response / visibility / publication | Explicit storage bounds; fill also supervised by cadence and capacity | Published ownership or bounded loss/quarantine |
| STOPPING / service cancellation | Original frame bound or hard 14 µs cancellation supervisor | Idle and drain/cancel, or FAULT/isolation |
| DRAINING / closure receipt | Hard 10 ms independent watchdog, without requiring a failed producer to reply | Terminal clean/loss/uncertain outcome; quarantine if necessary |
| IRQ / event / completion / terminal acknowledgement | Passive retained state; independent supervision and capacity/fault stop, no auto-clear deadline | Correct acknowledgement or continued retention; overflow counted per contract |
| Consumer lease / durable archive / restart prerequisite | Passive ownership; independently supervised disarmed state after capacity stop | Positive retirement/archive then explicit recovery; timeout never frees a lease |
| SAFE / READY / CLOSED / FAULT idle | Intentionally indefinite disarmed dwell under independent power/clock/isolation supervision | Explicit valid command or fault; never automatic restart |
| Quarantine / containment not positively confirmed | No active capture; independent isolation remains asserted | FAULT until independently verified containment; unknown is not zero outstanding work |
| Supervisor reference stops with power present | Independent analog permit watchdog isolates within ≤10 µs; no acknowledgement needed from the stopped supervisor | Fault/incomplete or uncertain closure; recording permit remains removed until explicit requalification |

An acknowledgement/host wait can be indefinite **only while passive and independently supervised**. Its elapsed time cannot block fault response or preserve RUN after capacity is exhausted. A binding without the promised local control timeout, independent emergency path, timer progress monitoring or containment is unsupported. Reset/clock/analog changes terminate the epoch under the contract; no new timing model is applied mid-epoch.

## Acceptance and repeated review

The [ACQ-R1-CDC1 supplement](clock-reset-lifecycle.md) keeps these deadline allocations. It assigns ARM-created ACE1 delivery ≤24 acquisition ticks normal/32 fault action and ≤32 further ticks for FIFO visibility/read transfer, all inside the existing 64-tick normal/80-tick timeout handoff window. Its per-target progress watchdog uses the existing 80 supervisor ticks plus 1.5 µs total last-response/detection/isolation allowance; A and S have independent timers. Reset/link setup is disarmed and consumes the existing 500 ms startup allocation, not extra configuration time. These are qualification suballocations; prior timing evidence is not physical proof of these crossings.

Run `python3 microcontroller/acquisition/check_timing.py --output <fresh-output.json>` for exact arithmetic, exhaustive BUSY-fall edge placement and rejection controls. The enumeration includes ticks 0..160 as a conservative superset; it does not admit an early/unmatched BUSY sequence. The final [r4 arithmetic](evidence/timing-2026-11-05/arithmetic-r4.json), [comment audit](evidence/timing-2026-11-05/comments.json) and [review record](evidence/timing-2026-11-05/review.json) identify their actual sources. Four successive calculation revisions and their exact source snapshots are retained; passing an older arithmetic revision did not cover later-discovered omissions. Previous definition and hardware-review evidence remains historical; it is not rewritten to appear to validate revision 3.

Review separates ADC limits from allocations, rejects 13 µs for the full admitted window, removes the first/last-edge ambiguity, charges clock tolerance and waveform distortion, adds setup/hold/SDI/turnaround paths, bounds service/storage/cancellation waits, and checks independent watchdog clock failure. It also corrected swapped STBY/PAR-SER U4 pin numbers in the board table against both schematic and datasheet. Independent reviewers recheck the final equations and outcome coverage; retained failed checks document corrections.

Specification arithmetic passes only if every admitted operation fits its allocation with positive margin and every wait is bounded or explicitly passive with independent supervision. **Actual implementation/physical acceptance remains open** until routed I/O min/max reports, qualified clocks/CDC/load/board/translator bounds, measured pin captures, memory service/containment tests and clock-loss/cancellation fault injections demonstrate those requirements. A document or offline checker cannot supply the missing measurements.

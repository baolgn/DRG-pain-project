# IRQ/WFI integration qualification

## Table of contents

1. [Evidence record](#evidence-record)

## Evidence record

`summary.json` binds each passing run to exact source hashes, the Verilator version, full commands and the final source snapshot. `c0/` and `c1/` retain complete compilation, simulation and calibrated failure logs. C1 changes alignment configuration only; the tested instruction stream remains raw RV32I/Zicsr. This is not ACT4/Sail or complete-core qualification.

The testbench independently maintains instruction identities, admission ownership, GPR/CSR state, counters, continuation PCs, interrupt events, physical bus ownership and target effects. Interrupt entry is a separate event; it does not fabricate an instruction retirement. An accepted read of x0 increments a device counter, so an extra effect can fail even when the retired load value is unchanged. Platform pending levels, time, compare, software interrupts and block counts are checked against independently maintained state. The platform and CPU execute on every test clock; CPU idle never gates the timer or the acquisition-clock monitor.

| Requirement | Executed coverage / detector |
|---|---|
| Masking and priority | All 64 combinations of three local enables and three pending sources; external > software > timer; unsupported source bits ignored |
| Immediate reevaluation | MIE and mie enabling writes; MRET with unacknowledged pending source; already-admitted clear-MIE/clear-mie cancellation; ignored mip writes |
| Live eligibility | Source withdrawal while old fetch ownership drains; cause changes before actual entry |
| Precise instruction boundary | Independent next-PC and admission ledger; unadmitted illegal instruction cancellation; admitted faulted diagnostic CSR drains before IRQ |
| Data ownership and synchronous priority | Pending IRQ before acceptance and during response wait; successful side-effectful load x0; guaranteed no-effect error wins over pending IRQ |
| Redirects | External flush continuation becomes saved mepc before IRQ entry |
| WFI | Masked source stays asleep; locally enabled source wakes with MIE=0; already-pending source prevents sleep; enabled wake saves PC+4; poisoned diagnostic continuation is ignored |
| Counters and reset | WFI retires once; mcycle and independent acquisition/timer clocks continue; hart reset wakes idle, preserves queued peripheral events, and drains an already-accepted access once without retiring its killed instruction |
| Real sources | CPU MMIO creates/clears MSIP, programs timer compare, enables and acknowledges retained block notifications |
| Healthy latency | Twenty service schedules per seed including 126/1, 0/127 and 63/64 acceptance/response splits; exact 128-clock launch-to-response service limit |
| Handler work | Actual raw32 stores save sixteen caller-clobbered GPRs; real block ACK; actual loads restore all values; MRET resumes the saved boundary |
| Uncertain outcomes | Explicit uncertain response and response at clock129 after deadline128; fatal evidence, no IRQ, no retirement, no replay; late response preserves recovery ownership |
| Checker calibration | Corrupted IRQ PC, cause, missing event, idle counter, wake observation, duplicate physical read effect; all must fail their named ordinary detector |

Latency starts at the edge at which a newly retained platform block makes the synchronized external level visible. One prior data transaction may consume 128 clocks including acceptance and response. Old instruction ownership is modeled by `fetch_busy_i` for four clocks; a separate fetch/controller test checks the actual fetch unit. The first endpoint case holds an already-admitted arithmetic token for 36 clocks after old data completes as a **future divider occupancy surrogate**. It executes ADDI, not division. The current-profile endpoint uses an eight-clock hold. The 36-clock case replaces that eight-clock hold; it does not exercise an additional 8+36 schedule. Measured schedule maxima are evidence, not a proof of all possible WCET schedules.

After entry, vector instruction delivery is modeled as sixteen adapter clocks, followed by actual F-to-D control transfers. The handler receives further raw32 packets without additional delivery delay. Local RAM and peripheral transactions accept one clock after launch and respond one clock after acceptance, with no DMA contention. These assumptions are required for the reported firmware intervals.

The final six runs (C0/C1 × seeds 0, 1, 305419896) each pass 110 cases, 16,892 clock edges, 3,032 normal retirements, 71 interrupt events and 714 bus responses. Aggregate independent checks: **54,329,388**. All twelve negative-control runs fail their required detector.

| Endpoint in CPU clocks | Current eight-clock hold schedule | Future 36-clock occupancy surrogate |
|---|---:|---:|
| Synchronized level → IRQ entry | 135 | 163 |
| Synchronized level → first handler D | 153 | 181 |
| Synchronized level → all sixteen saves retired | 220 | 248 |
| First handler D → ACK physical effect | 87 | 87 |
| First handler D → ACK response completion | 88 | 88 |
| First handler D → MRET retirement | 166 | 166 |

The measured maximum healthy data transaction is exactly 128 clocks. Fatal tests are separate: the explicit uncertain response contains at clock5; the missing-response case contains at deadline128 and receives its late response at clock129 without architectural completion or replay. These timings are not counted as passing healthy interrupt latency.

The handler's reserved 64-byte save area begins at `0x20000000`; x2 already points to it. The save set is `ra,t0-t2,a0-a7,t3-t6` (x1, x5-x7, x10-x17, x28-x31). The fixture performs sixteen stores, uses t0/t1 to ACK one queued block, restores sixteen registers with loads, then executes MRET. ACK acceptance is the physical device-effect endpoint; the matching response is recorded separately as ACK completion. No ADC conversion, capture or raw-data movement is performed by this handler. This fixture measures the declared stub, not an arbitrary application or acquisition-block algorithm.

The retained revisions record real development changes rather than repeated unsupported quality claims:

- `01-initial/` is the first smoke-only testbench before strict compilation. Strict compilation exposed a reserved identifier and test-process lint issues; these were corrected without HDL warning waivers.
- `02-wfi-fixture/` retains the expanded source and actual failure log. The WFI continuation assertion mistakenly compared saved mepc against the driver's PC after the IRQ helper had already changed that PC to the vector; the independent reference model had passed. The assertion now saves the expected continuation before calling that helper.
- Later changes expanded the corpus, separated ACK effect from response completion, corrected the independent timer-write reference at rollover, and added explicit fatal containment and complete firmware restore/return checks. Only the final source-hashed run is qualification evidence.

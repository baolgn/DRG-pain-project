# Multiply/divide control qualification

The [summary](summary.json) binds the passing executable runs to exact production RTL, testbench, runner and Makefile hashes. `qualified-source/` preserves those files; configuration directories retain full compiler, seed and negative-control logs. The testbench drives raw 32-bit instructions through the five-stage control input. It does not replace the multiplier/divider with a latency surrogate.

## Table of contents

1. [Configurations](#configurations)
2. [Independent checks](#independent-checks)
3. [Timing endpoints and assumptions](#timing-endpoints-and-assumptions)
4. [Review revisions](#review-revisions)

Final result: **15 passing runs**, **3,513 cases**, **315,996 clocks**, **167,511,445 comparisons**, and **four correctly detected corruptions**. The ledgers account for 4,389 arithmetic starts as 4,377 consumed completions plus 12 isolated cold-reset cancellations; 852 completions belonged to obsolete or contained instructions. There are 3,525 M retirements, 4,242 memory offers and responses, and 4,224 permitted memory effects.

Run from the project root:

```sh
python3 microcontroller/tests/run_muldiv_control.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-muldiv-control-replay
```

Every elaboration uses `--timing --assert -Wall`, without warning suppression. Each runs seeds `0`, `1` and `305419896`; the independent 32-bit LCG uses `state = state * 1664525 + 1013904223`. The simulator seed is separately fixed at `1`. Failures report the seed, case, clock, architectural PC, physical memory owner and ages, arithmetic owner and result, and all five pipeline identities. Exact commands appear in each log.

## Configurations

| M | Diagnostic | Forwarding | IRQ | Scope |
|---|---|---|---|---|
| 1 | 0 | 1 | 1 | Arithmetic, overlap, forwarding, cancellation, IRQ and actual handler |
| 1 | 0 | 0 | 1 | Same instruction corpus with interlocks |
| 1 | 1 | 1 | 1 | One instruction in flight; arithmetic, cancellation and division-phase IRQ |
| 1 | 0 | 1 | 0 | Arithmetic, overlap, forwarding and cancellation with IRQ admission disabled |
| 0 | 0 | 1 | 1 | All eight M encodings rejected; no arithmetic job; matching `misa` |

`C_ENABLED=0` in every configuration. `OP_BASE` rejects M even in an M-enabled build; `OP_MACHINE` is the enabled machine entry. The disabled profile has no measured arithmetic latency; its `10000` earliest-transfer/retirement fields are uninitialized-measurement sentinels, not latency claims.

## Independent checks

The retirement model decodes original raw bits and uses its own architectural GPR/CSR state. Mathematical multiplication, division and remainder determine expected results independently of the restoring divider. This catches incorrect captured operands as well as arithmetic errors. The separate job ledger checks exact start identity, one owner, fixed first-valid timing, capture, transfer, cancellation and stable saved results. Its unit-local result expectation uses the captured operand values; that check supplements the independent architectural model.

The bus ledger separately reconstructs permitted addresses and store data from architectural source values, accounts for offers, acceptance, response and effect, and models RAM and ticket-producing MMIO. A load to `x0` still consumes a ticket. A calibrated duplicate-ticket injection leaves retirement data unchanged and must fail the independent effect-count check.

| Requirement | Executable coverage / detector |
|---|---|
| All eight instructions and exact enablement | `arithmetic_cases`: 20 operand pairs per operation, `rd=x0`, `rs2=x0`, disabled M, `OP_BASE`, reserved `funct7`, RV64 word encoding, `misa` |
| Signed high products and division specials | Directed minimum/maximum signed values, mixed signs, zero, overflow, truncation/remainder cases and seeded full-width operands; independent mathematical result |
| Newest producer wins | Ready older W producer and unfinished same-destination X divide; D must remain blocked |
| Both M source operands | Dependent `rs1`, `rs2` and both-source alias multiply after divide |
| Consumer classes | Dependent ADDI, taken/untaken BEQ, load address and store data; independent RAM/MMIO effects |
| Stable completion | All eight operations under 40-clock X hold, then M and W backpressure; one start and one retirement |
| No obsolete result delivery | Hart reset and flush at every divide phase 0–33; older access fault and older jump; replacement M waits while an orphan finishes |
| Cold-reset identity reuse | Isolated cold reset during active division, followed by a different M instruction |
| Uncertain older response | Fatal containment prevents arithmetic retirement; job drains, hart reset retains uncertainty, cold isolation recovers |
| Exact stage endpoints | Per-UID start edge, first valid, first X capture, earliest X transfer and earliest retirement |
| Precise IRQ during division | IRQ onset at every phase 0–34; admitted divide retires before entry; pre-admission IRQ prevents a job start |
| Bounded complete service | 20 acceptance/response/hold schedules per overlapping IRQ run; real DIV, old data owner, fetch-busy indication, 16 stores, ACK, 16 loads and MRET |
| Wrong results detected | `mutate_m_result` fails the ordinary architectural register comparator |
| Stale/wrong ownership detected | `mutate_job_uid` fails the independent completion UID comparator |
| Wrong IRQ boundary detected | `mutate_irq_pc` fails the independent IRQ PC/cause comparator |
| Extra device effect detected | `mutate_duplicate_read` fails the separate physical-effect count |

Four detector calibrations run in the overlapping, forwarded IRQ profile. They must fail at the named comparator; an unrelated crash, inactive corruption or a final PASS is rejected by the runner.

## Timing endpoints and assumptions

Accepted arithmetic start is edge 0. All timing values below are measured clock intervals, including setup/final-selection cycles.

| Operation | First unit valid | X captures result | Earliest X transfer | Earliest retirement |
|---|---:|---:|---:|---:|
| MUL/MULH/MULHSU/MULHU | 2 | 3 | 4 | 6 |
| DIV/DIVU/REM/REMU | 33 | 34 | 35 | 37 |

Transfer and retirement can be delayed by backpressure. The unit's first-valid and controller-capture endpoints remain fixed in these tests. The general unit interface separately permits holding `valid` until the consumer accepts it; the controller connects that consumer-ready input high and retains its captured result in X.

The overlapping profiles retire the same 4,036 normal instructions, take the same four traps, start 386 arithmetic jobs and produce the same 702 memory effects per seed. Forwarding requires 30,915 clocks; interlocks require 33,701. The diagnostic profile omits overlap-only scenarios and is checked against the same independent architectural rules.

The IRQ service measurement starts when the retained same-clock platform event becomes visible. Its assumptions are one older data owner with `accept_delay + 1 + response_delay <= 128` clocks; outstanding instruction ownership clears within four clocks; at most eight additional X hold clocks; vector packet delivery takes 16 clocks; subsequent handler packets have no extra delivery stalls. Handler RAM/MMIO accept one clock after launch and respond one clock later, without DMA contention. Division overlaps older memory service in this fixture; the result is not evidence that these costs must add serially.

The actual handler saves `ra`, `t0`–`t2`, `a0`–`a7` and `t3`–`t6` through 16 stores into a reserved 64-byte area, acknowledges one retained block, restores the same registers through 16 loads and executes MRET. The saved values include the divide result that retired before entry. ACK acceptance/effect and ACK response/completion are recorded separately.

Healthy source-to-entry must be at most 195 clocks; source-to-first-handler-D at most 224; first-handler-D to completed ACK at most 640; first-handler-D through MRET at most 800. The isolated phase sweep additionally requires division-triggered IRQ drain within 40 clocks. Uncertain responses and timeouts are containment cases outside healthy response limits.

| Measured maximum | Forwarding | Interlocks |
|---|---:|---:|
| Source to IRQ entry | 135 | 135 |
| Source to first handler instruction in D | 153 | 153 |
| Source to all 16 register saves complete | 220 | 220 |
| First handler D to ACK effect | 87 | 91 |
| First handler D to ACK response | 88 | 92 |
| First handler D through MRET | 166 | 170 |

The standalone division-phase sweep reaches 38 clocks in the diagnostic profile. The 195/224/640/800 limits are assumption-dependent bounds, rather than the largest observed measurements rounded upward.

## Review revisions

1. `revisions/01-initial/`: strict lint rejected unused low bits of the reference signed product. The intentional unused slice was named explicitly; no diagnostic was waived.
2. `revisions/02-first-smoke/`: the initial 303-case overlap run passed. Review found absent cold-reset/fatal-response integration, a missing simultaneous orphan/replacement case, incomplete explicit timing endpoints, and no IRQ-disabled execution profile. Those cases and the independent duplicate-read count check were added.
3. `revisions/03-five-profile-qualification/`: all five profiles, three seeds and four detector classes passed. A further coverage review added dependent M `rs2`, both-source aliases, a taken dependent branch and fuller failure-state dumps.
4. The root summary, configuration logs and source snapshots contain the final qualification after those additions. No iteration-count claim substitutes for the recorded checks.

This evidence does not qualify ACT4/Sail, compressed instructions, a complete RV32IM CPU, production instruction-fetch integration, FPGA routing/frequency or physical programming. Debug is absent and disconnected, so no debug halt/resume result is claimed. Finite schedules validate their explicit bounds and assumptions; they are not a universal WCET proof.

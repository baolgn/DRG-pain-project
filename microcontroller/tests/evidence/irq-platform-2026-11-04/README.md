# Persistent interrupt platform qualification

The final standalone platform passed three reproducible seeds across capacities 1,
4 and 64, each running 12,848 clock edges and 385,449 comparisons. All seven
intentional observation corruptions failed their intended comparators. The default
capacity also passed generic Yosys synthesis, structural checks and latch rejection
without a warning waiver. This is component qualification; CPU admission, WFI
execution, firmware saving, CDC, FPGA routing and real acquisition remain separate.

`summary.json` records source SHA-256 values, tool entrypoint hashes, exact versions,
PASS terminals and expected negative failures. `sources/` contains that source set.
Full commands and outputs are retained in the logs; `build.log` includes the strict
Verilator build. Entrypoint hashes identify the invoked scripts, not the complete
OSS CAD Suite dependency closure. The parent project pins the bundle archive.

Reproduce from the repository root:

```sh
python3 microcontroller/tests/run_irq_platform.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --yosys /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/yosys \
  --build /tmp/drg5-irq-platform-repeat
```

The executed versions were Verilator `5.047 devel rev v5.046-19-ge9dd6eaaf (mod)`
and Yosys `0.62+112`, git `687a36af3`. The optional generic synthesis check does
not change the project's FPGA mapping/toolchain qualification or claim a frequency.
The Makefile's `irq-platform` target runs the same simulation and detector checks;
passing `--yosys` directly additionally runs structural synthesis.

## Exact component contract

`clk_i` is an always-running, single synchronous platform clock. It must continue
during CPU WFI, hart reset and any future CPU debug halt. Those controls have no
module ports. `mtime` increments once per non-reset rising edge, with modulo-2^64
wrap. Its physical tick frequency equals the connected clock frequency; there is
no divider, asynchronous source synchronizer or real-time-frequency assertion here.
Any later separate clock domain requires an explicit CDC bridge. Callers must
synchronize held event levels or convert durable producer events into synchronous
pulses without losing multiplicity. Raw asynchronous pulses are unsupported.

`command_i=1` at an edge denotes exactly one already accepted physical MMIO
transaction. `write_i`, full `addr_i`, `wdata_i`, `size_i` and `wstrb_i` describe it.
Each asserted edge is a distinct command; the module does not deduplicate a held
command. The bus bridge must pulse once per transaction, retain the immutable
request until that edge, sample `error_o` and `rdata_o` before the edge, and own any
delayed response. This component has no request/response handshake or response
buffer and cannot cancel, replay or acknowledge a transaction on the bridge's behalf.

All registers require natural word alignment, `size_i=2`, and `wstrb_i=0xf` for
writes or `0` for reads. Unsupported full addresses, direction, size, alignment,
strobes and empty consuming acknowledgements return `error_o=1`, `rdata_o=0` and
have no command effects. Autonomous timer/event evolution still occurs. An inactive
command returns no error and zero read data. Legal reads return pre-edge state and
have no side effects or hidden multiword snapshot latch.

The base is exactly `0x40001000`; offsets below are hexadecimal. This extension is
separate from the simulation test device's older `0x40000014` pending register.

| Offset | Register | Access and complete behavior |
| --- | --- | --- |
| `00`, `04` | `mtime` low, high | RW32; writing either half preserves the other pre-edge half and suppresses the entire coincident timer increment. |
| `08`, `0c` | `mtimecmp` low, high | RW32; independent half writes, with no latch. MTIP is the unsigned comparison `mtime >= mtimecmp`. Other platform writes do not suppress the timer tick. |
| `10` | MSIP | RW bit 0; other bits read zero and ignore writes. Drives mip bit 3. |
| `14` | EXT_PENDING | Bits 31:1 are sticky, coalescible notifications; W1C, with same-edge event set dominant. Bit 0 reads `BLOCK_COUNT != 0`; writes to bit 0 do nothing. |
| `18` | EXT_ENABLE | RW32; gates delivery, never event retention. MEIP, mip bit 11, is `|(EXT_PENDING & EXT_ENABLE)`. |
| `1c` | BLOCK_COUNT | RO32; number of unacknowledged block notifications, bounded by `BLOCK_CAPACITY`. |
| `20` | BLOCK_ACK | WO; bit 0 consumes exactly one pre-edge notification. Bit 0 clear is a legal no-op; other write bits are ignored. A consuming write at count zero errors even with a same-edge arrival; that arrival is retained. |
| `24` | OVERFLOW | RO bit 0, other bits zero; sticky until system reset. Also drives `overflow_o` and `stop_o`. |

MTIP drives mip bit 7. All other mip output bits are zero. Sources are levels, and
CPU masking does not alter their storage. Updated source levels appear after the
platform edge and are available to CPU decisions at the following clock edge.
Split `mtime` reads require the usual high/low/high retry in software. RV32 compare
updates can use low=`0xffffffff`, high=new-high, low=new-low to avoid unintended
intermediate expiry. No atomicity is implied by this register interface.

`event_set_i[31:1]` is set dominant over W1C. These bits deliberately coalesce;
each producer must retain detailed status, a counter or a FIFO until service.
They cannot preserve repeated event multiplicity by themselves. `block_ready_i`
adds one notification, at most one per edge. A valid simultaneous BLOCK_ACK frees
space first; the net count is unchanged, including at full capacity. The default
ledger capacity is 64; the legal parameter range is 1..65535, with simulation
rejecting invalid parameters. Tests cover capacities 1, 4 and 64.

A full ledger receiving an arrival without a valid same-edge acknowledgement
saturates and sets sticky overflow/stop. That arrival cannot be retained in this
finite ledger. This explicitly leaves the healthy-service contract and requires
hardware acquisition containment; it must never be represented as lossless normal
operation. Descriptor storage and data-ring ownership remain in dedicated hardware
until service. They are not implemented by this notification counter. Overflow
does not independently assert MEIP; any emergency interrupt routing must be supplied
by the surrounding platform. The stop output must be connected to hardware.

`system_reset_i` synchronously clears `mtime`, MSIP, events, enables, count and
overflow, and sets `mtimecmp` to all ones. Held reset suppresses timer ticks and
discards event inputs with the stopped acquisition epoch. A command during reset
is explicitly rejected with error and zero read data; reset's own state clearing
still occurs. The system must drain or isolate existing bridge transactions before
qualified platform reset. Hart reset has no connection, so it cannot discard this
state. Future debugger reset wiring must preserve that separation.

## Requirement-to-test matrix

| Requirement | Independent check and retained evidence |
| --- | --- |
| Complete MMIO decode and no effects on error | Arithmetic reference address decode; every nearby byte offset in both directions, all 4 sizes and 16 strobes, write-to-RO/read-from-WO, reset command collision, and all state outputs compared every edge. `seed-*.log`; error detector. |
| Exactly one effect per accepted command | Reference consumes the accepted command once per edge, compares exact counts and complete state, and never uses DUT state as its expected next state. Repeated acknowledgements drain one at a time. Count and read detectors. |
| Time, half-write priority and wrap | All-ones full wrap, low-half rollover, high/low/high reads, compare transition and safe update sequence, random writes, and 128 commandless clocks. Timer detector. |
| Software interrupt persistence | All-ones and reserved-bit MSIP writes, masked source values, reset clearing and per-edge mip-bit comparison. IRQ detector. |
| Masked external retention and set dominance | Walk every bit 1..31 while masked, enable it, collide W1C with set, then clear it without a new set. Pending and IRQ detectors. |
| Counted block notifications | Empty ACK+arrival, full ACK+arrival, exact fills with clean overflow, excess arrivals, W1C bit-0 non-consumption, and repeated consuming/no-op ACKs at all three capacities. Count detector. |
| Overflow is explicit and sticky | Saturation, queue drain without overflow clearing, matching stop output, and qualified system reset. Overflow detector. |
| Reproducible adversarial collisions | Seeds 0, 1 and 305419896; 12,000 LCG-generated vectors per seed after directed cases; guarded coverage of all address bins, directions and widths. Failure messages retain the complete command/source vector. |
| Supported synthesizable structure | Strict Verilator `-Wall`, no warning waiver; Yosys generic synthesis and checks reject latches. `build.log`, `structure.log`. |

These are simulation comparisons, not proofs for all traces. The observation
mutations calibrate seven specific comparators, not every possible RTL fault.
The component has no hart-reset/idle input; CPU WFI and hart-reset integration must
also be exercised by the separate encoded-core tests. Acquisition clock continuity,
descriptor durability, overload containment, CDC and bus response timing remain
explicit system integration obligations.

## Review and revisions

1. Initial module review found that reset discarded a command while its combinational
   preview could appear successful. `revisions/01-reset-review/` preserves that
   pre-correction module/fixture. The final decoder rejects commands during reset,
   and the directed reset collision checks both rejection and reset state.
2. Strict fixture lint identified two partially used reference indices and an
   over-wide old-state copy. `revisions/02-reference-review/` preserves that fixture.
   The final model validates indices and saves only the old fields it needs.
   Review also found that a full ACK/arrival test ran after overflow was already
   sticky. Fresh-reset, exact-fill cases now prove it does not newly set overflow
   for each tested capacity. Read and overflow comparator corruptions were added.
3. The final source set passed the complete runner on the versions above. No
   earlier snapshot is claimed to have passed the final tests. Review found no
   remaining component discrepancy within this declared scope; the integration
   obligations above remain requirements, not completed hardware claims.

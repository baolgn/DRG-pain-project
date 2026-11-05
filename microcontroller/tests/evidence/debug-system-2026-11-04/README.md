# Complete debug-wrapper qualification, 4 November 2026

## Table of contents

| Section |
| --- |
| [Evidence record](#evidence-record) |

## Evidence record

The final revision exercises the actual JTAG transport, Debug Module, CPU, frontend and wrapper guards. Debug operations enter only through public JTAG pins. Independent synchronous instruction, CPU-data and SBA targets retain their own descriptors and count effects at acceptance. No hierarchical DMI injection or internal-state modification is used.

Revision 07 passes all three seeds: **33 scenarios, 5,123 fabric edges and 29,481 checks**. It observes 12 actual reset episodes, 306 instruction responses, six CPU-data effects/responses and 21 SBA effects/responses. The [aggregate](aggregate.json) and [summary](summary.json) retain exact counts, source identities and commands. Three production-copy mutations separately defeat the acquisition write guard, running-code write guard and short-reset request latch; each fails the ordinary named checker. Positive and expected-failure results remain distinct.

The scenarios establish:

- Acquisition-active writes and side-effectful MMIO reads are rejected without external requests; ordinary RAM reads remain permitted. Buffer ownership blocks writes. Running-code writes are rejected.
- An allowed executable-memory write retains its owner through a delayed response. A queued resume waits for completion, then executes the changed instruction exactly once through the production frontend.
- Short `ndmreset` requests persist while instruction, CPU-data or SBA owners drain. With halt/reset-halt clear, the internal drain request does not cause an unintended halt after reset. Explicit reset-halt stops at PC zero with cause 5.
- Unowned SBA responses and reserved error codes 5/6 cause sticky containment. DM deactivation/reactivation and resume do not clear containment.
- Both acceptance-stalled and response-stalled SBA owners reach the configured **128-edge** deadline exactly. A timeout preserves the exposed operation through DM reset; one late response drains it without replay, while containment remains asserted.

The longest tested short-reset request-to-reset-release interval is **85 fabric edges**, including the exercised ownership drain. This finite maximum uses 80-edge old target response delays and explicit debugger command service. TCK scans may run while the fabric clock is paused; CDC requests then receive eight fabric edges and five idle TCK edges before response capture. These measurements count actual fabric edges and do not claim host, board, acquisition-firmware or wall-clock timing. The tests do not introduce any CPU-controlled clock gating.

The retained revisions include initial lint corrections; canonical zeroes for unrequested instruction parcels; correcting a DM-status query made before deactivation had finished; and rejecting two ineffective mutation attempts. One mutation caused a strict unused-input lint failure, so it did not count as detector calibration. Removing only the wrapper's resume gate was harmless because the DM independently blocks resume during SBA; that redundant-gate mutation was replaced by the running-code-write guard mutation. No wrapper RTL defect was found by these final scenarios. Every rejected attempt remains in `revisions/`.

Reproduce from the workspace root:

```sh
python3 microcontroller/tests/run_debug_system.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-debug-system-reproduce \
  --evidence-dir /tmp/drg5-debug-system-reproduce/evidence
```

The physical FPGA, programmer and routed clock remain separate gates. OpenOCD/GDB operates against this composition in the separate remote-debugger qualification; this fixture itself uses a deterministic JTAG driver.

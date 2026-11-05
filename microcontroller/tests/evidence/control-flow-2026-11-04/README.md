# Control-flow integration evidence

This qualification executes the packet-control prototype with real branch/JAL/JALR decode, immediate extraction, register-bank source reads, dependency stalls, X execution and W-only architectural commitment. It is not full CPU or ISA conformance. Ordinary non-control packets still supply precomputed operations. Two-byte control packets carry trusted externally expanded instructions; there is no compressed decoder in this integration.

Reproduce from the repository root:

```sh
python3 microcontroller/tests/run_control_flow.py --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator --build /tmp/drg5-control-flow-recheck
```

The runner accepts another explicit executable path. The tested Verilator reports `5.047 devel rev v5.046-19-ge9dd6eaaf (mod)` from OSS CAD Suite 2026-03-01. All four builds retain `-Wall` and `--assert`, with no warning waiver. `-CFLAGS -O0` changes generated C++ optimization only. `+verilator+seed+1` fixes simulator initialization; the program fixtures themselves are deterministic.

| Configuration | Directed programs | Clock edges | Normal retirements | Traps | Redirects | X behind owned load |
|---|---:|---:|---:|---:|---:|---:|
| C0 overlapping | 37 | 663 | 107 | 16 | 39 | 16 |
| C1 overlapping | 37 | 692 | 115 | 12 | 39 | 16 |
| C0 diagnostic | 37 | 932 | 107 | 16 | 39 | 0 |
| C1 diagnostic | 37 | 959 | 115 | 12 | 39 | 0 |

The independent program-map/PC/GPR reference covers all six branch conditions taken and untaken, signed and unsigned boundaries, a backward loop with the same PC executing both outcomes, JAL/JALR links, x0, rd=rs1, low-bit clearing, C-dependent alignment, original-length-two links, poisoned source/destination annotations, nearest-writer hazards, successful W bypass including CSR-read suppression, held X/W tokens, wrong-path MMIO suppression, malformed raw/expanded metadata, and incoming fetch-fault precedence. Both delayed-load success and failure must independently observe the younger unrelated jump in X while the load owns the data interface in overlapping mode. Separate load-dependent branches check operand availability and fault priority.

Every accepted UID must have exactly one live physical slot until independently justified retirement or squash. Terminal comparison reconstructs the complete packet, original instruction identity, captured operands, result, next PC, trap state and all GPR storage. C-dependent trap `mepc` masking is exercised at PC 0x102. The actual fetch manager connects through a verification-only packet adapter: JAL at 0x1000 commits link 0x1004 before a later target token faults at guard-denied 0x3000, without an external read of that target.

Three observation corruptions must fail their named detector with nonzero exit and no passing record: jump-link value, captured source value, and redirect target. These qualify the comparators; they are not mutations of the implementation RTL.

C1 software `mepc` write/MRET masking and new OP_CONTROL/external-flush collisions are source-reviewed rather than executed here. Legacy control regressions separately exercise the shared flush path. The separate control-fetch fixture covers an allowed target's actual bus error and stale wrong-path responses. This fixture does not claim their coverage.

`summary.json` records exact commands, tool version, results and SHA-256 values of every compiled source, macro header, runner and Makefile. Build/run logs and intended negative failures are retained here; generated binaries and C++ remain outside the repository. Source hashes matched before and after all runs and were rechecked when retaining these files. `SHA256SUMS` covers this evidence bundle.

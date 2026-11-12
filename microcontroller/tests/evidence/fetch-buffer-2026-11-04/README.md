# Fetch assembly buffer evidence

## Table of contents

1. [Evidence record](#evidence-record)

## Evidence record

The focused behavioral test covers the independent `drg5_fetch_buffer` component. The positive run passed **622,653 edges, 1,015,909 checks and 196,608 prefix cases**: every 16-bit prefix in the default non-C configuration and at both halfword positions with `C_FETCH=1`. The latter enables instruction framing only; no compressed decoder or C ISA implementation is claimed.

Directed checks cover held output, sequential slot rotation, address wrap, required-parcel faults and partial raw bytes, unsupported-length parking, stale/overlapping fills, reset held across fills, and redirect coincident with fill and output readiness. The raw observation-corruption control fails the intended packet-value comparator. This checks the checker; it is not an RTL mutation or formal completeness result. Independent manager tests cover external request ownership and malformed bus replies.

The final RTL SHA-256 is `a2a5dc5b6236751bc3df70c48eedc229b40a9e79c2adb7e0969c4355fa2b5844`. [summary.json](summary.json) records source, runner, tool, log and generated-netlist hashes. [results.json](results.json) records the behavioral test outcomes and exact simulation version. The simulation source and testbench were unchanged between the retained run and this record.

From the repository root, reproduce the behavioral run with:

```sh
python3 microcontroller/tests/run_fetch_buffer.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-fetch-buffer-tests
```

Both framing configurations also passed actual ECP5 synthesis, `check -assert`, and explicit latch rejection using the previously qualified 2026-01-20 Yosys bundle. These are mapped component counts, not a route or complete CPU resource/timing qualification.

| C_FETCH | LUT4 | FF | CCU2C | L6MUX21 | PFUMX |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 899 | 301 | 45 | 149 | 239 |
| 1 | 915 | 302 | 62 | 142 | 262 |

```sh
/tmp/drg5-control-tools/oss-cad-suite/bin/yosys -Q -T -p \
  'read_verilog -sv microcontroller/rtl/drg5_fetch_buffer.sv; hierarchy -check -top drg5_fetch_buffer; proc; check -assert; select -assert-none t:$dlatch; synth_ecp5 -top drg5_fetch_buffer -json /tmp/drg5-fetch-buffer-synth.json; check -assert; stat' \
  > /tmp/drg5-fetch-buffer-synth.log
/tmp/drg5-control-tools/oss-cad-suite/bin/yosys -Q -T -p \
  'read_verilog -sv microcontroller/rtl/drg5_fetch_buffer.sv; chparam -set C_FETCH 1 drg5_fetch_buffer; hierarchy -check -top drg5_fetch_buffer; proc; check -assert; select -assert-none t:$dlatch; synth_ecp5 -top drg5_fetch_buffer -json /tmp/drg5-fetch-buffer-c1-synth.json; check -assert; stat' \
  > /tmp/drg5-fetch-buffer-c1-synth.log
```

The complete synthesis logs are retained as `c0-synth.log` and `c1-synth.log`; generated netlists remain in `/tmp` with their hashes in the summary. Simulation uses the separately qualified Verilator 5.047 development build with `--timing --assert -Wall` and no warning suppression. The historical FPGA tool pins remain unchanged.

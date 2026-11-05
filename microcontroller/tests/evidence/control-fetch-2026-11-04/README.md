# Fetch-to-control verification bridge

This non-C fixture connects the existing instruction manager and assembly buffer to `OP_CONTROL` packets using the original fetched PC, raw bytes, byte-valid mask, original length and fetch-fault metadata. Control's registered redirect feeds fetch's restart input. This is a verification bridge, not production frontend integration or a complete CPU.

An independent 8 KiB word RAM responder owns one offered/accepted record. It records immutable address/tag/parcel fields at first observation of valid, samples RAM only at actual acceptance, and independently schedules the later response. No acceptance or completion is inferred from DUT internal state. Redirect revocation also applies when the responder first observes an already-presented offer on that edge. Source publication, data memory, interrupts and debug are outside this fixture.

RAM address 0 contains `0x100000ef`, a real `JAL x1,+0x100`. Its retirement must write x1=4 exactly once before target fetch. Other words contain `0x00000013`, a legal RV32I NOP that this deliberately restricted `OP_CONTROL` bridge rejects as a non-control sentinel. The sentinel's cause 2 is a fixture endpoint; it does not claim that NOP is architecturally illegal.

| Case | Target behavior | Required observed result |
| --- | --- | --- |
| 0 | Allowed-ROM target `0x100` returns canonical whole-beat rejection, status 01 | Source JAL retires and retains link 4; a separate target token traps with cause 1/mtval=`0x100` and unavailable raw bytes |
| 1 | Wrong-path address 4 is accepted before redirect; its delayed status 00 response faults both requested parcels | The actual response is discarded after redirect, never becoming an architectural fault; successful target fetch reaches the distinct cause 2 sentinel |
| 2 | Wrong-path address 4 remains offered and unaccepted across redirect; acceptance and fault response occur later | Valid/address/tag/mask remain unchanged, exactly one acceptance occurs, and the stale error is discarded before the target sentinel |

Every case holds the original fetched JAL output under downstream backpressure for four clocks and holds its W slot for five clocks. No retirement or redirect may repeat while held. Final checks require exactly one source retirement and one target terminal, distinct accepted-before-redirect versus unaccepted-across-redirect witnesses, retained x1=4, and equality of independently counted launches, offers, acceptances and completions after drainage. Each case completed four physical I requests.

The target's acceptance and response delay counters are independent. Address `0x100` uses A=2/R=3; other ordinary words use A=1/R=1; case 1 address 4 uses A=1/R=18; case 2 address 4 uses A=18/R=1. With this fixture's explicit first-observation and response-publication edges, capture occurs A+R+4 clocks after first registered request-valid. Fetch uses a declared **32-clock stress deadline**. These deliberately delayed transactions are not DRG5-F-80 local-memory timing qualification.

The final positive run passed **3 cases, 175 edges and 954 checks**. Two observation-corruption controls fail at the intended target-fault and stale-disposition comparators. Negative runs reject a positive final pass marker; compiler warnings, unrelated failures and finite-loop timeouts never qualify. The runner captures source hashes before compilation and rejects any concurrent source change afterward.

```sh
python3 microcontroller/tests/run_control_fetch.py \
  --verilator /tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator \
  --build /tmp/drg5-control-fetch-final
```

[summary.json](summary.json) pins the complete RTL/header/test/runner source set and exact Verilator version. Complete build, positive and negative logs are retained beside it. Verification uses `--timing --assert -Wall` without warning suppression. No RTL changes were required by this fixture.

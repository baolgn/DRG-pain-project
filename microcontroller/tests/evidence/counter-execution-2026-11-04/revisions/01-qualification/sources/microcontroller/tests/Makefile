# select the simulator explicitly and keep generated binaries outside source.
VERILATOR ?= verilator
YOSYS ?= yosys
BUILD_ROOT ?= /tmp/drg5-control-tests
# compile both occupancy modes with active assertions and fatal lint warnings.
RTL := ../rtl/drg5_control_pkg.sv ../rtl/drg5_decoder.sv ../rtl/drg5_decompress.sv ../rtl/drg5_immediate.sv ../rtl/drg5_branch.sv ../rtl/drg5_lsu.sv ../rtl/drg5_shifter.sv ../rtl/drg5_alu.sv ../rtl/drg5_forward.sv ../rtl/drg5_csr.sv ../rtl/drg5_control.sv
TB := drg5_control_tb.sv
# avoid optimizing large generated test tasks; retain all HDL lint and assertions.
FLAGS := --binary --timing --assert -Wall -j 2 -CFLAGS -O0 -I../rtl --top-module drg5_control_tb

# run normal diagnostic and overlapping pipeline regressions.
.PHONY: test diagnostic overlap negative
test: diagnostic overlap negative

# diagnostic mode permits only one live instruction.
diagnostic:
	mkdir -p $(BUILD_ROOT)/diagnostic
	$(VERILATOR) $(FLAGS) --Mdir $(BUILD_ROOT)/diagnostic -GDIAGNOSTIC=1 $(RTL) $(TB)
	$(BUILD_ROOT)/diagnostic/Vdrg5_control_tb +verilator+seed+1

# overlap mode must reach all five simultaneously occupied stages.
overlap:
	mkdir -p $(BUILD_ROOT)/overlap
	$(VERILATOR) $(FLAGS) --Mdir $(BUILD_ROOT)/overlap -GDIAGNOSTIC=0 $(RTL) $(TB)
	$(BUILD_ROOT)/overlap/Vdrg5_control_tb +verilator+seed+1

# require the named detector, not just any unsuccessful process exit.
negative: diagnostic overlap
	! $(BUILD_ROOT)/diagnostic/Vdrg5_control_tb +verilator+seed+1 +mutate_kill > $(BUILD_ROOT)/kill-negative.log 2>&1
	rg -q 'unjustified or missing instruction kill' $(BUILD_ROOT)/kill-negative.log
	! $(BUILD_ROOT)/diagnostic/Vdrg5_control_tb +verilator+seed+1 +mutate_result > $(BUILD_ROOT)/result-negative.log 2>&1
	rg -q 'wrong GPR commit trace' $(BUILD_ROOT)/result-negative.log
	! $(BUILD_ROOT)/diagnostic/Vdrg5_control_tb +verilator+seed+1 +mutate_orphan_offer > $(BUILD_ROOT)/offer-negative.log 2>&1
	rg -q 'ownerless or missing request valid' $(BUILD_ROOT)/offer-negative.log
	! $(BUILD_ROOT)/diagnostic/Vdrg5_control_tb +verilator+seed+1 +negative_cold_live > $(BUILD_ROOT)/cold-live-negative.log 2>&1
	rg -q 'cold reset without transaction isolation' $(BUILD_ROOT)/cold-live-negative.log
	! $(BUILD_ROOT)/diagnostic/Vdrg5_control_tb +verilator+seed+1 +negative_cold_fatal_free > $(BUILD_ROOT)/cold-fatal-free-negative.log 2>&1
	rg -q 'cold reset without transaction isolation' $(BUILD_ROOT)/cold-fatal-free-negative.log

# isolate combinational datapath qualification from the packet-control regression.
DATAPATH_RTL := ../rtl/drg5_decoder.sv ../rtl/drg5_immediate.sv ../rtl/drg5_shifter.sv ../rtl/drg5_alu.sv
DATAPATH_FLAGS := --binary --timing --assert -Wall -j 2 -CFLAGS -O0 -I../rtl --top-module drg5_datapath_tb

# run three explicit generator seeds and require six independent negative controls.
.PHONY: datapath datapath-build datapath-negative
datapath: datapath-build datapath-negative

# one compiled model serves exhaustive cases and reproducible varied operands.
datapath-build:
	mkdir -p $(BUILD_ROOT)/datapath
	$(VERILATOR) $(DATAPATH_FLAGS) --Mdir $(BUILD_ROOT)/datapath $(DATAPATH_RTL) drg5_datapath_tb.sv
	$(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=0
	$(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=1
	$(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=305419896

# each observation corruption must fail its own comparator rather than any process error.
datapath-negative: datapath-build
	! $(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=1 +mutate_decode > $(BUILD_ROOT)/datapath/decode-negative.log 2>&1
	rg -q 'decoder reference mismatch' $(BUILD_ROOT)/datapath/decode-negative.log
	! $(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=1 +mutate_illegal > $(BUILD_ROOT)/datapath/illegal-negative.log 2>&1
	rg -q 'decoder reference mismatch' $(BUILD_ROOT)/datapath/illegal-negative.log
	! $(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=1 +mutate_immediate > $(BUILD_ROOT)/datapath/immediate-negative.log 2>&1
	rg -q 'immediate reference mismatch' $(BUILD_ROOT)/datapath/immediate-negative.log
	! $(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=1 +mutate_alu > $(BUILD_ROOT)/datapath/alu-negative.log 2>&1
	rg -q 'ALU reference mismatch' $(BUILD_ROOT)/datapath/alu-negative.log
	! $(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=1 +mutate_compare > $(BUILD_ROOT)/datapath/compare-negative.log 2>&1
	rg -q 'ALU comparison mismatch' $(BUILD_ROOT)/datapath/compare-negative.log
	! $(BUILD_ROOT)/datapath/Vdrg5_datapath_tb +verilator+seed+1 +seed=1 +mutate_shift > $(BUILD_ROOT)/datapath/shift-negative.log 2>&1
	rg -q 'shifter reference mismatch' $(BUILD_ROOT)/datapath/shift-negative.log

# keep register-file timing and implementation comparisons in their owned runner.
.PHONY: regfile test-all
regfile:
	python3 run_regfile.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/regfile

# prove all arithmetic inputs and qualify the proof with an intentional failure.
.PHONY: arithmetic-formal
arithmetic-formal:
	python3 run_arithmetic_formal.py --yosys $(YOSYS) --build $(BUILD_ROOT)/arithmetic-formal

# keep the manager, parcel-buffer and bounded proof fixtures independently runnable.
.PHONY: fetch fetch-buffer fetch-formal fetch-all
fetch:
	python3 run_fetch.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/fetch

# exhaust parcel framing separately from the surviving bus manager.
fetch-buffer:
	python3 run_fetch_buffer.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/fetch-buffer

# prove manager invariants and require a failing mutation plus a wrap witness.
fetch-formal:
	python3 run_fetch_formal.py --yosys $(YOSYS) --build $(BUILD_ROOT)/fetch-formal

# combine all fetch evidence without changing the scope of an individual target.
fetch-all: fetch fetch-buffer fetch-formal

# compare real control execution against an independent architectural program sequence.
.PHONY: control-flow control-fetch control-events branch control-flow-synth
control-flow:
	python3 run_control_flow.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/control-flow

# connect the real fetch manager to control through a verification-only packet adapter.
control-fetch:
	python3 run_control_fetch.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/control-fetch

# check precise control transfers against flush, reset and return-address updates.
control-events:
	python3 run_control_events.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/control-events

# prove and simulate the standalone branch function independently of the pipeline.
branch:
	python3 run_branch.py --verilator $(VERILATOR) --yosys $(YOSYS) --build $(BUILD_ROOT)/branch

# optionally map the complete control prototype through the slang-enabled frontend.
control-flow-synth:
	python3 run_control_flow_synth.py --yosys $(YOSYS) --build $(BUILD_ROOT)/control-flow-synth

# qualify byte lanes and permissions independently of request ownership.
.PHONY: lsu memory
lsu:
	python3 run_lsu.py --verilator $(VERILATOR) --yosys $(YOSYS) --build $(BUILD_ROOT)/lsu

# compare decoded memory retirement and device effects with separate models.
memory:
	python3 run_memory.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/memory

# qualify priority selection independently of pipeline producer readiness.
.PHONY: forwarding base
forwarding:
	python3 run_forward.py --verilator $(VERILATOR) --yosys $(YOSYS) --build $(BUILD_ROOT)/forwarding

# compare raw base programs across diagnostic, interlocked and forwarded execution.
base:
	python3 run_base.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/base

# prove and exercise CSR permissions, state transitions and counter precedence.
.PHONY: csr csr-control
csr:
	python3 run_csr.py --verilator $(VERILATOR) --yosys $(YOSYS) --build $(BUILD_ROOT)/csr

# check encoded CSR access suppression and precise trap/return integration.
csr-control:
	python3 run_csr_control.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/csr-control

# check retained platform events independently of CPU interrupt admission.
.PHONY: irq-platform irq-control irq-fetch
irq-platform:
	python3 run_irq_platform.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/irq-platform

# compare precise interrupt entry, WFI and bounded firmware service.
irq-control:
	python3 run_irq_control.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/irq-control

# exercise real instruction-request drainage and handler fetch after IRQ entry.
irq-fetch:
	python3 run_irq_fetch.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/irq-fetch

# run all independently scoped unit regressions through one optional entrypoint.
test-all: test datapath regfile arithmetic-formal fetch-all control-flow control-fetch control-events branch lsu memory forwarding base csr csr-control irq-platform irq-control irq-fetch muldiv muldiv-control decompress compressed-execution fence-execution

# check all M arithmetic results, ownership and fixed completion bounds independently.
.PHONY: muldiv muldiv-control
muldiv:
	python3 run_muldiv.py --verilator $(VERILATOR) --yosys $(YOSYS) --build $(BUILD_ROOT)/muldiv

# compare encoded M execution, dependencies and precise interrupt drainage.
muldiv-control:
	python3 run_muldiv_control.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/muldiv-control

# classify every halfword and compare canonical C expansion independently.
.PHONY: decompress compressed-execution
decompress:
	python3 run_decompress.py --verilator $(VERILATOR) --yosys $(YOSYS) --build $(BUILD_ROOT)/decompress

# execute mixed-width programs through real instruction and data buses.
compressed-execution:
	python3 run_compressed_execution.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/compressed-execution

# verify completed-write visibility, invalidation and external writer synchronization.
.PHONY: fence-execution
fence-execution:
	python3 run_fence_execution.py --verilator $(VERILATOR) --build $(BUILD_ROOT)/fence-execution

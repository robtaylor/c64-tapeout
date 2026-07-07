MAKEFILE_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

TOP = chip_top

# macOS local-signoff fixes:
#  (1) open_pdks gf180mcuD KLayout decks call Linux-only `pmap` for a memory
#      log line — nil.strip crashes KLayout.DRC/.Antenna/.Density and LVS on
#      Darwin. Prepend a committed shim. Linux/CI has a real pmap and must
#      not have it shadowed. See tools/pmap-shim/pmap.
#  (2) KLayout 0.30.x parallel DRC crashes (std::bad_cast) on the macOS
#      build for large designs — KLayout #2339. Layer a serial overlay LAST
#      on Darwin ONLY; Linux/CI keeps workers: max.
ifeq ($(shell uname -s),Darwin)
export PATH := $(MAKEFILE_DIR)/tools/pmap-shim:$(PATH)
KLAYOUT_SERIAL_OVERLAY := librelane/klayout_serial_macos.yaml
endif

PDK_ROOT ?= $(MAKEFILE_DIR)/gf180mcu
PDK ?= gf180mcuD
PDK_TAG ?= 1.8.0

# Standard-cell library: 9T 5V. Must be exported BEFORE LibreLane loads
# the PDK config.tcl (same gotcha as test-tapeout-1).
export STD_CELL_LIBRARY ?= gf180mcu_fd_sc_mcu9t5v0

SLOT ?= 1x1

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
.PHONY: help

all: librelane ## Build the project (runs LibreLane)
.PHONY: all

clone-pdk: ## Clone the GF180MCU PDK repository
	rm -rf $(MAKEFILE_DIR)/gf180mcu
	git clone https://github.com/wafer-space/gf180mcu.git $(MAKEFILE_DIR)/gf180mcu --depth 1 --branch ${PDK_TAG}
.PHONY: clone-pdk

librelane: $(GHDL_VERILOG) ## Run full LibreLane flow incl. signoff
	librelane librelane/slots/slot_${SLOT}.yaml librelane/config.yaml $(KLAYOUT_SERIAL_OVERLAY) --save-views-to $(MAKEFILE_DIR)/final --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk
.PHONY: librelane

LIBRELANE_ITER_SKIPS = \
	--skip OpenROAD.FillInsertion \
	--skip Checker.YosysUnmappedCells \
	--skip KLayout.Antenna --skip Checker.KLayoutAntenna \
	--skip KLayout.DRC --skip Checker.KLayoutDRC \
	--skip KLayout.Density --skip Checker.KLayoutDensity \
	--skip KLayout.Filler \
	--skip KLayout.SealRing \
	--skip KLayout.XOR --skip Checker.XOR \
	--skip Magic.DRC --skip Checker.MagicDRC \
	--skip Magic.SpiceExtraction \
	--skip Netgen.LVS --skip Checker.LVS

librelane-pdn: $(GHDL_VERILOG) ## Run LibreLane through PnR/STA/IR-drop, skip GDS signoff (fast iteration)
	librelane librelane/slots/slot_${SLOT}.yaml librelane/config.yaml $(KLAYOUT_SERIAL_OVERLAY) --save-views-to $(MAKEFILE_DIR)/final --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk $(LIBRELANE_ITER_SKIPS)
.PHONY: librelane-pdn

librelane-openroad: ## Open the last run in OpenROAD
	librelane librelane/slots/slot_${SLOT}.yaml librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk --last-run --flow OpenInOpenROAD
.PHONY: librelane-openroad

librelane-klayout: ## Open the last run in KLayout
	librelane librelane/slots/slot_${SLOT}.yaml librelane/config.yaml --pdk ${PDK} --pdk-root ${PDK_ROOT} --manual-pdk --last-run --flow OpenInKLayout
.PHONY: librelane-klayout

# ----------------------------------------------------------------------------
# GHDL + Yosys synthesis test (no PDK required)
# ----------------------------------------------------------------------------
GHDL ?= /opt/homebrew/bin/ghdl
GHDL_WORK = build/ghdl_work
GHDL_VERILOG = build/c64_system_synth.v

$(GHDL_WORK):
	mkdir -p $@

$(GHDL_VERILOG): $(wildcard rtl/*.vhd rtl/t65/*.vhd) vhdl.f | $(GHDL_WORK)
	@while IFS= read -r f; do \
		case "$$f" in \#*|"") continue;; esac; \
		echo "GHDL-a: $$f"; \
		$(GHDL) -a --std=08 -fsynopsys --workdir=$(GHDL_WORK) "$$f" || exit 1; \
	done < vhdl.f
	$(GHDL) --synth --std=08 -fsynopsys --workdir=$(GHDL_WORK) --out=verilog c64_system 2>build/ghdl_warnings.txt > $@.tmp
	# Rename SystemVerilog reserved words emitted as identifiers by GHDL.
	# T65 uses `break` as a VHDL signal name; Icarus rejects it (Yosys is fine).
	perl -pe 's/\bbreak\b/break_sig/g' $@.tmp > $@
	rm -f $@.tmp
	@echo "GHDL synth: $$(wc -l < $@) lines of Verilog"

sim-smoke: $(GHDL_VERILOG) ## Run cocotb smoke test on chip_core (Verilator)
	cd cocotb && SIM=verilator uv run --with "cocotb>=2.0" python chip_core_tb.py
.PHONY: sim-smoke

sim-qspi: ## Run cocotb test on the standalone qspi_psram_ctrl (Verilator)
	cd cocotb && SIM=verilator uv run --with "cocotb>=2.0" python qspi_psram_tb.py
.PHONY: sim-qspi

synth-test: $(GHDL_VERILOG) ## Synthesize design with Yosys (no PDK, generic cells)
	yosys -p " \
		read_verilog $(GHDL_VERILOG); \
		read_verilog -sv rtl/mos6526.v; \
		read_verilog -sv ip/pulp/spi_master_clkgen.sv; \
		read_verilog -sv ip/pulp/spi_master_tx.sv; \
		read_verilog -sv ip/pulp/spi_master_rx.sv; \
		read_verilog -sv ip/pulp/spi_master_controller.sv; \
		read_verilog -sv rtl/qspi_psram_ctrl.sv; \
		read_verilog -sv src/zpstack_sram.sv; \
		read_verilog -sv src/chip_core.sv; \
		hierarchy -top chip_core -chparam NUM_INPUT_PADS 12 -chparam NUM_BIDIR_PADS 40 -chparam NUM_ANALOG_PADS 2; \
		synth -top chip_core -flatten; \
		stat; \
	" 2>&1 | tee build/synth_test.log | tail -30
.PHONY: synth-test

sim: ## Run RTL simulation with cocotb
	cd cocotb; PDK_ROOT=${PDK_ROOT} PDK=${PDK} SLOT=${SLOT} python3 chip_top_tb.py
.PHONY: sim

sim-gl: ## Run gate-level simulation with cocotb
	cd cocotb; GL=1 PDK_ROOT=${PDK_ROOT} PDK=${PDK} SLOT=${SLOT} python3 chip_top_tb.py
.PHONY: sim-gl

sim-view: ## View simulation waveforms in GTKWave
	gtkwave cocotb/sim_build/chip_top.fst
.PHONY: sim-view

# ----------------------------------------------------------------------------
# Jacquard post-PnR simulation
# ----------------------------------------------------------------------------

JACQUARD_DIR       := deps/jacquard
JACQUARD_BIN       ?= $(JACQUARD_DIR)/target/release/jacquard
OPENSTA_TO_IR_BIN  ?= $(JACQUARD_DIR)/crates/opensta-to-ir/target/release/opensta-to-ir
OPENSTA_BIN        ?= $(JACQUARD_DIR)/vendor/opensta/build/sta

JACQUARD_CORNER    ?= nom_tt_025C_5v00
LIBERTY_CORNER     := $(subst nom_,,$(JACQUARD_CORNER))
JACQUARD_TOP       ?= chip_top
JACQUARD_OUT       := build/jacquard

NETLIST            := final/pnl/chip_top.pnl.v
SDF                := final/sdf/$(JACQUARD_CORNER)/chip_top__$(JACQUARD_CORNER).sdf
LIBERTY            := gf180mcu/$(PDK)/libs.ref/gf180mcu_fd_sc_mcu9t5v0/lib/gf180mcu_fd_sc_mcu9t5v0__$(LIBERTY_CORNER).lib
TIMING_IR          := $(JACQUARD_OUT)/chip_top__$(JACQUARD_CORNER).jtir

$(JACQUARD_OUT):
	mkdir -p $@

jacquard-build: ## Build Jacquard + opensta-to-ir binaries
	cd $(JACQUARD_DIR) && git submodule update --init vendor/eda-infra-rs
	cd $(JACQUARD_DIR) && cargo build --release --features metal --bin jacquard
	cd $(JACQUARD_DIR)/crates/opensta-to-ir && cargo build --release
.PHONY: jacquard-build

jacquard-opensta: ## Build vendored OpenSTA
	cd $(JACQUARD_DIR) && git submodule update --init vendor/opensta
	$(JACQUARD_DIR)/scripts/build-opensta.sh
.PHONY: jacquard-opensta

$(TIMING_IR): $(OPENSTA_TO_IR_BIN) $(OPENSTA_BIN) $(NETLIST) $(SDF) $(LIBERTY) | $(JACQUARD_OUT)
	$(OPENSTA_TO_IR_BIN) \
	    --opensta-bin $(OPENSTA_BIN) \
	    --liberty $(LIBERTY_CORNER)=$(LIBERTY) \
	    --verilog $(NETLIST) \
	    --sdf $(SDF) \
	    --top chip_top \
	    --output $@

jacquard-ir: $(TIMING_IR) ## Stage 1: build timing IR (Liberty+SDF+netlist)
.PHONY: jacquard-ir

vendor:
	ln -sfn deps/jacquard/vendor vendor

jacquard-cosim: $(JACQUARD_BIN) vendor | $(JACQUARD_OUT) ## Stage 2: GPU-replay stimulus through post-PnR netlist
	$(JACQUARD_BIN) cosim \
	    --config cocotb/sim_config.json \
	    $(NETLIST) \
	    --top-module $(JACQUARD_TOP) \
	    --cell-library tools/jacquard_cell_lib/ocd_sram_shim.v \
	    --max-clock-edges 5000000
.PHONY: jacquard-cosim

render-image: ## Render chip layout as PNG
	mkdir -p img/
	PDK_ROOT=${PDK_ROOT} PDK=${PDK} python3 scripts/lay2img.py final/gds/${TOP}.gds img/${TOP}.png --width 2048 --oversampling 4
.PHONY: render-image

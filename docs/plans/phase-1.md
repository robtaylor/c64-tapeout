# Plan — Phase 1: RTL integration, PnR, and Jacquard simulation

**Status:** Active.

## Goal

Produce a GDS-ready C64 subset (T65 + VIC-II + CIA + 8KB SRAM) on the GF180MCU 1×1 slot via LibreLane, verified by cocotb RTL simulation and Jacquard post-PnR timing simulation. Implements ADRs 0001–0003.

## Prerequisites

- ADR 0001 accepted (scope + clock)
- ADR 0002 accepted (GHDL-Yosys synthesis)
- ADR 0003 accepted (memory architecture)
- Access to wafer.space GF180MCU PDK (clone-pdk)
- GHDL + ghdl-yosys-plugin available in Nix shell

## Where things stand (2026-05-26)

- Project structure: created, docs framework in place
- RTL: not yet copied/adapted from C64_MiSTer
- Flow infrastructure: not yet set up (Makefile, flake.nix, config.yaml)

## Workstreams

### WS1 — Flow infrastructure (Nix + Makefile + LibreLane config)

**Status:** Not started

Set up the build system cribbed from test-tapeout-1:
- `flake.nix`: LibreLane 3.0 dev shell + GHDL + cocotb + Icarus
- `Makefile`: clone-pdk, sim, librelane, librelane-pdn, jacquard-ir, jacquard-cosim
- `librelane/config.yaml`: GF180 9T, 8 SRAM macros, chip_top design
- `librelane/slots/slot_1x1.yaml`: pad ring, die/core area
- `librelane/chip_top.sdc`: timing constraints (8 MHz clock)
- `librelane/pdn_cfg.tcl`: PDN with 8-macro SRAM grid

**Deliverables:**
- `nix develop` enters a working shell with all tools
- `make clone-pdk` fetches PDK
- `make librelane-pdn` runs (even if design is trivial/empty)

**Exit criteria:**
- LibreLane can synthesize a minimal chip_top (heartbeat-only stub) through PnR

### WS2 — RTL adaptation (C64 core → tapeout-ready)

**Status:** Not started

Copy and adapt the C64 VHDL/Verilog from C64_MiSTer:

1. **T65 CPU** (4 VHDL files): copy as-is, review for ASIC compatibility (no initial values without reset, no tri-state internal buses).
2. **cpu_6510 wrapper** (VHDL): copy, strip cassette/keyboard I/O port bits not relevant.
3. **VIC-II** (VHDL): copy. Hardwire to PAL variant (6569). Remove runtime PAL/NTSC switching.
4. **fpga64_buslogic** (VHDL): adapt memory map for 8KB RAM + synthesized ROMs.
5. **mos6526 CIA** (Verilog): copy 1 instance. Wire port A/B to bidir pads.
6. **Color palette** (VHDL): copy as-is.
7. **Color RAM / spram** (VHDL): replace with synthesizable FF-based RAM.
8. **Cycle sequencer**: extract from fpga64_sid_iec.vhd — keep VIC/CPU timing, strip SID/IEC.
9. **Synthesized ROMs**: generate Verilog ROM modules from C64 ROM binaries.
10. **chip_core.sv**: new top-level integrating all of the above + SRAM + pad I/O.
11. **chip_top.sv**: padframe (crib from test-tapeout-1).

**Deliverables:**
- `rtl.f` and `vhdl.f` filelists
- All source compiles under GHDL (analysis pass)
- All source compiles under Icarus/Verilator (lint)

**Exit criteria:**
- `ghdl -a` succeeds on all VHDL files
- Yosys `read_verilog` succeeds on all Verilog/SV files
- `ghdl --synth` produces RTLIL for the VHDL subset

### WS3 — cocotb RTL simulation

**Status:** Not started

Write a cocotb testbench that:
1. Applies reset, starts clock
2. Verifies CPU executes from KERNAL reset vector ($FFFC/$FFFD)
3. Verifies VIC-II produces HSYNC/VSYNC at expected intervals
4. Verifies CIA timer counts down and generates IRQ
5. Verifies screen RAM writes appear in VIC video output
6. (Stretch) Runs a small test program that fills the screen with characters

**Deliverables:**
- `cocotb/chip_top_tb.py`
- `test_program/` with simple 6502 assembly test

**Exit criteria:**
- `make sim` passes: CPU boots, VIC produces video-like output, CIA timer fires

### WS4 — GHDL-Yosys synthesis integration

**Status:** Not started

Make the VHDL→RTLIL→Yosys→ABC→GF180 pipeline work end-to-end:
1. Write a LibreLane custom synthesis hook or `EXTRA_SYNTH_COMMANDS` that calls `ghdl --synth`
2. Verify all VHDL entities appear as Yosys modules after import
3. Verify the full chip elaborates in Yosys (VHDL + Verilog + SV together)
4. Run `synth_gf180mcu` (or equivalent) successfully

**Deliverables:**
- Working synthesis that produces a gate-level netlist
- Area estimate from Yosys (cell count, estimated mm²)

**Exit criteria:**
- `make librelane-pdn` completes through synthesis + PnR for the full C64 design
- Timing report shows slack ≥ 0 at TT corner

### WS5 — LibreLane PnR and signoff

**Status:** Not started (depends on WS1, WS2, WS4)

Iterate on placement/routing:
1. SRAM macro floorplan (8 macros, 2 rows × 4 columns)
2. PDN tuning for SRAM + logic
3. Timing closure at TT/25°C/5V
4. Full signoff: DRC, LVS, antenna

**Deliverables:**
- `final/gds/chip_top.gds` — tapeout-ready GDS
- `final/pnl/chip_top.pnl.v` — post-PnR netlist
- `final/sdf/` — timing annotation

**Exit criteria:**
- `make librelane` completes with no DRC/LVS errors (or documented waivers)
- Timing: zero setup violations at TT corner
- Area utilization < 60%

### WS6 — Jacquard post-PnR simulation

**Status:** Not started (depends on WS3, WS5)

Two-stage Jacquard pipeline (same pattern as test-tapeout-1):
1. **Stage 1** (`jacquard-ir`): opensta-to-ir produces timing IR from Liberty + SDF + netlist
2. **Stage 2** (`jacquard-cosim`): GPU-replay cocotb stimulus through post-PnR netlist

**Deliverables:**
- `build/jacquard/chip_top__nom_tt_025C_5v00.jtir`
- Jacquard cosim passes (video output matches RTL sim)

**Exit criteria:**
- Jacquard timing simulation shows no setup/hold violations at 8 MHz
- VIC video output in post-PnR matches RTL simulation waveforms

## Phase exit criteria

- [ ] Full PnR GDS exists and passes DRC/LVS
- [ ] cocotb RTL sim demonstrates CPU + VIC + CIA operation
- [ ] Jacquard post-PnR sim confirms timing at 8 MHz
- [ ] All workstreams shipped or explicitly deferred

## References

- `docs/adr/0001-system-scope-and-clock.md`
- `docs/adr/0002-vhdl-synthesis-via-ghdl.md`
- `docs/adr/0003-memory-architecture.md`
- `~/Code/Apitronix/test-tapeout-1` — reference tapeout
- `~/Code/Retro/C64_MiSTer` — source RTL

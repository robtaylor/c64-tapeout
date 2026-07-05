# Plan — Tapeout roadmap: external QSPI PSRAM + clean PnR

**Status:** Active. The live tapeout roadmap (was `phase-2.md` until 2026-07-06). Memory-subsystem detail lives in [`memory-integration.md`](memory-integration.md); the initial core bring-up is archived at [`archive/initial-core-bringup.md`](archive/initial-core-bringup.md).

## Goal

Land [ADR 0004](../adr/0004-external-qspi-psram.md): rip on-die SRAM out of `chip_core`, drop in a QSPI PSRAM controller talking to 6 pads, get LibreLane PnR through to a placed-and-routed GDS, and re-run the cocotb smoke + Jacquard post-PnR sim.

## Where things stand (2026-06-30 — end of phase-1)

- WS1 (flow infra): ✓ Nix shell builds on aarch64-darwin (dropped `ghdl-mcode` per flake.nix). LibreLane 3.0.0 from FOSSI cache works. Homebrew GHDL handles VHDL synth out-of-band.
- WS2 (RTL): ✓ T65 + VIC-II + CIA + bus logic + cycle sequencer + ROMs all wired through `chip_core`. Cocotb smoke passes.
- WS3 (cocotb): ✓ `make sim-smoke` passes under Verilator (chip_core boots, VIC HSYNC pulses, CPU drives VIC/CIA addresses).
- WS4 (GHDL → Yosys): ✓ `make synth-test` → 255K cells, 1 benign tri-state warning.
- WS5 (LibreLane PnR): ⚠ Reached OpenROAD.GlobalPlacement (stage 22/83); RePlAce diverges because OCD SRAM macros are 3.3V on a 5V standard-cell library — power nets float. **This phase fixes that by dropping on-die SRAM.**
- WS6 (Jacquard sim): ✗ Not started — blocked on a closed PnR.

## Memory subsystem

The memory timing budget, VIC-contention analysis, the cycle-accurate gating decision, the measured access pattern (findings a/b/c), and the resulting architecture (sequencer early-trigger, VIC line-buffer, ZP/stack SRAM carve-out, 64 MHz clock) now live in their own plan: [`memory-integration.md`](memory-integration.md). That doc is the home for WS-P2-2 detail; the summary below (WS-P2-2) links into it.

## Workstreams

### WS-P2-1 — Pick or write the QSPI PSRAM controller

**Goal:** Have a synthesizable `qspi_psram_ctrl` module with a simple wishbone-ish interface to `c64_system`.

**Decision (2026-07-01):** Vendor the PULP `axi_spi_master` SPI engine (4 dependency-free files: `spi_master_controller/clkgen/tx/rx`, Solderpad SHL-0.51) and drive it with a ~80-line FSM. Verified via survey: it's a *generic* cmd/addr/dummy/data engine (not flash-specific), quad TX+RX first-class, zero external repo deps. **ZipCPU `qspiflash` rejected** — LGPLv3 (copyleft, undesirable in an ASIC deliverable) + flash erase/program semantics (wrong for byte-writable RAM). `udma_qspi` rejected — `Bender.yml` drags in `udma_core` + `common_cells` + `tech_cells_generic`. Roll-our-own was a near-tie; PULP chosen for proven silicon RTL. Vendored under **`ip/pulp/`** (Solderpad license preserved; *not* `vendor/`, which was reserved for the now-obsolete Jacquard symlink — see WS-P2-6).

**Status — DONE 2026-07-01.** `make sim-qspi` → 3/3 cocotb tests pass under Verilator (read, write-then-read-back, address sweep); Yosys synth clean (620 cells, single clock domain, no latches). Files: `rtl/qspi_psram_ctrl.sv` (~90-line FSM), `cocotb/qspi_psram_model.py` (BFM), `cocotb/qspi_psram_tb.py`, `ip/pulp/{spi_master_controller,clkgen,tx,rx}.sv` + LICENSE + README, `Makefile` `sim-qspi` target.

Settled params: **controller clock 64 MHz** (2× the 32 MHz SCK; `f_sck = f_clk/(2·(CLK_DIV+1))`, `CLK_DIV=0`), **0xEB dummy = 6** (`QRD_DUMMY`, APS6404L), **write = 0x38 quad**, QPI entered via single-lane `0x35` at reset. `sio_oe` derived from `spi_mode` (STD→`0001`, QUAD_TX→`1111`, QUAD_RX→`0000`).

**Carries into WS-P2-2 (flagged by the implementing agent):**
- **Bus port crossover.** `c64_system.vhd` names ports system-side (`ramDout` = write data *out*, `ramDin` = read data *in*); `qspi_psram_ctrl` names them memory-side (`ramDin` = write *in*, `ramDout` = read *out*). Integration wiring is a crossover: `qspi.ramDin ⇐ c64.ramDout`, `c64.ramDin ⇐ qspi.ramDout`. (Consider renaming the controller's ports at integration to avoid the foot-gun.)
- **Trigger contract couples to the sequencer rework.** The controller currently starts on `ce_rise` against the *late* CE timing (`rtl/qspi_psram_ctrl.sv:116,154`); the early-trigger sequencer rework (architecture item 1) must update both together.
- **Init completion** is detected via `spi_status[0]` (the `0x35` command-only transaction produces no `eot` — a PULP FSM quirk).
- **Handshake** is a single-cycle `ready` pulse with `ramDout` held in `rdata_q`; WS-P2-2 maps this onto the 32-state sequencer + the VIC line-buffer.

**Tasks:**
1. Survey OSS options:
   - LiteSPI PSRAM driver (LiteX) — Python-generated SV; check whether the standalone Verilog is reusable.
   - ZipCPU `qspiflash` family — well-documented, MIT-licensed; adapter from flash semantics to PSRAM ~50 lines.
   - TinyTapeout APS6404 controllers (e.g. `tt07-qspi-psram` series) — small, proven on a similar shuttle context.
   - Roll our own — APS6404L protocol is ~150 SV lines; SDR fast-read (`0x0B`), write (`0x02`), quad-mode enter (`0x35`).
2. Pick one. Decision criteria: SDR-only is fine for our 1 MHz CPU; we don't need DDR or advanced power management; bonus points if it includes a cocotb-compatible BFM.
3. Vendor or write under `rtl/qspi_psram_ctrl.sv` (single file preferred).

**Deliverables:**
- `rtl/qspi_psram_ctrl.sv` synthesizable
- Companion `cocotb/qspi_psram_model.py` BFM (responder)

**Exit criteria:**
- Standalone cocotb test: controller issues read → BFM responds → controller delivers data on the bus interface within the expected cycle budget.

### WS-P2-2 — RTL integration

**Goal:** Wire the controller into `c64_system`'s RAM ports, add the on-die ZP/stack SRAM carve-out, rework the sequencer for PSRAM latency, add the VIC line-buffer, and remove the bulk on-die SRAM.

**Full design, tasks, and exit criteria: [`memory-integration.md`](memory-integration.md).** In short, six tasks in dependency order: (1) 64 MHz pad + ÷2 clock, (2) `chip_core.sv` memory split (`qspi_psram_ctrl` + 2× `sram256x8` ZP/stack, `is_lowpage` decode + `ram_din` mux), (3) pad wiring for CS#/SCK/SIO at bidir[33..38], (4) `c64_system.vhd` sequencer early-trigger, (5) ~40 B VIC c-access line-buffer (second increment), (6) cleanup. Exit: `make synth-test` clean, `make sim-smoke` boots from the PSRAM BFM with ZP/stack served on-die.

### WS-P2-3 — LibreLane config cleanup

**Goal:** Remove the *3.3V OCD bulk-SRAM* machinery from the LibreLane config, and register the *2× 5V `sram256x8`* ZP/stack macros ([ADR 0004 §9](../adr/0004-external-qspi-psram.md#decision)) cleanly. The floorplan goes from "8 big 3.3V macros" to "2 small 5V macros" — near-cells-only, and PDN-coherent because the returning macros are 5V-native.

**Tasks:**
1. `librelane/config.yaml`:
   - Remove `VERILOG_DEFINES: USE_SRAM_MACROS` (the bulk `sram_wrapper` is gone; the ZP/stack macros are instantiated directly, not via the wrapper).
   - Remove the `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` `MACROS:` entry (3.3V OCD, retired).
   - **Add** a `MACROS:` entry for 2× `gf180mcu_fd_ip_sram__sram256x8m8wm1` with genuine 5V libs (see task 6).
   - Remove the *bulk* SRAM `IGNORE_DISCONNECTED_MODULES` entries; add any needed for the 2 new macros.
   - Tighten `DIE_AREA`/`CORE_AREA` — far smaller than the old 3500×4700 µm (two `sram256x8` macros are tiny); estimate from a placement pass.
2. `librelane/pdn_cfg.tcl`:
   - Remove the bulk `pdn_c64_sram` (8-macro) grid section. Keep stdcell grid + core ring.
   - Add a small macro grid for the 2× `sram256x8` (or rely on the default macro grid if it straps them adequately) — these are 5V macros on the same rails as the cells, so the grid is coherent (no cross-voltage strapping).
3. `deps/gf180mcu_ocd_ip_sram/` — gitignore stays; the dep is no longer needed but harmless to keep cloned.
4. **`Makefile:185`** — drop `--cell-library tools/jacquard_cell_lib/ocd_sram_shim.v` from the Jacquard invocation (OCD-macro shim, dead once the macro is gone).
5. **`CLAUDE.md`** — update the stale "Memory: 8 × OCD SRAM macros (8KB main RAM)" line to reflect ADR 0004 (external QSPI PSRAM, color RAM + ROMs on-die). It currently describes the superseded arch as current.
6. **Register the ZP/stack macros with genuine 5V libs — corner-aliasing guardrail (3.3V audit, 2026-07-01; now the active path per ADR 0004 §9).** Add a `MACROS:` block for 2× `gf180mcu_fd_ip_sram__sram256x8m8wm1` using that macro's genuine `_5v00`/`_5v50`/`_4v50` lib files under the matching 5V corner keys. The removed OCD block (`config.yaml:190-196`) registered **3.3V** libs (`__tt_025C_3v30/__ff_n40C_3v60/__ss_125C_3v00`) under **5V corner keys** (`*_tt_025C_5v00`/`*_ff_n40C_5v50`/`*_ss_125C_4v50`) — a physically false alias that quieted STA but left the 3.3V power domain floating (→ PSM-0039). **Never repeat that: never alias a 3.3V lib under a 5V key.** Add the 2-macro PDN grid back to `pdn_cfg.tcl` (see task 2). Re-running the 3.3V grep audit (search: `3v30|3v00|3v60`, `ocd`, corner-key vs lib-file mismatch) after cleanup should return only board-side PSRAM hits — **no** on-die SRAM hits, since the ZP/stack macros are genuinely 5V.
7. Re-run `make librelane-pdn` and trace through to PnR completion.

**Deliverables:**
- `librelane/config.yaml` — OCD 3.3V SRAM removed, 2× 5V `sram256x8` registered with genuine 5V libs
- `librelane/pdn_cfg.tcl` — bulk SRAM grid removed, 2-macro grid (or default) coherent on the 5V rails
- Successful run to at least `OpenROAD.GlobalPlacement` completion (no PSM-0039 / RePlAce divergence)

**Exit criteria:**
- `make librelane-pdn` reaches `OpenROAD.DetailedRouting` without diverging
- IR-drop check passes
- Saved views in `final/`

### WS-P2-4 — wafer.space chip-decoration IP

**Goal:** Re-instate `chip_id` and `wafer_space_logo` so the chip is wafer.space-submittable.

**Tasks:**
1. Identify the source repo for `gf180mcu_ws_ip__id` and `gf180mcu_ws_ip__logo` (test-tapeout-1 has these in `ip/` in its agent worktrees; trace the URL).
2. Clone into `ip/` (consider submodules).
3. Un-comment the `MACROS:` blocks in `librelane/config.yaml`.
4. Un-comment the instantiations in `src/chip_top.sv`.
5. Re-run PnR.

**Deliverables:**
- `ip/gf180mcu_ws_ip__id/` and `ip/gf180mcu_ws_ip__logo/` populated
- `chip_top.sv` instantiates them

**Exit criteria:**
- LibreLane PnR with chip-decoration IP completes
- KLayout shows the logo + ID block correctly placed

### WS-P2-5 — Re-run cocotb smoke and tighten the test

**Goal:** Update the smoke test to reflect the PSRAM path. Add a second test that pre-loads the BFM with a known program and verifies it executes.

**Tasks:**
1. Update `cocotb/chip_core_tb.py` to instantiate the PSRAM BFM (from WS-P2-1).
2. Pre-load the BFM with: NOP-pad-to-RESET-vector + a 4-instruction program (e.g. LDA #$AA / STA $D020 / NOP / JMP self).
3. Verify the CPU executes the program — observable on the address-debug pads.

**Deliverables:**
- `cocotb/chip_core_tb.py` with PSRAM BFM
- New `test_run_simple_program` that fetches and executes

**Exit criteria:**
- Both tests pass under Verilator

### WS-P2-6 — Jacquard post-PnR timing simulation

**Goal:** Run the PnR'd netlist through Jacquard with SDF back-annotation, verify timing closes at 32 MHz and the C64 system functionality survives gate-level delays.

**Update (2026-07-01): Jacquard is released — do NOT vendor it.** Use the released Jacquard (installed tool) rather than the `deps/jacquard` submodule + build-from-source. Consequences for the Makefile:
- Retire the `vendor:` target (`ln -sfn deps/jacquard/vendor vendor`, `Makefile:177-178`) and the `jacquard-build` / `jacquard-opensta` submodule targets — obsolete once Jacquard is a released tool.
- `jacquard-cosim` (`Makefile:180`) no longer depends on the `vendor` symlink; re-point it at the released binary's invocation.
- The `.gitignore` `vendor` entry becomes dead once the symlink target is gone — remove it in this cleanup.
- (This is also why the WS-P2-1 PULP IP lives in `ip/pulp/`, not `vendor/` — no collision, and `vendor/` is going away.)

**Cosim model — DECISION (2026-07-01, Track A): built-in GPU `qspi_ram` peripheral.** The C64's main RAM is accessed nearly every cycle, so a CPU-side cosim model runs at Jacquard's `batch=1` almost continuously (~2.5 s/frame Metal, 8–13 s/frame CUDA/HIP — GPU speedup erased). The performant path is a **GPU-side** peripheral generalizing Jacquard's existing flash `FlashState` (already `data_width=1|4`, 4-lane, 24-bit addr, mode+dummy, SPI-mode-0 phase — matches our controller), adding enter-QPI (0x35), quad-write (0x38) into a writable store, and RAM init, behind a small `GpuBidirPeripheral` sub-trait (down-payment on Jacquard ADR 0017 Tier-2). Rob (Jacquard author) will land this in gpu-eda/jacquard; the general user-provided CPU `PeripheralModel` interface is a **fast-follow (Track B)**, off this repo's critical path. Full analysis: [`docs/spikes/jacquard-cosim-models.md`](../spikes/jacquard-cosim-models.md). Est. ~1.5–3 wk for Track A.

**Tasks:**
1. Confirm how released Jacquard is obtained/invoked (binary on PATH? nix? cargo/pip?) — **open, owner: Rob** — and record the exact invocation.
2. Run post-PnR sim with the cocotb harness re-pointed at the gate-level netlist + SDF, driving the released Jacquard.
3. Remove the obsolete vendored-Jacquard Makefile/gitignore machinery (see update above).

**Deliverables:**
- `make jacquard-cosim` target (released-Jacquard based) that runs the smoke test against the PnR netlist
- Timing report showing closure at 32 MHz TT corner
- Vendored-Jacquard machinery removed

**Exit criteria:**
- Smoke test passes against the PnR'd gate-level netlist
- No setup/hold violations at TT corner

### WS-P2-7 — Test board notes (out of immediate scope, document only)

**Goal:** Pin down the test-board side of the QSPI PSRAM so phase-3 (bring-up) isn't a surprise.

**Tasks:**
1. Pick a specific PSRAM part. Candidates:
   - **APS6404L-3SQR** — 8 MB QSPI, 3.3V, 144 MHz. Needs level shifter if our pads are 5V-tolerant only one-way.
   - **IS66WVS1M8** — 1 MB QSPI, 1.65–3.6V, supposedly 5V-tolerant on some pins.
   - **W955D8M** — Winbond HyperRAM (for comparison; rejected per ADR 0004 alts).
2. Decide whether we need a level shifter or pick a fully 5V-tolerant chip.
3. Sketch the connectivity: chip pads ↔ level shifter ↔ PSRAM ↔ PSRAM-bypass header (for backdoor load).
4. Document a backdoor preload path — JTAG-style host control of CS#/SCK/SIO from a USB header on the test board.

**Deliverables:**
- `docs/board/qspi-psram-notes.md` (or appended to phase-2 plan)

**Exit criteria:** Document committed. Hardware not built in this phase.

## Dependencies between workstreams

```
WS-P2-1 (controller) ─┬─→ WS-P2-2 (RTL integration) ─┬─→ WS-P2-3 (LibreLane config) ─→ WS-P2-6 (Jacquard)
                      └─→ WS-P2-5 (cocotb) ──────────┘
                                                     ↓
                                            WS-P2-4 (chip-deco IP) ─→ WS-P2-6
WS-P2-7 (board notes) — independent, do anytime
```

## Decision log

- **Why phase-2, not amend phase-1?** Phase-1 successfully landed the GHDL→Yosys synth pipeline, cocotb smoke, and the LibreLane infra on aarch64-darwin. The pivot away from on-die SRAM is a meaningful architecture shift driven by a fact discovered during phase-1 bring-up (5V cell library × 3.3V SRAM macro). Cleaner to mark phase-1's WS5 as "infrastructure landed, blocked on architecture" and start fresh.
- **Why not just use the 5V foundry SRAM?** See [ADR 0004 alternatives](../adr/0004-external-qspi-psram.md#alternatives-considered). Short version: 4 KB on-die isn't worth the area + PDN tuning when 64 KB external is achievable.
- **Why QSPI vs HyperRAM?** See [ADR 0004 alternatives](../adr/0004-external-qspi-psram.md#alternatives-considered). Short version: fewer pins, more OSS IP, simpler single-ended I/O.

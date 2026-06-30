# Plan — Phase 2: External QSPI PSRAM + clean PnR

**Status:** Active (2026-06-30).

## Goal

Land [ADR 0004](../adr/0004-external-qspi-psram.md): rip on-die SRAM out of `chip_core`, drop in a QSPI PSRAM controller talking to 6 pads, get LibreLane PnR through to a placed-and-routed GDS, and re-run the cocotb smoke + Jacquard post-PnR sim.

## Where things stand (2026-06-30 — end of phase-1)

- WS1 (flow infra): ✓ Nix shell builds on aarch64-darwin (dropped `ghdl-mcode` per flake.nix). LibreLane 3.0.0 from FOSSI cache works. Homebrew GHDL handles VHDL synth out-of-band.
- WS2 (RTL): ✓ T65 + VIC-II + CIA + bus logic + cycle sequencer + ROMs all wired through `chip_core`. Cocotb smoke passes.
- WS3 (cocotb): ✓ `make sim-smoke` passes under Verilator (chip_core boots, VIC HSYNC pulses, CPU drives VIC/CIA addresses).
- WS4 (GHDL → Yosys): ✓ `make synth-test` → 255K cells, 1 benign tri-state warning.
- WS5 (LibreLane PnR): ⚠ Reached OpenROAD.GlobalPlacement (stage 22/83); RePlAce diverges because OCD SRAM macros are 3.3V on a 5V standard-cell library — power nets float. **This phase fixes that by dropping on-die SRAM.**
- WS6 (Jacquard sim): ✗ Not started — blocked on a closed PnR.

## Workstreams

### WS-P2-1 — Pick or write the QSPI PSRAM controller

**Goal:** Have a synthesizable `qspi_psram_ctrl` module with a simple wishbone-ish interface to `c64_system`.

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

**Goal:** Wire the controller into `c64_system`'s existing `ramAddr`/`ramDin`/`ramDout`/`ramCE`/`ramWE` ports. Remove on-die SRAM entirely.

**Tasks:**
1. Remove `sram_wrapper` instantiation from `chip_core.sv`. Replace with `qspi_psram_ctrl`.
2. Add new pad signals: `psram_cs_n`, `psram_sck`, `psram_sio[3:0]`. Wire to bidir[33..38] (table in [ADR 0004 §2](../adr/0004-external-qspi-psram.md)).
3. Update bidir output steering in `chip_core.sv`: drive CS#/SCK as outputs always; SIO[3:0] direction depends on the controller's `sio_oe` signal.
4. Decide whether the cycle sequencer needs adjustment for PSRAM latency: at 32 MHz SCK, a fast-read is ~470 ns = ~15 sequencer states. The CPU access window today is 1 state of the 32-state sequencer. Likely needs the sequencer to widen the CPU access window, or the controller buffers reads ahead.
5. Update `c64_buslogic.vhd` if the ramCE/ramWE handshake needs to gate on a controller-ready signal (it currently assumes 1-cycle SRAM).
6. Delete (or stub) `src/sram_wrapper.sv`.

**Deliverables:**
- `chip_core.sv` updated
- `c64_system.vhd` + `c64_buslogic.vhd` updated if sequencer/handshake changes
- `vhdl.f` / `rtl.f` updated

**Exit criteria:**
- `make synth-test` passes
- `make sim-smoke` boots and reads first instruction from PSRAM (via BFM) instead of internal SRAM
- KERNAL reset-vector fetch visible on the bidir pads as before

### WS-P2-3 — LibreLane config cleanup

**Goal:** Strip everything SRAM from the LibreLane config so the PnR floorplan is cells-only.

**Tasks:**
1. `librelane/config.yaml`:
   - Remove `VERILOG_DEFINES: USE_SRAM_MACROS` (no more SRAM wrapper).
   - Remove the `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` `MACROS:` entry.
   - Remove the SRAM `IGNORE_DISCONNECTED_MODULES` entries.
   - Tighten `DIE_AREA`/`CORE_AREA` — we no longer need 3500×4700 µm of core; estimate from a placement pass.
2. `librelane/pdn_cfg.tcl`:
   - Remove the `pdn_c64_sram` grid section. Keep stdcell grid + core ring + default macro grid.
3. `deps/gf180mcu_ocd_ip_sram/` — gitignore stays; the dep is no longer needed but harmless to keep cloned.
4. Re-run `make librelane-pdn` and trace through to PnR completion.

**Deliverables:**
- `librelane/config.yaml` SRAM-free
- `librelane/pdn_cfg.tcl` SRAM-free
- Successful run to at least `OpenROAD.GlobalPlacement` completion

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

**Tasks:**
1. Crib from test-tapeout-1's Jacquard setup (`deps/jacquard`).
2. Build Jacquard locally (`make jacquard-build`).
3. Run post-PnR sim with cocotb harness re-pointed at the gate-level netlist + SDF.

**Deliverables:**
- `make jacquard-cosim` target that runs the smoke test against the PnR netlist
- Timing report showing closure at 32 MHz TT corner

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

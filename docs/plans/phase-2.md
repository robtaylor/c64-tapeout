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

## Memory timing budget & VIC contention (gating decision for WS-P2-2)

Grounded in the original C64 hardware (c64-wiki "Hardware internals of the C64", verified 2026-07-01):

- **Main RAM = 8 × 64K×1 DRAM (4164-class)** — *"arranged in 8 chips of 65536 bits each; each chip is responsible for one bit of all memory bytes."* (Not 4116, which is 16K×1 → only 16 KB and needs three supply rails; that was the VIC-20 part.) Color RAM = 2114-class 1K×4 SRAM, **stays on-die per [ADR 0004 §5](../adr/0004-external-qspi-psram.md)**.
- **Memory is dual-accessed every cycle:** *"During Φ2=0 the VIC accesses the system, during Φ2=1 (mostly) the CPU."* The ~1 µs CPU cycle splits into two ~500 ns halves (VIC phi1 / CPU phi2). VIC contention on external RAM is real, not hypothetical.
- **Per-access data budget ≈ 400 ns:** *"address bus valid 60–75 ns after the positive edge of Φ2"*; *"data at the latest on the falling edge about 400 ns later."* The original 4164 DRAM (tRAC ~150–200 ns) met this with margin.

### Implication for the QSPI PSRAM path

A faithful drop-in for main RAM must resolve a random read within ~400 ns. A quad fast-read (0xEB) is ~22 SCK cycles/byte:

| Budget | SCK needed (quad, ~22 cyc) |
|---|---|
| ~400 ns (cycle-faithful CPU phi2 window) | ~55 MHz |
| ~500 ns (one access per half-cycle) | ~44 MHz |
| 1 µs (CPU-only, wait-stated) | ~22 MHz |

55 MHz quad SCK is tight for a GF180 5 V part + board parasitics. Three levers (not mutually exclusive):

1. **Prefetch / line-buffer (recommended).** Fetch a 16–32 B burst per transaction, serve sequential reads from an on-die buffer. The VIC's phi1 stream (screen matrix, char/bitmap, sprite) and CPU instruction fetch are largely *sequential* → amortized per-byte SCK cost drops far below the worst-case-per-byte numbers above. Relaxes the SCK requirement more than overclocking does.
2. **Brute-force SCK (~55 MHz).** Simplest RTL, hardest on signoff + board.
3. **CPU wait-states.** Stall the CPU during external fetches. Functionally correct; breaks cycle-exact timing (raster effects, SID).

Keeping color RAM on-die removes the VIC's *color* fetches from external RAM, but the VIC still pulls screen matrix + character/bitmap + sprite data from external main RAM during phi1 — that is the contention that matters on the QSPI bus.

### GATING DECISION — RESOLVED 2026-07-01: **cycle-accurate**

Target raster effects, SID timing, and demos running. Consequences: **no CPU wait-states in the common case**; a small on-die VIC line-buffer is required (but on-die main-RAM / ZP-stack is **not** — see measured findings).

### Measured access pattern (scout against the RTL, 2026-07-01)

Verified against `c64_system.vhd` / `c64_buslogic.vhd` / `video_vicII_656x.vhd`. This **supersedes the speculation above** — three corrections:

**(a) The real bottleneck today is the sequencer, not SCK.** `c64_system.vhd` runs a 32-state sequencer at 32 MHz (1 µs/period; states 0–15 ≈ VIC half, 16–31 ≈ CPU half), tuned for 1-cycle SRAM: `ramCE` pulses *late* — `CYCLE_VIC0` (state 12) and `CYCLE_CPUC` (state 28) — only **~3 clk32 cycles (~94 ns)** before the data-sample edge (`c64_system.vhd:432-433`). So the *current* budget is ~94 ns, far tighter than the ~400 ns hardware model — **but the address is stable for nearly the whole period**, so reworking the sequencer to trigger the PSRAM transaction at the *start* of each half-window (state 0/16) recovers the full **~500 ns**, comfortably inside a ~470 ns quad fast-read with no wait-states. This rework is the core WS-P2-2 deliverable.

**(b) On-die ZP/stack is NOT load-bearing for timing — demoted to optional.** With the early-trigger rework, CPU random reads/writes get the full ~500 ns window (writes already hold `ramWE` for the whole 16-cycle CPU window, `c64_system.vhd:432`). The ZP/stack-hot argument is 6502 domain knowledge, not something the timing forces; a carve-out is cheap to add later (`c64_buslogic.vhd:162-165` already special-cases page 0) **if** profiling shows a perf/power win. **So we defer it and park the flops-vs-5V-SRAM-macro decision** — the earlier "512-byte hot-page macro" is no longer the driver.

**(c) The real pinch is VIC badlines — a *concurrency* problem, not a randomness one.** During a badline (once per 8 scanlines), VIC needs **two** main-RAM accesses in the same 1 µs cycle the CPU is halted for: the sequential 40-byte **c-access** burst (`VM+colCounter`, predictable) plus the scattered **g-access** stream. Two ~470 ns quad reads in ~1 µs = effectively **zero slack**, and there is **no existing memory-ready/wait-state handshake** (`baLoc`/`enableCpu` are driven by VIC badline logic, not a memory-ready signal). This — not CPU ZP/stack — is what actually motivates on-die buffering.

### Revised architecture (cycle-accurate, measured)

1. **Sequencer early-trigger rework** in `c64_system.vhd` — fire the PSRAM transaction at the start of each half-window; recovers ~500 ns/access. **Couples to the controller:** `qspi_psram_ctrl.sv` currently triggers off `ce_rise` against the *late* CE timing (`rtl/qspi_psram_ctrl.sv:116,154`), so WS-P2-2 must touch both the sequencer and the controller's trigger contract.
2. **VIC c-access line-buffer (~40 bytes, flops — no SRAM macro).** Prefetch the badline's sequential 40-byte c-access burst (address-predictable) so it isn't serialized against the per-cycle g-access. This is the buffering the access pattern genuinely requires, and it's small enough to be flops — keeping the clean cells-only PnR. Sprite s-access (3-byte bursts at arbitrary `MPtr*64`) is low-frequency; flag for timing follow-up once integration exists.
3. **External QSPI PSRAM** for the bulk 64 KB (unchanged).
4. **SCK target ~32–44 MHz quad** — with the early-trigger giving ~500 ns and the c-access buffered, ~32 MHz regains slack; pin down once the integrated sim exists.
5. **Optional, deferred:** on-die ZP/stack carve-out (`c64_buslogic.vhd:162-165`) only if profiling motivates it; flops-vs-5V-SRAM-macro trade parked until then.

**Decision (i) — RESOLVED 2026-07-01: VIC badline c-access line-buffer (over CPU wait-states).** A ~40-byte on-die flop buffer prefetches the badline's sequential c-access burst; the common-case path stays wait-state-free. This is committed (architecture item 2 above is no longer provisional).

**Open decision (ii) for Rob:** whether to add a memory-ready/stall handshake as a *safety net* for worst-case sprite-heavy lines (8 sprites × 3-byte s-access at arbitrary `MPtr*64`). Deferred to WS-P2-2 — resolve once the integrated cocotb sim can measure real slack rather than deciding blind. Note: the handshake (if added) is a fallback, not the primary mechanism, since (i) chose the buffer.

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

**Goal:** Wire the controller into `c64_system`'s existing `ramAddr`/`ramDin`/`ramDout`/`ramCE`/`ramWE` ports. Remove on-die SRAM entirely.

**Tasks:**
1. Remove `sram_wrapper` instantiation from `chip_core.sv`. Replace with `qspi_psram_ctrl`.
2. Add new pad signals: `psram_cs_n`, `psram_sck`, `psram_sio[3:0]`. Wire to bidir[33..38] (table in [ADR 0004 §2](../adr/0004-external-qspi-psram.md)).
3. Update bidir output steering in `chip_core.sv`: drive CS#/SCK as outputs always; SIO[3:0] direction depends on the controller's `sio_oe` signal.
4. Decide whether the cycle sequencer needs adjustment for PSRAM latency — **driven by the [Memory timing budget & VIC contention](#memory-timing-budget--vic-contention-gating-decision-for-ws-p2-2) section above.** Resolve the gating cycle-accurate-vs-functional decision first; it sets whether we need a prefetch line-buffer, brute-force SCK (~55 MHz for the cycle-faithful ~400 ns window), or CPU wait-states. Also verify how `video_vicII_656x.vhd` / `c64_system.vhd` route VIC phi1 fetches before pinning an SCK target.
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
4. **`Makefile:185`** — drop `--cell-library tools/jacquard_cell_lib/ocd_sram_shim.v` from the Jacquard invocation (OCD-macro shim, dead once the macro is gone).
5. **`CLAUDE.md`** — update the stale "Memory: 8 × OCD SRAM macros (8KB main RAM)" line to reflect ADR 0004 (external QSPI PSRAM, color RAM + ROMs on-die). It currently describes the superseded arch as current.
6. ⚠ **Corner-aliasing guardrail (3.3V audit, 2026-07-01).** The removed OCD `MACROS:` block (`config.yaml:190-196`) registered the macro's **3.3V** libs (`__tt_025C_3v30/__ff_n40C_3v60/__ss_125C_3v00`) under **5V corner keys** (`*_tt_025C_5v00`/`*_ff_n40C_5v50`/`*_ss_125C_4v50`) — a physically false alias that quieted STA but left the 3.3V power domain (→ PSM-0039 floating VDD). If WS-P2-2 adopts the on-die 5V `gf180mcu_fd_ip_sram__sram512x8m8wm1` for ZP/stack, it MUST use that macro's genuine `_5v00`/`_5v50`/`_4v50` lib files under the matching keys — **never alias a 3.3V lib under a 5V key**. Re-running the 3.3V grep audit (search: `3v30|3v00|3v60`, `ocd`, corner-key vs lib-file mismatch) after cleanup should return only board-side PSRAM hits.
7. Re-run `make librelane-pdn` and trace through to PnR completion.

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

**Update (2026-07-01): Jacquard is released — do NOT vendor it.** Use the released Jacquard (installed tool) rather than the `deps/jacquard` submodule + build-from-source. Consequences for the Makefile:
- Retire the `vendor:` target (`ln -sfn deps/jacquard/vendor vendor`, `Makefile:177-178`) and the `jacquard-build` / `jacquard-opensta` submodule targets — obsolete once Jacquard is a released tool.
- `jacquard-cosim` (`Makefile:180`) no longer depends on the `vendor` symlink; re-point it at the released binary's invocation.
- The `.gitignore` `vendor` entry becomes dead once the symlink target is gone — remove it in this cleanup.
- (This is also why the WS-P2-1 PULP IP lives in `ip/pulp/`, not `vendor/` — no collision, and `vendor/` is going away.)

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

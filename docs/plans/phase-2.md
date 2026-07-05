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

**(b) On-die ZP/stack is NOT load-bearing for timing — but is now included for perf + bus-contention relief.** With the early-trigger rework, CPU random reads/writes get the full ~500 ns window (writes already hold `ramWE` for the whole 16-cycle CPU window, `c64_system.vhd:432`). The ZP/stack-hot argument is 6502 domain knowledge, not something the timing forces; a carve-out is cheap (`c64_buslogic.vhd:162-165` already special-cases page 0).

> **UPDATE 2026-07-05 — RESOLVED (in): on-die 5V SRAM ZP/stack carve-out.** No longer deferred. ZP (`$0000–$00FF`) + stack (`$0100–$01FF`) go on-die as **2 × `gf180mcu_fd_ip_sram__sram256x8m8wm1`** (5V-native, genuine `_5v00`/`_5v50`/`_4v50` corners). The motivation is not timing (the early-trigger already closes it) but (i) 1-cycle access to the two hottest fixed-address 6502 pages, and (ii) removing that traffic from the QSPI bus, easing the badline contention in finding (c). PnR-safe because the 5V macro shares VDD/VSS with the 5V cells (the phase-1 divergence was the *3.3V* OCD macro floating). See [ADR 0004 §9](../adr/0004-external-qspi-psram.md#decision). The flops-vs-macro trade is settled: **macro** (2× sram256x8), not flops.

**(c) The real pinch is VIC badlines — a *concurrency* problem, not a randomness one.** During a badline (once per 8 scanlines), VIC needs **two** main-RAM accesses in the same 1 µs cycle the CPU is halted for: the sequential 40-byte **c-access** burst (`VM+colCounter`, predictable) plus the scattered **g-access** stream. Two ~470 ns quad reads in ~1 µs = effectively **zero slack**, and there is **no existing memory-ready/wait-state handshake** (`baLoc`/`enableCpu` are driven by VIC badline logic, not a memory-ready signal). This — not CPU ZP/stack — is what actually motivates on-die buffering.

### Revised architecture (cycle-accurate, measured)

1. **Sequencer early-trigger rework** in `c64_system.vhd` — fire the PSRAM transaction at the start of each half-window; recovers ~500 ns/access. **Couples to the controller:** `qspi_psram_ctrl.sv` currently triggers off `ce_rise` against the *late* CE timing (`rtl/qspi_psram_ctrl.sv:116,154`), so WS-P2-2 must touch both the sequencer and the controller's trigger contract.
2. **VIC c-access line-buffer (~40 bytes, flops — no SRAM macro).** Prefetch the badline's sequential 40-byte c-access burst (address-predictable) so it isn't serialized against the per-cycle g-access. This is the buffering the access pattern genuinely requires, and it's small enough to be flops — keeping the clean cells-only PnR. Sprite s-access (3-byte bursts at arbitrary `MPtr*64`) is low-frequency; flag for timing follow-up once integration exists.
3. **External QSPI PSRAM** for the bulk 64 KB (unchanged).
4. **SCK target ~32–44 MHz quad** — with the early-trigger giving ~500 ns and the c-access buffered, ~32 MHz regains slack; pin down once the integrated sim exists.
5. **On-die 5V SRAM ZP/stack carve-out (RESOLVED 2026-07-05, was "optional/deferred").** 2× `gf180mcu_fd_ip_sram__sram256x8m8wm1` for page 0 (`$0000–$00FF`) + stack (`$0100–$01FF`); `c64_buslogic.vhd` decodes `$0000–$01FF` to the macros, everything else to `qspi_psram_ctrl`. 5V-native corners only (never alias a 3.3V lib under a 5V key). Screen matrix stays on the line-buffer (item 2); color RAM stays flops. See [ADR 0004 §9](../adr/0004-external-qspi-psram.md#decision).

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

**Goal:** Wire the controller into `c64_system`'s existing `ramAddr`/`ramDin`/`ramDout`/`ramCE`/`ramWE` ports. Remove the bulk on-die SRAM; keep the 512 B ZP/stack carve-out ([ADR 0004 §9](../adr/0004-external-qspi-psram.md#decision)).

#### Design, grounded against the RTL (2026-07-06)

Read `chip_core.sv`, `sram_wrapper.sv`, `c64_system.vhd`, `c64_buslogic.vhd`, and `qspi_psram_ctrl.sv` before writing this. Four things drive the design.

**Clock (RESOLVED — 64 MHz pad ÷2 to core, see [ADR 0001 amendment 2026-07-06](../adr/0001-system-scope-and-clock.md#decision)).** The controller needs a 64 MHz clock for 32 MHz SCK (`qspi_psram_ctrl.sv:29`, min divide ÷2); the core sequencer runs at 32 MHz (`c64_system.vhd:148`). At 32 MHz the best SCK is 16 MHz (~940 ns/quad-read), which blows the window, so the pad clock becomes 64 MHz and a single flop in `chip_top`/`chip_core` divides it to the 32 MHz `clk32` the core already expects. The controller gets the raw 64 MHz. Two synchronous domains (2× related), no async CDC. `CLK_DIV=0` then gives 32 MHz SCK.

**The ZP/stack physical split lives in `chip_core.sv`, not `c64_buslogic.vhd`.** `c64_system` exposes one location-agnostic RAM interface; `cs_ram` means "a RAM access," not "which chip." `c64_buslogic.vhd:162-165` (`when X"0"`) is the `$0xxx` memory-*map* decode (RAM vs ROM/IO), identical to the `when others` default, and does not change. In `chip_core.sv`, decode `is_lowpage = (ram_addr[15:9] == 0)` (i.e. `< $0200`) and route: reads mux `ram_din = is_lowpage ? zpstack_dout : psram_dout`; the ZP/stack SRAM takes `din ⇐ ram_dout`, `we`, `ce = ram_ce & is_lowpage`; the PSRAM controller's `ramCE` is gated with `~is_lowpage` so no QSPI transaction is issued for ZP/stack (that traffic staying off the bus is the point of the carve-out). The crossover (`sram.din ⇐ ram_dout`, `ram_din ⇐ sram.dout`) is exactly what `sram_wrapper` already does at `chip_core.sv:203-210`.

**There is no wait-state path today, so the early-trigger has to close by construction.** `c64_system` samples read data combinationally (`c64_buslogic` `dataToCpu ⇐ ramData ⇐ ramDin`) at the CPU edge and never consumes the controller's `ready`/latency. The ZP/stack SRAM is 1-cycle synchronous like the old wrapper, so it is always ready in-window. For the PSRAM path, `ramCE` currently asserts late (`c64_system.vhd:433`: `cs_ram_int when sysCycle = CYCLE_VIC0 or cpu_cyc`, i.e. state 12 / state 28, ~94 ns before the sample edge). The controller triggers on a rising edge of `ramCE` (`qspi_psram_ctrl.sv:122,188`), latches the address, and runs one byte transaction. Move that assertion to the *start* of each access window so a ~470 ns quad read finishes inside the ~500 ns window with `ready` left unconsumed. The decision-(ii) stall safety-net stays deferred until the integrated sim can measure real slack.

**Two accesses per period is the badline pinch, and the line-buffer is a second increment.** The sequencer does a VIC access (`CYCLE_VIC0`) and a CPU access (`CYCLE_CPUC`) per 32-state period, so up to two ~470 ns reads land in ~1 µs (near-zero slack, finding (c)). The ~40 B flop line-buffer for the badline c-access is what buys that slack back. It is more involved than the basic bus wiring, so stage it after a functional single-access integration proves out (see task 5).

Open items to verify during implementation, not blockers: the 6510 processor port overlays `$0000`/`$0001` (handled in `cpu_6510.vhd` via `diIO/doIO`, `c64_system.vhd:423-424`) — confirm reads of `$00/$01` take the port value, not the ZP-SRAM byte, so the shadow write underneath is harmless; and confirm the address is stable at the new early-trigger point for both the VIC (`vicAddr`) and CPU (`cpuAddr`) phases.

**Tasks (in dependency order):**
1. **Clock.** In `chip_top.sv`/`chip_core.sv`, take the 64 MHz pad clock, add a ÷2 flop to produce `clk32` for `c64_system` and the ROMs/CIA, and route the 64 MHz clock to `qspi_psram_ctrl`. Confirm reset synchronisation across both.
2. **`chip_core.sv` memory split.** Instantiate `qspi_psram_ctrl` (main-RAM path, `~is_lowpage` CE gate) and 2× `gf180mcu_fd_ip_sram__sram256x8m8wm1` for ZP+stack (`is_lowpage` CE). Add the `is_lowpage` decode and the `ram_din` mux. Remove the `sram_wrapper` instance.
3. **Pads.** Add `psram_cs_n`/`psram_sck` (always output) at bidir[33..34] and `psram_sio[3:0]` (bidir, `out_drive ⇐ sio_o`, `oe ⇐ sio_oe`, `ie=1`, `sio_i ⇐ bidir_in`) at bidir[35..38], per [ADR 0004 §2](../adr/0004-external-qspi-psram.md). Update the `oe_mask`/`ie_mask`/`out_drive` block (`chip_core.sv:252-290`).
4. **Sequencer early-trigger.** In `c64_system.vhd`, assert `ramCE` for PSRAM-region accesses at the start of the access window (one clean rising edge per access) instead of the late `CYCLE_VIC0`/`cpu_cyc` timing, so the quad read closes before the sample edge. Leave the ZP/stack path 1-cycle.
5. **VIC c-access line-buffer (~40 B flops).** Prefetch the badline sequential c-access burst so it is not serialised against the g-access. Second increment; land after 1–4 pass a functional sim.
6. **Cleanup.** Stub or delete `src/sram_wrapper.sv`; update `vhdl.f`/`rtl.f`; drop the `USE_SRAM_MACROS` wrapper path.

**Deliverables:**
- `chip_top.sv`/`chip_core.sv` updated (clock divider, memory split, pads)
- `c64_system.vhd` updated (early-trigger `ramCE`); `c64_buslogic.vhd` unchanged for the split
- VIC c-access line-buffer module
- `vhdl.f`/`rtl.f` updated

**Exit criteria:**
- `make synth-test` passes (clean; the 2 SRAM macros as black boxes)
- `make sim-smoke` boots and fetches the KERNAL reset vector from the PSRAM BFM (not internal SRAM), ZP/stack served on-die
- Reset-vector fetch visible on the bidir pads as before

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

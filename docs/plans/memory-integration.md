# Plan — Memory subsystem integration (phase-2 WS-P2-2)

**Status:** Active (2026-07-06). The WS-P2-2 workstream of [phase-2](phase-2.md); extracted from the phase roadmap on 2026-07-06 so the memory design has its own home.

## Goal

Wire `qspi_psram_ctrl` into the C64 core, add the on-die ZP/stack SRAM carve-out ([ADR 0004 §9](../adr/0004-external-qspi-psram.md#decision)), rework the sequencer so PSRAM reads close within the cycle, and add the VIC badline line-buffer. Remove the bulk on-die SRAM. Implements the memory side of [ADR 0004](../adr/0004-external-qspi-psram.md) and the clock change in [ADR 0001](../adr/0001-system-scope-and-clock.md#decision).

## Memory timing budget & VIC contention

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

**(a) The real bottleneck today is the sequencer, not SCK.** `c64_system.vhd` runs a 32-state sequencer at 32 MHz (1 µs/period; states 0–15 ≈ VIC half, 16–31 ≈ CPU half), tuned for 1-cycle SRAM: `ramCE` pulses *late* — `CYCLE_VIC0` (state 12) and `CYCLE_CPUC` (state 28) — only **~3 clk32 cycles (~94 ns)** before the data-sample edge (`c64_system.vhd:432-433`). So the *current* budget is ~94 ns, far tighter than the ~400 ns hardware model — **but the address is stable for nearly the whole period**, so reworking the sequencer to trigger the PSRAM transaction at the *start* of each half-window (state 0/16) recovers the full **~500 ns**, comfortably inside a ~470 ns quad fast-read with no wait-states. This rework is the core deliverable.

**(b) On-die ZP/stack is NOT load-bearing for timing — but is now included for perf + bus-contention relief.** With the early-trigger rework, CPU random reads/writes get the full ~500 ns window (writes already hold `ramWE` for the whole 16-cycle CPU window, `c64_system.vhd:432`). The ZP/stack-hot argument is 6502 domain knowledge, not something the timing forces; a carve-out is cheap (`c64_buslogic.vhd:162-165` already special-cases page 0).

> **UPDATE 2026-07-05 — RESOLVED (in): on-die 5V SRAM ZP/stack carve-out.** No longer deferred. ZP (`$0000–$00FF`) + stack (`$0100–$01FF`) go on-die as **2 × `gf180mcu_fd_ip_sram__sram256x8m8wm1`** (5V-native, genuine `_5v00`/`_5v50`/`_4v50` corners). The motivation is not timing (the early-trigger already closes it) but (i) 1-cycle access to the two hottest fixed-address 6502 pages, and (ii) removing that traffic from the QSPI bus, easing the badline contention in finding (c). PnR-safe because the 5V macro shares VDD/VSS with the 5V cells (the phase-1 divergence was the *3.3V* OCD macro floating). See [ADR 0004 §9](../adr/0004-external-qspi-psram.md#decision). The flops-vs-macro trade is settled: **macro** (2× sram256x8), not flops.

**(c) The real pinch is VIC badlines — a *concurrency* problem, not a randomness one.** During a badline (once per 8 scanlines), VIC needs **two** main-RAM accesses in the same 1 µs cycle the CPU is halted for: the sequential 40-byte **c-access** burst (`VM+colCounter`, predictable) plus the scattered **g-access** stream. Two ~470 ns quad reads in ~1 µs = effectively **zero slack**, and there is **no existing memory-ready/wait-state handshake** (`baLoc`/`enableCpu` are driven by VIC badline logic, not a memory-ready signal). This — not CPU ZP/stack — is what actually motivates on-die buffering.

### Revised architecture (cycle-accurate, measured)

1. **Sequencer early-trigger rework** in `c64_system.vhd` — fire the PSRAM transaction at the start of each half-window; recovers ~500 ns/access. **Couples to the controller:** `qspi_psram_ctrl.sv` currently triggers off `ce_rise` against the *late* CE timing (`rtl/qspi_psram_ctrl.sv:116,154`), so this must touch both the sequencer and the controller's trigger contract.
2. **VIC c-access line-buffer (~40 bytes, flops — no SRAM macro).** Prefetch the badline's sequential 40-byte c-access burst (address-predictable) so it isn't serialized against the per-cycle g-access. This is the buffering the access pattern genuinely requires, and it's small enough to be flops — keeping the clean cells-only PnR. Sprite s-access (3-byte bursts at arbitrary `MPtr*64`) is low-frequency; flag for timing follow-up once integration exists.
3. **External QSPI PSRAM** for the bulk 64 KB (unchanged).
4. **SCK target ~32–44 MHz quad** — with the early-trigger giving ~500 ns and the c-access buffered, ~32 MHz regains slack; pin down once the integrated sim exists.
5. **On-die 5V SRAM ZP/stack carve-out (RESOLVED 2026-07-05, was "optional/deferred").** 2× `gf180mcu_fd_ip_sram__sram256x8m8wm1` for page 0 (`$0000–$00FF`) + stack (`$0100–$01FF`); the physical decode lives in `chip_core.sv` (see the grounded design below), everything else to `qspi_psram_ctrl`. 5V-native corners only (never alias a 3.3V lib under a 5V key). Screen matrix stays on the line-buffer (item 2); color RAM stays flops. See [ADR 0004 §9](../adr/0004-external-qspi-psram.md#decision).

**Decision (i) — RESOLVED 2026-07-01: VIC badline c-access line-buffer (over CPU wait-states).** A ~40-byte on-die flop buffer prefetches the badline's sequential c-access burst; the common-case path stays wait-state-free. This is committed (architecture item 2 above is no longer provisional).

**Open decision (ii) for Rob:** whether to add a memory-ready/stall handshake as a *safety net* for worst-case sprite-heavy lines (8 sprites × 3-byte s-access at arbitrary `MPtr*64`). Deferred — resolve once the integrated cocotb sim can measure real slack rather than deciding blind. Note: the handshake (if added) is a fallback, not the primary mechanism, since (i) chose the buffer.

## Controller notes carried from WS-P2-1

- **Bus port crossover.** `c64_system.vhd` names ports system-side (`ramDout` = write data *out*, `ramDin` = read data *in*); `qspi_psram_ctrl` names them memory-side (`ramDin` = write *in*, `ramDout` = read *out*). Integration wiring is a crossover: `qspi.ramDin ⇐ c64.ramDout`, `c64.ramDin ⇐ qspi.ramDout`. The existing `sram_wrapper` already wires it this way (`chip_core.sv:203-210`).
- **Trigger contract couples to the sequencer rework.** The controller starts on `ce_rise` against the *late* CE timing (`rtl/qspi_psram_ctrl.sv:116,154`); the early-trigger rework must update both together.
- **Init completion** is detected via `spi_status[0]` (the `0x35` command-only transaction produces no `eot` — a PULP FSM quirk).
- **Handshake** is a single-cycle `ready` pulse with `ramDout` held in `rdata_q`.
- **Settled params:** controller clock 64 MHz, `CLK_DIV=0` → 32 MHz SCK; `QRD_DUMMY=6` (0xEB, APS6404L); write = 0x38 quad; QPI entered via single-lane 0x35 at reset; `sio_oe` derived from `spi_mode` (STD→`0001`, QUAD_TX→`1111`, QUAD_RX→`0000`).

## Design, grounded against the RTL (2026-07-06)

Read `chip_core.sv`, `sram_wrapper.sv`, `c64_system.vhd`, `c64_buslogic.vhd`, and `qspi_psram_ctrl.sv` before writing this. Four things drive the design.

**Clock (RESOLVED — 64 MHz pad ÷2 to core, see [ADR 0001 amendment 2026-07-06](../adr/0001-system-scope-and-clock.md#decision)).** The controller needs a 64 MHz clock for 32 MHz SCK (`qspi_psram_ctrl.sv:29`, min divide ÷2); the core sequencer runs at 32 MHz (`c64_system.vhd:148`). At 32 MHz the best SCK is 16 MHz (~940 ns/quad-read), which blows the window, so the pad clock becomes 64 MHz and a single flop in `chip_top`/`chip_core` divides it to the 32 MHz `clk32` the core already expects. The controller gets the raw 64 MHz. Two synchronous domains (2× related), no async CDC. `CLK_DIV=0` then gives 32 MHz SCK.

**The ZP/stack physical split lives in `chip_core.sv`, not `c64_buslogic.vhd`.** `c64_system` exposes one location-agnostic RAM interface; `cs_ram` means "a RAM access," not "which chip." `c64_buslogic.vhd:162-165` (`when X"0"`) is the `$0xxx` memory-*map* decode (RAM vs ROM/IO), identical to the `when others` default, and does not change. In `chip_core.sv`, decode `is_lowpage = (ram_addr[15:9] == 0)` (i.e. `< $0200`) and route: reads mux `ram_din = is_lowpage ? zpstack_dout : psram_dout`; the ZP/stack SRAM takes `din ⇐ ram_dout`, `we`, `ce = ram_ce & is_lowpage`; the PSRAM controller's `ramCE` is gated with `~is_lowpage` so no QSPI transaction is issued for ZP/stack (that traffic staying off the bus is the point of the carve-out). The crossover (`sram.din ⇐ ram_dout`, `ram_din ⇐ sram.dout`) is exactly what `sram_wrapper` already does at `chip_core.sv:203-210`.

**There is no wait-state path today, so the early-trigger has to close by construction.** `c64_system` samples read data combinationally (`c64_buslogic` `dataToCpu ⇐ ramData ⇐ ramDin`) at the CPU edge and never consumes the controller's `ready`/latency. The ZP/stack SRAM is 1-cycle synchronous like the old wrapper, so it is always ready in-window. For the PSRAM path, `ramCE` currently asserts late (`c64_system.vhd:433`: `cs_ram_int when sysCycle = CYCLE_VIC0 or cpu_cyc`, i.e. state 12 / state 28, ~94 ns before the sample edge). The controller triggers on a rising edge of `ramCE` (`qspi_psram_ctrl.sv:122,188`), latches the address, and runs one byte transaction. Move that assertion to the *start* of each access window so a ~470 ns quad read finishes inside the ~500 ns window with `ready` left unconsumed. The decision-(ii) stall safety-net stays deferred until the integrated sim can measure real slack.

**Two accesses per period is the badline pinch, and the line-buffer is a second increment.** The sequencer does a VIC access (`CYCLE_VIC0`) and a CPU access (`CYCLE_CPUC`) per 32-state period, so up to two ~470 ns reads land in ~1 µs (near-zero slack, finding (c)). The ~40 B flop line-buffer for the badline c-access is what buys that slack back. It is more involved than the basic bus wiring, so stage it after a functional single-access integration proves out (see task 5).

Open items to verify during implementation, not blockers: the 6510 processor port overlays `$0000`/`$0001` (handled in `cpu_6510.vhd` via `diIO/doIO`, `c64_system.vhd:423-424`) — confirm reads of `$00/$01` take the port value, not the ZP-SRAM byte, so the shadow write underneath is harmless; and confirm the address is stable at the new early-trigger point for both the VIC (`vicAddr`) and CPU (`cpuAddr`) phases.

## Tasks (in dependency order)

1. **Clock.** In `chip_top.sv`/`chip_core.sv`, take the 64 MHz pad clock, add a ÷2 flop to produce `clk32` for `c64_system` and the ROMs/CIA, and route the 64 MHz clock to `qspi_psram_ctrl`. Confirm reset synchronisation across both.
2. **`chip_core.sv` memory split.** Instantiate `qspi_psram_ctrl` (main-RAM path, `~is_lowpage` CE gate) and 2× `gf180mcu_fd_ip_sram__sram256x8m8wm1` for ZP+stack (`is_lowpage` CE). Add the `is_lowpage` decode and the `ram_din` mux. Remove the `sram_wrapper` instance.
3. **Pads.** Add `psram_cs_n`/`psram_sck` (always output) at bidir[33..34] and `psram_sio[3:0]` (bidir, `out_drive ⇐ sio_o`, `oe ⇐ sio_oe`, `ie=1`, `sio_i ⇐ bidir_in`) at bidir[35..38], per [ADR 0004 §2](../adr/0004-external-qspi-psram.md). Update the `oe_mask`/`ie_mask`/`out_drive` block (`chip_core.sv:252-290`).
4. **Sequencer early-trigger.** In `c64_system.vhd`, assert `ramCE` for PSRAM-region accesses at the start of the access window (one clean rising edge per access) instead of the late `CYCLE_VIC0`/`cpu_cyc` timing, so the quad read closes before the sample edge. Leave the ZP/stack path 1-cycle.
5. **VIC c-access line-buffer (~40 B flops).** Prefetch the badline sequential c-access burst so it is not serialised against the g-access. Second increment; land after 1–4 pass a functional sim.
6. **Cleanup.** Stub or delete `src/sram_wrapper.sv`; update `vhdl.f`/`rtl.f`; drop the `USE_SRAM_MACROS` wrapper path.

## Deliverables

- `chip_top.sv`/`chip_core.sv` updated (clock divider, memory split, pads)
- `c64_system.vhd` updated (early-trigger `ramCE`); `c64_buslogic.vhd` unchanged for the split
- VIC c-access line-buffer module
- `vhdl.f`/`rtl.f` updated

## Exit criteria

- `make synth-test` passes (clean; the 2 SRAM macros as black boxes)
- `make sim-smoke` boots and fetches the KERNAL reset vector from the PSRAM BFM (not internal SRAM), ZP/stack served on-die
- Reset-vector fetch visible on the bidir pads as before

## Links

- [ADR 0001 — system scope + clock (64 MHz pad ÷2)](../adr/0001-system-scope-and-clock.md)
- [ADR 0004 — external QSPI PSRAM + ZP/stack carve-out (§9)](../adr/0004-external-qspi-psram.md)
- [phase-2 roadmap](phase-2.md)

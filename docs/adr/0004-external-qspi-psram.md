# ADR 0004 — External QSPI PSRAM, supersedes on-die SRAM macros (ADR 0003)

**Status:** Accepted (2026-06-30). Supersedes the main-RAM portion of [ADR 0003](0003-memory-architecture.md). ROM strategy in ADR 0003 remains in force.

**TL;DR.** In the context of taping out a C64 subset on GF180MCU 9T 5V (`gf180mcu_fd_sc_mcu9t5v0`), facing a voltage mismatch between the 3.3V `gf180mcu_ocd_ip_sram` macros and the 5V cell library, and limited foundry alternatives (only 64x8–512x8 5V SRAM macros in `gf180mcu_fd_ip_sram`, capping at 4KB across 8 macros), we chose to move main RAM **off-die** to an external QSPI PSRAM accessed through 6 of our spare bidir pads, accepting the controller logic and board complexity in exchange for full 64 KB (the original C64 memory map) and a clean tapeout.

## Context

Three options were considered after the on-die SRAM plan ran into trouble during first PnR:

### Why ADR 0003 doesn't work as-stated

1. **Voltage mismatch.** The `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macro is 3.3V only — its `.lib` corners are `tt_025C_3v30`, `ff_n40C_3v60`, `ss_125C_3v00`. Our standard cells (`gf180mcu_fd_sc_mcu9t5v0`) are 5V. They cannot share VDD/VSS rails. This manifested at PnR as PSM-0039 unconnected-VDD on 16/16 SRAM pins after the floorplan and macro-placement passes succeeded — RePlAce then diverged at global placement because the floating SRAM power nets push gradients to infinity.

2. **Foundry 5V SRAM tops out small.** The wafer.space PDK clone includes `gf180mcu_fd_ip_sram__sram{64,128,256,512}x8m8wm1` — 5V-compatible (has `_5v00` corners), but the largest is 512×8 (512 bytes). Reaching 8 KB requires 16 macros and a comparably bigger floorplan; 4 KB across 8 macros is the natural fit.

3. **The reduced-RAM path also reduces software compatibility.** Going to 4 KB on-die makes even more C64 software unusable than the already-aggressive 8 KB cut in ADR 0003.

### Why external PSRAM works

- **Pin budget.** Our 1×1 slot exposes 40 bidir + 12 input pads. Current chip_core uses 33 bidir + 0 input. QSPI PSRAM needs 6 pads: `CS#, SCK, SIO[3:0]`. That fits with 1 bidir pad to spare and 12 unused input pads still available for debug.
- **Bandwidth.** QSPI at 32 MHz SCK × 4 bits = 16 MB/s peak. The C64 CPU at ~1 MHz × 1 byte/cycle = 1 MB/s required. 16× margin.
- **Latency.** A QSPI fast-read = ~15 SCK cycles (cmd + 24-bit addr + wait + data). At 32 MHz SCK that's ~470 ns, well inside one CPU cycle (1 µs at 1 MHz).
- **Density.** Commodity APS6404L / IS66WVS chips ship at 8 Mbit (1 MB) to 64 Mbit (8 MB). Full 64 KB C64 memory map fits with vast headroom; real C64 software runs.
- **OSS controllers available.** LiteSPI's PSRAM driver, ZipCPU's qspiflash family, and several TinyTapeout cores cover this protocol. The protocol is simple enough (~150 lines of Verilog) that rolling our own is also tractable.
- **Voltage tolerance.** Many PSRAMs are 3.3V parts with 5V-tolerant inputs (or run from a board-side level shifter); the wafer.space test board choice doesn't constrain the chip decision until we cut the PCB.

## Decision

1. **Main RAM (64 KB) moves off-die** to a board-level QSPI PSRAM accessed through a `qspi_psram_ctrl` module instantiated inside `chip_core` (between `c64_system`'s `ramAddr`/`ramDin`/`ramDout` ports and the pad ring).

2. **Pad allocation** (additions to `chip_core.sv`):

   | Pad index | Signal | Direction |
   |-----------|--------|-----------|
   | bidir[33] | `psram_cs_n` | output |
   | bidir[34] | `psram_sck`  | output |
   | bidir[35] | `psram_sio0` | bidir |
   | bidir[36] | `psram_sio1` | bidir |
   | bidir[37] | `psram_sio2` | bidir |
   | bidir[38] | `psram_sio3` | bidir |
   | bidir[39] | spare        | — |

3. **Drop on-die SRAM** entirely: remove the `sram_wrapper` instantiation, the OCD macro IP dep, the `MACROS:` SRAM entries, the SRAM PDN block, and the `USE_SRAM_MACROS` define. `src/sram_wrapper.sv` is retired (or left as a stub).

4. **ROMs stay on-die** as synthesized LUT logic (KERNAL, BASIC, CHARGEN) — see ADR 0003 §2–4. They are not affected by this pivot.

5. **Color RAM stays on-die** as flops (1024 × 4 bits → 512 B equivalent) — ADR 0003 §5 unchanged.

6. **Controller spec**:
   - Single 24-bit byte address (16 MB max, although we only use 64 KB).
   - SDR for the first revision (50 MHz max SCK); DDR optional later.
   - Always-fast-read mode; no quad-write optimization (write throughput is fine at 1-bit).
   - Initialization: enter quad mode on reset via `0x35` command, then `0x0B` (fast read) / `0xEB` (quad fast read).
   - Bus handshake to `c64_system`: present `ramDin` valid one CPU cycle after `ramCE` asserts with R/W=1; sample `ramDout` on `ramWE` rising edge.
   - Sequencer integration: the existing 32-state cycle sequencer in `c64_system` already gates CPU access into ~1 MHz timing. Schedule the QSPI transaction to start at the beginning of each CPU cycle and complete before the CPU's data-sample edge.

7. **Floorplan rework**:
   - SRAM rectangle in the right half of the core area becomes free routable space.
   - Estimated core area: drops from ~12.9 mm² (current) to whatever the standard-cell logic actually wants. Re-tighten `DIE_AREA` and `PL_TARGET_DENSITY_PCT` after a placement pass.

8. **Test board** (out of scope for this ADR — see phase-2 plan): QSPI PSRAM chip + 5V↔3.3V level shift on SIO/SCK/CS# if not using a 5V-tolerant PSRAM.

## Alternatives considered

- **16 × 5V `sram_fd_ip__sram512x8m8wm1` for 8 KB on-die** — rejected because (a) doubles the floorplan SRAM footprint and the PDN tuning surface, (b) bumps us into level-7 KLayout DRC territory test-tapeout-1 already hit, (c) we still don't get full C64 memory.

- **HyperRAM** — sound technically (≈11 pins, faster). Rejected because QSPI PSRAM (a) needs fewer pins, (b) has materially more OSS controller IP, (c) needs only single-ended I/O at our speeds (no LVDS pair routing on the test board).

- **Synthesized 64 KB register file** — rejected because 64 KB × 8 = 524288 flops, well beyond the current 70K-DFF synth-test footprint, and area-uneconomical when QSPI PSRAM exists.

- **Reduce scope to 2 KB on-die SRAM** — rejected because 2 KB doesn't run anything more useful than 4 KB; if we're cutting we should cut to 0 KB and embrace external RAM.

## Consequences

- **C64 software compatibility goes from 8 KB-limited (ADR 0003) to full 64 KB.** Real KERNAL boot-up traces through correctly. BASIC immediate-mode programs run. Standard C64 test programs (e.g. screen-fill, sprite demos, character-set tests) work.

- **Read latency rises** from ~1 cycle (on-die SRAM) to ~15 SCK cycles (470 ns at 32 MHz SCK). The CPU cycle budget absorbs this comfortably (1 µs at 1 MHz CPU).

- **Test board complexity** — the chip is no longer self-contained for memory bring-up. Bringing the chip up at wafer.space means having the PSRAM populated on the test board *before* the silicon arrives. Mitigation: add a JTAG-style backdoor to preload PSRAM via the same pads when CS#/SCK can be host-driven (out of scope for the ADR; will go in phase-2 plan).

- **PnR converges cleanly.** No in-die SRAM macros means no SRAM PDN tuning, no macro-placement constraints. RePlAce should pass. KLayout DRC should pass without the M3.2b wide-metal SRAM workaround.

- **Test latency**: cocotb sim needs a PSRAM model. We'll vendor or write a `psram_bfm.v` that responds to the QSPI command set.

- **Area win for the chip itself** — even if our overall area is constrained by the slot, we get back the right-side core area that was reserved for the 8 SRAM macros (~7×484 µm × 4-wide = ~13700 µm² × 8 macros = 110000 µm² gross, minus halos).

## Walk-back options

- **PSRAM controller drops out** — we still have ~33500 µm² of free core area. Fall back to the foundry 4 KB SRAM array (8 × `sram_fd_ip__sram512x8m8wm1`) for a chip-only memory floor.

- **PSRAM too slow at signoff timing** — drop to single-line SPI (read mode `0x03`). Halves the data lanes to 1, but we have so much CPU-cycle headroom it still works at 32 MHz SCK.

- **5V-3.3V level shift annoying on the test board** — pick a 5V-tolerant PSRAM up front (some `IS66WV…` parts are spec'd 5V-tolerant on all I/O).

## Links

- [ADR 0001 — system scope](0001-system-scope-and-clock.md)
- [ADR 0003 — memory architecture (superseded by this ADR for main RAM)](0003-memory-architecture.md)
- `docs/plans/phase-2.md` — workstreams to execute this pivot
- `src/qspi_psram_ctrl.sv` — controller module (to be written)

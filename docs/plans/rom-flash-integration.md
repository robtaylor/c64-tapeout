# Plan — External flash ROM integration (phase-2 WS-P2-10)

**Status:** Active (2026-07-06). Implements [ADR 0005](../adr/0005-external-flash-roms.md): move KERNAL/BASIC/CHARGEN off-die to an external QSPI NOR flash sharing the PSRAM bus. Unblocks WS-P2-3 routing (the LUT ROMs are the congestion source) and is a prerequisite to a clean signoff.

## Goal

Delete the 20 KB of LUT-synthesized ROMs and serve KERNAL/BASIC/CHARGEN from an external QSPI flash on the shared QSPI bus (second chip-select on bidir[39]), with an on-die prefetch buffer so the sequential fetch stream stays cheap. Keep color RAM synthesized (1024×4 flops), bulk RAM in PSRAM, ZP/stack in the on-die 5V SRAM.

## Design (grounded against the RTL)

**Bus topology (ADR 0005 §2).** Shared QSPI: SCK = bidir[34], SIO[3:0] = bidir[35..38] (shared with PSRAM); CS_psram = bidir[33]; **CS_flash = bidir[39]** (last spare pad — budget now fully consumed). One PULP serial engine, two chip-selects, arbitrated.

**Controller (ADR 0005 §3 + 2026-07-07 amendment).** Extend `qspi_psram_ctrl` with:
- a flash chip-select + a **read-only `0xEB` QPI quad read** — the flash is a read-only PSRAM on CSN1, reusing the engine's existing quad stimulus (the amendment resolved single-I/O `0x0B` → QPI `0xEB`: the PULP engine is single/quad-only, and a 1.5 µs single read overruns the CPU cycle where a 0.5 µs QPI read fits). Requires a QPI-capable NOR flash + QE bit at provisioning + an enter-QPI init on CSN1 mirroring the PSRAM's `0x35`;
- an **arbiter** that serializes PSRAM (RAM) and flash (ROM) requests onto the single engine — RAM and ROM are never needed on the same SCK, but VIC (CHARGEN) + CPU (instruction fetch + RAM) can contend within a cycle, so arbitration covers the worst case (re-measure in integrated sim, as with the PSRAM early-trigger).

**ROM prefetch buffer (ADR 0005 §4).** Small on-die buffer (a cache line or two) fed by sequential flash reads. Instruction fetch and CHARGEN reads are sequential, so a hit serves in-cycle and only line-fill pays the QSPI latency. Design alongside the VIC c-access line-buffer (the deferred WS-P2-2 task 5) — same mechanism.

**Bus logic (ADR 0005 §5).** `c64_buslogic` already produces `cs_kernal`/`cs_basic`/`cs_chargen`. Route those reads to the flash ROM port (with a KERNAL/BASIC/CHARGEN base-offset map into the flash address space) instead of the deleted on-die ROM data ports. `dataToCpu` mux (`c64_buslogic.vhd:82-105`) and `dataToVic` (chargen) source from the flash path.

**Boot.** Gate CPU release until both the flash and PSRAM controllers have completed init, so the first reset-vector fetch ($FFFC/$FFFD → KERNAL → flash) returns valid data.

## Tasks (dependency order)

1. **Flash read path in the controller.** ✅ *Done (QPI `0xEB`, commit 3f8e921).* Flash CS + read-only `0xEB` QPI read (reusing the quad stimulus) + flash enter-QPI init on CSN1 + two-device arbiter in `qspi_psram_ctrl`. `make sim-qspi` 6/6 with a read-only QPI flash BFM (`QspiFlashModel(QspiPsramModel)`).
2. **ROM prefetch buffer.** *Deferred (optimization, not load-bearing — the 0.5 µs QPI read fits the cycle; ADR 0005 amendment).* On-die line buffer for sequential flash reads. **This is where the VIC CHARGEN path gets wired to issue its own flash reads (today it reads the controller's held `romDout`), finally exercising the worst-case CPU+VIC concurrency the arbiter is built for.** Co-design with the VIC c-access buffer.
3. **`chip_core.sv` wiring.** ✅ *Done (commit ca3f2c7).* Flash port + `init_done` wired; `cs_flash_n` at bidir[39]; `rom_kernal`/`rom_basic`/`rom_chargen` instances deleted (`.sv` files remain until task 6).
4. **`c64_buslogic` / `c64_system` ROM data routing.** ✅ *Done (commit ca3f2c7).* Single `romData` byte selected by the existing `cs_*` decode; early ROM trigger at `CYCLE_EXT0` (mirrors `psramCE`); flash offset map KERNAL@0x000000 / BASIC@0x002000 / CHARGEN@0x004000. ROM PLA decode unified via `cpu_rom_region()`.
5. **Boot gating.** ✅ *Done (commit ca3f2c7).* Controller `init_done`; C64 core held in reset until `qspi_init_done` (both enter-QPI passes complete).
6. **Cleanup.** Remove `src/rom_kernal.sv`, `src/rom_basic.sv`, `src/rom_chargen.sv`; update `rtl.f`, the Makefile synth-test list, `librelane/config.yaml` VERILOG_FILES, and CLAUDE.md ("ROMs synthesized as LUTs" → external flash). **⚠ Landmine:** `chip_core_tb.py`'s `extract_rom_bytes()` parses the generated `rom_*.sv` for the flash BFM images — deleting those files breaks `sim-smoke`. Task 6 must first repurpose `scripts/mif2rom.py` (or a sibling) to emit a checked-in flat ROM-image fixture that both the test and flash-provisioning consume, *then* delete the `.sv`.
7. **Re-run PnR.** `make librelane-pdn` — with the LUT ROMs gone from the hierarchy, GlobalRouting should converge (this is the whole point). Needs the task-6 `config.yaml` source-list update first, plus SDC/pin constraints for the new `cs_flash_n` at bidir[39]. Then trace to signoff.
8. **Cosim.** Add the flash model to the Jacquard cosim (it already models QSPI flash) alongside PSRAM; replay through the post-PnR netlist (WS-P2-6).

## Exit criteria

- `make synth-test` clean; core logic mass drops sharply (no 20 KB mux trees).
- `make sim-smoke` boots: reset vector + KERNAL fetched from the flash BFM; RAM from PSRAM; ZP/stack on-die; color RAM in flops.
- `make librelane-pdn` **routes to completion** (the congestion that blocked WS-P2-3 is gone).

## Links

- [ADR 0005 — external QSPI flash ROMs (shared bus)](../adr/0005-external-flash-roms.md)
- [ADR 0004 — external QSPI PSRAM + ZP/stack](../adr/0004-external-qspi-psram.md)
- [memory-integration.md](memory-integration.md) — PSRAM early-trigger + VIC line-buffer (the prefetch mechanism this shares)
- [tapeout roadmap](tapeout-roadmap.md)

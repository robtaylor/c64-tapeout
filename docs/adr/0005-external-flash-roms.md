# ADR 0005 — External QSPI flash for ROMs (shared bus), supersedes synthesized ROMs (ADR 0003)

**Status:** Accepted (2026-07-06). Supersedes the **synthesized-ROM** decision of [ADR 0003](0003-memory-architecture.md) (KERNAL/BASIC/CHARGEN as combinational `case` logic). Extends the external-QSPI approach of [ADR 0004](0004-external-qspi-psram.md) — the ROMs join the bulk RAM off-die, sharing one QSPI bus.

**TL;DR.** In the context of taping out a C64 subset on GF180MCU 9T 5V, having moved bulk RAM off-die to QSPI PSRAM (ADR 0004), we found the three ROMs (KERNAL 8 KB + BASIC 8 KB + CHARGEN 4 KB = 20 KB) still synthesized as LUT `case(addr)` mux trees per ADR 0003 — an enormous, densely-interconnected block that makes the core **unroutable** (GlobalRouting churned 3+ hrs of CPU without converging; congestion 1.25 driven almost entirely by the ROM mux fabric). GF180 has **no ROM IP** and SRAM-as-ROM would need ~40 macros plus a boot-load path, so we move the ROMs to an **external QSPI NOR flash sharing the existing QSPI bus** (one added chip-select on the last spare pad), read through the same serial engine with a small on-die prefetch buffer to amortize the sequential instruction/character fetches.

## Context

- **Root problem.** `rom_kernal.sv` (8192×8), `rom_basic.sv` (8192×8), `rom_chargen.sv` (4096×8) are auto-generated `case(addr)` ROMs (`scripts/mif2rom.py`, ADR 0003). 20 KB of constant data becomes tens of thousands of gates of mux tree. After the ADR 0004 pivot moved RAM off-die, these ROMs were never re-examined and are now the dominant logic mass and the sole cause of the WS-P2-3 routing congestion (verified: PnR reaches GlobalRouting and cannot converge; the placement/CTS/STA stages all pass once the SRAM-macro PDN and clock are fixed).
- **No on-die ROM option.** The gf180mcuD PDK ships only `gf180mcu_fd_ip_sram` (64/128/256/512 ×8). There is no ROM compiler. Building 20 KB from 512×8 SRAM = ~40 macros (huge floorplan in a 1×1 slot) **and** SRAM is volatile, so it would need a boot-time load mechanism anyway — i.e. an external ROM source regardless.
- **Pad budget.** PSRAM already occupies bidir[33..38] (CS#, SCK, SIO[3:0]). Exactly **one** bidir pad remains free (bidir[39]). A second independent QSPI (6 pads) does not fit; a shared bus needs only +1 CS pad — which is exactly what is available.
- **Cosim alignment.** Jacquard's cosim models a QSPI **flash** peripheral (the `qspi_ram` model was built by extending flash — see the jacquard-qspi-cosim history). External-flash ROMs are therefore directly representable in the post-PnR Jacquard cosim (WS-P2-6).

## Decision

1. **ROMs move to an external QSPI NOR flash** (e.g. W25Q-class). KERNAL, BASIC and CHARGEN images are programmed into flash at known base offsets. `rom_kernal.sv` / `rom_basic.sv` / `rom_chargen.sv` and the `mif2rom.py` LUT path are **removed**.
2. **Shared QSPI bus, second chip-select.** Flash shares SCK (bidir[34]) and SIO[3:0] (bidir[35..38]) with the PSRAM; add **CS_flash on bidir[39]** (the last spare). PSRAM keeps CS on bidir[33]. Total QSPI = 7 pads; **pad budget fully consumed**.
3. **Read-only fast-read path** in the QSPI controller. Extend `qspi_psram_ctrl` (or a thin sibling) with a flash chip-select and a read-only fast-read command (0x0B or 0xEB quad); no write/erase/program. A small arbiter serializes PSRAM and flash accesses onto the single serial engine.
4. **On-die ROM prefetch / line-buffer.** ROM fetches are continuous (CPU instruction fetch from KERNAL) and largely **sequential**, so a small prefetch buffer amortizes the ~500 ns per-access QSPI latency to near-zero per-byte. This buffer is **load-bearing** here (unlike the VIC c-access buffer, which was a badline optimization) and is designed together with it.
5. **`c64_buslogic` routes the ROM regions to the flash path.** The existing `cs_kernal`/`cs_basic`/`cs_chargen` decodes are unchanged; their read data now comes from the flash controller's ROM port instead of the on-die ROM data ports. The address→flash-offset mapping (KERNAL/BASIC/CHARGEN base offsets) lives in the flash ROM path.
6. **Unchanged:** bulk 64 KB RAM stays external PSRAM (ADR 0004); ZP/stack stays 2× on-die 5V `sram256x8` (ADR 0004 §9); **color RAM stays synthesized** as 1024×4 flip-flops (`spram`). The only synthesized memory remaining is the 512 B-equivalent color RAM — matching the intended "1K×4 synthesized + PDK/external for everything else".

## Consequences

- **Routability restored.** Deleting the 20 KB LUT-ROM fabric removes the dominant congestion source; the core becomes near-cells-only + 2 small SRAM macros. This is the fix for the WS-P2-3 GlobalRouting non-convergence.
- **Controller grows a flash path + arbiter.** The single PULP serial engine now serves two devices; PSRAM and flash accesses serialize. The prefetch buffer keeps the common case (sequential fetch) cheap; worst-case concurrency (VIC CHARGEN fetch + CPU RAM + CPU instruction fetch in one cycle) needs the timing budget re-checked in integrated sim, same discipline as the PSRAM early-trigger.
- **Boot.** The flash controller must complete init and be ready before the CPU's first reset-vector fetch from KERNAL ($FFFC/$FFFD). Reset sequencing must gate the CPU until flash + PSRAM are ready.
- **Board / deliverable.** Adds a QSPI NOR flash chip and a step to program the C64 ROM images into it. Pad budget is now fully allocated — no further external interfaces without reclaiming pads.
- **Cosim.** WS-P2-6 gains a flash model alongside the PSRAM model; both replay through the same bus in the Jacquard post-PnR cosim.

## Alternatives considered

- **Keep synthesized ROMs (ADR 0003).** Rejected — the definitive cause of unroutable congestion; 3+ hrs GRT without convergence.
- **On-die ROM as SRAM macros.** Rejected — ~40 `sram512x8` macros for 20 KB (no room in the 1×1 slot) and still volatile → needs an external load path regardless. No GF180 ROM IP exists.
- **Separate QSPI interface for flash.** Rejected — needs 6 pads; only 1 bidir pad is free.
- **Strip BASIC (ADR 0003 escape hatch).** Rejected — KERNAL + CHARGEN (12 KB) still congest, and it loses BASIC. A partial, non-cosim-aligned mitigation.

## References

- [ADR 0003 — Memory architecture (synthesized ROMs, now superseded here)](0003-memory-architecture.md)
- [ADR 0004 — External QSPI PSRAM + ZP/stack carve-out](0004-external-qspi-psram.md)
- WS-P2-3 PnR bring-up (commit bc0ccc5): SRAM-macro PDN + clock fixed; GlobalRouting congestion traced to the LUT ROMs.
- Implementation plan: [`docs/plans/rom-flash-integration.md`](../plans/rom-flash-integration.md)

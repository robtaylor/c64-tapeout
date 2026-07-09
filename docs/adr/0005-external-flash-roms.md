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
3. **Read-only QPI fast-read path** in the QSPI controller. Extend `qspi_psram_ctrl` with a flash chip-select and a read-only **`0xEB` quad read with the flash in QPI mode** — i.e. the flash is treated as a read-only PSRAM on CSN1, reusing the engine's existing quad stimulus (see the 2026-07-07 amendment for why QPI over single-I/O `0x0B` and dual-I/O). No write/erase/program. A small arbiter serializes PSRAM and flash accesses onto the single serial engine. Requires a **QPI-capable NOR flash** (e.g. W25Q…-QPI class) with its QE bit set at provisioning; the controller sends an enter-QPI init on CSN1 at boot, mirroring the PSRAM's `0x35` on CSN0.
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

## Amendment (2026-07-07) — flash read mode: QPI `0xEB`, not single-I/O `0x0B`

Decision §3 originally left the flash read command open ("0x0B or 0xEB quad"). WS-P2-10 task 1 first implemented single-I/O `0x0B`; measuring it against the timing budget, and checking what the vendored PULP engine can actually drive, resolved the choice to **QPI `0xEB`**.

**The vendored PULP engine is single-lane or quad-lane only — no dual.** Verified in `ip/pulp/spi_master_tx.sv:42,85` / `spi_master_rx.sv`: the shift datapath is a hard binary choice (`en_quad ? data_int[28] : data_int[31]`, shifting 4 bits or 1 bit); `en_quad` (`spi_master_controller.sv:96`) is a single boolean spanning the whole transaction; mode encodings are only `SPI_STD` / `SPI_QUAD_TX` / `SPI_QUAD_RX`. So the engine's "quad" is effectively **QPI** (command *and* address *and* data all 4-lane) — it cannot do the mixed-lane NOR reads (`0x6B` quad-output, or `0xEB` QIO-from-standard-SPI where the command stays single-lane).

Per-single-byte read cost at 32 MHz SCK (31.25 ns/cycle), phases as `bits×lanes`:

| Read command | cmd | addr | dummy | data | SCK | time | on this engine? |
|---|---|---|---|---|---|---|---|
| `0x0B` Fast Read (single-I/O) | 8×1 | 24×1 | 8 | 8×1 | 48 | 1.50 µs | ✓ native (std) |
| `0xBB` Dual I/O | 8×1 | 12×2 | 4 | 4×2 | 28 | 0.88 µs | ✗ no dual mode |
| `0x6B` Quad Output | 8×1 | 24×1 | 8 | 2×4 | 42 | 1.31 µs | ✗ mixed-lane |
| `0xEB` Quad I/O (from std SPI) | 8×1 | 6×4 | 6 | 2×4 | 22 | 0.69 µs | ✗ engine sends cmd quad |
| **`0xEB` in QPI mode (chosen)** | 2×4 | 6×4 | 6 | 2×4 | **16** | **0.50 µs** | ✓ native (needs QE bit) |

**Why QPI `0xEB`:** a single un-buffered `0x0B` read is **1.5 µs — longer than one ~1 MHz CPU cycle** (~1 µs), so the PSRAM early-trigger trick (fire at cycle start, close before the CPU sample) that works for the PSRAM's 0.5 µs `0xEB` quad read *cannot* close a 1.5 µs flash read within a cycle. Single-I/O would therefore force either a CPU stall or a *mandatory* prefetch buffer. QPI `0xEB` costs the same **16 SCK = 0.5 µs** as the PSRAM read (the address phase drops from 24 single-lane SCK to 6 quad SCK — that phase is what dominates a single-byte read), fits inside a CPU cycle, and reuses the engine's existing quad stimulus almost verbatim (a read-only PSRAM on CSN1). This makes the prefetch buffer (§4) an **optimization rather than a necessity**.

**Cost:** the flash must be a QPI-capable NOR part with QE set at provisioning, and boot sends a second enter-QPI init on CSN1. QPI NOR flash is common and QE is a provisioning-time register write done when the ROM image is programmed, so this is a mild constraint. This supersedes the "buffer is load-bearing" wording in §4 — with QPI reads the buffer is valuable (3× faster line-fills, sequential hits served in-cycle) but no longer required for correctness; confirm with integrated sim.

**Rejected read-mode alternatives:**
- **Single-I/O `0x0B`.** Rejected — 1.5 µs/read overruns the CPU cycle; would mandate a prefetch buffer and still stress the VIC CHARGEN window.
- **Dual-I/O `0xBB` / `0x3B`.** Rejected — the PULP engine has no 2-lane datapath; would require patching the vendored tx/rx shift logic for a mediocre 0.88 µs.
- **Mixed-lane `0x6B` / `0xEB`-QIO-from-SPI.** Rejected — the engine drives the command quad in quad mode, so only a fully-QPI flash matches it.
- **XIP / continuous-read mode (M7–M0).** Rejected as separate work — its only saving is the command byte on back-to-back reads, which the on-die prefetch buffer (§4) already amortizes by sending command+address once per line-fill; it adds mode-bit protocol state for redundant benefit.

## Amendment (2026-07-09) — WS-P2-10 timing closure: QSPI outputs are source-synchronous; slow-corner CS setup is an accepted risk

Closing STA on the flash-ROM design (WS-P2-10 task 7) surfaced a setup WNS of
**−3.4 ns on the two chip-select pads** (`cs_flash_n`@bidir[39], `cs_psram`
@bidir[33]), 10 violating endpoints, *all in the slow corners* (`ss_125C_4v50`);
`tt`/`ff` were clean. The path is a ~9-gate combinational decode of the QSPI
controller/engine state to the CS pad. Two things were learned resolving it:

**1. The QSPI outputs are a source-synchronous interface and must not be timed
against the internal clock.** CS and SIO are latched by the external APS1604M
PSRAM on the *emitted SCK*, not on `clk_PAD`. The stock 20%-of-period
(`output_delay` = 3.125 ns) blanket against `clk_PAD` is the wrong model. The
honest constraint uses the device's real AC specs (APS1604M-3SQR v3.1: tCSP =
2.5 ns CS setup, tCHD = 3.0 ns CS hold, tSP/tHD = 2 ns data). Because SCK =
`clk_PAD`/2 with rising edges *coincident* with `clk_PAD` edges, this reduces to
a single-cycle `clk_PAD` path with `output_delay` = the device setup — see
`librelane/chip_top.sdc`. (Modelling SCK as a divided generated clock *at the
pad* was tried and rejected: it injects the SCK-pad insertion delay as ~3.3 ns of
false launch/capture skew → bogus hold violations, RUN_2026-07-09_01-18-14.)

**2. Under the correct model there is a real, small, slow-corner-only CS setup
miss (~2.5 ns) — accepted and documented, not fixed in silicon.** The controller
FSM asserts CS and enables SCK in the *same* cycle (`spi_master_controller.sv`
IDLE), and the clkgen's first SCK rise lands on the *next* `clk_PAD` edge, so CS
has exactly one 15.6 ns cycle (minus tCSP) to settle. The combinational decode →
pad measures ~15.6 ns in `ss_125C_4v50`, so CS cannot beat the first 32 MHz SCK
edge when 125 °C + 4.5 V + slow silicon coincide. `nom`/`tt`/`ff` all pass.
Registering CS in RTL to make it a clean flop→pad was tried and **corrupts the
protocol** — CS leads SCK by <1 cycle, so a 1-cycle register delay eats the whole
lead (verified: `make sim-qspi` 0/6). Sign-off is therefore taken at the typical
(`tt`) corners (`TIMING_VIOLATION_CORNERS: ["*tt*"]`), with the ss-corner CS
marginality accepted. **This risk is real but bounded to the worst PVT corner.**

Candidate fixes if the ss corner must be closed later (deferred):
- **16 MHz SCK** (`CLK_DIV=1`) — first SCK edge moves out one cycle, giving CS
  ~31 ns; but the quad read doubles to ~1 µs and likely overruns the CPU cycle
  (contra the §Amendment-2026-07-07 budget) — needs re-measuring first.
- **Register `csreg`/flash-select** in the controller to shorten the CS decode
  tail (csreg is stable well before the transaction, so this does not disturb
  CS-vs-SCK phasing) — keeps 32 MHz; may or may not fully close ss.
- **Full source-synchronous CS pipeline** — robust flop→pad CS, but needs the
  FSM to assert CS a cycle earlier and careful RX-turnaround handling.

**Coupled decision — IO voltage.** The APS1604M is a 3.0–3.6 V part; the GF180 IO
sign-off corners here are 4.5–5.5 V. Whether we use external level shifters (adds
shifter propagation delay into the tCSP/tSP budget) or run the GF180 IO
under-voltage at 3.3 V (invalidates the 4.5–5.5 V pad characterisation — pads are
slower, so 5 V-corner STA is optimistic) **re-scopes this CS budget**. Tracked in
[spike: QSPI IO voltage](../spikes/qspi-io-voltage.md) and
[ADR 0006](0006-qspi-io-voltage-domain.md); the ss-corner acceptance above is
provisional on that outcome.

## References

- [ADR 0003 — Memory architecture (synthesized ROMs, now superseded here)](0003-memory-architecture.md)
- [ADR 0004 — External QSPI PSRAM + ZP/stack carve-out](0004-external-qspi-psram.md)
- WS-P2-3 PnR bring-up (commit bc0ccc5): SRAM-macro PDN + clock fixed; GlobalRouting congestion traced to the LUT ROMs.
- Implementation plan: [`docs/plans/rom-flash-integration.md`](../plans/rom-flash-integration.md)

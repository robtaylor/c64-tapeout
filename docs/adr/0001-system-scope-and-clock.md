# ADR 0001 — System scope and clock: T65 CPU + VIC-II + CIA at 32 MHz

**Status:** Accepted (2026-05-26); clock amended 2026-07-06 (64 MHz pad ÷2 to the 32 MHz core; see the [2026-07-06 amendment](#decision)). Memory (item 3) superseded by [ADR 0003](0003-memory-architecture.md) → [ADR 0004](0004-external-qspi-psram.md) (bulk RAM) and [ADR 0005](0005-external-flash-roms.md) (ROMs); see the [2026-07-17 memory amendment](#decision) below. Real-C64 clock comparison appended 2026-07-17.

**TL;DR.** In the context of taping out a C64 subset on GF180MCU (1×1 slot), facing severe area constraints (~20 mm²), we chose to include T65 CPU + VIC-II + 1× CIA on a single clock domain, accepting a C64 *subset* test chip rather than a full machine. The clock settled at **32 MHz** (a 64 MHz pad ÷2; originally specified ~8 MHz — see the clock amendments), and the memory — originally 8KB on-die SRAM + synthesized LUT ROMs — moved **off-die to QSPI PSRAM + flash** ([ADR 0004](0004-external-qspi-psram.md) / [ADR 0005](0005-external-flash-roms.md)), restoring the full 64 KB map.

## Context

The full C64 has 64KB RAM + 20KB ROM + SID + 2× CIA + VIC-II + CPU. On GF180MCU:
- Each OCD SRAM macro (sram1024x8m8wm1) provides 1KB
- A 1×1 slot has ~20 mm² total die area
- The reference Hazard3 tapeout used 16 SRAM macros at 35% density
- 85 SRAM macros for full C64 memory is infeasible in 1×1

The C64 system clock architecture: a master oscillator (PAL: 17.73 MHz, NTSC: 14.32 MHz) feeds the VIC-II which generates the dot clock (~8 MHz), and the CPU runs at dot_clock/8 (~1 MHz). The fpga64_sid_iec module implements a 32-state cycle sequencer on a ~32 MHz clock in the MiSTer version.

GF180MCU 9T cells at TT/25°C can close timing at 25 MHz comfortably (proven by test-tapeout-1). The C64's 8 MHz dot clock is well within this envelope.

## Decision

1. **Scope**: T65 6510 CPU + VIC-II (video_vicII_656x) + 1× MOS6526 CIA + bus logic (fpga64_buslogic) + color palette + color RAM.
2. **Excluded**: SID (sound), second CIA, cartridge port, IEC serial, tape, REU.
3. **Memory** *(superseded — see the [2026-07-17 amendment](#decision) below)*: originally 8 × OCD SRAM (8KB main RAM) + KERNAL/BASIC/CHARGEN as synthesized LUT ROMs + synthesized color RAM. The design is now hybrid external QSPI + on-die ZP/stack SRAM + external flash ROMs ([ADR 0004](0004-external-qspi-psram.md) / [ADR 0005](0005-external-flash-roms.md)); only the synthesized **color RAM** survives.
4. **Clock**: Single clock domain at 32 MHz. The MiSTer's 32-state cycle sequencer runs at this frequency, producing ~8 MHz effective pixel rate and ~1 MHz effective CPU rate. GF180 9T cells handle 32 MHz comfortably (31.25 ns period vs test-tapeout-1's 40 ns at 25 MHz). No PLL needed — external oscillator feeds the clock pad directly.

**Amendment (2026-05-26):** Originally specified ~8 MHz, but the proven cycle sequencer from fpga64_sid_iec requires 32 MHz. Changing pixel rate would require rewriting VIC-II line timing. 32 MHz is well within GF180 capability.

**Amendment (2026-07-06):** The clock pad is now 64 MHz, and a single on-chip flip-flop divides it by two to produce the 32 MHz sequencer clock. The 32 MHz core (1 MHz CPU, cycle sequencer) is unchanged; the extra 64 MHz clock exists only to run the [ADR 0004](0004-external-qspi-psram.md) QSPI PSRAM controller at the frequency it needs for a 32 MHz SCK (`f_sck = f_clk / (2·(CLK_DIV+1))`, so 32 MHz SCK requires a 64 MHz controller clock). "Single clock domain at 32 MHz" in item 4 becomes two synchronous domains derived from one pad: a 2× multiple, so the 32 MHz signals the controller samples are stable across both 64 MHz edges and no asynchronous CDC synchronisers are needed. Still no PLL — the external oscillator feeds the 64 MHz pad, and the ÷2 flop is the only clocking logic. Rationale and the sequencer early-trigger scheme this enables are in `docs/plans/memory-integration.md`.
5. **CIA selection**: CIA1 (keyboard matrix scanner, timer A/B, IRQ generation). CIA2 (VIC bank select, serial bus) excluded; VIC bank hardwired to bank 0.

**Amendment (2026-07-17) — memory (item 3 and its consequences) superseded.** The on-die-8KB-SRAM + synthesised-LUT-ROM scheme in item 3 no longer holds. The hybrid memory architecture replaces it:

- **Bulk 64 KB RAM** lives off-die in external QSPI PSRAM (APS1604M) via `qspi_psram_ctrl`. [ADR 0003](0003-memory-architecture.md) chose the on-die/off-die split; [ADR 0004](0004-external-qspi-psram.md) committed to QSPI PSRAM after a 5 V-SRAM-vs-cell-library mismatch killed the on-die-64KB path.
- **On-die SRAM** is now only the zero-page/stack region ($0000–$01FF) = 2× `gf180mcu_fd_ip_sram__sram256x8m8wm1`, kept on-die for single-cycle CPU access.
- **KERNAL/BASIC/CHARGEN ROMs** are no longer synthesised as combinational LUTs — they live in external QSPI flash on the shared bus (CSN1, `0xEB` QPI read), image built by `scripts/build_flash_image.py`. See [ADR 0005](0005-external-flash-roms.md); the LUT-ROM RTL sources were deleted (WS-P2-10).
- **Color RAM** (1 KB × 4-bit) stays as flops, as originally specified.

So RAM is now a full 64 KB (external, not the original 8 KB) and the ROMs are a re-flashable flash image (not compile-time constants); the now-obsolete "8KB RAM" / "compile-time ROM" consequences and on-die-SRAM alternatives have been removed from the sections below (their history lives in ADR 0003/0004/0005). The **clock decision (item 4) is unaffected** — indeed the 64 MHz pad domain exists *because* of this external-QSPI memory: a 32 MHz SCK needs a 64 MHz controller clock (`f_sck = f_clk / (2·(CLK_DIV+1))`).

## Alternatives considered

- **Full 64KB + 2×2 slot** — rejected because a full *on-die* memory would need ~85 SRAM macros and a much larger, more expensive die; this is a test chip proving the concept in a 1×1 slot. (Full 64KB was later achieved *off-die* — see [ADR 0004](0004-external-qspi-psram.md).)
- **No VIC-II (CPU-only)** — rejected because the VIC-II is the interesting part; a 6502 alone has been taped out many times.

Memory-sizing and on- vs off-die RAM alternatives (16KB on-die, external SPI/QSPI RAM) are owned by [ADR 0003](0003-memory-architecture.md) → [ADR 0004](0004-external-qspi-psram.md) — note that external RAM, rejected at first here, was later adopted there once the on-die 5V-SRAM path proved unviable.

## Consequences

- VIC-II bank is hardwired to $0000–$3FFF (bank 0): character data, screen RAM, and sprite data visible to the VIC must live in bank 0.
- The cycle sequencer from fpga64_sid_iec needs adaptation: strip SID/IEC logic, keep the VIC/CPU/bus timing state machine.
- CIA1's port A/B will map to pad I/O for keyboard matrix or general-purpose GPIO.

## Walk-back options

- **If VIC-II is too large for remaining area** — simplify to text-mode only (strip sprite logic, reduce to ~800 lines).
- **If GHDL-Yosys can't synthesize the VHDL cleanly** — convert VHDL to Verilog via GHDL --synth (one-time effort, ~4600 lines).

## Appendix — real C64 clock structure vs. this design

Recorded here because our single-clock-domain-plus-enables scheme (item 4) is a deliberate departure from how a physical C64 clocks itself, and understanding the original explains *why* the simplification is sound rather than lossy.

### Real C64 clock chain (reference)

How the physical machine generates its clocks (PAL figures unless noted):

- **Color clock** — crystal Y1 at 17.734472 MHz (PAL).
- **Pixel / dot clock** — ~7.88 MHz (PAL), generated from the color clock by the PLL in U32 (among other things). Nine color-clock edges correspond to four pixel-clock edges (PAL 9:4); the NTSC ratio is 7:4.
- **Φ0 (~1 MHz)** — an output from the VIC where the pixel clock ÷8 is present. Φ0 is at least one gate delay behind the pixel clock, has a 1:1 high/low ratio, and likely changes on the rising edge of the pixel clock.
- **Φ2** — Φ0 delayed by 30–40 ns (temperature-dependent) through the 6510. Φ2 is the main system clock. (Sources: Gideon Zweijtzer, CBM-Hackers list; Skoe, "Hardware layout of the C64", c64-wiki.de / Forum64.de, German.)

Bus timing relative to the phases:

- During Φ2=0 the VIC accesses the system; during Φ2=1 (mostly) the CPU does.
- The 6510 sets the address bus and R/W tADS=100–300 ns after the *falling* edge of Φ2 — but at that time the VIC-II holds AEC low, so address/data buses and R/W are under VIC-II control.
- Write cycle: the 6510 drives the data bus tMDS=150–200 ns after the *rising* edge of Φ2.
- Read cycle: the 6510 reads on the *falling* edge of Φ0. IRQ/NMI/RESET are read on the falling edge of Φ0; RDY on the rising edge.
- At the rising edge of Φ2 the address/data buses and R/W are not yet stable: the VIC releases AEC so late that the 6510 re-activates its outputs only very late. In practice the address bus is valid 60–75 ns after the positive Φ2 edge, and data at the latest by the falling edge ~400 ns later. Modules may assume a valid address bus ~160 ns after the positive Φ2 edge and valid data ~120 ns after that. Selected chips (RAM/ROM/…) must have put their data on the bus at the latest 370 ns after the positive Φ2 edge. In write accesses the 6510 pulls R/W low ~40 ns after the positive Φ2 edge, with write data valid ~40 ns later; the VIC-II reads CPU-written data well before the Φ2 falling edge. The PLA reacts to its inputs in ~20–40 ns. (Sources: Skoe, "C128 Expansion Port Timing", Forum64.de, German; comp.sys.cbm.)
- **Why the shifted phases exist:** from the 6510's perspective these shifted clock signals are necessary because the 6510 is built with *dynamic logic*, and with that technique consecutive latches cannot be toggled simultaneously due to potential race conditions.
- **Datasheet caveat:** in the 6510 datasheet Φ0 does not appear — Φ1 is named as the input clock instead. This is historical: on the 6502 Φ0 was the input, Φ1 was the slightly-delayed inverted output, and Φ2 was the opposite phase to Φ1 (short high when Φ1 is low). The 6510 exposes only one clock output.
- **TOD:** the CIAs' TOD timers are clocked separately via U27 from the mains-derived network clock (9 V AC), 50/60 Hz (except the SX64).

### How this tapeout differs

The physical machine is genuinely multi-phase — distinct clock nets (color, dot, Φ0, Φ1, Φ2) with sub-cycle timing relationships synthesised by analog means (the U32 PLL for the dot clock; RC/gate delays for the 30–40 ns Φ0→Φ2 shift). The two-phase, non-overlapping structure exists for one concrete reason: **the 6510 is dynamic logic**, so consecutive pass-transistor latches physically cannot be transparent at the same instant, and non-overlapping phases are required to avoid destroying stored charge.

Our T65 is a static-CMOS, edge-triggered reimplementation: every storage node is a real flip-flop that holds its value indefinitely. The entire *reason* for the multi-phase clock therefore evaporates — there is no dynamic-logic race to dodge — and a single rising edge plus clock *enables* is sufficient and correct. The phase relationships do not vanish; they are re-encoded as states of the 32-state sequencer running on the single 32 MHz `clk32`:

| Real C64 | This tapeout |
|---|---|
| Φ0 = dot ÷ 8 (~0.985 MHz PAL) | sequencer ÷32 enable → 1 MHz CPU beat; the 8:1 dot:Φ0 ratio **is preserved** |
| dot clock = color × 4/9 (PAL), ×4/7 (NTSC) — non-integer | **not preserved** — we start at a clean 32 MHz and take integer ÷4 → 8 MHz "pixel" beat |
| Φ2=0 → VIC owns the bus; Φ2=1 → CPU owns it | a phase bit / enable in `c64_buslogic` selecting who drives address/data — no AEC handoff race, because there is no shared tri-state bus, just a mux |
| Φ0→Φ2 delay 30–40 ns through the 6510 | does not exist — collapsed to zero; there is no separate CPU clock output to delay |
| CIA TOD clocked from 50/60 Hz mains (U27, 9 V AC) | `todclk`: a counter off `clk32` toggling at ~50 Hz — a synchronous digital approximation, **not** mains-locked |

What is faithfully reproduced is the *cycle-level* interleave (VIC in one half-cycle, CPU in the other) — that is exactly what the MiSTer sequencer encodes. What is discarded is the *sub-cycle analog timing* — tADS, tMDS, "address valid 60–75 ns after Φ2", "chips must present data ≤370 ns after Φ2". Those are continuous-time budgets against physically delayed edges; in a fully synchronous design there is no analog budget, only "does the path meet setup at the next 32 MHz edge", which STA checks statically. The color clock never enters our design at all — we are not generating a composite carrier; video is a digital tap.

**The one place the original's discipline returned:** the real machine's rule "selected chips must present data ≤370 ns after the positive Φ2 edge" is precisely the constraint we had to reconstruct, relocated. Our RAM/ROM is external QSPI with ~500 ns quad-read latency, so `c64_system` fires **early triggers** — PSRAM and ROM reads launch at the start of each sequencer period so the data lands before the CPU's sample point. That is our synthetic equivalent of the 370 ns data-valid deadline, at a coarser (~1 µs CPU-period) granularity. And the QSPI first-nibble setup race fixed in commit `dde3762` is the same *class* of hazard the C64's non-overlapping phases were designed to prevent — a launch and capture edge coinciding with zero setup — dodged here by deferring the SCK clock-enable rise one 64 MHz cycle instead.

## Links

- `docs/plans/archive/initial-core-bringup.md` — initial core bring-up (closed/archived)
- `docs/plans/tapeout-roadmap.md` — current tapeout roadmap; `docs/plans/memory-integration.md` — memory subsystem (clock, PSRAM, ZP/stack SRAM)
- ADR 0002 — VHDL synthesis strategy
- ADR 0003 — memory architecture and bus adaptation
- ADR 0004 — external QSPI PSRAM (bulk RAM; source of the 64 MHz domain)
- ADR 0005 — external flash ROMs (KERNAL/BASIC/CHARGEN)

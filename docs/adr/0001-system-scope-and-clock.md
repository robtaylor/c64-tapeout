# ADR 0001 — System scope: CPU + VIC-II + CIA + 8KB SRAM at ~8 MHz

**Status:** Accepted (2026-05-26); clock amended 2026-07-06 (64 MHz pad ÷2 to the 32 MHz core; see the [2026-07-06 amendment](#decision)). Memory (item 3) superseded by [ADR 0003](0003-memory-architecture.md) then [ADR 0004](0004-external-qspi-psram.md).

**TL;DR.** In the context of taping out a C64 subset on GF180MCU (1×1 slot), facing severe area constraints (~20 mm²), we chose to include T65 CPU + VIC-II + 1× CIA with 8KB SRAM and synthesized ROMs, targeting the C64 dot clock (~8 MHz) as the system clock, accepting that most C64 software requires 64KB and won't run unmodified.

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
3. **Memory**: 8 × OCD SRAM macros (8KB) for main RAM. KERNAL ROM (8KB), BASIC ROM (8KB), Character ROM (4KB) synthesized as combinational logic (LUTs). Color RAM (1KB, 4-bit) synthesized.
4. **Clock**: Single clock domain at 32 MHz. The MiSTer's 32-state cycle sequencer runs at this frequency, producing ~8 MHz effective pixel rate and ~1 MHz effective CPU rate. GF180 9T cells handle 32 MHz comfortably (31.25 ns period vs test-tapeout-1's 40 ns at 25 MHz). No PLL needed — external oscillator feeds the clock pad directly.

**Amendment (2026-05-26):** Originally specified ~8 MHz, but the proven cycle sequencer from fpga64_sid_iec requires 32 MHz. Changing pixel rate would require rewriting VIC-II line timing. 32 MHz is well within GF180 capability.

**Amendment (2026-07-06):** The clock pad is now 64 MHz, and a single on-chip flip-flop divides it by two to produce the 32 MHz sequencer clock. The 32 MHz core (1 MHz CPU, cycle sequencer) is unchanged; the extra 64 MHz clock exists only to run the [ADR 0004](0004-external-qspi-psram.md) QSPI PSRAM controller at the frequency it needs for a 32 MHz SCK (`f_sck = f_clk / (2·(CLK_DIV+1))`, so 32 MHz SCK requires a 64 MHz controller clock). "Single clock domain at 32 MHz" in item 4 becomes two synchronous domains derived from one pad: a 2× multiple, so the 32 MHz signals the controller samples are stable across both 64 MHz edges and no asynchronous CDC synchronisers are needed. Still no PLL — the external oscillator feeds the 64 MHz pad, and the ÷2 flop is the only clocking logic. Rationale and the sequencer early-trigger scheme this enables are in `docs/plans/phase-2.md` WS-P2-2.
5. **CIA selection**: CIA1 (keyboard matrix scanner, timer A/B, IRQ generation). CIA2 (VIC bank select, serial bus) excluded; VIC bank hardwired to bank 0.

## Alternatives considered

- **Full 64KB + 2×2 slot** — rejected because 85 SRAM macros require a much larger (and more expensive) die, complex PDN with 85-macro floorplan, and this is a test chip proving the concept.
- **16KB RAM** — rejected because even 16 macros is near the proven limit of the 1×1 slot, and the VIC-II + T65 + CIA logic area hasn't been characterized yet. 8 macros leaves headroom.
- **External SPI RAM** — rejected because it adds a new SPI controller, introduces multi-cycle latency incompatible with the C64's cycle-exact bus timing, and complicates bring-up.
- **No VIC-II (CPU-only)** — rejected because the VIC-II is the interesting part; a 6502 alone has been taped out many times.

## Consequences

- Custom test programs only — can't run BASIC programs that use >8KB RAM.
- VIC-II bank is hardwired to $0000-$3FFF (bank 0). Character ROM, screen RAM, and sprite data must live in the first 8KB.
- KERNAL/BASIC ROMs are compile-time constants (no OSD loading). Use the original Commodore ROM images (will need to handle IP — could use open-source replacements like OpenROMs).
- The cycle sequencer from fpga64_sid_iec needs adaptation: strip SID/IEC logic, keep the VIC/CPU/bus timing state machine.
- CIA1's port A/B will map to pad I/O for keyboard matrix or general-purpose GPIO.

## Walk-back options

- **If 8 SRAM macros don't fit with the logic** — drop to 4KB (4 macros) and make it truly a demo chip.
- **If VIC-II is too large for remaining area** — simplify to text-mode only (strip sprite logic, reduce to ~800 lines).
- **If GHDL-Yosys can't synthesize the VHDL cleanly** — convert VHDL to Verilog via GHDL --synth (one-time effort, ~4600 lines).

## Links

- `docs/plans/archive/phase-1.md` — phase-1 implementation plan (closed/archived)
- `docs/plans/phase-2.md` — current phase roadmap; `docs/plans/memory-integration.md` — memory subsystem (clock, PSRAM, ZP/stack SRAM)
- ADR 0002 — VHDL synthesis strategy
- ADR 0003 — memory architecture and bus adaptation

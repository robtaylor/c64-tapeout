# ADR 0003 — Memory architecture: 8KB SRAM + synthesized ROMs

**Status:** Superseded (2026-06-30) by [ADR 0004](0004-external-qspi-psram.md) for the main-RAM decision. ROM and color-RAM strategy below still applies.

**TL;DR.** In the context of fitting a C64 subset into a GF180MCU 1×1 slot, facing 85KB total memory requirement vs ~16-macro practical limit, we chose 8 × OCD SRAM macros (8KB main RAM) with KERNAL/BASIC/Character ROMs synthesized as combinational logic, accepting that only custom programs fitting in 8KB can run.

## Context

C64 memory map (original):
- $0000–$9FFF: 40KB RAM (lower)
- $A000–$BFFF: 8KB BASIC ROM (overlays RAM)
- $C000–$CFFF: 4KB RAM (upper)
- $D000–$DFFF: 4KB I/O space (VIC, SID, CIA1, CIA2, Color RAM)
- $E000–$FFFF: 8KB KERNAL ROM (overlays RAM)
- Character ROM: 4KB at $D000–$DFFF (visible to VIC only, when bank-switched)

Total: 64KB RAM + 20KB ROM + 1KB color RAM = 85KB.

GF180 OCD SRAM macro: `sram1024x8m8wm1` — 1024×8-bit, single-port, 3.3V. Each provides 1KB. Reference tapeout used 16 macros (4 byte-lanes × 4 banks) arranged in a 2×4 grid.

## Decision

1. **Main RAM**: 8 × sram1024x8m8wm1 macros = 8KB, mapped at $0000–$1FFF. Arranged as 4 byte-lanes × 2 banks (2KB per lane per bank).
2. **BASIC ROM** (8KB): Synthesized as a Verilog `case` statement ROM. Read-only, addressed by the bus logic when $A000–$BFFF is selected and BASIC ROM is banked in.
3. **KERNAL ROM** (8KB): Same approach. Addressed at $E000–$FFFF.
4. **Character ROM** (4KB): Synthesized. VIC-II reads this for character shapes. Addressed at $1000–$1FFF from VIC's perspective (relative to VIC bank base).
5. **Color RAM** (1KB, 4-bit): Synthesized as flip-flops (1024 × 4-bit = 512 bytes equivalent). Directly addressed by VIC at $D800–$DBFF.
6. **Memory map adaptation**: The fpga64_buslogic PLA decode is modified to reflect the reduced RAM range. Addresses $2000–$9FFF and $C000–$CFFF return open bus (no RAM backing them).
7. **SRAM PDN**: Follow the test-tapeout-1 `sram_pdn_ns` pattern — 2 rows with N/S orientation alternation, 4 macros per row on the right side of the core.

## Alternatives considered

- **16 SRAM macros (16KB)** — rejected because the VIC-II + T65 + CIA logic area hasn't been proven yet; 8 macros leaves comfortable headroom. Can expand in a future tapeout.
- **ROM in SRAM (preloaded)** — rejected because SRAM is volatile and there's no mechanism to load ROM content at power-on without a boot controller (adds complexity).
- **Reduced character set** — rejected because the character ROM is only 4KB and synthesizes to a modest number of LUTs (~4K 8-bit entries = ~32Kbit, well within synthesis capability).

## Consequences

- Programs must fit in 8KB ($0000–$1FFF). Screen RAM at $0400 (default) is within this range.
- VIC-II screen memory, sprite pointers, and character data must all be in the first 8KB (bank 0, $0000–$1FFF range visible to VIC).
- The BASIC ROM is present but most BASIC programs won't run due to RAM constraints (variables, string heap, etc. normally live above $0800).
- Simple test patterns: fill screen RAM with characters, set up color RAM, verify VIC outputs video.
- ROM content committed as `.hex` or `.mem` files; a script generates the Verilog ROM modules from the binary dumps.
- SRAM write path: the 8-bit C64 bus writes one byte at a time. The OCD macros are 8-bit wide, so no byte-lane complexity — we use 8 macros in a simple 8KB linear address space (13-bit address, 3 bits select macro, 10 bits select word within macro).

## Walk-back options

- **If synthesized ROMs blow up area** — strip BASIC ROM (not needed for bare-metal test programs that don't call BASIC). Saves 8KB of LUT area.
- **If 8 SRAM macros are tight** — drop to 4KB (4 macros). Screen RAM ($0400–$07FF) still fits.
- **If color RAM as FFs is too large** — use 1 additional SRAM macro for color RAM (read-modify-write for the 4-bit width).

## Links

- ADR 0001 — system scope
- ADR 0005 — SRAM placement and PDN
- `src/sram_wrapper.sv` — SRAM macro composition module
- `src/rom_kernal.sv`, `src/rom_basic.sv`, `src/rom_chargen.sv` — synthesized ROMs

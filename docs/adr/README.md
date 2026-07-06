# Architecture Decision Records

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-system-scope-and-clock.md) | System scope: CPU + VIC-II + CIA + 8KB SRAM at ~8 MHz | Accepted |
| [0002](0002-vhdl-synthesis-via-ghdl.md) | VHDL synthesis via GHDL-Yosys plugin | Accepted |
| [0003](0003-memory-architecture.md) | Memory architecture: 8KB SRAM + synthesized ROMs | Superseded (main RAM by 0004, ROMs by 0005) |
| [0004](0004-external-qspi-psram.md) | External QSPI PSRAM + on-die 5V SRAM ZP/stack carve-out | Accepted (amended 2026-07-05) |
| [0005](0005-external-flash-roms.md) | External QSPI flash for ROMs (shared bus, 2nd CS) | Accepted (2026-07-06) |

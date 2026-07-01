# Vendored PULP `axi_spi_master` SPI engine

These files are a **partial, verbatim** vendoring of the generic SPI master
engine from the PULP platform, used as the serial-shift core underneath our
`rtl/qspi_psram_ctrl.sv` QSPI PSRAM controller (see
[ADR 0004](../../docs/adr/0004-external-qspi-psram.md) and
[phase-2 plan WS-P2-1](../../docs/plans/phase-2.md)).

## Source

- **Upstream repo:** https://github.com/pulp-platform/axi_spi_master
- **Commit:** `ee219078353a76e468674c25675f5b7fe5f51127` (tag `v0.1.1`, "Release v0.1.1")
- **License:** Solderpad Hardware License v0.51 (permissive, Apache-2.0 compatible).
  Full text in [`LICENSE.solderpad`](LICENSE.solderpad). Each source file retains
  its original copyright header verbatim.

## What was vendored (and why only these four)

| File | LOC | Role |
|------|-----|------|
| `spi_master_controller.sv` | 560 | Generic cmd/addr/dummy/data FSM. Memory-agnostic — no flash erase/program semantics. Drives the tx/rx/clkgen sub-blocks. |
| `spi_master_clkgen.sv` | 81 | Divides the system clock into the SCK *waveform* + `spi_rise`/`spi_fall` shift enables. Single clock domain. |
| `spi_master_tx.sv` | 129 | MSB-first shift-out register (std 1-bit and quad 4-bit). |
| `spi_master_rx.sv` | 139 | MSB-first shift-in register (std 1-bit and quad 4-bit). |

These four are **dependency-free**: no `common_cells`, no `tech_cells_generic`,
no SystemVerilog packages, no vendor primitives. They synthesize standalone
through Yosys/Verilator with a single clock and async-active-low reset.

**Deliberately NOT vendored:** `axi_spi_master.sv`, `spi_master_axi_if.sv`,
`spi_master_fifo.sv`. We drive `spi_master_controller` directly from our own
~80-line FSM (`rtl/qspi_psram_ctrl.sv`), so the AXI bus wrapper and the TX/RX
FIFOs are unnecessary.

## Local modifications

None. The four `.sv` files are byte-for-byte copies of the upstream commit.
All adaptation (QPI command sequencing, `sio_oe` derivation, SRAM-style bus
handshake) lives in `rtl/qspi_psram_ctrl.sv`, outside this directory.

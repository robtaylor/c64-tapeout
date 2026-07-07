"""
QSPI PSRAM responder BFM (cocotb)
=================================

A behavioural model of an APS6404L-style QSPI PSRAM, sufficient to exercise
``rtl/qspi_psram_ctrl.sv`` (WS-P2-1, see docs/plans/phase-2.md).

It is *not* a full APS6404L model — it implements exactly the command subset
the controller issues:

  * ``0x35`` Enter Quad (QPI) mode   — received single-lane while in SPI mode.
  * ``0xEB`` Fast Read Quad          — cmd+addr+dummy+data all over 4 lanes.
  * ``0x38`` Quad Write              — cmd+addr+data all over 4 lanes.

Wire protocol (SPI mode 0, matching the PULP ``spi_master_clkgen``):

  * The master changes its outputs on the SCK **falling** edge and samples on
    the **rising** edge. The device therefore *samples* master data (command /
    address / write data) on the rising edge, and *drives* read data on the
    falling edge so it is stable by the next rising edge.

Bit/nibble ordering is MSB-first. In quad phases the four lanes carry one
nibble per SCK cycle with SIO3 = MSB of the nibble, SIO0 = LSB — matching the
PULP tx/rx shift registers (``{sdi3,sdi2,sdi1,sdi0}``).

Signals (all from the controller's point of view, driven onto the DUT):

  * ``cs_n``   : input  — chip select, active low (controller output)
  * ``sck``    : input  — serial clock                (controller output)
  * ``sio_o``  : input  — 4-bit data the controller drives (MOSI lanes)
  * ``sio_oe`` : input  — 4-bit output-enable from the controller (unused by
                          the model except for documentation/debug)
  * ``sio_i``  : output — 4-bit data the model drives back (MISO lanes)
"""

from __future__ import annotations

import cocotb
from cocotb.triggers import Edge, FallingEdge


# QSPI PSRAM command opcodes
CMD_ENTER_QPI = 0x35
CMD_READ_QUAD = 0xEB
CMD_WRITE_QUAD = 0x38


class _CSDeasserted(Exception):
    """Raised internally when CS# rises mid-transaction."""


class QspiPsramModel:
    """Cocotb QSPI PSRAM responder.

    Parameters
    ----------
    dut_handles:
        cocotb signal handles for ``cs_n``, ``sck``, ``sio_o``, ``sio_oe``,
        ``sio_i``.
    size:
        Backing array size in bytes (default 64 KiB — the full C64 map).
    read_dummy_cycles:
        Number of SCK dummy cycles inserted after the address phase of a
        ``0xEB`` read, before data. Must match the controller's
        ``QRD_DUMMY`` parameter.
    """

    def __init__(
        self,
        cs_n,
        sck,
        sio_o,
        sio_oe,
        sio_i,
        size: int = 64 * 1024,
        read_dummy_cycles: int = 6,
    ) -> None:
        assert size & (size - 1) == 0, "size must be a power of two"
        self.cs_n = cs_n
        self.sck = sck
        self.sio_o = sio_o
        self.sio_oe = sio_oe
        self.sio_i = sio_i
        self.mem = bytearray(size)
        self.size = size
        self.read_dummy_cycles = read_dummy_cycles
        self.qpi = False
        # transaction log for test introspection
        self.reads: list[tuple[int, int]] = []
        self.writes: list[tuple[int, int]] = []

    # ----------------------------------------------------------------- #
    #  Memory preload helpers (used by tests)
    # ----------------------------------------------------------------- #
    def load(self, addr: int, data: bytes | bytearray) -> None:
        self.mem[addr : addr + len(data)] = bytes(data)

    def poke(self, addr: int, value: int) -> None:
        self.mem[addr & (self.size - 1)] = value & 0xFF

    def peek(self, addr: int) -> int:
        return self.mem[addr & (self.size - 1)]

    # ----------------------------------------------------------------- #
    #  Low-level edge helpers
    # ----------------------------------------------------------------- #
    def _cs_high(self) -> bool:
        return bool(self.cs_n.value)

    async def _edge(self, want_level: int) -> None:
        """Await the next SCK edge to ``want_level`` (1=rising, 0=falling).

        Raises ``_CSDeasserted`` if CS# goes high first.
        """
        while True:
            await Edge(self.sck)
            if self._cs_high():
                raise _CSDeasserted
            if int(self.sck.value) == want_level:
                return

    async def _rising(self) -> None:
        await self._edge(1)

    async def _falling(self) -> None:
        await self._edge(0)

    def _sample_lanes(self, lanes: int) -> int:
        o = int(self.sio_o.value)
        if lanes == 1:
            return o & 0x1
        return o & 0xF

    async def _recv(self, n_bits: int, lanes: int) -> int:
        """Sample ``n_bits`` MSB-first, ``lanes`` bits per SCK rising edge."""
        val = 0
        edges = n_bits // lanes
        for _ in range(edges):
            await self._rising()
            val = (val << lanes) | self._sample_lanes(lanes)
        return val

    async def _dummy(self, cycles: int) -> None:
        for _ in range(cycles):
            await self._rising()

    async def _wait_cs_high(self) -> None:
        """Block until CS# returns high, anchoring transaction boundaries."""
        while not self._cs_high():
            await Edge(self.cs_n)

    async def _send_byte_quad(self, byte: int) -> None:
        """Drive one byte back over 4 lanes, high nibble first.

        Each nibble is presented on the falling edge and then *held across* the
        following rising edge, on which the master samples it — otherwise the
        value would be cleared before the master latches the final nibble.
        """
        for nib in ((byte >> 4) & 0xF, byte & 0xF):
            await self._falling()
            self.sio_i.value = nib
            await self._rising()  # master samples here; hold the nibble across it

    # ----------------------------------------------------------------- #
    #  Main responder loop
    # ----------------------------------------------------------------- #
    async def run(self) -> None:
        while True:
            await FallingEdge(self.cs_n)
            try:
                await self._transaction()
            except _CSDeasserted:
                pass
            # release the bus between transactions
            self.sio_i.value = 0

    async def _do_quad_read(self) -> None:
        """Serve one ``0xEB`` quad read: addr (24×4) + dummy + one data byte.

        Shared by the PSRAM responder here and the read-only flash subclass, so
        the read wire-protocol is single-sourced.
        """
        addr = await self._recv(24, 4) & (self.size - 1)
        await self._dummy(self.read_dummy_cycles)
        byte = self.mem[addr]
        await self._send_byte_quad(byte)
        self.reads.append((addr, byte))
        await self._wait_cs_high()

    async def _transaction(self) -> None:
        cmd_lanes = 4 if self.qpi else 1
        cmd = await self._recv(8, cmd_lanes)

        if cmd == CMD_ENTER_QPI:
            self.qpi = True
            await self._wait_cs_high()
            return

        if cmd == CMD_READ_QUAD:
            await self._do_quad_read()
            return

        if cmd == CMD_WRITE_QUAD:
            addr = await self._recv(24, 4) & (self.size - 1)
            byte = await self._recv(8, 4)
            self.mem[addr] = byte
            self.writes.append((addr, byte))
            await self._wait_cs_high()
            return

        # Unknown command — ignore until CS# rises.
        raise _CSDeasserted


def start(model: QspiPsramModel):
    """Spawn the model's responder loop, returning the cocotb task."""
    return cocotb.start_soon(model.run())

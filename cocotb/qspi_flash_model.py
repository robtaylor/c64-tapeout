"""
QSPI NOR flash responder BFM (cocotb, read-only QPI)
====================================================

A behavioural model of a W25Q-class QSPI NOR flash operated as a **read-only
PSRAM on CSN1**, sufficient to exercise the read-only ROM port of
``rtl/qspi_psram_ctrl.sv`` (WS-P2-10 task 1, ADR 0005 + 2026-07-07 amendment).

The controller treats the flash exactly like the PSRAM's quad read path — the
PULP serial engine is single-lane or quad-lane only (no dual), so the flash is
driven in **QPI mode** where command *and* address *and* data are all 4-lane.
The model therefore implements exactly two commands:

  * ``0x38`` Enter QPI mode — received **single-lane** (SIO0) while the flash is
    still in standard SPI mode; sets the model into QPI mode. (W25Q-class parts
    use ``0x38`` for enter-QPI; note this differs from the PSRAM's ``0x35``.)
    The part must be QPI-capable with its QE bit set at provisioning — modelled
    here by simply honouring the enter-QPI command at boot.
  * ``0xEB`` Fast Read Quad — cmd (2×4) + addr (6×4) + dummy + data (2×4), all
    over 4 lanes once in QPI mode, MSB/high-nibble first. Read-only.

No write/erase/program — a ROM is read-only. Any other opcode is ignored until
CS# rises.

This shares the ``QspiPsramModel`` machinery: the flash is a *read-only PSRAM*,
so all of the quad edge/recv/send helpers and the preload/introspection helpers
are inherited unchanged. Only the responder ``_transaction`` is overridden, to
map ``0x38`` to enter-QPI (rather than the base model's quad *write*) and to
reject any write. This mirrors the repo's existing ``ChipCoreBFM(QspiPsramModel)``
precedent in ``chip_core_tb.py`` and keeps the wire protocol single-sourced.

The chip-select handle passed in is the *flash* select (controller
``cs_flash_n`` = engine ``spi_csn1``); SCK / SIO[3:0] are the bus shared with
the PSRAM. See ``qspi_psram_model.py`` for the full wire-protocol description.
"""

from __future__ import annotations

from qspi_psram_model import CMD_READ_QUAD, QspiPsramModel, _CSDeasserted, start

# QSPI NOR flash command opcodes (read-only QPI subset).
# Enter-QPI for a W25Q-class flash is 0x38 (received single-lane, pre-QPI).
# Note: 0x38 is the PSRAM's *quad write* opcode in the base model — here, on the
# flash CS and while still single-lane, it means "enter QPI" instead.
CMD_FLASH_ENTER_QPI = 0x38

# Re-export so callers can ``from qspi_flash_model import start`` symmetrically
# with the PSRAM model; it is the shared, model-agnostic spawn shim.
__all__ = ["QspiFlashModel", "start"]


class QspiFlashModel(QspiPsramModel):
    """Cocotb read-only QSPI NOR flash responder (QPI mode).

    Subclasses :class:`QspiPsramModel`, inheriting all of its quad helpers
    (``_edge``/``_rising``/``_falling``/``_recv``/``_dummy``/``_send_byte_quad``/
    ``_wait_cs_high``), preload helpers (``load``/``poke``/``peek``), the
    ``self.qpi`` lane-width state, and the responder ``run`` loop. Only the
    read-only flash behaviour is overridden below.

    Parameters
    ----------
    cs_n:
        The flash chip-select handle (controller ``cs_flash_n``). Distinct from
        the PSRAM ``cs_n`` so both devices can share SCK / SIO on one bus.
    sck, sio_o, sio_oe, sio_i:
        The shared QSPI bus handles (same signals the PSRAM model watches).
    size:
        Backing array size in bytes (default 16 MiB — 24-bit flash space; the
        C64 ROM images occupy a small window near the base).
    read_dummy_cycles:
        Number of SCK dummy cycles inserted after the address phase of a
        ``0xEB`` QPI read, before data. Must match the controller's
        ``FRD_DUMMY`` parameter.
    """

    def __init__(
        self,
        cs_n,
        sck,
        sio_o,
        sio_oe,
        sio_i,
        size: int = 16 * 1024 * 1024,
        read_dummy_cycles: int = 6,
    ) -> None:
        super().__init__(
            cs_n=cs_n,
            sck=sck,
            sio_o=sio_o,
            sio_oe=sio_oe,
            sio_i=sio_i,
            size=size,
            read_dummy_cycles=read_dummy_cycles,
        )

    async def _transaction(self) -> None:
        # Command lane width tracks QPI state, exactly like the PSRAM base: the
        # enter-QPI command arrives single-lane (pre-QPI); every later command
        # (the 0xEB reads) arrives 4-lane.
        cmd_lanes = 4 if self.qpi else 1
        cmd = await self._recv(8, cmd_lanes)

        if cmd == CMD_FLASH_ENTER_QPI and not self.qpi:
            # Enter QPI — read-only model, so 0x38 is *not* a write here.
            self.qpi = True
            await self._wait_cs_high()
            return

        if cmd == CMD_READ_QUAD and self.qpi:
            # Read-only quad read: identical wire behaviour to the PSRAM's 0xEB,
            # so reuse the inherited read sequence verbatim (single-sourced).
            await self._do_quad_read()
            return

        # Unknown / unsupported command (any write, erase, program, or a read
        # issued before enter-QPI) — a read-only ROM ignores it until CS# rises.
        raise _CSDeasserted

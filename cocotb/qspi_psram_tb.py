# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "cocotb>=2.0",
# ]
# ///
"""
QSPI PSRAM controller standalone test (WS-P2-1)
===============================================

Drives ``rtl/qspi_psram_ctrl.sv`` through its SRAM-style bus and checks that it
talks correctly to the QSPI PSRAM BFM (``qspi_psram_model.py``):

  * controller issues an ``0xEB`` quad read  -> BFM responds -> controller
    delivers the correct byte on ``ramDout`` with ``ready`` within the cycle
    budget.
  * controller issues an ``0x38`` quad write -> BFM stores the byte ->
    a subsequent read of the same address reads it back.

Single clock domain: the controller runs at 64 MHz so that, with the default
divider (CLK_DIV=0), SCK = clk/2 = 32 MHz — the phase-2 target.

Invocation:
    make sim-qspi
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, SimTimeoutError, Timer, with_timeout
from cocotb.utils import get_sim_time

from qspi_flash_model import QspiFlashModel
from qspi_flash_model import start as start_flash
from qspi_psram_model import QspiPsramModel, start

# Controller clock: 64 MHz -> 15.625 ns period. On the 1 ps simulator grid that
# is an odd 15625 steps, so split the duty cycle (7813 ps high / 7812 ps low)
# via period_high to keep the frequency exactly 64 MHz -> 32 MHz SCK.
CLK_PERIOD_PS = 15_625
CLK_HIGH_PS = 7_813


def _start_clock(dut) -> None:
    cocotb.start_soon(
        Clock(dut.clk, CLK_PERIOD_PS, unit="ps", period_high=CLK_HIGH_PS).start()
    )

# Single source of truth for the 0xEB dummy-cycle count: passed into the
# Verilator build as the RTL's QRD_DUMMY parameter, and into the BFM's
# read_dummy_cycles, so RTL default / BFM / tb never drift apart.
QRD_DUMMY_CYCLES = 6

# Same discipline for the flash 0xEB QPI quad read: this is the RTL's
# FRD_DUMMY parameter and the flash BFM's read_dummy_cycles. QPI 0xEB read
# latency is part-specific (2 mode + 4 dummy = 6 SCK, per ADR 0005 amendment).
FRD_DUMMY_CYCLES = 6

# Generous per-access budget: enter-QPI (~8 SCK) + read (~16 SCK) etc., each
# SCK = 2 controller clocks, plus FSM overhead. 4000 clocks is comfortable.
ACCESS_BUDGET_CLOCKS = 4000


def _attach_bfms(dut) -> tuple[QspiPsramModel, QspiFlashModel]:
    """Attach both device models to the shared QSPI bus.

    The PSRAM responds on ``cs_n`` (CSN0); the read-only flash on ``cs_flash_n``
    (CSN1). SCK / SIO[3:0] are shared — each model only drives ``sio_i`` while
    its own chip-select is low, so the fixed-priority arbiter's serialisation
    keeps them from colliding.
    """
    psram = QspiPsramModel(
        cs_n=dut.cs_n,
        sck=dut.sck,
        sio_o=dut.sio_o,
        sio_oe=dut.sio_oe,
        sio_i=dut.sio_i,
        read_dummy_cycles=QRD_DUMMY_CYCLES,
    )
    flash = QspiFlashModel(
        cs_n=dut.cs_flash_n,
        sck=dut.sck,
        sio_o=dut.sio_o,
        sio_oe=dut.sio_oe,
        sio_i=dut.sio_i,
        read_dummy_cycles=FRD_DUMMY_CYCLES,
    )
    start(psram)
    start_flash(flash)
    return psram, flash


async def _reset(dut) -> None:
    dut.rst_n.value = 0
    dut.ramAddr.value = 0
    dut.ramDin.value = 0
    dut.ramCE.value = 0
    dut.ramWE.value = 0
    dut.romAddr.value = 0
    dut.romCE.value = 0
    dut.sio_i.value = 0
    await Timer(200, unit="ns")
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _wait_ready(dut, budget: int = ACCESS_BUDGET_CLOCKS) -> int:
    """Wait until the controller asserts ``ready``; return clocks elapsed.

    ``ready`` is a single-cycle pulse, so an edge-triggered wait (rather than
    a per-clock poll loop) is sufficient and catches it directly.
    """
    start_ps = get_sim_time(unit="ps")
    try:
        await with_timeout(RisingEdge(dut.ready), budget * CLK_PERIOD_PS, "ps")
    except SimTimeoutError:
        raise AssertionError(f"ready never asserted within {budget} clocks")
    elapsed_ps = get_sim_time(unit="ps") - start_ps
    return round(elapsed_ps / CLK_PERIOD_PS)


async def _wait_rom_ready(dut, budget: int = ACCESS_BUDGET_CLOCKS) -> int:
    """Wait until the controller asserts ``romReady``; return clocks elapsed."""
    start_ps = get_sim_time(unit="ps")
    try:
        await with_timeout(RisingEdge(dut.romReady), budget * CLK_PERIOD_PS, "ps")
    except SimTimeoutError:
        raise AssertionError(f"romReady never asserted within {budget} clocks")
    elapsed_ps = get_sim_time(unit="ps") - start_ps
    return round(elapsed_ps / CLK_PERIOD_PS)


async def _bus_read(dut, addr: int) -> tuple[int, int]:
    """Perform one SRAM-style read; return (data, clocks)."""
    await RisingEdge(dut.clk)
    dut.ramAddr.value = addr
    dut.ramWE.value = 0
    dut.ramCE.value = 1
    await RisingEdge(dut.clk)
    dut.ramCE.value = 0
    cycles = await _wait_ready(dut)
    data = int(dut.ramDout.value)
    await RisingEdge(dut.clk)
    return data, cycles


async def _rom_read(dut, addr: int) -> tuple[int, int]:
    """Perform one read-only ROM (flash 0xEB QPI) access; return (data, clocks)."""
    await RisingEdge(dut.clk)
    dut.romAddr.value = addr
    dut.romCE.value = 1
    await RisingEdge(dut.clk)
    dut.romCE.value = 0
    cycles = await _wait_rom_ready(dut)
    data = int(dut.romDout.value)
    await RisingEdge(dut.clk)
    return data, cycles


async def _bus_write(dut, addr: int, data: int) -> int:
    """Perform one SRAM-style write; return clocks elapsed."""
    await RisingEdge(dut.clk)
    dut.ramAddr.value = addr
    dut.ramDin.value = data
    dut.ramWE.value = 1
    dut.ramCE.value = 1
    await RisingEdge(dut.clk)
    dut.ramCE.value = 0
    dut.ramWE.value = 0
    cycles = await _wait_ready(dut)
    await RisingEdge(dut.clk)
    return cycles


async def _wait_init_done(dut, bfm: QspiPsramModel, budget: int = ACCESS_BUDGET_CLOCKS) -> None:
    """After reset the controller issues an enter-QPI command to each device
    (0x35 to the PSRAM on CSN0, 0x38 to the flash on CSN1). Wait until the given
    BFM has actually seen its command (``bfm.qpi`` goes True) rather than
    sleeping for a fixed, ``CLK_DIV``-coupled number of clocks."""
    n = 0
    while not bfm.qpi:
        await RisingEdge(dut.clk)
        n += 1
        if n > budget:
            raise AssertionError(f"controller did not enter QPI mode within {budget} clocks")


async def _bringup(dut) -> tuple[QspiPsramModel, QspiFlashModel]:
    """Start the clock, attach both BFMs, reset the DUT and wait for the
    controller to complete its two-device enter-QPI init sequence: 0x35 to the
    PSRAM on CSN0, then 0x38 to the flash on CSN1. Both devices must be in QPI
    mode before any read (the flash's 0xEB read is a quad transaction).

    Returns ``(psram, flash)``. PSRAM-only tests can ignore the flash model.
    """
    _start_clock(dut)
    psram, flash = _attach_bfms(dut)
    await _reset(dut)
    await _wait_init_done(dut, psram)
    await _wait_init_done(dut, flash)
    return psram, flash


# --------------------------------------------------------------------- #
#  Tests
# --------------------------------------------------------------------- #
@cocotb.test()
async def test_read_delivers_byte(dut):
    """0xEB read: BFM holds a known byte, controller must deliver it."""
    bfm, _ = await _bringup(dut)
    bfm.poke(0x1234, 0xA5)
    assert bfm.qpi, "controller did not put the PSRAM into QPI mode (0x35)"

    data, cycles = await _bus_read(dut, 0x1234)
    assert data == 0xA5, f"read returned 0x{data:02X}, expected 0xA5"
    assert bfm.reads, "BFM saw no read transaction"
    raddr, rbyte = bfm.reads[-1]
    assert raddr == 0x1234, f"BFM decoded addr 0x{raddr:04X}, expected 0x1234"
    dut._log.info(f"read 0x{data:02X} from 0x1234 in {cycles} controller clocks")


@cocotb.test()
async def test_write_then_read_back(dut):
    """0x38 write then 0xEB read of the same address returns the written byte."""
    bfm, _ = await _bringup(dut)
    assert bfm.qpi, "controller did not enter QPI mode"

    wr_cycles = await _bus_write(dut, 0x2ABC, 0x3C)
    assert bfm.peek(0x2ABC) == 0x3C, (
        f"BFM stored 0x{bfm.peek(0x2ABC):02X}, expected 0x3C"
    )

    data, rd_cycles = await _bus_read(dut, 0x2ABC)
    assert data == 0x3C, f"read-back returned 0x{data:02X}, expected 0x3C"
    dut._log.info(
        f"wrote 0x3C in {wr_cycles} clocks, read back in {rd_cycles} clocks"
    )


@cocotb.test()
async def test_multiple_addresses(dut):
    """A short sweep to confirm address decode across several locations."""
    await _bringup(dut)

    vectors = {0x0000: 0x11, 0x00FF: 0x22, 0xFFFC: 0x33, 0xFFFF: 0x44}
    for addr, val in vectors.items():
        await _bus_write(dut, addr, val)
    for addr, val in vectors.items():
        data, _ = await _bus_read(dut, addr)
        assert data == val, (
            f"addr 0x{addr:04X}: read 0x{data:02X}, expected 0x{val:02X}"
        )
    dut._log.info(f"address sweep OK over {len(vectors)} locations")


# --------------------------------------------------------------------- #
#  Flash ROM path (WS-P2-10 task 1, ADR 0005)
# --------------------------------------------------------------------- #
@cocotb.test()
async def test_flash_read_returns_byte(dut):
    """0xEB QPI quad read: flash BFM holds a preloaded ROM byte on CSN1; the
    controller must select the flash, run the quad read and deliver the byte on
    ``romDout`` with ``romReady``. The flash must already be in QPI mode from
    the boot init sequence."""
    _psram, flash = await _bringup(dut)
    assert flash.qpi, "controller did not put the flash into QPI mode (0x38)"

    # A 24-bit flash offset, wider than the 16-bit RAM map — the flash space
    # holds KERNAL/BASIC/CHARGEN at distinct offsets (ADR 0005 §5).
    rom_off = 0x01_E000
    flash.load(rom_off, bytes([0xC3]))

    data, cycles = await _rom_read(dut, rom_off)
    assert data == 0xC3, f"flash read returned 0x{data:02X}, expected 0xC3"
    assert flash.reads, "flash BFM saw no read transaction"
    raddr, rbyte = flash.reads[-1]
    assert raddr == rom_off, f"flash decoded addr 0x{raddr:06X}, expected 0x{rom_off:06X}"
    # The flash lives on CSN1; the PSRAM's CSN0 must stay deasserted (high).
    assert int(dut.cs_n.value) == 1, "PSRAM CS asserted during a flash read"
    dut._log.info(f"flash read 0x{data:02X} from 0x{rom_off:06X} in {cycles} clocks")


@cocotb.test()
async def test_flash_read_multiple_offsets(dut):
    """Sweep a few flash offsets (KERNAL/BASIC/CHARGEN-style bases) to confirm
    24-bit address decode on the read-only QPI port."""
    _psram, flash = await _bringup(dut)
    assert flash.qpi, "controller did not put the flash into QPI mode (0x38)"

    vectors = {0x00_0000: 0xAA, 0x00_2000: 0xBB, 0x01_C000: 0xCC, 0x02_0000: 0xDD}
    for off, val in vectors.items():
        flash.load(off, bytes([val]))
    for off, val in vectors.items():
        data, _ = await _rom_read(dut, off)
        assert data == val, (
            f"flash 0x{off:06X}: read 0x{data:02X}, expected 0x{val:02X}"
        )
    dut._log.info(f"flash offset sweep OK over {len(vectors)} locations")


@cocotb.test()
async def test_ram_and_rom_serialize(dut):
    """Concurrent RAM (PSRAM) + ROM (flash) requests fired in the same cycle
    must both complete, serialised onto the one engine. RAM wins the tie
    (fixed priority), so ``ready`` precedes ``romReady``; both bytes return."""
    psram, flash = await _bringup(dut)

    psram.poke(0x0400, 0x5A)          # RAM byte
    flash.load(0x01_8000, bytes([0x91]))  # ROM byte

    # Fire both chip-enables on the same clock edge.
    await RisingEdge(dut.clk)
    dut.ramAddr.value = 0x0400
    dut.ramWE.value = 0
    dut.ramCE.value = 1
    dut.romAddr.value = 0x01_8000
    dut.romCE.value = 1
    await RisingEdge(dut.clk)
    dut.ramCE.value = 0
    dut.romCE.value = 0

    # RAM has priority, so it completes first.
    await _wait_ready(dut)
    ram_data = int(dut.ramDout.value)
    assert ram_data == 0x5A, f"RAM read returned 0x{ram_data:02X}, expected 0x5A"

    # ROM was held pending during the RAM transaction; it is serviced next.
    await _wait_rom_ready(dut)
    rom_data = int(dut.romDout.value)
    assert rom_data == 0x91, f"ROM read returned 0x{rom_data:02X}, expected 0x91"

    assert psram.reads and psram.reads[-1][0] == 0x0400, "PSRAM read did not occur"
    assert flash.reads and flash.reads[-1][0] == 0x01_8000, "flash read did not occur"
    dut._log.info("concurrent RAM+ROM requests serialised correctly (RAM first)")


# --------------------------------------------------------------------- #
#  Runner
# --------------------------------------------------------------------- #
def qspi_runner() -> None:
    from cocotb_tools.runner import get_runner

    project_root = Path(__file__).resolve().parent.parent
    build_dir = project_root / "cocotb" / "sim_build_qspi"
    build_dir.mkdir(parents=True, exist_ok=True)

    pulp_ip = project_root / "ip" / "pulp"
    sources = [
        str(pulp_ip / "spi_master_clkgen.sv"),
        str(pulp_ip / "spi_master_tx.sv"),
        str(pulp_ip / "spi_master_rx.sv"),
        str(pulp_ip / "spi_master_controller.sv"),
        str(project_root / "rtl" / "qspi_psram_ctrl.sv"),
    ]

    sim = os.environ.get("SIM", "verilator")
    runner = get_runner(sim)

    extra_build_args: list[str] = []
    if sim == "verilator":
        extra_build_args += [
            "--Wno-fatal",
            "-Wno-WIDTHEXPAND",
            "-Wno-WIDTHTRUNC",
            "-Wno-CASEINCOMPLETE",
            "-Wno-UNOPTFLAT",
            "-Wno-MULTIDRIVEN",
        ]

    runner.build(
        sources=sources,
        hdl_toplevel="qspi_psram_ctrl",
        parameters={"QRD_DUMMY": QRD_DUMMY_CYCLES, "FRD_DUMMY": FRD_DUMMY_CYCLES},
        build_args=extra_build_args,
        build_dir=str(build_dir),
        always=True,
        waves=True,
    )
    runner.test(
        hdl_toplevel="qspi_psram_ctrl",
        test_module="qspi_psram_tb",
        build_dir=str(build_dir),
        waves=True,
    )


if __name__ == "__main__":
    qspi_runner()

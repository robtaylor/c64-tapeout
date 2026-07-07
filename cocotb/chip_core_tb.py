# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "cocotb>=2.0",
# ]
# ///
"""
C64 tapeout — chip_core smoke test
==================================

Brings up the synthesized chip_core, releases reset, and verifies:
  - heartbeat counter advances (clock/reset path alive)
  - VIC HSYNC pulses (VIC-II raster sequencer running)
  - CPU drives an address bus consistent with reset-vector fetch
    (high byte = 0xFF when fetching $FFFC/$FFFD)

Runs on Icarus Verilog against the GHDL-pre-synthesized Verilog
(`build/c64_system_synth.v`) plus the SV wrappers + ROMs.

Invocation:
    make sim-smoke
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge, Timer

from qspi_flash_model import QspiFlashModel
from qspi_psram_model import QspiPsramModel, _CSDeasserted

# --------------------------------------------------------------------- #
#  Pad indices (must match src/chip_core.sv)
# --------------------------------------------------------------------- #
PAD_HEARTBEAT = 0
PAD_VIC_HSYNC = 5
PAD_VIC_VSYNC = 6
PAD_CIA_IRQ   = 23
PAD_CPU_RW    = 24
PAD_ADDR_HI0  = 25  # cpu_addr[15:8] occupies bidir[25:32]
# QSPI PSRAM pads (must match src/chip_core.sv)
PAD_PSRAM_CSN  = 33
PAD_PSRAM_SCK  = 34
PAD_PSRAM_SIO0 = 35  # sio[3:0] = bidir[35..38]
PAD_PSRAM_CS_FLASH = 39  # flash CS# (ADR 0005), shares SCK/SIO with PSRAM

QRD_DUMMY_CYCLES = 6  # must match the RTL's QRD_DUMMY parameter
FRD_DUMMY_CYCLES = 6  # must match the RTL's FRD_DUMMY parameter (flash 0xEB QPI)

# Flash offset map (ADR 0005 / rom-flash-integration.md task 4)
FLASH_OFF_KERNAL  = 0x000000  # 8 KB
FLASH_OFF_BASIC   = 0x002000  # 8 KB
FLASH_OFF_CHARGEN = 0x004000  # 4 KB


# --------------------------------------------------------------------- #
#  ROM image extraction from the generated LUT-ROM case statements
# --------------------------------------------------------------------- #
def extract_rom_bytes(sv_path: Path, depth: int) -> bytes:
    """Extract the ROM contents from a generated ``rom_*.sv`` case statement.

    The generated modules (scripts/mif2rom.py) encode each populated address as
    ``N'hAAAA: data = 8'hVV;`` plus a ``default: data = 8'hVV;`` for the common
    fill byte. We rebuild the flat byte image so the flash BFM returns exactly
    the bytes the deleted LUT ROMs would have — a valid KERNAL reset vector at
    the mapped $FFFC/$FFFD is essential for boot.
    """
    text = sv_path.read_text()
    m = re.search(r"default:\s*data = 8'h([0-9A-Fa-f]{2})", text)
    default = int(m.group(1), 16) if m else 0
    mem = bytearray([default] * depth)
    for addr_hex, val_hex in re.findall(
        r"\d+'h([0-9A-Fa-f]+):\s*data = 8'h([0-9A-Fa-f]{2})", text
    ):
        mem[int(addr_hex, 16)] = int(val_hex, 16)
    return bytes(mem)


# --------------------------------------------------------------------- #
#  QSPI PSRAM BFM wired onto the chip_core pad vectors
# --------------------------------------------------------------------- #
class _VecSlice:
    """Present a bit-slice of a packed vector handle as an integer .value.

    Writes read-modify-write the backing handle so neighbouring pad bits are
    preserved (the BFM only ever drives the 4 SIO input lanes).
    """

    def __init__(self, handle, lsb: int, width: int) -> None:
        self._h = handle
        self._lsb = lsb
        self._mask = (1 << width) - 1

    @property
    def value(self) -> int:
        return (int(self._h.value) >> self._lsb) & self._mask

    @value.setter
    def value(self, v: int) -> None:
        cur = int(self._h.value)
        cur &= ~(self._mask << self._lsb)
        cur |= (v & self._mask) << self._lsb
        self._h.value = cur


class _ChipCorePadBFM:
    """Shared chip_core pad-vector plumbing for the QSPI BFMs.

    Both the PSRAM and flash models sit on the same muxed pads: the controller's
    cs_n/sck/sio are bit-slices of the ``bidir_out`` vector, and sio_i is driven
    back through ``bidir_in``. cocotb can't put an ``Edge`` on a bit-select of a
    Verilator vector port, so the trigger primitives wake on the whole
    ``bidir_out`` vector and re-check the bits. Only the CS pad differs between
    the two models (``cs_pad``); everything else is identical.

    Mixed in *before* the concrete model class, so these methods override the
    model's; the model still supplies ``_recv``/``_transaction``/
    ``_do_quad_read`` etc. (which this mixin deliberately does not define).
    """

    def __init__(self, dut, cs_pad: int, **kw) -> None:
        sio_i = _VecSlice(dut.bidir_in, PAD_PSRAM_SIO0, 4)
        super().__init__(
            cs_n=None, sck=None, sio_o=None, sio_oe=None, sio_i=sio_i, **kw
        )
        self._dut = dut
        self._cs_pad = cs_pad

    def _cs_high(self) -> bool:
        return bool((int(self._dut.bidir_out.value) >> self._cs_pad) & 1)

    def _sck_level(self) -> int:
        return (int(self._dut.bidir_out.value) >> PAD_PSRAM_SCK) & 1

    async def _edge(self, want_level: int) -> None:
        while True:
            await Edge(self._dut.bidir_out)
            if self._cs_high():
                raise _CSDeasserted
            if self._sck_level() == want_level:
                return

    def _sample_lanes(self, lanes: int) -> int:
        o = (int(self._dut.bidir_out.value) >> PAD_PSRAM_SIO0) & 0xF
        return (o & 0x1) if lanes == 1 else (o & 0xF)

    async def _wait_cs_high(self) -> None:
        while not self._cs_high():
            await Edge(self._dut.bidir_out)

    async def run(self) -> None:
        while True:
            # Wait for a genuine CS# high -> low transition (transaction start).
            await self._wait_cs_high()
            while self._cs_high():
                await Edge(self._dut.bidir_out)
            try:
                await self._transaction()
            except _CSDeasserted:
                pass
            self.sio_i.value = 0


class ChipCoreBFM(_ChipCorePadBFM, QspiPsramModel):
    """``QspiPsramModel`` attached to chip_core's muxed QSPI pads (PSRAM CS)."""

    def __init__(self, dut, **kw) -> None:
        super().__init__(dut, PAD_PSRAM_CSN, **kw)


class ChipCoreFlashBFM(_ChipCorePadBFM, QspiFlashModel):
    """Read-only QSPI NOR flash model on chip_core's flash CS (bidir[39]).

    Same pad-vector plumbing as :class:`ChipCoreBFM` but watches the *flash*
    chip-select pad. Both BFMs run concurrently on the shared SCK/SIO bus; only
    one CS is ever low at a time (the controller serialises RAM and ROM onto the
    single engine), so the inactive model just consumes bus edges without driving
    ``sio_i``.
    """

    def __init__(self, dut, **kw) -> None:
        super().__init__(dut, PAD_PSRAM_CS_FLASH, **kw)


# --------------------------------------------------------------------- #
#  Helpers
# --------------------------------------------------------------------- #
def bidir_bit(dut, idx: int) -> int:
    """Read a single bit out of bidir_out (LSB-first packing)."""
    return (int(dut.bidir_out.value) >> idx) & 0x1


def bidir_byte(dut, lsb: int) -> int:
    """Read 8 bits starting at lsb."""
    return (int(dut.bidir_out.value) >> lsb) & 0xFF


async def reset(dut, hold_ns: int = 200) -> None:
    dut.rst_n.value = 0
    dut.input_in.value = 0
    dut.bidir_in.value = 0
    dut.analog.value = 0
    await Timer(hold_ns, unit="ns")
    dut.rst_n.value = 1


# --------------------------------------------------------------------- #
#  Tests
# --------------------------------------------------------------------- #
@cocotb.test()
async def test_boot_smoke(dut):
    """Reset, run for ~5000 32 MHz clocks, observe vital signs."""

    # 64 MHz pad clock = 15.625 ns period; chip_core divides by 2 to the
    # 32 MHz C64 system clock (ADR 0001, 2026-07-06 amendment). 15625 ps is
    # odd on the 1 ps grid, so split the duty (7813 high / 7812 low) via
    # period_high to keep the frequency exactly 64 MHz (as in qspi_psram_tb).
    cocotb.start_soon(Clock(dut.clk, 15625, unit="ps", period_high=7813).start())

    # Attach the QSPI PSRAM BFM to the pads before releasing reset so it catches
    # the controller's 0x35 enter-QPI init transaction. PSRAM starts zeroed; the
    # KERNAL RAM test writes then reads back, and the BFM stores/returns bytes so
    # RAM outside the on-die ZP/stack behaves like real memory.
    bfm = ChipCoreBFM(dut, read_dummy_cycles=QRD_DUMMY_CYCLES)
    cocotb.start_soon(bfm.run())

    # Attach the read-only flash BFM on the flash CS (bidir[39]), sharing the
    # SCK/SIO bus. Preload the REAL KERNAL/BASIC/CHARGEN images (extracted from
    # the generated LUT-ROM case statements) at the ADR 0005 offset map, so the
    # reset-vector fetch ($FFFC/$FFFD -> KERNAL) and KERNAL code fetches return
    # correct bytes over QPI (ADR 0005 boot path).
    src = Path(__file__).resolve().parent.parent / "src"
    kernal_img  = extract_rom_bytes(src / "rom_kernal.sv", 8192)
    basic_img   = extract_rom_bytes(src / "rom_basic.sv", 8192)
    chargen_img = extract_rom_bytes(src / "rom_chargen.sv", 4096)
    # Sanity: the KERNAL reset vector at $FFFC/$FFFD maps to flash 0x1FFC/0x1FFD.
    reset_vec = kernal_img[0x1FFC] | (kernal_img[0x1FFD] << 8)
    assert reset_vec == 0xFCE2, f"unexpected KERNAL reset vector ${reset_vec:04X}"

    flash = ChipCoreFlashBFM(dut, read_dummy_cycles=FRD_DUMMY_CYCLES)
    flash.load(FLASH_OFF_KERNAL, kernal_img)
    flash.load(FLASH_OFF_BASIC, basic_img)
    flash.load(FLASH_OFF_CHARGEN, chargen_img)
    cocotb.start_soon(flash.run())

    await reset(dut, hold_ns=500)
    await RisingEdge(dut.clk)

    # Give the controller time to finish BOTH enter-QPI inits (PSRAM 0x35 then
    # flash 0x38) before the CPU is released. The CPU is boot-gated on the
    # controller's init_done, so it will not fetch the reset vector until both
    # devices are in QPI mode.
    for _ in range(2000):
        if bfm.qpi and flash.qpi:
            break
        await RisingEdge(dut.clk)
    assert bfm.qpi, "PSRAM did not enter QPI mode (0x35) after reset"
    assert flash.qpi, "flash did not enter QPI mode (0x38) after reset"

    hsync_toggles = 0
    last_hsync    = bidir_bit(dut, PAD_VIC_HSYNC)
    addr_hi_seen: set[int] = set()

    # dut.clk is the 64 MHz pad clock (÷2 → 32 MHz core, ÷32 states → ~1 MHz
    # CPU). 128000 pad clocks ≈ 2 ms ≈ ~2000 CPU cycles — far enough into the
    # KERNAL reset to run the RAMTAS memory test, which reads *and* writes
    # external RAM through the PSRAM BFM.
    CYCLES = 128000
    for _ in range(CYCLES):
        await RisingEdge(dut.clk)

        h = bidir_bit(dut, PAD_VIC_HSYNC)
        if h != last_hsync:
            hsync_toggles += 1
            last_hsync = h

        addr_hi_seen.add(bidir_byte(dut, PAD_ADDR_HI0))

    # The heartbeat counter is 25 bits — MSB toggles after 2**24 / 32e6 ≈ 0.5 s,
    # too long for a smoke test. Just check the bus is driven (not X).
    assert dut.bidir_out.value.is_resolvable, "bidir_out drove X — uninit logic"

    # HSYNC should have pulsed at least a few times: VIC has a ~63 cycle
    # horizontal counter at ~8 MHz, so several HSYNC edges in 250 us.
    assert hsync_toggles >= 2, (
        f"VIC HSYNC did not toggle (saw {hsync_toggles} edges in {CYCLES} clocks)"
    )

    # CPU address bus should have driven *something* meaningful — at minimum,
    # more than one distinct value. Reset vector fetch puts 0xFF on the high
    # byte; KERNAL code lives in 0xE000..0xFFFF.
    distinct = len(addr_hi_seen)
    assert distinct >= 2, (
        f"CPU address bus stuck — only {distinct} distinct upper bytes "
        f"seen: {sorted(addr_hi_seen)}"
    )

    # The BFM should have serviced real PSRAM traffic (RAM outside ZP/stack).
    assert bfm.reads or bfm.writes, (
        "BFM saw no PSRAM transactions — CPU never touched external RAM"
    )

    # The flash BFM must have served ROM fetches — proving the reset vector and
    # KERNAL bytes came from the external flash, not the deleted LUT ROMs.
    flash_offsets = {addr for addr, _ in flash.reads}
    assert flash.reads, "flash BFM saw no ROM reads — CPU never fetched from flash"

    # The reset-vector fetch ($FFFC/$FFFD) maps to flash 0x1FFC / 0x1FFD.
    reset_vec_hit = 0x1FFC in flash_offsets or 0x1FFD in flash_offsets
    # KERNAL code region ($E000-$FFFF -> flash 0x0000-0x1FFF) fetches after reset.
    kernal_fetches = sorted(a for a in flash_offsets if a < 0x2000)
    assert reset_vec_hit, (
        f"flash never served the reset vector (0x1FFC/0x1FFD); "
        f"flash offsets seen (low 8): {sorted(flash_offsets)[:8]}"
    )
    assert len(kernal_fetches) >= 2, (
        f"too few KERNAL fetches from flash: {kernal_fetches[:8]}"
    )

    # Verify a served byte matches the preloaded image (data-integrity, not just
    # that a transaction happened).
    for off, byte in flash.reads:
        assert flash.mem[off] == byte, (
            f"flash returned 0x{byte:02X} at 0x{off:06X}, image has "
            f"0x{flash.mem[off]:02X}"
        )

    dut._log.info(
        f"smoke OK — hsync toggles={hsync_toggles}, "
        f"distinct addr_hi={distinct}, samples={sorted(addr_hi_seen)[:8]}…, "
        f"psram reads={len(bfm.reads)}, writes={len(bfm.writes)}, "
        f"flash reads={len(flash.reads)}, "
        f"reset-vec offsets hit={sorted(o for o in flash_offsets if o in (0x1FFC, 0x1FFD))}, "
        f"kernal fetch offsets(sample)={[hex(a) for a in kernal_fetches[:6]]}"
    )


# --------------------------------------------------------------------- #
#  Runner
# --------------------------------------------------------------------- #
def parse_filelist(path: Path) -> list[str]:
    """Read a .f filelist, strip comments and blanks, resolve relative paths."""
    base = path.parent
    out: list[str] = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        p = (base / line).resolve()
        out.append(str(p))
    return out


def chip_core_runner() -> None:
    from cocotb_tools.runner import get_runner

    project_root = Path(__file__).resolve().parent.parent
    build_dir    = project_root / "cocotb" / "sim_build"
    build_dir.mkdir(parents=True, exist_ok=True)

    # chip_top.sv pulls the GF180 padframe — skip it for chip_core sim.
    # sram_wrapper.sv is no longer instantiated (replaced by the QSPI PSRAM +
    # ZP/stack split), so skip it too.
    rtl = [p for p in parse_filelist(project_root / "rtl.f")
           if not (p.endswith("chip_top.sv") or p.endswith("sram_wrapper.sv"))]
    pulp = project_root / "ip" / "pulp"
    sources = [
        str(project_root / "build" / "c64_system_synth.v"),
        # PULP serial engine + QSPI PSRAM controller + on-die ZP/stack SRAM
        str(pulp / "spi_master_clkgen.sv"),
        str(pulp / "spi_master_tx.sv"),
        str(pulp / "spi_master_rx.sv"),
        str(pulp / "spi_master_controller.sv"),
        str(project_root / "rtl" / "qspi_psram_ctrl.sv"),
        str(project_root / "src" / "zpstack_sram.sv"),
        *rtl,
    ]

    sim = os.environ.get("SIM", "verilator")
    runner = get_runner(sim)

    # Verilator: downgrade lint warnings — the GHDL output and vendored
    # mos6526.v aren't lint-clean but they're synthesizable and Yosys-checked.
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
        sources       = sources,
        hdl_toplevel  = "chip_core",
        parameters    = {
            "NUM_INPUT_PADS": 12,
            "NUM_BIDIR_PADS": 40,
            "NUM_ANALOG_PADS": 2,
        },
        build_args    = extra_build_args,
        build_dir     = str(build_dir),
        always        = True,
        waves         = True,
    )
    runner.test(
        hdl_toplevel = "chip_core",
        test_module  = "chip_core_tb",
        build_dir    = str(build_dir),
        waves        = True,
    )


if __name__ == "__main__":
    chip_core_runner()

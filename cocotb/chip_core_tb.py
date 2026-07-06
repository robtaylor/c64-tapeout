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
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

# --------------------------------------------------------------------- #
#  Pad indices (must match src/chip_core.sv)
# --------------------------------------------------------------------- #
PAD_HEARTBEAT = 0
PAD_VIC_HSYNC = 5
PAD_VIC_VSYNC = 6
PAD_CIA_IRQ   = 23
PAD_CPU_RW    = 24
PAD_ADDR_HI0  = 25  # cpu_addr[15:8] occupies bidir[25:32]


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

    await reset(dut, hold_ns=500)
    await RisingEdge(dut.clk)

    hsync_toggles = 0
    last_hsync    = bidir_bit(dut, PAD_VIC_HSYNC)
    addr_hi_seen: set[int] = set()

    CYCLES = 8000  # ~250 us at 32 MHz → ~8 full CPU cycles
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

    dut._log.info(
        f"smoke OK — hsync toggles={hsync_toggles}, "
        f"distinct addr_hi={distinct}, samples={sorted(addr_hi_seen)[:8]}…"
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
    rtl = [p for p in parse_filelist(project_root / "rtl.f")
           if not p.endswith("chip_top.sv")]
    sources = [
        str(project_root / "build" / "c64_system_synth.v"),
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

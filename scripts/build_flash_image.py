#!/usr/bin/env python3
"""Build the combined C64 QSPI-flash ROM image (WS-P2-10 task 6, ADR 0005).

Produces ``cocotb/fixtures/c64_flash_rom.bin`` — the flat flash image with
KERNAL / BASIC / CHARGEN laid out at the ADR 0005 offset map. This single
artifact is the source of truth for BOTH:

  * the ``sim-smoke`` flash BFM preload (``cocotb/chip_core_tb.py``), and
  * the physical QSPI-flash provisioning step (what gets programmed into the
    external NOR flash on the board).

It replaces parsing the generated LUT-ROM ``.sv`` at test time. The byte source
is the generated ``src/rom_*.sv`` case statements (the only in-repo copy of the
ROM contents). After task 6 deletes those ``.sv`` files this ``.bin`` becomes
the source of truth; regenerating from scratch would need the original Commodore
ROM binaries. Run once, check the result in.

Run:  python3 scripts/build_flash_image.py
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "cocotb" / "fixtures" / "c64_flash_rom.bin"

# (generated .sv, populated depth in bytes, flash byte offset) — ADR 0005 map.
REGIONS = [
    ("rom_kernal.sv", 8192, 0x0000),
    ("rom_basic.sv", 8192, 0x2000),
    ("rom_chargen.sv", 4096, 0x4000),
]
IMAGE_SIZE = 0x5000  # 20 KiB: KERNAL(8K) + BASIC(8K) + CHARGEN(4K), contiguous
RESET_VECTOR = 0xFCE2  # C64 KERNAL reset vector at $FFFC/$FFFD -> flash 0x1FFC


def extract_rom_bytes(sv_path: Path, depth: int) -> bytes:
    """Rebuild a flat byte image from a generated ``rom_*.sv`` case statement.

    The generator (``scripts/mif2rom.py``) encodes each populated address as
    ``N'hAAAA: data = 8'hVV;`` plus a ``default: data = 8'hVV;`` fill byte.
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


def main() -> None:
    image = bytearray(IMAGE_SIZE)
    for name, depth, off in REGIONS:
        image[off : off + depth] = extract_rom_bytes(SRC / name, depth)

    reset_vec = image[0x1FFC] | (image[0x1FFD] << 8)
    assert reset_vec == RESET_VECTOR, (
        f"KERNAL reset vector ${reset_vec:04X} != expected ${RESET_VECTOR:04X} "
        "— ROM image is wrong, refusing to write"
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(bytes(image))
    print(f"wrote {OUT} ({len(image)} bytes); KERNAL reset vector ${reset_vec:04X}")


if __name__ == "__main__":
    main()

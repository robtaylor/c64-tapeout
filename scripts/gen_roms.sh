#!/usr/bin/env bash
# Generate Verilog ROM modules from C64 MIF files.
# Run from project root: bash scripts/gen_roms.sh
set -euo pipefail

cd "$(dirname "$0")/.."

MISTER_ROMS=~/Code/Retro/C64_MiSTer/rtl/roms

echo "Generating rom_chargen.sv (4KB character ROM)..."
python3 scripts/mif2rom.py "$MISTER_ROMS/chargen.mif" rom_chargen 12 > src/rom_chargen.sv

echo "Generating rom_combined.sv (16KB BASIC+KERNAL)..."
# std_C64.mif is 16KB: BASIC at 0x0000-0x1FFF, KERNAL at 0x2000-0x3FFF
# The bus logic addresses it as cpuAddr(14) & cpuAddr(12:0) = {bank, offset}
# For our split ROMs, we generate from the combined MIF then split via
# a Python one-liner.
python3 -c "
import sys
sys.path.insert(0, 'scripts')
from mif2rom import parse_mif, generate_rom
from pathlib import Path

data = parse_mif(Path('$MISTER_ROMS/std_C64.mif'))

# BASIC ROM: addresses 0x0000-0x1FFF (8KB)
basic = {a: v for a, v in data.items() if a < 0x2000}
sys.stdout = open('src/rom_basic.sv', 'w')
generate_rom(basic, 'rom_basic', 13)
sys.stdout = sys.__stdout__
print(f'  rom_basic.sv: {len(basic)} entries')

# KERNAL ROM: addresses 0x2000-0x3FFF, remapped to 0x0000-0x1FFF
kernal = {a - 0x2000: v for a, v in data.items() if a >= 0x2000}
sys.stdout = open('src/rom_kernal.sv', 'w')
generate_rom(kernal, 'rom_kernal', 13)
sys.stdout = sys.__stdout__
print(f'  rom_kernal.sv: {len(kernal)} entries')
"

echo "Done. Generated:"
wc -l src/rom_chargen.sv src/rom_basic.sv src/rom_kernal.sv

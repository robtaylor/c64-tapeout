# VHDL source files — elaboration order (dependencies first)
# Consumed by GHDL for analysis and synthesis (ADR 0002)

# T65 CPU core (6502/65C02/65816)
rtl/t65/T65_Pack.vhd
rtl/t65/T65_ALU.vhd
rtl/t65/T65_MCode.vhd
rtl/t65/T65.vhd

# 6510 CPU wrapper (adds I/O port at $0000/$0001)
rtl/cpu_6510.vhd

# VIC-II video chip
rtl/video_vicII_656x.vhd

# Bus logic / PLA (memory map decode)
rtl/fpga64_buslogic.vhd

# Color palette (VIC color index → RGB)
rtl/fpga64_rgbcolor.vhd

# Single-port RAM (used for color RAM in original; may be replaced)
rtl/spram.vhd

# System integrator (cycle sequencer — to be adapted)
rtl/fpga64_sid_iec.vhd

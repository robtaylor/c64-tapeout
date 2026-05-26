# VHDL source files — elaboration order (dependencies first)
# Consumed by GHDL for analysis and synthesis (ADR 0002)

# T65 CPU core
rtl/t65/T65_Pack.vhd
rtl/t65/T65_ALU.vhd
rtl/t65/T65_MCode.vhd
rtl/t65/T65.vhd

# 6510 CPU wrapper
rtl/cpu_6510.vhd

# VIC-II video chip
rtl/video_vicII_656x.vhd

# Color palette (VIC color index → RGB, unused in tapeout but kept for reference)
rtl/fpga64_rgbcolor.vhd

# Single-port RAM (used for color RAM)
rtl/spram.vhd

# Tapeout-specific bus logic (simplified PLA, no dprom)
rtl/c64_buslogic.vhd

# Tapeout-specific system integrator (stripped-down cycle sequencer)
rtl/c64_system.vhd

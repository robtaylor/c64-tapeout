# Verilog/SystemVerilog source files
# Canonical filelist consumed by cocotb/Icarus, LibreLane, and Jacquard.
# VHDL files are in vhdl.f (handled separately by GHDL).

# CIA (Verilog)
rtl/mos6526.v

# SRAM wrapper
src/sram_wrapper.sv

# ROMs (KERNAL/BASIC/CHARGEN) are external QSPI flash — ADR 0005, no on-die RTL.

# Tapeout integration
src/chip_core.sv
src/chip_top.sv

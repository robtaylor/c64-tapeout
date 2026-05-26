# Verilog/SystemVerilog source files
# Canonical filelist consumed by cocotb/Icarus, LibreLane, and Jacquard.
# VHDL files are in vhdl.f (handled separately by GHDL).

# CIA (Verilog)
rtl/mos6526.v

# SRAM wrapper
src/sram_wrapper.sv

# Synthesized ROMs
src/rom_kernal.sv
src/rom_basic.sv
src/rom_chargen.sv

# Tapeout integration
src/chip_core.sv
src/chip_top.sv

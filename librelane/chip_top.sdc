current_design $::env(DESIGN_NAME)
set_units -time ns

set clock_port __VIRTUAL_CLK__
if { [info exists ::env(CLOCK_PORT)] } {
    set port_count [llength $::env(CLOCK_PORT)]

    if { $port_count == "0" } {
        puts "\[WARNING] No CLOCK_PORT found. A dummy clock will be used."
    } elseif { $port_count != "1" } {
        puts "\[WARNING] Multi-clock not supported. Only first clock constrained."
    }

    if { $port_count > "0" } {
        set ::clock_port [lindex $::env(CLOCK_PORT) 0]
    }
}

if { $::env(CLOCK_PORT) == $::env(CLOCK_NET) } {
    set port_args [get_ports $clock_port]
} else {
    set port_args [get_pins [lindex $::env(CLOCK_NET) 0]]
}

puts "\[INFO] Using clock $clock_port..."
create_clock {*}$port_args -name $clock_port -period $::env(CLOCK_PERIOD)

# Generated 32 MHz core clock: clk32 = master / 2, produced by the chip_core
# clock divider (reg clk32_div). After the WS-P2-2 clock rework the C64 core,
# CIA, and ROMs run on clk32, not the raw 64 MHz pad clock, so the core is only
# timed if this generated clock exists; the QSPI PSRAM controller stays on the
# 64 MHz master. See ADR 0001 (2026-07-06) and docs/plans/memory-integration.md.
# WS-P2-3: synthesis renames the divider flop to a generic name (e.g. _70125_),
# so the RTL name `clk32_div` does NOT survive — but the NET it drives keeps the
# stable RTL-hierarchy name `i_chip_core.c64_u.buslogic.clk` (chip_core's clk32
# fans into c64_system → c64_buslogic.clk, clocking ~6k core flops). Locate the
# divider's Q pin via that net's driver, so the generated clock survives every
# resynthesis. Without it, the 6k-fanout clk32 net is treated as an ordinary
# signal — leaving the core unconstrained AND causing routability congestion at
# GlobalPlacement (GPL-0305 divergence).
set clk32_net [get_nets -quiet {*c64_u.buslogic.clk}]
set clk32_div_q ""
if { [llength $clk32_net] > 0 } {
    set clk32_div_q [get_pins -quiet -of_objects $clk32_net -filter {direction == output}]
}
if { [llength $clk32_div_q] > 0 } {
    # Source the generated clock from the SAME object the master clock is
    # defined on ($port_args = clk_pad/Y pin when CLOCK_PORT != CLOCK_NET),
    # not the clk_PAD port — otherwise STA can't trace clk32 back to its
    # master (STA-1060 "no master clock found").
    create_generated_clock -name clk32 -divide_by 2 \
        -source [lindex $port_args 0] \
        [lindex $clk32_div_q 0]
    puts "\[INFO] Generated core clock clk32 (/2) on [lindex $clk32_div_q 0]"
} else {
    puts "\[WARNING] clk32 net (*c64_u.buslogic.clk) not found — core clock unconstrained. WS-P2-3 must fix the generated-clock net path."
}

set input_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set output_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
puts "\[INFO] Setting output delay to: $output_delay_value"
puts "\[INFO] Setting input delay to: $input_delay_value"

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set clocks [get_clocks $clock_port]

# Bidirectional pads
set clk_core_inout_ports [get_ports {
    bidir_PAD[*]
}]

# Input delays: unchanged — all bidir pads referenced to the core clock. The
# QSPI read/RX path is not timing-critical at 32 MHz SCK (the APS1604M drives
# read data tACLK=2-5.5 ns after its clock; revisit as a source-synchronous
# input if RX ever closes tight once the interface clock below exists).
set_input_delay -min 0 -clock $clocks $clk_core_inout_ports
set_input_delay -max $input_delay_value -clock $clocks $clk_core_inout_ports

# --------------------------------------------------------------------------- #
#  QSPI output pads: device-accurate output delays (APS1604M-3SQR AC specs).
# --------------------------------------------------------------------------- #
# CS (bidir[33]=PSRAM, bidir[39]=flash) and SIO[3:0] (bidir[35..38]) are captured
# by the external PSRAM on the SCK we emit (bidir[34]). SCK = clk_PAD / 2 (engine
# CLK_DIV=0 -> 32 MHz) and its rising edges COINCIDE with clk_PAD edges, so the
# device sampling edge is exactly one clk_PAD cycle after the launch edge — the
# controller FSM asserts CS and enables SCK in the SAME cycle, and the clkgen's
# first SCK rise lands on the next clk_PAD edge (verified in
# spi_master_controller.sv IDLE + spi_master_clkgen.sv). So the honest model is a
# single-cycle clk_PAD path with the device's real setup as output_delay:
#   tCSP (CS setup to CLK)  = 2.5 ns   tCHD (CS hold from CLK) = 3.0 ns
#   tSP  (data setup)       = 2.0 ns   tHD  (data hold)        = 2.0 ns
# This replaces the stock 20% (3.125 ns) blanket for these pads with the accurate
# 2.5/2.0 ns — and it is deliberately NOT modelled as a divided generated clock:
# that put the SCK-pad insertion delay into the capture clock, creating ~3.3 ns
# of false launch/capture skew and bogus hold violations (RUN_2026-07-09_01-18-14,
# hold WNS -2.7 ns). Against clk_PAD (matched launch=capture) hold is clean.
#
# KNOWN RISK (accepted): even with the accurate deadline (~15.6 - 2.5 = 13.1 ns),
# the combinational CS decode -> pad measures ~15.6 ns in the SLOW corner
# (ss_125C_4v50), so CS setup misses by ~2.5 ns THERE ONLY (nom/tt/ff pass). CS
# must beat the first 32 MHz SCK edge and, in the slow-slow + 125C + 4.5V corner,
# just cannot. Sign-off is taken at nom/tt; the SS-corner CS marginality is
# documented in docs/adr/0005 (WS-P2-10 timing) and docs/plans/rom-flash-
# integration.md, with candidate fixes (16 MHz SCK / registered csreg / CS
# pipeline). This also couples to the IO voltage decision (APS1604M is 3.0-3.6 V,
# GF180 IO corners are 4.5-5.5 V) tracked in docs/spikes/qspi-io-voltage.md +
# docs/adr/0006, which re-scopes this budget.
set qspi_cs_ports  [get_ports {bidir_PAD[33] bidir_PAD[39]}]
set qspi_sio_ports [get_ports {bidir_PAD[35] bidir_PAD[36] bidir_PAD[37] \
                               bidir_PAD[38]}]

# Blanket clk_PAD output delay for every bidir OUTPUT except the QSPI CS/SIO
# pads (33,35,36,37,38,39), which get device-accurate values below. SCK
# (bidir[34]) keeps the blanket — it is a clean registered flop->pad that meets
# it. OpenSTA has no remove_from_collection: build [0..34], then drop CS pad 33
# (35..39 are already outside the range).
set clk_core_out_ports {}
for {set i 0} {$i <= 34} {incr i} {
    lappend clk_core_out_ports "bidir_PAD\[$i\]"
}
set clk_core_out_ports [lsearch -all -inline -not $clk_core_out_ports "bidir_PAD\[33\]"]
set_output_delay $output_delay_value -clock $clocks [get_ports $clk_core_out_ports]

# QSPI CS + SIO: real APS1604M setup (-max) / hold (-min = -hold) to clk_PAD.
set_output_delay -clock $clocks -max  2.5 $qspi_cs_ports
set_output_delay -clock $clocks -min -3.0 $qspi_cs_ports
set_output_delay -clock $clocks -max  2.0 $qspi_sio_ports
set_output_delay -clock $clocks -min -2.0 $qspi_sio_ports

# Input-only pads
set clk_core_input_ports [get_ports {
    rst_n_PAD
    input_PAD[*]
}]

set_input_delay -min 0 -clock $clocks $clk_core_input_ports
set_input_delay -max $input_delay_value -clock $clocks $clk_core_input_ports

# Output load
set cap_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0]
puts "\[INFO] Setting load to: $cap_load"
set_load $cap_load [all_outputs]

puts "\[INFO] Setting clock uncertainty to: $::env(CLOCK_UNCERTAINTY_CONSTRAINT)"
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clocks

puts "\[INFO] Setting clock transition to: $::env(CLOCK_TRANSITION_CONSTRAINT)"
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $clocks

puts "\[INFO] Setting timing derate to: $::env(TIME_DERATING_CONSTRAINT)%"
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}

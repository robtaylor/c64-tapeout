# PDN configuration for C64 tapeout
# 8 SRAM macros in 2 rows × 4 columns (N/S orientation alternation)
# Adapted from test-tapeout-1's sram_pdn_ns (wren6991/riscboy-180 pattern)

# Standard cell grid
set_pdn_grid \
    -name stdcell_grid \
    -voltage_domain VDD \
    -pins {Metal3} \
    -straps {Metal2 Metal3} \
    -connect {{Metal2 Metal3}}

add_pdn_stripe \
    -grid stdcell_grid \
    -layer Metal2 \
    -width $::env(PDN_VWIDTH) \
    -spacing $::env(PDN_VSPACING) \
    -pitch $::env(PDN_VPITCH) \
    -offset 5

add_pdn_stripe \
    -grid stdcell_grid \
    -layer Metal3 \
    -width $::env(PDN_HWIDTH) \
    -spacing $::env(PDN_HSPACING) \
    -pitch $::env(PDN_HPITCH) \
    -offset 5

# SRAM macro PDN — Metal4 straps bridging between macro power pins
# and the core grid. Each macro's VDD/VSS pins are on Metal3;
# Metal4 runs vertically to connect to the Metal2/Metal3 grid.
proc sram_pdn_ns {macro_instances} {
    foreach inst $macro_instances {
        set_pdn_grid \
            -name "sram_${inst}" \
            -macro \
            -instances $inst \
            -voltage_domain VDD \
            -halo {5 5 5 5} \
            -straps {Metal4} \
            -connect {{Metal3 Metal4}}

        add_pdn_stripe \
            -grid "sram_${inst}" \
            -layer Metal4 \
            -width 3 \
            -spacing 1 \
            -pitch 30 \
            -offset 5
    }
}

sram_pdn_ns {
    i_chip_core.sram_u.macro_0
    i_chip_core.sram_u.macro_1
    i_chip_core.sram_u.macro_2
    i_chip_core.sram_u.macro_3
    i_chip_core.sram_u.macro_4
    i_chip_core.sram_u.macro_5
    i_chip_core.sram_u.macro_6
    i_chip_core.sram_u.macro_7
}

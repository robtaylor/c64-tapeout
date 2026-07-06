# PDN configuration for C64 tapeout (GF180MCU, 2 × 5V SRAM 256×8 ZP/stack).
#
# Boilerplate (voltage domain + stdcell grid + core ring + default macro
# grid) is adapted verbatim from the LibreLane reference pdn_cfg.tcl
# (Apache-2.0, Copyright 2025 LibreLane Contributors). Project-specific
# addition: the pdn_c64_sram grid that lays Metal4 straps over the 2 on-die
# 5V SRAM macros (bulk RAM is off-die QSPI PSRAM, ADR 0004 §9).

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd

        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }

    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd

        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE \
    -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary

# ---------------------------------------------------------------------
# Standard cell grid (Metal2 + Metal3 — vertical/horizontal straps)
# ---------------------------------------------------------------------
if { $::env(PDN_MULTILAYER) == 1 } {
    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary"  -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_HORIZONTAL_LAYER) \
        -width $::env(PDN_HWIDTH) \
        -pitch $::env(PDN_HPITCH) \
        -offset $::env(PDN_HOFFSET) \
        -spacing $::env(PDN_HSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
} else {
    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary"  -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list
}

# Standard cell rails (Metal1 followpins).
if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}

# ---------------------------------------------------------------------
# Core ring (Metal2 vertical, Metal3 horizontal — set in config.yaml)
# ---------------------------------------------------------------------
if { $::env(PDN_CORE_RING) == 1 } {
    if { $::env(PDN_MULTILAYER) == 1 } {
        set arg_list [list]
        append_if_flag arg_list PDN_CORE_RING_ALLOW_OUT_OF_DIE -allow_out_of_die
        append_if_flag arg_list PDN_CORE_RING_CONNECT_TO_PADS  -connect_to_pads
        append_if_exists_argument arg_list PDN_CORE_RING_CONNECT_TO_PAD_LAYERS -connect_to_pad_layers

        set pdn_core_vertical_layer   $::env(PDN_VERTICAL_LAYER)
        set pdn_core_horizontal_layer $::env(PDN_HORIZONTAL_LAYER)

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            set pdn_core_vertical_layer $::env(PDN_CORE_VERTICAL_LAYER)
        }
        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            set pdn_core_horizontal_layer $::env(PDN_CORE_HORIZONTAL_LAYER)
        }

        add_pdn_ring \
            -grid stdcell_grid \
            -layers   "$pdn_core_vertical_layer $pdn_core_horizontal_layer" \
            -widths   "$::env(PDN_CORE_RING_VWIDTH) $::env(PDN_CORE_RING_HWIDTH)" \
            -spacings "$::env(PDN_CORE_RING_VSPACING) $::env(PDN_CORE_RING_HSPACING)" \
            -core_offset "$::env(PDN_CORE_RING_VOFFSET) $::env(PDN_CORE_RING_HOFFSET)" \
            {*}$arg_list

        # When the core-ring layers differ from the stdcell V/H grid
        # layers, add the cross connects. With Metal2/Metal3 both for
        # ring and grid (our default), pdngen's stdcell V/H connect
        # already covers it — re-adding would error with PDN-0186.
        set core_v $::env(PDN_CORE_VERTICAL_LAYER)
        set core_h $::env(PDN_CORE_HORIZONTAL_LAYER)
        set grid_v $::env(PDN_VERTICAL_LAYER)
        set grid_h $::env(PDN_HORIZONTAL_LAYER)
        # Helper: two unordered-layer pairs are the same connect.
        proc connect_pair_eq {a1 a2 b1 b2} {
            return [expr {($a1 == $b1 && $a2 == $b2) ||
                          ($a1 == $b2 && $a2 == $b1)}]
        }
        if { ![connect_pair_eq $core_v $core_h $grid_v $grid_h] } {
            add_pdn_connect -grid stdcell_grid \
                -layers "$core_v $core_h"
        }
        if { $core_v != "Metal2" && ![connect_pair_eq $core_v "Metal2" $grid_v $grid_h] } {
            add_pdn_connect -grid stdcell_grid \
                -layers "$core_v Metal2"
        }
        if { $core_h != "Metal2" && ![connect_pair_eq $core_h "Metal2" $grid_v $grid_h] } {
            add_pdn_connect -grid stdcell_grid \
                -layers "$core_h Metal2"
        }
    } else {
        throw APPLICATION "PDN_CORE_RING cannot be used when PDN_MULTILAYER is set to false."
    }
}

# Default macro grid (fallback for any non-SRAM macro).
define_pdn_grid \
    -macro \
    -default \
    -name macro \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

add_pdn_connect \
    -grid macro \
    -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"

# ---------------------------------------------------------------------
# 2 × 5V SRAM 256×8 macros (ZP/stack) — Metal4 straps
# ---------------------------------------------------------------------
# Recipe adopted from the silicon-proven sram_pdn_ns from
# wren6991/riscboy-180 (via test-tapeout-1 librelane/pdn/pdn_5v_sram.tcl),
# which ran on the foundry-5V sramNxx8 family — exactly the macro this uses.
# The two connects tie the macro's Metal2/Metal3 power pins into the grid;
# the Metal4 straps deliver power over the macro and reach Metal3 via the
# Metal4↔Metal3 core-ring connect (PDN_CORE_VERTICAL_LAYER=Metal4).
#   - bracket straps: 2 GROUND Metal4 stripes on the macro W/E edges
#     (pitch 432 ≈ macro width 431.86 µm)
#   - internal grid : 7 denser Metal4 stripes across the macro interior
# Use -cells (not -instances): the genvar block in src/zpstack_sram.sv
# yields Yosys-escaped names (macro[0].macro_inst) that break -instances;
# -cells covers both macros since they are the same cell type.
define_pdn_grid \
    -macro \
    -cells gf180mcu_fd_ip_sram__sram256x8m8wm1 \
    -name pdn_c64_sram \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

# Grid V/H are the gf180 defaults Metal4/Metal5, so these are distinct:
#   Metal4↔Metal5 ties the SRAM Metal4 straps to the stdcell Metal5 H-grid;
#   Metal4↔Metal3 vias them down to the macro's Metal3 power pins. (With the
#   old Metal2/Metal3 grid override both collapsed to Metal2-Metal3 → PDN-0186
#   and left the macro pins unreachable.)
add_pdn_connect -grid pdn_c64_sram \
    -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
add_pdn_connect -grid pdn_c64_sram \
    -layers "$::env(PDN_VERTICAL_LAYER) Metal3"

# Bracket the macro with two GROUND Metal4 straps on its W/E edges.
add_pdn_stripe -grid pdn_c64_sram -layer Metal4 \
    -width 2.36 -offset 1.18 -spacing 0.28 \
    -pitch 432 -starts_with GROUND -number_of_straps 2

# The bracket straps block the top-level PDN at Metal4, so add a denser
# internal Metal4 grid to keep the macro's power integrity.
add_pdn_stripe -grid pdn_c64_sram -layer Metal4 \
    -width 4 -offset 46 -spacing 0.28 \
    -pitch 50 -starts_with GROUND -number_of_straps 7

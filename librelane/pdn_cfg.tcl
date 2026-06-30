# PDN configuration for C64 tapeout (GF180MCU, 8 × OCD SRAM 1024×8).
#
# Boilerplate (voltage domain + stdcell grid + core ring + default macro
# grid) is adapted verbatim from the LibreLane reference pdn_cfg.tcl
# (Apache-2.0, Copyright 2025 LibreLane Contributors). Project-specific
# additions: the sram_pdn_ns proc that lays Metal4 straps over our
# 8 OCD SRAM macros, and the macro enumeration that follows.

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
# 8 × OCD SRAM 1024×8 macros — Metal4 straps
# ---------------------------------------------------------------------
# Use -cells to match by macro cell type rather than instance name —
# this avoids the Tcl/pdngen escape trouble with Yosys-escaped Verilog
# identifiers (\[0\], etc.) that breaks the -instances form.
define_pdn_grid \
    -macro \
    -cells gf180mcu_ocd_ip_sram__sram1024x8m8wm1 \
    -name pdn_c64_sram \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

add_pdn_connect -grid pdn_c64_sram \
    -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
# Bridge stdcell straps (Metal4 below if set up) to SRAM Metal3 pins.
# Skip when redundant with the V/H connect above (V=Metal2, H=Metal3 →
# `Metal2 Metal3` already covers Metal2-Metal3).
if { $::env(PDN_VERTICAL_LAYER) != "Metal3" && $::env(PDN_HORIZONTAL_LAYER) != "Metal3" } {
    add_pdn_connect -grid pdn_c64_sram \
        -layers "$::env(PDN_VERTICAL_LAYER) Metal3"
}

# Light Metal4 straps over the OCD SRAM macro footprint. Pitch is
# roomy — this is signoff PDN, not custom power routing.
add_pdn_stripe -grid pdn_c64_sram -layer Metal4 \
    -width 4 -offset 20 -spacing 0.28 \
    -pitch 60 -starts_with GROUND -number_of_straps 4

// SPDX-License-Identifier: Apache-2.0
// C64 tapeout — core integration
//
// Instantiates c64_system (VHDL) which contains the cycle sequencer,
// T65 CPU, VIC-II, CIA1, and bus logic. This module provides:
//   - SRAM wrapper (8KB)
//   - Synthesized ROMs (KERNAL, BASIC, chargen)
//   - Pad I/O steering
//
// Clock: 64 MHz pad, divided by 2 on-chip to the 32 MHz C64 system
// clock (clk32). The 32-state sequencer on clk32 gives ~1 MHz CPU and
// ~8 MHz pixel rate (matching real C64). The raw 64 MHz `clk` is
// reserved for the QSPI PSRAM controller (ADR 0001, 2026-07-06 amend).
//
// Pad allocation (1×1 slot, 40 bidir pads):
//   bidir[0]     — heartbeat (1 Hz from counter)
//   bidir[1..4]  — VIC color output [3:0]
//   bidir[5]     — VIC HSYNC
//   bidir[6]     — VIC VSYNC
//   bidir[7..14] — CIA1 port A [7:0] (keyboard col / GPIO)
//   bidir[15..22]— CIA1 port B [7:0] (keyboard row / GPIO)
//   bidir[23]    — CIA1 IRQ_N
//   bidir[24]    — CPU R/W (1=read, 0=write)
//   bidir[25..32]— CPU address [15:8] (upper byte for debug)
//   bidir[33..39]— spare (active low)

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
) (
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif

    input  wire clk,
    input  wire rst_n,

    input  wire [NUM_INPUT_PADS-1:0] input_in,
    output wire [NUM_INPUT_PADS-1:0] input_pu,
    output wire [NUM_INPUT_PADS-1:0] input_pd,

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,

    inout  wire [NUM_ANALOG_PADS-1:0] analog
);

    // -----------------------------------------------------------------
    // Pad index assignments
    // -----------------------------------------------------------------
    localparam int PAD_HEARTBEAT = 0;
    localparam int PAD_VIC_COL0  = 1;
    localparam int PAD_VIC_HSYNC = 5;
    localparam int PAD_VIC_VSYNC = 6;
    localparam int PAD_CIA_PA0   = 7;
    localparam int PAD_CIA_PA7   = 14;
    localparam int PAD_CIA_PB0   = 15;
    localparam int PAD_CIA_PB7   = 22;
    localparam int PAD_CIA_IRQ   = 23;
    localparam int PAD_CPU_RW    = 24;
    localparam int PAD_ADDR_HI0  = 25;
    localparam int PAD_ADDR_HI7  = 32;
    // QSPI PSRAM pads (ADR 0004 §2)
    localparam int PAD_PSRAM_CSN  = 33;
    localparam int PAD_PSRAM_SCK  = 34;
    localparam int PAD_PSRAM_SIO0 = 35;  // sio1..3 = +1..+3
    // Flash chip-select (ADR 0005): shares SCK/SIO with the PSRAM, second CS on
    // the last spare pad. Pad budget now fully consumed.
    localparam int PAD_PSRAM_CS_FLASH = 39;

    // -----------------------------------------------------------------
    // C64 system ↔ memory/ROM signals
    // -----------------------------------------------------------------
    wire [15:0] ram_addr;
    wire [7:0]  ram_din;
    wire [7:0]  ram_dout;
    wire        ram_ce;
    wire        ram_we;

    // Memory split: $0000-$01FF on-die ZP/stack SRAM, else external QSPI PSRAM
    wire        is_lowpage;
    wire [7:0]  zp_rdata;      // on-die ZP/stack SRAM read data
    wire [7:0]  psram_rdata;   // external QSPI PSRAM read data
    wire        psram_ready;   // controller done strobe (unconsumed for now)
    // Early PSRAM trigger from c64_system (CPU address + write flag, valid at
    // period start; see the sequencer early-trigger in c64_system.vhd).
    wire [15:0] psram_addr;
    wire        psram_ce;
    wire        psram_we;
    wire        psram_is_lowpage;
    wire        psram_cs_n;
    wire        psram_cs_flash_n;   // flash chip-select (CSN1), bidir[39]
    wire        psram_sck;
    wire [3:0]  psram_sio_o;
    wire [3:0]  psram_sio_oe;
    wire [3:0]  psram_sio_i;
    wire        qspi_init_done;     // both enter-QPI passes (PSRAM + flash) complete -> release CPU

    // External flash ROM path (ADR 0005): c64_system forms the 24-bit flash
    // offset + early trigger; the controller returns the captured byte.
    wire [23:0] rom_addr;           // c64_system -> controller (flash offset)
    wire        rom_ce;             // c64_system -> controller (early trigger)
    wire [7:0]  rom_dout;           // controller -> c64_system (captured byte)
    wire        rom_ready;          // controller done strobe (unconsumed for now)
    wire        rom_cs_kernal;
    wire        rom_cs_basic;
    wire        rom_cs_chargen;

    // VIC video
    wire        vic_hsync;
    wire        vic_vsync;
    wire [3:0]  vic_color;

    // CIA1 — register interface (c64_system ↔ mos6526)
    wire        cia_cs;
    wire        cia_rw;
    wire [3:0]  cia_rs;
    wire [7:0]  cia_din;
    wire [7:0]  cia_dout;
    wire        cia_phi2_p;
    wire        cia_phi2_n;
    wire        cia_irq_n;
    wire [7:0]  cia_pa_out_w;
    wire [7:0]  cia_pa_oe_w;
    wire [7:0]  cia_pb_out_w;
    wire [7:0]  cia_pb_oe_w;
    wire        c64_reset;

    // CPU debug
    wire [15:0] cpu_addr_dbg;
    wire        cpu_rw_dbg;

    // -----------------------------------------------------------------
    // Clock divider: `clk` is the 64 MHz pad clock; clk32 = clk/2 is the
    // 32 MHz C64 system clock (ADR 0001, 2026-07-06 amendment). The raw
    // 64 MHz `clk` will drive the QSPI PSRAM controller; clk32 drives the
    // C64 core, CIA, ROMs, and housekeeping counters.
    // -----------------------------------------------------------------
    reg clk32_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            clk32_div <= 1'b0;
        else
            clk32_div <= ~clk32_div;
    end
    wire clk32 = clk32_div;

    // -----------------------------------------------------------------
    // C64 system (VHDL — T65 + VIC-II + bus logic + sequencer)
    // CIA1 interface exposed as ports (mos6526 instantiated below)
    // -----------------------------------------------------------------
    c64_system c64_u (
        .clk32       (clk32),
        // Boot gating (ADR 0005): hold the C64 core in reset until BOTH QPI
        // inits (PSRAM 0x35 + flash 0x38) complete, so the first reset-vector
        // fetch ($FFFC/$FFFD -> KERNAL -> flash) returns valid data.
        .reset_n     (rst_n & qspi_init_done),

        .ramAddr     (ram_addr),
        .ramDin      (ram_din),
        .ramDout     (ram_dout),
        .ramCE       (ram_ce),
        .ramWE       (ram_we),

        .psramCE     (psram_ce),
        .psramAddr   (psram_addr),
        .psramWE     (psram_we),

        .romData     (rom_dout),
        .romAddr     (rom_addr),
        .romCE       (rom_ce),
        .cs_kernal   (rom_cs_kernal),
        .cs_basic    (rom_cs_basic),
        .cs_chargen  (rom_cs_chargen),

        .hsync       (vic_hsync),
        .vsync       (vic_vsync),
        .colorIndex  (vic_color),

        .cia1_cs     (cia_cs),
        .cia1_rw     (cia_rw),
        .cia1_rs     (cia_rs),
        .cia1_din    (cia_din),
        .cia1_dout   (cia_dout),
        .cia1_phi2_p (cia_phi2_p),
        .cia1_phi2_n (cia_phi2_n),
        .cia1_irq_n  (cia_irq_n),

        .cpuAddr_o   (cpu_addr_dbg),
        .cpuRW_o     (cpu_rw_dbg),
        .reset_o     (c64_reset)
    );

    // -----------------------------------------------------------------
    // CIA1 (Verilog — mos6526)
    // -----------------------------------------------------------------
    // TOD clock: ~50 Hz for PAL (counted on the 32 MHz core clock)
    reg todclk;
    reg [19:0] tod_counter;
    always @(posedge clk32 or negedge rst_n) begin
        if (!rst_n) begin
            todclk <= 1'b0;
            tod_counter <= '0;
        end else begin
            if (tod_counter >= 20'd319999) begin
                tod_counter <= '0;
                todclk <= ~todclk;
            end else begin
                tod_counter <= tod_counter + 1'b1;
            end
        end
    end

    mos6526 cia1_u (
        .clk    (clk32),
        .mode   (1'b0),
        .phi2_p (cia_phi2_p),
        .phi2_n (cia_phi2_n),
        .res_n  (~c64_reset),
        .cs_n   (~cia_cs),
        .rw     (cia_rw),

        .rs     (cia_rs),
        .db_in  (cia_din),
        .db_out (cia_dout),

        .pa_in  (bidir_in[PAD_CIA_PA7:PAD_CIA_PA0]),
        .pa_out (cia_pa_out_w),
        .pa_oe  (cia_pa_oe_w),
        .pb_in  (bidir_in[PAD_CIA_PB7:PAD_CIA_PB0]),
        .pb_out (cia_pb_out_w),
        .pb_oe  (cia_pb_oe_w),

        .flag_n (1'b1),
        .tod    (todclk),
        .sp_in  (1'b1),
        .cnt_in (1'b1),
        .irq_n  (cia_irq_n)
    );

    // -----------------------------------------------------------------
    // Memory: on-die 5V ZP/stack SRAM ($0000-$01FF) + external QSPI PSRAM
    // (bulk 64 KB). ADR 0004 §9. ram_din muxes on-die vs PSRAM; the PSRAM
    // controller is only triggered for non-low-page accesses (keeping that
    // traffic off the QSPI bus is the point of the carve-out).
    // -----------------------------------------------------------------
    // Read mux + ZP/stack decode use systemAddr (ram_addr), which equals
    // cpuAddr during the CPU half — so is_lowpage is correct at the CPU sample.
    assign is_lowpage  = (ram_addr[15:9] == 7'b0);   // $0000-$01FF
    assign ram_din     = is_lowpage ? zp_rdata : psram_rdata;
    assign psram_sio_i = bidir_in[PAD_PSRAM_SIO0 +: 4];

    // The PSRAM controller is triggered off the early strobe, whose address is
    // cpuAddr — decode low-page from that so ZP/stack traffic stays off the bus.
    assign psram_is_lowpage = (psram_addr[15:9] == 7'b0);

    zpstack_sram zpstack_u (
        .clk  (clk32),
        .addr (ram_addr[8:0]),
        .din  (ram_dout),           // CPU write data -> memory
        .dout (zp_rdata),           // memory read data -> CPU
        .we   (ram_we),
        .ce   (ram_ce & is_lowpage)
    );

    qspi_psram_ctrl psram_u (
        .clk        (clk),          // 64 MHz -> 32 MHz SCK (CLK_DIV=0)
        .rst_n      (rst_n),
        .ramAddr    (psram_addr),   // CPU address (early trigger)
        .ramDin     (ram_dout),     // CPU write data -> memory
        .ramCE      (psram_ce & ~psram_is_lowpage),
        .ramWE      (psram_we),
        .ramDout    (psram_rdata),  // memory read data -> CPU
        .ready      (psram_ready),
        // Read-only flash ROM port (KERNAL/BASIC/CHARGEN images, ADR 0005)
        .romAddr    (rom_addr),     // 24-bit flash offset (early trigger)
        .romCE      (rom_ce),
        .romDout    (rom_dout),     // flash byte -> c64_system.romData
        .romReady   (rom_ready),
        .init_done  (qspi_init_done),
        .cs_n       (psram_cs_n),
        .cs_flash_n (psram_cs_flash_n),
        .sck        (psram_sck),
        .sio_o      (psram_sio_o),
        .sio_oe     (psram_sio_oe),
        .sio_i      (psram_sio_i)
    );

    // -----------------------------------------------------------------
    // Heartbeat counter (1 Hz at 32 MHz → bit 24)
    // -----------------------------------------------------------------
    reg [24:0] heartbeat_ctr;
    always @(posedge clk32 or negedge rst_n) begin
        if (!rst_n)
            heartbeat_ctr <= '0;
        else
            heartbeat_ctr <= heartbeat_ctr + 1'b1;
    end

    // -----------------------------------------------------------------
    // Pad output steering
    // -----------------------------------------------------------------
    assign input_pu = '0;
    assign input_pd = '0;

    reg [NUM_BIDIR_PADS-1:0] oe_mask;
    reg [NUM_BIDIR_PADS-1:0] ie_mask;
    reg [NUM_BIDIR_PADS-1:0] out_drive;
    integer pi;

    always @* begin
        // Default: all pads driven low (no floating)
        for (pi = 0; pi < NUM_BIDIR_PADS; pi = pi + 1) begin
            oe_mask[pi]   = 1'b1;
            ie_mask[pi]   = 1'b0;
            out_drive[pi] = 1'b0;
        end

        // Heartbeat
        out_drive[PAD_HEARTBEAT] = heartbeat_ctr[24];

        // VIC color [3:0]
        out_drive[PAD_VIC_COL0 +: 4] = vic_color;

        // VIC sync
        out_drive[PAD_VIC_HSYNC] = vic_hsync;
        out_drive[PAD_VIC_VSYNC] = vic_vsync;

        // CIA port A (bidirectional)
        for (pi = PAD_CIA_PA0; pi <= PAD_CIA_PA7; pi = pi + 1) begin
            ie_mask[pi]   = 1'b1;
            out_drive[pi] = cia_pa_out_w[pi - PAD_CIA_PA0];
        end

        // CIA port B (bidirectional)
        for (pi = PAD_CIA_PB0; pi <= PAD_CIA_PB7; pi = pi + 1) begin
            ie_mask[pi]   = 1'b1;
            out_drive[pi] = cia_pb_out_w[pi - PAD_CIA_PB0];
        end

        // CIA IRQ
        out_drive[PAD_CIA_IRQ] = cia_irq_n;

        // CPU R/W
        out_drive[PAD_CPU_RW] = cpu_rw_dbg;

        // CPU address upper byte
        out_drive[PAD_ADDR_HI0 +: 8] = cpu_addr_dbg[15:8];

        // QSPI PSRAM: CS# and SCK are always outputs
        out_drive[PAD_PSRAM_CSN] = psram_cs_n;
        out_drive[PAD_PSRAM_SCK] = psram_sck;
        // QSPI flash CS# (ADR 0005): output-only, shares SCK/SIO with the PSRAM
        out_drive[PAD_PSRAM_CS_FLASH] = psram_cs_flash_n;
        // SIO[3:0]: bidirectional, per-lane output enable from the controller
        for (pi = 0; pi < 4; pi = pi + 1) begin
            ie_mask[PAD_PSRAM_SIO0 + pi]   = 1'b1;
            oe_mask[PAD_PSRAM_SIO0 + pi]   = psram_sio_oe[pi];
            out_drive[PAD_PSRAM_SIO0 + pi] = psram_sio_o[pi];
        end
    end

    assign bidir_oe  = oe_mask;
    assign bidir_ie  = ie_mask;
    assign bidir_out = out_drive;
    assign bidir_cs  = '0;
    assign bidir_sl  = '0;
    assign bidir_pu  = '0;
    assign bidir_pd  = '0;

    wire _unused;
    assign _unused = &{1'b0, input_in, analog,
                       rom_cs_kernal, rom_cs_basic, rom_cs_chargen,
                       cia_pa_oe_w, cia_pb_oe_w, psram_ready, rom_ready};

endmodule

`default_nettype wire

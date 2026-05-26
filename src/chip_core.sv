// SPDX-License-Identifier: Apache-2.0
// C64 tapeout — core integration: T65 CPU + VIC-II + CIA + 8KB SRAM
//
// Clock domain: single 8 MHz dot clock (clk). The C64's internal cycle
// sequencer divides this into CPU phases (~1 MHz effective).
//
// Pad allocation (1×1 slot, 40 bidir pads):
//   bidir[0]     — heartbeat (directly from CIA timer for debug)
//   bidir[1..4]  — VIC color output [3:0] (accent color index)
//   bidir[5]     — VIC HSYNC
//   bidir[6]     — VIC VSYNC
//   bidir[7]     — VIC blanking (active-low display enable)
//   bidir[8..15] — CIA port A (directly accessible GPIO / keyboard col)
//   bidir[16..23]— CIA port B (directly accessible GPIO / keyboard row)
//   bidir[24]    — CIA IRQ_N output
//   bidir[25]    — CPU RW (read/write indicator for logic analyzer)
//   bidir[26..33]— CPU address bus [15:8] (upper byte, for debug)
//   bidir[34..39]— spare (active low, strap-down)
//
// Memory map (ADR 0003):
//   $0000–$1FFF: 8KB SRAM (main RAM)
//   $A000–$BFFF: BASIC ROM (synthesized)
//   $D000–$D3FF: VIC-II registers
//   $D400–$D7FF: SID (absent — returns $00)
//   $D800–$DBFF: Color RAM (synthesized FF)
//   $DC00–$DCFF: CIA1 registers
//   $E000–$FFFF: KERNAL ROM (synthesized)
//   Character ROM: VIC-visible at $1000–$1FFF (VIC bank 0)

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
    localparam int PAD_HEARTBEAT  = 0;
    localparam int PAD_VIC_COL0   = 1;
    localparam int PAD_VIC_COL3   = 4;
    localparam int PAD_VIC_HSYNC  = 5;
    localparam int PAD_VIC_VSYNC  = 6;
    localparam int PAD_VIC_BLANK  = 7;
    localparam int PAD_CIA_PA0    = 8;
    localparam int PAD_CIA_PA7    = 15;
    localparam int PAD_CIA_PB0    = 16;
    localparam int PAD_CIA_PB7    = 23;
    localparam int PAD_CIA_IRQ    = 24;
    localparam int PAD_CPU_RW     = 25;
    localparam int PAD_ADDR_HI0   = 26;
    localparam int PAD_ADDR_HI7   = 33;

    // -----------------------------------------------------------------
    // Reset synchroniser
    // -----------------------------------------------------------------
    reg [1:0] rst_sync;
    wire rst_n_sync = rst_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rst_sync <= 2'b00;
        else
            rst_sync <= {rst_sync[0], 1'b1};
    end

    // -----------------------------------------------------------------
    // C64 core signals (accent bus between modules)
    // -----------------------------------------------------------------

    // CPU bus
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_di;
    wire [7:0]  cpu_do;
    wire        cpu_rw;    // 1=read, 0=write
    wire        cpu_irq_n;
    wire        cpu_nmi_n;

    // VIC-II interface
    wire [13:0] vic_addr;
    wire [7:0]  vic_data;
    wire [3:0]  vic_color;
    wire        vic_hsync;
    wire        vic_vsync;
    wire        vic_den;   // display enable (active during visible area)
    wire        vic_irq_n;

    // CIA interface
    wire [7:0]  cia_pa_in;
    wire [7:0]  cia_pa_out;
    wire [7:0]  cia_pb_in;
    wire [7:0]  cia_pb_out;
    wire        cia_irq_n;

    // Cycle sequencer outputs
    wire        phi0;      // CPU clock enable (active 1 cycle per 8)
    wire        vic_cycle; // VIC memory access cycle
    wire        cpu_cycle; // CPU memory access cycle
    wire        ba;        // bus available (VIC not stealing)

    // Memory bus
    wire [15:0] addr_bus;
    wire [7:0]  data_bus_out;
    wire [7:0]  data_bus_in;
    wire        ram_we;
    wire        ram_ce;

    // Chip-select signals from bus logic
    wire        cs_ram;
    wire        cs_basic;
    wire        cs_kernal;
    wire        cs_chargen;
    wire        cs_vic;
    wire        cs_cia;
    wire        cs_colorram;

    // -----------------------------------------------------------------
    // 8KB SRAM (8 × OCD macros via sram_wrapper)
    // -----------------------------------------------------------------
    wire [7:0] sram_dout;

    sram_wrapper sram_u (
        .clk   (clk),
        .addr  (addr_bus[12:0]),
        .din   (data_bus_out),
        .dout  (sram_dout),
        .we    (ram_we & cs_ram),
        .ce    (cs_ram)
    );

    // -----------------------------------------------------------------
    // Synthesized ROMs
    // -----------------------------------------------------------------
    wire [7:0] kernal_dout;
    wire [7:0] basic_dout;
    wire [7:0] chargen_dout;

    rom_kernal kernal_u (
        .addr (addr_bus[12:0]),
        .data (kernal_dout)
    );

    rom_basic basic_u (
        .addr (addr_bus[12:0]),
        .data (basic_dout)
    );

    rom_chargen chargen_u (
        .addr (vic_addr[11:0]),
        .data (chargen_dout)
    );

    // -----------------------------------------------------------------
    // Color RAM (1024 × 4-bit, synthesized as FF)
    // -----------------------------------------------------------------
    reg [3:0] color_ram [0:1023];
    wire [3:0] color_ram_dout;

    assign color_ram_dout = color_ram[addr_bus[9:0]];

    always @(posedge clk) begin
        if (ram_we && cs_colorram)
            color_ram[addr_bus[9:0]] <= data_bus_out[3:0];
    end

    // -----------------------------------------------------------------
    // Data bus read multiplexer
    // -----------------------------------------------------------------
    assign data_bus_in = cs_ram      ? sram_dout :
                         cs_basic    ? basic_dout :
                         cs_kernal   ? kernal_dout :
                         cs_colorram ? {4'hF, color_ram_dout} :
                         // VIC and CIA will be muxed here once instantiated
                         8'hFF;

    // -----------------------------------------------------------------
    // TODO: Instantiate C64 core modules (WS2)
    //
    // The following modules need to be instantiated here:
    //   - T65 CPU (via cpu_6510 wrapper)
    //   - video_vicII_656x
    //   - mos6526 (CIA1)
    //   - fpga64_buslogic (PLA decode)
    //   - Cycle sequencer (extracted from fpga64_sid_iec)
    //
    // For now, drive outputs with placeholder logic so the design
    // can be elaborated and the flow infrastructure tested.
    // -----------------------------------------------------------------

    // Placeholder: heartbeat counter (proves chip is alive)
    reg [22:0] heartbeat_ctr;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            heartbeat_ctr <= '0;
        else
            heartbeat_ctr <= heartbeat_ctr + 1'b1;
    end

    // Placeholder outputs (will be replaced by real C64 signals)
    assign cpu_addr = '0;
    assign cpu_do = '0;
    assign cpu_rw = 1'b1;
    assign vic_color = '0;
    assign vic_hsync = 1'b1;
    assign vic_vsync = 1'b1;
    assign vic_den = 1'b0;
    assign cia_pa_out = '0;
    assign cia_pb_out = '0;
    assign cia_irq_n = 1'b1;
    assign addr_bus = '0;
    assign data_bus_out = '0;
    assign ram_we = 1'b0;
    assign cs_ram = 1'b0;
    assign cs_basic = 1'b0;
    assign cs_kernal = 1'b0;
    assign cs_chargen = 1'b0;
    assign cs_vic = 1'b0;
    assign cs_cia = 1'b0;
    assign cs_colorram = 1'b0;
    assign vic_addr = '0;

    // CIA port A/B directly connected to pads (directly usable as GPIO)
    assign cia_pa_in = bidir_in[PAD_CIA_PA7:PAD_CIA_PA0];
    assign cia_pb_in = bidir_in[PAD_CIA_PB7:PAD_CIA_PB0];

    // -----------------------------------------------------------------
    // Pad output / OE / IE assignment
    // -----------------------------------------------------------------
    assign input_pu = '0;
    assign input_pd = '0;

    reg [NUM_BIDIR_PADS-1:0] oe_mask;
    reg [NUM_BIDIR_PADS-1:0] ie_mask;
    reg [NUM_BIDIR_PADS-1:0] out_drive;
    integer pi;
    always @* begin
        // Default: all pads output-driven low (no floating)
        for (pi = 0; pi < NUM_BIDIR_PADS; pi = pi + 1) begin
            oe_mask[pi]   = 1'b1;
            ie_mask[pi]   = 1'b0;
            out_drive[pi] = 1'b0;
        end

        // Heartbeat
        out_drive[PAD_HEARTBEAT] = heartbeat_ctr[22];

        // VIC color [3:0]
        out_drive[PAD_VIC_COL0 +: 4] = vic_color;

        // VIC sync/blanking
        out_drive[PAD_VIC_HSYNC] = vic_hsync;
        out_drive[PAD_VIC_VSYNC] = vic_vsync;
        out_drive[PAD_VIC_BLANK] = vic_den;

        // CIA port A (bidirectional)
        for (pi = PAD_CIA_PA0; pi <= PAD_CIA_PA7; pi = pi + 1) begin
            oe_mask[pi]   = 1'b1;  // TODO: use CIA DDRA for per-bit OE
            ie_mask[pi]   = 1'b1;
            out_drive[pi] = cia_pa_out[pi - PAD_CIA_PA0];
        end

        // CIA port B (bidirectional)
        for (pi = PAD_CIA_PB0; pi <= PAD_CIA_PB7; pi = pi + 1) begin
            oe_mask[pi]   = 1'b1;  // TODO: use CIA DDRB for per-bit OE
            ie_mask[pi]   = 1'b1;
            out_drive[pi] = cia_pb_out[pi - PAD_CIA_PB0];
        end

        // CIA IRQ (active-low output)
        out_drive[PAD_CIA_IRQ] = cia_irq_n;

        // CPU RW
        out_drive[PAD_CPU_RW] = cpu_rw;

        // CPU address upper byte (debug)
        out_drive[PAD_ADDR_HI0 +: 8] = cpu_addr[15:8];
    end

    assign bidir_oe  = oe_mask;
    assign bidir_ie  = ie_mask;
    assign bidir_out = out_drive;
    assign bidir_cs  = '0;
    assign bidir_sl  = '0;
    assign bidir_pu  = '0;
    assign bidir_pd  = '0;

    // Unused signals
    wire _unused;
    assign _unused = &{1'b0, input_in, analog,
                       cpu_di, cpu_irq_n, cpu_nmi_n,
                       vic_data, vic_irq_n,
                       phi0, vic_cycle, cpu_cycle, ba};

endmodule

`default_nettype wire

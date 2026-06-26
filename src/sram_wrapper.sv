// SPDX-License-Identifier: Apache-2.0
// 8KB SRAM from 8 × gf180mcu_ocd_ip_sram__sram1024x8m8wm1 macros
//
// Linear 8KB address space (13-bit address). Upper 3 bits select macro,
// lower 10 bits select word within the macro. Single-port, 8-bit data.

`default_nettype none

module sram_wrapper (
    input  wire        clk,
    input  wire [12:0] addr,
    input  wire [7:0]  din,
    output wire [7:0]  dout,
    input  wire        we,
    input  wire        ce
);

    wire [2:0] macro_sel = addr[12:10];
    wire [9:0] word_addr = addr[9:0];

    wire [7:0] macro_dout [0:7];
    wire [7:0] macro_ce;

    // Decode macro chip-enable
    assign macro_ce[0] = ce & (macro_sel == 3'd0);
    assign macro_ce[1] = ce & (macro_sel == 3'd1);
    assign macro_ce[2] = ce & (macro_sel == 3'd2);
    assign macro_ce[3] = ce & (macro_sel == 3'd3);
    assign macro_ce[4] = ce & (macro_sel == 3'd4);
    assign macro_ce[5] = ce & (macro_sel == 3'd5);
    assign macro_ce[6] = ce & (macro_sel == 3'd6);
    assign macro_ce[7] = ce & (macro_sel == 3'd7);

    // Output mux
    assign dout = macro_dout[macro_sel];

    // Instantiate 8 SRAM macros
    generate
        for (genvar i = 0; i < 8; i++) begin : macro
            `ifdef USE_SRAM_MACROS
            gf180mcu_ocd_ip_sram__sram1024x8m8wm1 macro_inst (
                .CLK  (clk),
                .CEN  (~macro_ce[i]),   // active-low chip enable
                .GWEN (~(we & macro_ce[i])), // active-low global write enable
                .WEN  (8'h00),          // byte write enables (active-low, all bytes)
                .A    (word_addr),
                .D    (din),
                .Q    (macro_dout[i])
            );
            `else
            // Behavioural model for simulation
            reg [7:0] mem [0:1023];
            always @(posedge clk) begin
                if (macro_ce[i]) begin
                    if (we)
                        mem[word_addr] <= din;
                end
            end
            assign macro_dout[i] = mem[word_addr];

            `ifdef SIM_PRELOAD_BACKDOOR
            initial begin
                // Preload from hex file for simulation
                $readmemh("sram_init.hex", mem);
            end
            `endif
            `endif
        end
    endgenerate

endmodule

`default_nettype wire

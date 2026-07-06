// SPDX-License-Identifier: Apache-2.0
// 512 B zero-page + stack SRAM — 2 × gf180mcu_fd_ip_sram__sram256x8m8wm1
// (5V-native macros). Covers $0000-$01FF: page 0 (zero page) + page 1
// (6502 stack). ADR 0004 §9; docs/plans/memory-integration.md.
//
// addr[8] selects the macro (0 = page 0, 1 = page 1); addr[7:0] is the word
// within the 256-byte macro. Single-port, 8-bit, synchronous write AND
// synchronous (registered) read — matching the fd_ip_sram macro, whose Q is
// registered. The behavioural fallback registers Q the same way so simulation
// matches silicon.
//
// The 6510 processor port overlays $0000/$0001 (cpu_6510.vhd): reads of those
// two addresses return the port register, not the bus, so the shadow write
// into this SRAM underneath is harmless and needs no exclusion.

`default_nettype none

module zpstack_sram (
    input  wire        clk,
    input  wire [8:0]  addr,
    input  wire [7:0]  din,
    output wire [7:0]  dout,
    input  wire        we,
    input  wire        ce
);

    wire       macro_sel = addr[8];     // 0 = page 0 (ZP), 1 = page 1 (stack)
    wire [7:0] word_addr = addr[7:0];

    wire [7:0] macro_dout [0:1];
    wire [1:0] macro_ce;

    assign macro_ce[0] = ce & (macro_sel == 1'b0);
    assign macro_ce[1] = ce & (macro_sel == 1'b1);

    // Registered read: Q reflects the macro selected on the previous clock.
    // Latch the selector so the output mux tracks the registered data.
    reg macro_sel_q;
    always @(posedge clk) begin
        if (ce)
            macro_sel_q <= macro_sel;
    end
    assign dout = macro_dout[macro_sel_q];

    generate
        for (genvar i = 0; i < 2; i++) begin : macro
            `ifdef USE_SRAM_MACROS
            gf180mcu_fd_ip_sram__sram256x8m8wm1 macro_inst (
                .CLK  (clk),
                .CEN  (~macro_ce[i]),          // active-low chip enable
                .GWEN (~(we & macro_ce[i])),   // active-low global write enable
                .WEN  (8'h00),                 // per-bit write enable (active-low, all bytes)
                .A    (word_addr),
                .D    (din),
                .Q    (macro_dout[i])
            );
            `else
            // Behavioural model — synchronous write, registered read (matches
            // the fd_ip_sram macro's Q).
            reg [7:0] mem [0:255];
            reg [7:0] q_reg;
            always @(posedge clk) begin
                if (macro_ce[i]) begin
                    if (we)
                        mem[word_addr] <= din;
                    else
                        q_reg <= mem[word_addr];
                end
            end
            assign macro_dout[i] = q_reg;
            `endif
        end
    endgenerate

endmodule

`default_nettype wire

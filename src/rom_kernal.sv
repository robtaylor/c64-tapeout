// SPDX-License-Identifier: Apache-2.0
// C64 KERNAL ROM — 8KB synthesized as combinational logic
// Generated from ROM binary (placeholder — real content in WS2)

`default_nettype none

module rom_kernal (
    input  wire [12:0] addr,
    output reg  [7:0]  data
);

    // TODO (WS2): Replace with actual KERNAL ROM content.
    // Use a script to convert the 8KB binary to a case statement.
    // For now, provide the reset vector pointing to $E000 and a
    // simple infinite loop at that address.
    always @* begin
        case (addr)
            // Reset vector: $FFFC/$FFFD → $E000
            13'h1FFC: data = 8'h00; // low byte
            13'h1FFD: data = 8'hE0; // high byte
            // NMI vector: $FFFA/$FFFB → $FE47 (stub)
            13'h1FFA: data = 8'h47;
            13'h1FFB: data = 8'hFE;
            // IRQ vector: $FFFE/$FFFF → $FF48 (stub)
            13'h1FFE: data = 8'h48;
            13'h1FFF: data = 8'hFF;
            // $E000: JMP $E000 (infinite loop for now)
            13'h0000: data = 8'h4C; // JMP
            13'h0001: data = 8'h00; // low
            13'h0002: data = 8'hE0; // high
            // $FE47: RTI (NMI handler stub)
            13'h1E47: data = 8'h40; // RTI
            // $FF48: RTI (IRQ handler stub)
            13'h1F48: data = 8'h40; // RTI
            default:  data = 8'hEA; // NOP fill
        endcase
    end

endmodule

`default_nettype wire

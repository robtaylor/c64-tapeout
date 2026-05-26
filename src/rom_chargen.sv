// SPDX-License-Identifier: Apache-2.0
// C64 Character Generator ROM — 4KB synthesized as combinational logic
// Generated from ROM binary (placeholder — real content in WS2)

`default_nettype none

module rom_chargen (
    input  wire [11:0] addr,
    output reg  [7:0]  data
);

    // TODO (WS2): Replace with actual character ROM content.
    // The C64 chargen contains 2 × 128 characters × 8 bytes = 4KB.
    // For now, provide a simple test pattern.
    always @* begin
        // Simple pattern: each character is 8 horizontal lines
        // where the line pattern is the character code XOR the row
        data = {addr[10:3]} ^ {5'b0, addr[2:0]};
    end

endmodule

`default_nettype wire

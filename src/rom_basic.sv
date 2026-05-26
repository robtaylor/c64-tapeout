// SPDX-License-Identifier: Apache-2.0
// C64 BASIC ROM — 8KB synthesized as combinational logic
// Generated from ROM binary (placeholder — real content in WS2)

`default_nettype none

module rom_basic (
    input  wire [12:0] addr,
    output reg  [7:0]  data
);

    // TODO (WS2): Replace with actual BASIC ROM content or
    // open-source replacement (OpenROMs).
    always @* begin
        data = 8'hEA; // NOP fill
    end

endmodule

`default_nettype wire

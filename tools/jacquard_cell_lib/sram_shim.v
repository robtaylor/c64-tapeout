/* SPDX-License-Identifier: Apache-2.0

   Jacquard `--cell-library` shim for the GF180MCU foundry SRAM macro used by
   the C64 tapeout: gf180mcu_fd_ip_sram__sram256x8m8wm1 (2 instances form the
   512 B on-die ZP/stack SRAM, ADR 0004). Cosim treats the hard macro as an
   opaque RAM; this file declares its pin directions in the form sverilogparse
   accepts (non-ANSI: names in header + separate input/output decls), and the
   sibling manifest `sram_shim.cells.toml` tags it `kind = "ram"` so Jacquard
   builds a RAMBlock (port-resolved pins, active-low polarity composition,
   tick-0 preload).

   Pin shape is factual — it mirrors the PDK blackbox at
   gf180mcu/gf180mcuD/libs.ref/gf180mcu_fd_ip_sram/verilog/
   gf180mcu_fd_ip_sram__sram256x8m8wm1__blackbox.v. Power pins (VDD/VSS) are
   omitted: they only appear under USE_POWER_PINS, which sim does not define. */

module gf180mcu_fd_ip_sram__sram256x8m8wm1 (CLK, CEN, GWEN, WEN, A, D, Q);
  input        CLK;
  input        CEN;
  input        GWEN;
  input  [7:0] WEN;
  input  [7:0] A;
  input  [7:0] D;
  output [7:0] Q;
endmodule

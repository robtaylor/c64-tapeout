# Spike — Can GHDL-Yosys synthesize the C64 VHDL subset?

**Status:** Open. Time-box: ≤ 1 day; abort if Q1 fails.

## Question

Can the GHDL-Yosys plugin successfully analyze, elaborate, and synthesize all VHDL modules in the C64 tapeout subset into Yosys RTLIL, ready for ABC mapping to GF180 cells?

## Why this is in question

The C64 core is ~5000 lines of VHDL from the FPGA64 project (2005-2021), targeting Altera/Intel FPGAs. GHDL-Yosys support for arbitrary VHDL varies — some constructs (shared variables, attribute declarations, MIF-loaded ROMs) may not synthesize cleanly. If GHDL-Yosys can't handle the VHDL, we need to fall back to Verilog conversion (ADR 0002 walk-back).

## Approach

- **Q1.** Does `ghdl -a` (analysis) pass on all VHDL files?
  - Step 1: Enter nix shell (`nix develop`)
  - Step 2: Run `ghdl -a --std=08 -fsynopsys` on each file in vhdl.f order
  - Step 3: Record any errors

- **Q2.** Does `ghdl --synth` produce RTLIL for c64_system?
  - Step 1: Run `ghdl --synth --out=verilog c64_system` (or RTLIL output)
  - Step 2: Check for unsupported construct errors
  - Step 3: Feed output to Yosys `read_rtlil` / `read_verilog`
  - Step 4: Run `synth` (generic) to verify elaboration

## Decision matrix

| Outcome | Means | Action |
|---|---|---|
| Q1 fails | GHDL can't parse some VHDL constructs | Patch or rewrite failing files; if >2 files fail, walk back to Verilog conversion |
| Q1 passes, Q2 fails | GHDL understands the code but can't synthesize it | Identify unsynthesizable constructs, patch them; if systemic, walk back |
| Both pass | VHDL→RTLIL pipeline works | ADR 0002 confirmed; proceed with WS4 LibreLane integration |

## Findings

(To be filled in when running the spike)

## Outcome

(Pending)

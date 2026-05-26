# ADR 0002 — VHDL synthesis via GHDL-Yosys plugin

**Status:** Accepted (2026-05-26).

**TL;DR.** In the context of synthesizing a VHDL C64 core (T65 + VIC-II + bus logic) through the LibreLane/Yosys flow, facing Yosys's lack of native VHDL support, we chose to use the GHDL-Yosys plugin to synthesize VHDL directly, accepting dependency on GHDL availability in the Nix dev shell.

## Context

The C64 MiSTer core's critical logic is VHDL (the FPGA64 codebase by Peter Wendrich):
- T65 CPU: 4 files, ~2460 lines VHDL
- VIC-II: 1 file, 1756 lines VHDL
- Bus logic: 390 lines VHDL
- 6510 wrapper: 107 lines VHDL
- Color palette: 193 lines VHDL
- Color RAM: 46 lines VHDL

The CIA (mos6526.v, 531 lines) is already Verilog. The tapeout wrapper (chip_top.sv, chip_core.sv) will be SystemVerilog.

LibreLane uses Yosys for synthesis. Yosys has no native VHDL frontend, but the ghdl-yosys-plugin bridges GHDL's VHDL analysis/elaboration into Yosys's RTLIL intermediate representation.

## Decision

1. Use the **ghdl-yosys-plugin** (`ghdl --synth` frontend for Yosys) to synthesize VHDL modules directly.
2. Add GHDL + ghdl-yosys-plugin to the Nix flake dev shell.
3. In `librelane/config.yaml`, use LibreLane's `EXTRA_SYNTH_COMMANDS` or a custom synthesis script that invokes `ghdl --synth` to import VHDL as RTLIL before Yosys's ABC mapping pass.
4. Maintain a `vhdl.f` filelist (parallel to `rtl.f`) listing VHDL source files in elaboration order.
5. Keep original VHDL unmodified where possible — minimal patches only for GF180-incompatible constructs (e.g., initial values on signals that map to flip-flops).

## Alternatives considered

- **Convert all VHDL to Verilog** — rejected because it's a significant one-time effort (~4600 lines), risks introducing translation bugs, and breaks traceability to the upstream C64_MiSTer codebase. Walk-back option if GHDL hits blockers.
- **Use Verific (commercial)** — rejected because it's proprietary, not available in open-source flows, and defeats the point of an open tapeout.
- **Rewrite from scratch in SystemVerilog** — rejected because the existing VHDL is proven (passes Lorenz test suite for T65, known-good VIC-II timing).

## Consequences

- The Nix flake must include `ghdl` and `yosys-ghdl` (or build ghdl-yosys-plugin from source).
- Synthesis script order matters: GHDL must analyze all VHDL files before `ghdl --synth` can elaborate the top-level VHDL entity.
- Mixed-language design: VHDL entities instantiated from SystemVerilog chip_core.sv requires Yosys to see both the GHDL-imported RTLIL modules and the Verilog/SV modules in the same session.
- VHDL `initial` blocks and `signal x := value` default assignments need review — GHDL-Yosys maps these to reset values, which is correct for FFs but must be verified against the ASIC flow (no initial values without explicit reset).
- cocotb simulation will use GHDL as the VHDL simulator (already supported by cocotb) or Icarus with the Verilog-converted output for gate-level sim.

## Walk-back options

- **If GHDL-Yosys can't handle a specific VHDL construct** — convert just that file to Verilog (`ghdl --synth --out=verilog` can dump Verilog for individual entities).
- **If the entire GHDL approach is too fragile** — bulk-convert to Verilog and commit as a one-time snapshot (ADR amendment, not supersession).

## Links

- ADR 0001 — system scope (defines which VHDL files are in scope)
- `vhdl.f` — VHDL filelist (elaboration order)
- `rtl.f` — Verilog/SV filelist

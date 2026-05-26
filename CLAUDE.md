# C64 Tapeout — GF180MCU via wafer.space

Commodore 64 subset tapeout: T65 CPU + VIC-II + 8KB SRAM + 1× CIA on GF180MCU 1×1 slot.

## Project memory discipline

This project uses the four-document discipline from
<https://robtaylor.github.io/claude-project-discipline/>. Four kinds of
project memory, each with a clear home and a clear lifecycle:

| Doc kind | Lives in | Lifetime | Answers |
|---|---|---|---|
| **Architecture Decision Record (ADR)** | `docs/adr/NNNN-*.md` | Forever; amended in place; never deleted | *Why* did we choose this? |
| **Plan** | `docs/plans/<topic>.md` | Long-lived; updated as work lands | *What's next, in what order?* |
| **Spike** | `docs/spikes/<topic>.md` | Forever, marked Resolved | *Did this idea work?* |
| **Handoff** | `docs/handoffs/<topic>-handoff.md` | Ephemeral — folded into the others, then deleted | *What's in flight right now?* |

The load-bearing rule: **information has exactly one home, and the
handoff is the only doc that gets deleted.**

### Where things go

| If you're about to write… | It belongs in… |
|---|---|
| "We chose X over Y because Z" | A new ADR |
| "What needs to happen next, in what order" | The relevant plan doc |
| "I want to validate <assumption> before committing" | A new spike |
| "Here's what's in flight right now" | A handoff |

## Build commands

```bash
nix develop            # Enter dev shell (LibreLane 3.0 + GHDL + cocotb)
make clone-pdk         # Fetch GF180MCU PDK
make sim               # cocotb RTL simulation
make librelane-pdn     # Fast PnR iteration (skip DRC/LVS)
make librelane         # Full signoff flow
make jacquard-ir       # Jacquard timing IR (stage 1)
make jacquard-cosim    # Jacquard GPU cosim (stage 2)
```

## RTL source

The C64 core RTL lives in `rtl/` (copied from C64_MiSTer with minimal modifications):
- VHDL: T65 CPU, VIC-II, bus logic, 6510 wrapper, color palette
- Verilog: CIA 6526
- SystemVerilog: chip_top.sv, chip_core.sv (tapeout wrapper)

VHDL is synthesized via the GHDL-Yosys plugin (ghdl --synth → Yosys RTLIL).

## Key constraints

- Clock: single-domain, targeting ~8 MHz (C64 dot clock). See ADR 0001.
- Memory: 8 × OCD SRAM macros (8KB main RAM) + ROMs synthesized as LUTs.
- PDK: gf180mcu_fd_sc_mcu9t5v0 (9-track 5V). Must export STD_CELL_LIBRARY before LibreLane.
- Slot: 1×1 (3932×5122 µm die).

## Reference

- `~/Code/Apitronix/test-tapeout-1` — Hazard3 tapeout (crib for flow/infra)
- `~/Code/Retro/C64_MiSTer` — source RTL (FPGA64 by Peter Wendrich)

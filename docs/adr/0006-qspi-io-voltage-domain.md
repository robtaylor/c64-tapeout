# ADR 0006 — QSPI IO voltage domain (3.3 V memories vs 5 V GF180 IO)

**Status:** Proposed (2026-07-09) — **decision pending** the investigation in
[spike: QSPI IO voltage](../spikes/qspi-io-voltage.md). Extends
[ADR 0004](0004-external-qspi-psram.md) (external QSPI PSRAM) and
[ADR 0005](0005-external-flash-roms.md) (external QSPI flash), which put the bulk
RAM and the ROMs on a shared QSPI bus.

## Context

The QSPI memories are 3.3 V parts (PSRAM APS1604M-3SQR, VDD 3.0–3.6 V; a
QPI NOR flash of the same class). The die uses the GF180 **5 V** standard-cell and
IO libraries. The shared QSPI bus (SCK/CS/SIO on `bidir[33..39]`) therefore
crosses a voltage domain, and the crossing choice **changes the timing budget** we
sign off against — the QSPI CS setup path is already marginal in the slow corner
at 5 V (ADR 0005, 2026-07-09 amendment).

## Decision

**Pending.** Choose between:

1. **External level shifters** (GF180 5 V IO ↔ 3.3 V memories). Keeps the pads at
   their characterised 5 V, but adds shifter propagation delay into the device
   tCSP/tSP window and consumes board area.
2. **Under-voltage GF180 IO at 3.3 V** (no shifters). Removes shifter delay and
   simplifies the board, but invalidates the 4.5–5.5 V pad-timing corners
   (pads run slower at 3.3 V → current STA is optimistic) and depends on
   under-voltage IO being a sanctioned, confirmed configuration.

The spike resolves which is viable and supplies the delay/characterisation
numbers; this ADR will record the decision and its rationale.

## Consequences

_To be completed on decision._ Whichever is chosen, the QSPI `output_delay`
budget in `librelane/chip_top.sdc` must be updated with the real numbers
(shifter tPD, or 3.3 V IO timing), and the ss-corner CS setup acceptance in
ADR 0005 re-evaluated against that budget.

## Alternatives considered

- _(captured in the spike; summarised here on decision.)_

## References

- [Spike — QSPI IO voltage](../spikes/qspi-io-voltage.md)
- [ADR 0004 — External QSPI PSRAM + ZP/stack carve-out](0004-external-qspi-psram.md)
- [ADR 0005 — External QSPI flash for ROMs](0005-external-flash-roms.md) (2026-07-09 amendment: source-synchronous QSPI timing + ss-corner CS risk)
- APS1604M-3SQR datasheet: `docs/APM_PSRAM_E5_QSPI (APS1604M-3SQR KGD_PKG) v3.1.pdf`

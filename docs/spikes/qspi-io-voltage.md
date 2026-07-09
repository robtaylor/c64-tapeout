# Spike — QSPI IO voltage: 3.3 V PSRAM/flash vs 5 V GF180 IO

**Status:** Open (2026-07-09). Blocks the final QSPI timing budget and the
sign-off IO characterisation. Decision recorded in
[ADR 0006](../adr/0006-qspi-io-voltage-domain.md).

## Question

The external QSPI memories are **3.3 V parts** (PSRAM: APS1604M-3SQR, VDD
3.0–3.6 V; flash: a QPI NOR of the same class). The C64 tapeout uses the GF180
**5 V** IO and standard-cell libraries (`gf180mcu_fd_sc_mcu9t5v0`,
`gf180mcu_fd_io__bi_24t`). How do we bridge the voltage domain on the shared QSPI
bus (SCK/CS/SIO on `bidir[33..39]`), and what does that choice do to the timing
budget we sign off against?

Two candidate approaches:
- **(A) External level shifters** between the GF180 5 V pads and the 3.3 V memories.
- **(B) Run the GF180 IO under-voltage at 3.3 V** (drive VDDIO of the QSPI pads at
  3.3 V), no shifters.

## Why this is in question

- **Timing coupling.** ADR 0005 (2026-07-09 amendment) shows the QSPI CS setup
  path already misses by ~2.5 ns in the slow corner *at 5 V*. Each approach moves
  that budget:
  - (A) adds level-shifter propagation delay (part-dependent, ~1–10 ns) directly
    into the device tCSP/tSP window, and may add SCK-vs-CS/SIO channel skew — this
    could dominate the failure.
  - (B) means the 4.5–5.5 V pad-timing corners **no longer describe the pads**: at
    3.3 V the GF180 IO is weaker/slower than even `ss_..._4v50`, so current STA is
    *optimistic*. Correct sign-off would need 3.3 V IO characterisation (may not
    exist in the PDK) or a documented derate.
- **"Works fine" is unconfirmed.** Under-voltage GF180 IO operation at 3.3 V is
  reported to work but is **not vendor-confirmed here**. A tapeout should not
  commit to it on hearsay.
- **Pad budget / area.** External shifters need board area and possibly more pads
  or a shared-rail scheme; the 1×1 slot pad budget is already fully consumed
  (`bidir[39]` was the last spare, ADR 0005).

## Approach

- **Q1 — Is under-voltage 3.3 V operation of the GF180 5 V IO supported?**
  - Read the `gf180mcu_fd_io` databook / cell docs for a 3.3 V VDDIO mode or a
    supported operating range on `bi_24t` (and the `sl`/`ie`/`cs` controls).
  - Check whether the PDK ships 3.3 V IO corner `.lib`s (grep the PDK
    `libs.ref/gf180mcu_fd_io/lib` for a 3v3 / 3p3 variant).
  - Ask wafer.space / the GF180 community whether under-voltage IO is a
    sanctioned tapeout configuration.

- **Q2 — If level shifters: pick a part and get its delay.**
  - Choose an auto-direction or dir-controlled QSPI-capable shifter (must pass
    32 MHz SCK + bidirectional SIO). Record tPD and channel-skew.
  - Recompute the CS/SIO budget: does tCSP(2.5) − tPD still close at nom/tt?

- **Q3 — Timing re-scope for the chosen path.**
  - (A): add the shifter delay to `output_delay` in `chip_top.sdc`; re-run STA.
  - (B): obtain/derate 3.3 V IO timing; re-characterise or apply a documented
    margin; re-run STA at the 3.3 V-equivalent corner.

## Decision matrix

| Outcome | Means | Action |
|---|---|---|
| Q1 confirms 3.3 V IO supported + PDK has (or we can derate to) 3.3 V corners | Under-voltage is legitimate | Prefer (B): no shifter delay, simplest board; re-sign-off at 3.3 V IO timing |
| Q1 unsupported / unconfirmable | Under-voltage is a silicon gamble | Take (A) with a chosen shifter; fold its tPD into the QSPI SDC budget |
| Q2 shifter tPD blows tCSP/tSP even at nom/tt | Shifters too slow for 32 MHz phase | Reconsider: slower SCK (ADR 0005 fixes), or a source-synchronous CS pipeline |

## Findings

- 2026-07-09: Spike opened. APS1604M AC specs extracted for the timing budget
  (tCSP 2.5, tCHD 3.0, tSP/tHD 2.0, tACLK 2–5.5 ns; QPI 0xEB read max 84–133 MHz,
  so our 32 MHz SCK has ample frequency margin — the constraint is phase/skew, not
  frequency). See ADR 0005 (2026-07-09 amendment).
- _(pending Q1/Q2/Q3)_

## Outcome

_Pending._ Feeds [ADR 0006](../adr/0006-qspi-io-voltage-domain.md) and re-scopes
the QSPI CS/SIO timing budget in [ADR 0005](../adr/0005-external-flash-roms.md)
and [`docs/plans/rom-flash-integration.md`](../plans/rom-flash-integration.md).

# Design Spike: User-Provided Cosim Models in Jacquard
Consumer: reactive QSPI PSRAM model for C64 tapeout post-PnR gate-level timing cosim
Repo investigated: /tmp/claude/jacquard-spike (github.com/gpu-eda/jacquard @ b842bd7)
Confidence tags: [V]=verified by reading source, [I]=inferred from code/docs

---

## TL;DR

Jacquard **already has** a reactive-peripheral cosim architecture — it is not a
greenfield feature. Two distinct seams exist:

1. **Tier-1 CPU `PeripheralModel` trait** (`src/sim/models/mod.rs:56` [V]) — the
   general, user-facing seam. Bidirectional reactive models already ship on it
   (SPI slave, I2C). Cost: a mid-transaction model sets `is_active()==true`,
   which forces `batch=1` (one GPU dispatch per scheduler edge). General but slow.

2. **Bespoke GPU-kernel peripherals** baked into the `CosimBackend` trait — the
   SPI *flash* (`FlashState`, `gpu_apply_flash_din`, `gpu_flash_model_step`,
   `csrc/kernel_v1.metal:717+` [V]). Runs *inside* the batch → 100% batched, full
   GPU throughput. Fast but hardcoded per-backend (Metal + CUDA/HIP + CPU mirror),
   not user-provided.

The critical finding for QSPI PSRAM: **the existing SPI-flash GPU peripheral is
~90% of a QSPI PSRAM already** — it does `data_width = 1|4` (SPI/QSPI), 4-lane
`d_in_pos[4]`/`d_out_pos[4]`, 24-bit address accumulation, mode+dummy cycles, and
a writable-shaped backing buffer (`csrc/kernel_v1.metal:738-769`, `FlashState`
`src/sim/cosim/mod.rs:324-346` [V]). Deltas to become an APS6404L PSRAM: enter-QPI
(0x35) latch, quad *write* (0x38) into the backing store, and a RAM (vs erased-
flash) init. The wire phase (sample on rising / drive on falling, MSB-first
nibble, SIO3=MSB) already matches the C64 controller's SPI-mode-0 timing exactly
(cocotb reference `qspi_psram_model.py` docstring vs `flash_eval_commit_persistent`).

There is **no Python/cocotb binding** to the engine (`pyproject.toml` [V] has no
pyo3/maturin; Python is only PDK tooling). User models are Rust today.

**Recommendation:** two-track.
- **MVP (weeks, not months):** add a built-in `qspi_ram` bidirectional GPU
  peripheral by generalizing flash. Fast (100% batched), unblocks the C64 tapeout.
- **General interface (the actual ask):** formalize the CPU `PeripheralModel`
  registration into a documented user-extension point (`bidirectional` variant +
  named output-pin resolution). Works today, pays the `batch=1` tax. The
  "user-provided AND GPU-fast" endgame is ADR 0017's Tier-3 peripheral-FSM IR —
  large, not needed to ship QSPI.

---

## 1. How Jacquard cosim works today [V unless noted]

### 1.1 Execution model

`jacquard sim` = **open-loop replay** of a recorded input VCD through the netlist
(`docs/interop.md:15` [V]). Non-reactive by construction.

`jacquard cosim` = **reactive** peripheral models run alongside a GPU-simulated
design and drive/observe design pins per clock edge (`docs/interop.md:16`,
`docs/getting-started.md:62-92`). This is the relevant mode.

The cosim loop (`src/sim/cosim/mod.rs`, `run_cosim`) groups consecutive scheduler
edges into **batches** of up to `BATCH_SIZE = 1024` and dispatches each batch as
one GPU command buffer (ADR 0017:29-53 [V]). Between batches the CPU: runs
`PeripheralModel::step_edge` on every model, drains GPU→CPU ring buffers, patches
model overrides into per-edge `BitOp` ops for the next batch.

The design/pad boundary is a packed bit-vector: full state is
`[input_state | output_state]`, `2 × state_size` words (`CosimBackend::state()`
doc, `mod.rs:1825-1828`). Inputs are injected by writing `BitOp{position,value}`
entries applied by the `state_prep` kernel; outputs are sampled by reading
`&backend.state()[state_size..]` (`mod.rs:3090`, `3429`). Pin *names* resolve to
bit positions via `GpioMapping` (`input_bits`/`output_bits` maps, keyed by GPIO
index) and the multi-candidate `resolve_to_state_pos` resolver (ADR 0013:170-178).

### 1.2 The backend seam: `CosimBackend` trait (`mod.rs:1776-1902`)

One impl per substrate: `MetalBackend`, `CudaBackend`, `HipBackend`, `CpuBackend`
(reference oracle). Key methods:
- `run_edges(batch, schedule_offset) -> token` — run N consecutive edges in one
  dispatch, snapshot each edge's output to a VCD ring (`mod.rs:1896-1899`).
- `init_schedule` / `edge_ops_mut(edge)` — materialise + patch per-edge ops;
  zero-copy over the shared `MTLBuffer` on Metal, host-mirror+dirty-upload on
  CUDA/HIP (ADR 0017:216-234).
- `state()` / `state_mut()` — the `2×state_size` design state.

**Crucially, flash is hardcoded into this trait**: `flash_set_in_reset`,
`flash_d_i`, `flash_debug_snapshot` are trait methods (`mod.rs:1837-1869`). There
is **no generic `GpuPeripheral` trait yet** — ADR 0017:249-353 describes it as the
Tier-2/Tier-3 *target*, not shipped. [V]

### 1.3 The CPU-side seam: `PeripheralModel` trait (`src/sim/models/mod.rs:56-95`)

```rust
pub trait PeripheralModel {
    fn name(&self) -> &str;
    fn driven_positions(&self) -> &[u32];        // input bits this model drives
    fn apply_action(&mut self, action: &QueuedAction);
    fn step_edge(&mut self, output_state: &[u32],// OBSERVE design outputs
                 overrides: &mut ModelOverrides,  // DRIVE design inputs (pos→val)
                 emitted: &mut Vec<EmittedEvent>);// EMIT decoded records
    fn contribute_overrides(&self, overrides: &mut ModelOverrides);
    fn is_active(&self) -> bool { false }         // true → forces batch=1
}
```

Models registered as `Vec<Box<dyn PeripheralModel>>` at startup
(`mod.rs:2318-2510`). Each batch boundary: `step_edge(output_state=&state[state_size..], …)`
(`mod.rs:3090-3104` [V] — the "empty `&[]`" note in ADR 0013 is stale; output
readback is now wired). Overrides → `BitOp`s → `state_prep`.

**Bidirectional reactive models already exist on this trait:**
- `models/spi.rs:80-156` [V] — SPI *slave*: reads clk/csn/copi outputs, drives
  cipo input, MSB-first shift, per-frame `data` events. Single lane.
- `models/i2c.rs:94-187` [V] — I2C: open-drain, reads `sda_oe/scl_oe`, drives
  `sda_i/scl_i`, START/STOP/ACK FSM. Proves multi-pin bidirectional + output-
  enable-style semantics work over the trait.

Both are noted "wiring is TODO — needs port-mapping infrastructure to look up the
design's peripheral port positions by name" (`spi.rs:23-25`, `i2c.rs:19-23`) —
i.e. the *model FSMs* are done and tested; the *named-output-pin resolution* is
the missing glue. This is exactly the glue a user QSPI model also needs.

### 1.4 The flash GPU peripheral (the fast, bespoke path) [V]

`FlashState` (`mod.rs:324-346`, mirrors `csrc/kernel_v1.metal:738`):
`data_width` (1=SPI, 4=QSPI), `d_i` (4-bit MISO nibble), `addr`, `bit_count`,
`byte_count`, `command`, `out_buffer`, reset handling.

Two kernels per edge (bidirectional pattern, ADR 0013:96-104):
- `gpu_apply_flash_din` — *pre-simulate*: inject `d_i` nibble into the 4 design-
  input bits `d_in_pos[4]` (also clears their X-mask).
- `gpu_flash_model_step` — *post-simulate*: read design outputs (`clk_out_pos`,
  `csn_out_pos`, `d_out_pos[4]`), advance FSM, compute next `d_i`
  (`flash_process_byte` handles cmd 0x03 slow read, 0xEB quad read with
  `byte_count>=6` = 1 mode + 2 dummy clocks, 0x9F ID; `kernel_v1.metal:775-841`).

Pin config `FlashConfig` (`testbench.rs:328-334`): `clk_gpio`, `csn_gpio`,
`d0_gpio` (d1..d3 = `d0_gpio+i`), `firmware`, `firmware_offset`. Resolved in
`build_flash_buffers` (`cosim/metal.rs:1002-1046`) via `gpio_map.input_bits` /
`output_bits`. The **tristate SIO pad is decomposed at the netlist boundary into
separate design-output nets (`d_out`) and design-input nets (`d_i`)** — there is
no shared electrical node, so the model injecting `d_i` while the DUT drives
`d_out` causes no contention; direction is a protocol-FSM concept, not electrical.

Measured: flash/UART/bus designs run **100% batched** (ADR 0017:179-193); the
GPU-side FSM consumes each edge's output to drive the next edge's input *inside*
the batch, so no per-edge CPU↔GPU round-trip.

---

## 2. The core tension, in Jacquard's actual architecture

A GPU gate engine wants large batches; a reactive peripheral needs per-edge
request/response. Jacquard resolves this **only** at the two extremes:

| Path | Where model runs | Batching | User-authorable? | Perf |
|---|---|---|---|---|
| CPU `PeripheralModel`, `is_active()` | CPU, between batches | **batch=1** while active | **Yes** (Rust trait) | Slow |
| GPU-kernel peripheral (flash) | GPU, inside batch | **100% batched** | No (hardcoded) | Full GPU |

There is **no middle path** today ("user-provided AND batched"). ADR 0017:249-378
is explicit: batching a reactive design *requires the peripheral to run inside the
batch = on the GPU*, because the peripheral consumes each edge's output to produce
the next edge's input. On unified-memory Metal the CPU-model `batch=1` path is
merely expensive; on discrete CUDA/HIP it is a PCIe round-trip per edge (~1–2 µs
each way, ADR 0017:253-257) — "likely slower than the CPU backend."

### 2.1 What sync granularity does QSPI-at-32MHz actually need?

The QSPI PSRAM must react **per SCK edge** (sample MOSI on rising, drive MISO on
falling — cocotb `qspi_psram_model.py` and `flash_eval_commit_persistent`). SCK is
generated by the controller dividing the fabric clock (PULP `spi_master_clkgen`);
for 32 MHz SCK the fabric `sys_clk` is ≥64 MHz [I]. The scheduler tick `gcd_ps`
is the fastest half-period (~7.8 ns at 64 MHz); an SCK edge lands every ~15.6 ns =
every 2 scheduler edges [I].

So a **CPU** QSPI model needs per-scheduler-edge visibility → `is_active()==true`
for the whole burst → `batch=1` throughout. And because the PSRAM is the C64's
**main RAM**, it is accessed on essentially every memory cycle — the sim runs at
`batch=1` almost continuously, not in short bursts like a UART.

### 2.2 Performance cost, quantified [I — parametric]

Take a C64 video frame ≈ 20 ms sim time. At `sys_clk` 64 MHz → 1.28 M cycles →
~2.56 M scheduler edges.
- **CPU model / batch=1 on Metal:** the `jtag_minimal` fixture shows single-edge
  commits at roughly ~1 µs/edge dominating wall-clock (ADR 0017:184). → ~2.5 s per
  frame. Usable for short traces, painful for boot/long runs. The GPU parallelism
  across gates is retained per-edge; only the *batching* amortization is lost.
- **CPU model / batch=1 on discrete CUDA/HIP:** ~3–5 µs/edge managed-memory sync +
  launch → ~8–13 s/frame. GPU speedup erased; often slower than pure CPU.
- **GPU-kernel peripheral (flash-style):** 100% batched → the design runs at full
  `sim`-like throughput regardless of QSPI activity. This is the only path that
  keeps the GPU advantage for a continuously-accessed main RAM.

**Conclusion:** for the C64 main-RAM use case the CPU-model path is a correctness-
first fallback, not a performance path. The QSPI PSRAM should be a **GPU-side
bidirectional peripheral**, exactly like flash. This is not a limitation to work
around — it is what the flash precedent already demonstrates.

---

## 3. Proposed user-provided cosim-model interface

Two layers, matching the two seams. Prefer generalizing existing seams over a
bolt-on (both already exist; the work is formalization + wiring).

### 3.1 Layer A — formalize the CPU `PeripheralModel` as the user extension point

The trait is already the right shape (observe→FSM→drive/emit, bidirectional
proven by spi/i2c). Make it a *documented, wired* extension point:

**A1. Named bidirectional pin resolution** (the missing glue `spi.rs:23`/`i2c.rs:19`
call out). Add an output-pin resolver mirroring `input_bits`: resolve a config's
named design-output pins (`sck`, `csn`, `sio_o[0..3]`, optional `sio_oe[0..3]`) and
named design-input pins (`sio_i[0..3]`) to state positions, reusing
`resolve_to_state_pos` (ADR 0013:170-178). Package as a reusable `PinResolver`
passed to model constructors — one helper both QSPI and the scaffolded i2c/spi
use.

**A2. Per-invocation contract** (already the trait): each batch boundary,
`step_edge(output_state, overrides, emitted)`:
- **inputs to the model:** `output_state: &[u32]` (whole design output snapshot;
  model reads its pad bits via `read_bit`), and implicitly current time via the
  model's own edge counters.
- **outputs from the model:** `overrides.insert(pos, val)` for each driven input
  bit (this *is* the per-lane drive; per-lane OE is expressed by simply choosing
  whether to write a lane's `sio_i` position or leave it), plus `emitted` records.
- **reactive:** `is_active()==true` while mid-burst forces `batch=1` so drives
  land edge-aligned.

**A3. Registration/config.** A config struct in `TestbenchConfig`
(`testbench.rs`), plural per ADR 0013:219-228 (`qspi_rams: Vec<QspiRamConfig>`),
deserialized from `sim_config.json`; constructed and `register_model`'d in the
`mod.rs:2318-2510` block. No CLI change beyond `--config`.

**A4. Timing/SDF.** Cosim already back-annotates arrival times on Metal
(`arrival_state_offset`, ADR 0017:481-495). A CPU model observing `output_state`
sees post-SDF-settled values at each scheduler edge; it does not itself model pad
delay (the pad/PHY delay lives in the DUT netlist). The model drives *logical*
values; SDF on the DUT's input path applies on the next `state_prep`. Timed cosim
is Metal-only today (CPU/CUDA/HIP assert `!timing_arrivals_enabled`,
ADR 0017:485-490) — a QSPI CPU model works untimed on all backends and timed on
Metal.

This is the **general** interface. Any user peripheral (I2C EEPROM, SPI sensor,
custom) implements `PeripheralModel` + a config + pin names. Ships fast; pays
`batch=1`.

### 3.2 Layer B — built-in GPU `qspi_ram` peripheral (the fast path for QSPI)

Generalize flash into a second bidirectional GPU peripheral. Same three-substrate
structure flash uses (Metal `.metal` + shared CUDA/HIP `_impl.cuh` + CPU mirror in
`CpuBackend::run_edges`). New config `QspiRamConfig` (mirrors `FlashConfig` but
with a writable backing store and no firmware-erased init):

```
QspiRamConfig { sck_gpio, csn_gpio,
                sio_o0_gpio,   // design output (MOSI lanes), 4 consecutive
                sio_i0_gpio,   // design input  (MISO lanes), 4 consecutive
                sio_oe0_gpio?, // optional, for X/direction assertions
                size_bytes, preload? }
```

`QspiRamState` = `FlashState` + `qpi: u32` (mode latch) + backing store is
read/write. Two kernels mirror flash: `qspi_apply_din` (inject MISO nibble),
`qspi_model_step` (read MOSI/OE, advance FSM, on 0x38 write DUT `d_out` nibble
into `mem[addr]`). Because this runs inside the batch it is **100% batched** —
the C64 main-RAM performance requirement is met.

This is *not* user-authored (it is a built-in), but it is the concrete unblock and
the reference implementation that validates Layer A's contract.

### 3.3 Not recommended now: socket/DPI bridge or Python/cocotb

No engine Python binding exists (`pyproject.toml` [V]). The interactive
`--jtag-server` `remote_bitbang` socket path (`bitbang_client.py`, ADR 0017:439-
479) proves an *externally-paced* CPU model works — but it is inherently `batch=1`
for the whole session and a socket per edge is far slower than an in-process Rust
model. `docs/interop.md:49-51` explicitly defers cocotb ("would marshal Python↔GPU
every cycle… erase the GPU speedup"). A user QSPI model as a socket peripheral is
possible but strictly worse than Layer A. Skip.

---

## 4. Reference QSPI PSRAM model against the interface

### 4.1 Layer A form (CPU `PeripheralModel`) — pseudocode

```rust
struct QspiRamModel {
    name: String,
    pins: QspiPins,        // resolved positions: sck_o, csn_o, sio_o[4], sio_i[4]
    mem: Vec<u8>, size_mask: usize,
    qpi: bool,             // set by 0x35 Enter-QPI
    sck_edge: EdgeDetector, csn_edge: EdgeDetector,
    phase: Phase,          // Idle|Cmd|Addr|Dummy|ReadData|WriteData
    shift: u32, bitcnt: u32, cmd: u8, addr: u32, dummy_left: u32,
    sio_i: [u8;4],         // driven MISO nibble (0 unless ReadData)
    active: bool,
}

impl PeripheralModel for QspiRamModel {
    fn driven_positions(&self)->&[u32] { &self.pins.sio_i }  // 4 input bits
    fn step_edge(&mut self, out:&[u32], ov:&mut ModelOverrides, ev:&mut Vec<EmittedEvent>) {
        let csn = read_bit(out, self.pins.csn_o)!=0;
        let sck = read_bit(out, self.pins.sck_o)!=0;
        match self.csn_edge.update(csn) {
            Falling => { self.active=true; self.begin_transaction(); }
            Rising  => { self.active=false; self.sio_i=[0;4];
                         self.phase=Phase::Idle; ev.push(deselect); }
            None => match self.sck_edge.update(sck) {
                Rising if !csn => {                 // sample MOSI (cmd/addr/wdata)
                    let lanes = if self.wide() {4} else {1};
                    let n = sample_lanes(out, &self.pins.sio_o, lanes);
                    self.shift = (self.shift<<lanes)|n; self.bitcnt+=lanes;
                    self.advance_phase_on_full_unit(ev);   // cmd@8,addr@24,byte@8
                }
                Falling if !csn && self.phase==ReadData => {
                    let nib = self.next_read_nibble();     // mem[addr] hi/lo nibble
                    self.sio_i = nibble_to_lanes(nib);     // drive on falling
                }
                _=>{}
            }
        }
        self.contribute_overrides(ov);   // writes sio_i[0..3] into overrides
    }
    fn is_active(&self)->bool { self.active }   // batch=1 during a burst
}
```

Commands needed (from cocotb ref `qspi_psram_model.py`): `0x35` Enter-QPI (cmd
sampled 1-lane in SPI mode → set `qpi`), `0xEB` Quad Read (cmd + 24-bit addr @4
lanes + `read_dummy_cycles` dummy + data @4 lanes, drive on falling), `0x38` Quad
Write (cmd + 24-bit addr + data @4 lanes, sampled on rising into `mem`). This
covers quad read/write + dummy + per-lane drive (OE emerges from *which* lanes the
model writes vs leaves). The i2c model (`i2c.rs`) already proves the multi-pin
bidirectional + edge-FSM structure compiles and tests cleanly on this trait.

### 4.2 OE handling

At gate level the SIO pad is split into `sio_o[4]` (+optional `sio_oe[4]`) design
outputs and `sio_i[4]` design inputs — **separate nets, no contention** (§1.4).
The model drives `sio_i` only during ReadData; during Cmd/Addr/WriteData it leaves
`sio_i` at idle (0) and the DUT ignores those inputs. Reading `sio_oe` is optional
and used only to **assert** the DUT actually tri-states during ReadData and drives
during WriteData (an X/contention sanity check). The cocotb reference confirms
`sio_oe` is "unused by the model except for documentation/debug" — direction is a
protocol-FSM property, not an electrical one. So the interface's `(position,value)`
override model is sufficient; explicit OE plumbing is a nice-to-have assertion, not
a correctness requirement.

### 4.3 Layer B form: it is flash + {qpi latch, 0x38 write, RW store}. The FSM body
above ports directly into `qspi_model_step` (`flash_process_byte` is the same
shape); `next_read_nibble` reads and `WriteData` writes the shared `mem` buffer.

---

## 5. What to land in Jacquard

### MVP — make QSPI PSRAM work (Layer B, built-in GPU peripheral)

| Item | Location | Notes |
|---|---|---|
| `QspiRamConfig` struct + plural `qspi_rams` | `src/testbench.rs` | mirror `FlashConfig:328`; add `size_bytes`, `sio_i0_gpio`, `qpi`/write params |
| `QspiRamState` device struct + ABI asserts | `src/sim/cosim/mod.rs` | mirror `FlashState:324` + `qpi:u32`; keep `#[repr(C)]` size asserts |
| Metal kernels `qspi_apply_din`/`qspi_model_step` | `csrc/kernel_v1.metal` | mirror `:717-883`; add 0x35 latch, 0x38 write-to-mem |
| CUDA/HIP kernels | `csrc/kernel_v1_impl.cuh` | shared with Metal-parity per ADR 0017:264-269 |
| CPU mirror | `CpuBackend::run_edges` (`mod.rs:4639+`) | golden oracle, as flash has at `:4686-4753` |
| Buffer build + pin resolve | `cosim/metal.rs:956` `build_flash_buffers` sibling; `mod.rs:1119` `build_flash_buffers_dev` sibling | writable store, preload |
| Backend trait hooks | `CosimBackend` (`mod.rs:1776`) | either add `qspi_*` methods (as flash `:1837-1869`) or — better — introduce a small `GpuBidirPeripheral` sub-trait so flash+qspi share it (down-payment on ADR 0017 Tier-2) |
| Fixture + golden | `tests/qspi_psram/` | mirror `tests/mcu_soc` flash fixture; cross-backend byte-identical VCD per ADR 0017:363-367 |

**Effort:** ~1.5–3 weeks [I]. The FSM logic is a port of an existing, tested model;
the risk is in the three-substrate ABI sync and the write path (flash is read-
mostly). Landing it *behind* a shared `GpuBidirPeripheral` sub-trait (rather than
three more `flash_*`-style trait methods) is only marginally more work and is the
first concrete step of the Tier-2 generalization.

### General interface — user-provided models (Layer A)

| Item | Location | Notes |
|---|---|---|
| `PinResolver` for named design-output + input pins | new helper near `trace_signals.rs` resolver | the glue `spi.rs:23`/`i2c.rs:19` are blocked on |
| Wire `output_state` + named-pin config for spi/i2c/user | `mod.rs:2318-2510` registration block | i2c/spi FSMs already done; finish their wiring as the template |
| Document `PeripheralModel` as the extension point | `docs/` (new `docs/user-peripherals.md`) | contract, `is_active`/batch=1 caveat, config schema |
| Register-by-config for external Rust models | `TestbenchConfig` + registration | keeps user models in-tree (no dylib ABI risk) |

**Effort:** ~1 week [I] on top of MVP (mostly the pin resolver + docs; the trait
and two example models exist).

### Endgame (do NOT build now)

ADR 0017:270-277 Tier-3: single-source peripheral-FSM IR compiling to CPU + all
GPU backends. This is the only path to "user-provided AND GPU-batched." Large,
speculative, unnecessary for the C64 tapeout. Note it as the north star.

### Risks
- **Three-substrate ABI drift** (Metal/CUDA-HIP/CPU structs hand-synced — ADR
  0017:329-337 flags this as the standing tax). Mitigate with the existing
  `#[repr(C)]` size asserts (`mod.rs:373-377`) + cross-backend golden VCD.
- **Write path** is genuinely new vs flash (flash never writes the store). Test
  quad-write read-back explicitly against the cocotb model's `writes[]` log.
- **SPI-mode phase**: confirm the C64 controller's sample/drive edges match the
  kernel's negedge-`d_i`-update cadence (`kernel_v1.metal:841-883`); the cocotb
  ref says sample-rising/drive-falling, which matches — verify in the fixture.
- **Timed cosim is Metal-only** (ADR 0017:485-490): post-PnR *timing* cosim of the
  QSPI path runs on Metal today; CUDA/HIP give functional-only until arrival
  tracking is extended. Fine if the tapeout timing runs on Apple silicon.

---

## 6. Open questions for the author

1. **Trait vs three methods:** land `qspi_ram` as more `flash_*`-style
   `CosimBackend` methods (fast to write, more debt) or introduce the
   `GpuBidirPeripheral` sub-trait now (a bit more work, pays down Tier-2)? The
   latter makes flash + qspi share one seam and is the natural refactor.
2. **Backend target for the tapeout:** is post-PnR *timed* QSPI cosim expected on
   Metal only (works today), or must CUDA/HIP get arrival tracking first
   (ADR 0017:485-490 open item)?
3. **Writable-store semantics:** should `qspi_ram` support pre/post dump + compare
   like SRAM (`sram_dump.rs`) so a write burst is verifiable end-of-run, or is the
   in-loop `writes[]`-style event log enough?
4. **User-model distribution:** in-tree Rust `PeripheralModel` impls compiled into
   `jacquard` (simple, no ABI) vs an out-of-tree dylib/registration ABI? In-tree
   seems right given the audience is the author, but confirm.
5. **Fabric clock ratio:** what is the actual `sys_clk`:SCK ratio for the C64
   controller? It sets `gcd_ps` and thus how many scheduler edges per SCK edge —
   relevant if a Layer-A CPU fallback is ever used (batch=1 cost scales with it).
6. **Scope of the "general" ask now:** ship Layer B (QSPI built-in) alone for the
   tapeout and defer Layer A formalization, or land both together so the QSPI CPU
   model doubles as the worked example for the user interface?


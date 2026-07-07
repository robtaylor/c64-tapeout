// SPDX-License-Identifier: Solderpad-0.51
//
// qspi_psram_ctrl — SRAM-style bus <-> QSPI PSRAM + read-only flash ROM bridge
// ============================================================================
//
// Bridges the C64 system's existing SRAM-style memory bus to an external
// QSPI PSRAM (APS6404L-class) using the vendored PULP `spi_master_controller`
// serial engine (see ../ip/pulp/). Phase-2 / WS-P2-1; ADR 0004.
//
// WS-P2-10 (ADR 0005 + 2026-07-07 amendment) adds a *second* device on the same
// serial engine: an external read-only QSPI NOR flash holding the
// KERNAL/BASIC/CHARGEN ROM images. It is treated as a **read-only PSRAM on
// CSN1** — the amendment resolved the flash read to QPI `0xEB` (not single-I/O
// `0x0B`) because the PULP engine is single/quad-only and a 1.5 µs single read
// overruns the ~1 µs CPU cycle, whereas the 0.5 µs QPI read fits and reuses the
// engine's existing quad stimulus almost verbatim. The two devices share SCK +
// SIO[3:0] and are distinguished by two chip-selects driven from the engine's
// hardware CS mux (`spi_csreg`):
//   * PSRAM on CSN0 (`cs_n`)       — read/write, 0xEB / 0x38 quad, csreg=0001
//   * flash on CSN1 (`cs_flash_n`) — read-only, 0xEB quad read (QPI), csreg=0010
// A fixed-priority arbiter serialises the two request streams onto the single
// engine (see the arbiter note by S_IDLE). RAM and ROM are never needed on the
// same SCK; ADR 0005 defers worst-case-concurrency re-measurement (VIC CHARGEN
// + CPU fetch + CPU RAM within one cycle) to integrated sim, so the arbiter is
// deliberately simple here — the future ROM prefetch buffer (task 2) amortises
// the common sequential-fetch case.
//
// This is the *standalone* controller. RTL integration into chip_core /
// c64_system is WS-P2-2/3 and is intentionally NOT done here.
//
// Bus convention (memory-centric — note the crossover vs. c64_system):
//   * ramDin  (input)  = data CPU is writing  TO  memory  (c64_system.ramDout)
//   * ramDout (output) = data memory returns  TO  CPU     (c64_system.ramDin)
//   ramAddr/ramCE/ramWE match c64_system polarity (WE=1 -> write, CE active high).
//
// Per CPU access (one byte): on a rising edge of ramCE the controller loads the
// engine with the appropriate QPI command (0xEB read / 0x38 write), a 24-bit
// address {8'h00, ramAddr}, the read dummy count and a 1-byte data length, then
// asserts the matching direction strobe. When the engine signals `eot`, the
// captured byte is presented on `ramDout` and `ready` pulses for one clock.
//
// Reset initialisation: two "Enter Quad (QPI) mode" commands are issued
// single-lane before any access, so all later commands go out over 4 lanes —
// 0x35 to the PSRAM on CSN0, then 0x38 to the flash on CSN1 (W25Q-class
// enter-QPI opcode; the flash must be a QPI-capable part with its QE bit set at
// provisioning, per the ADR 0005 amendment).
//
// Clocking: the engine generates SCK as a divided *waveform* from `clk`:
//     f_sck = f_clk / (2 * (CLK_DIV + 1))
// With CLK_DIV=0 a 64 MHz controller clock yields the phase-2 target 32 MHz SCK.
// This clock is separate from (and faster than) the ~1 MHz C64 CPU clock.
//
// Single clock domain, async active-low reset, no DDR, no vendor IO cells —
// SCK is a data waveform, so the module is OpenROAD/LibreLane clean.

module qspi_psram_ctrl #(
    parameter logic [7:0]  CLK_DIV   = 8'd0,  // SCK = clk / (2*(CLK_DIV+1))
    parameter int unsigned QRD_DUMMY = 6,     // 0xEB dummy SCK cycles (APS6404L)
    parameter int unsigned FRD_DUMMY = 6,     // flash 0xEB QPI dummy SCK cycles
                                              // (part-specific: 2 mode + 4 dummy)
    parameter logic [7:0]  PSRAM_BANK = 8'h00 // high byte of the 24-bit PSRAM address
) (
    input  logic        clk,
    input  logic        rst_n,

    // SRAM-style bus (PSRAM / RAM side)
    input  logic [15:0] ramAddr,
    input  logic [7:0]  ramDin,    // CPU -> memory (write data)
    input  logic        ramCE,
    input  logic        ramWE,     // 1 = write, 0 = read
    output logic [7:0]  ramDout,   // memory -> CPU (read data)
    output logic        ready,     // 1-cycle done strobe; ramDout valid

    // Read-only ROM port (external QSPI NOR flash side). 24-bit address: the
    // flash space holds KERNAL/BASIC/CHARGEN at distinct offsets, wider than
    // the 16-bit RAM map. No write path — a ROM is read-only.
    input  logic [23:0] romAddr,   // flash byte address
    input  logic        romCE,     // rising-edge read trigger (like ramCE)
    output logic [7:0]  romDout,   // flash -> CPU (read data)
    output logic        romReady,  // 1-cycle done strobe; romDout valid

    // Init-complete strobe: high once the two-device enter-QPI init sequence
    // (0x35 PSRAM + 0x38 flash) has finished and the engine is operational.
    // Used by chip_core to hold the C64 core in reset until the first
    // reset-vector fetch ($FFFC/$FFFD -> KERNAL -> flash) can return valid data
    // (ADR 0005 boot-gating). Monotonic 0 -> 1: once the FSM reaches S_IDLE it
    // never re-enters the init sequence, so this is a clean one-way release.
    output logic        init_done,

    // QSPI pads (bus shared by PSRAM and flash)
    output logic        cs_n,      // PSRAM chip select  (CSN0), active low
    output logic        cs_flash_n,// flash chip select  (CSN1), active low
    output logic        sck,       // serial clock            (always driven)
    output logic [3:0]  sio_o,     // data driven onto the lanes
    output logic [3:0]  sio_oe,    // per-lane output enable
    input  logic [3:0]  sio_i      // data sampled from the lanes
);

  // QPI command opcodes (left-justified into spi_cmd[31:24]).
  localparam logic [31:0] CMD_ENTER_QPI = 32'h35 << 24;
  localparam logic [31:0] CMD_READ_QUAD = 32'hEB << 24;
  localparam logic [31:0] CMD_WRITE_QUAD = 32'h38 << 24;
  // Flash enter-QPI opcode — W25Q-class parts use 0x38 (issued single-lane,
  // pre-QPI, on CSN1). Note this differs from the PSRAM's 0x35: it happens to
  // share the *value* of CMD_WRITE_QUAD but is a distinct semantic (a
  // single-lane command to the flash, not a quad write to the PSRAM).
  localparam logic [31:0] CMD_FLASH_ENTER_QPI = 32'h38 << 24;

  // PULP spi_mode encodings.
  localparam logic [1:0] SPI_STD     = 2'b00;
  localparam logic [1:0] SPI_QUAD_TX = 2'b01;
  localparam logic [1:0] SPI_QUAD_RX = 2'b10;

  // Protocol length constants (command/address/data phase widths, in bits).
  localparam logic [5:0]  CMD_LEN  = 6'd8;
  localparam logic [5:0]  ADDR_LEN = 6'd24;
  localparam logic [15:0] DATA_LEN = 16'd8;

  // ----------------------------------------------------------------------- //
  //  Engine wiring
  // ----------------------------------------------------------------------- //
  logic        eng_eot;
  logic [6:0]  eng_status;
  logic [31:0] eng_cmd;
  logic [5:0]  eng_cmd_len;
  logic [31:0] eng_addr;
  logic [5:0]  eng_addr_len;
  logic [15:0] eng_data_len;
  logic [15:0] eng_dummy_rd;
  logic        eng_wr, eng_qrd, eng_qwr;
  logic [31:0] eng_tx_data;
  logic        eng_tx_valid;
  logic        eng_tx_ready;
  logic [31:0] eng_rx_data;
  logic        eng_rx_valid;
  logic        eng_rx_ready;
  logic [1:0]  eng_mode;
  logic        eng_sdo0, eng_sdo1, eng_sdo2, eng_sdo3;
  logic        eng_csn0, eng_csn1;
  logic [3:0]  eng_csreg;
  logic        eng_clkdiv_valid;

  // ----------------------------------------------------------------------- //
  //  Wrapper FSM
  // ----------------------------------------------------------------------- //
  typedef enum logic [3:0] {
    S_RST,
    S_INIT_ISSUE,  // enter-QPI: 0x35 on CSN0 (PSRAM) then 0x38 on CSN1 (flash),
    S_INIT_BUSY,   //   run twice, selected by init_dev
    S_INIT_IDLE,
    S_IDLE,
    S_RD_ISSUE,
    S_RD_WAIT,
    S_WR_ISSUE,
    S_WR_WAIT,
    S_DONE,
    S_FRD_ISSUE,   // flash 0xEB QPI read: issue quad-read strobe
    S_FRD_WAIT,    // flash 0xEB QPI read: await engine eot
    S_FRD_DONE     // flash 0xEB QPI read: pulse romReady
  } state_t;

  state_t      state, state_next;

  logic [15:0] addr_q;     // latched RAM access address
  logic [7:0]  wdata_q;    // latched write data
  logic        we_q;       // latched RAM direction (1 = write)
  logic [7:0]  rdata_q;    // captured RAM read data
  logic [23:0] romaddr_q;  // latched flash (ROM) access address
  logic [7:0]  romdata_q;  // captured flash read data
  logic        ramCE_q;    // for rising-edge detection (RAM)
  logic        romCE_q;    // for rising-edge detection (ROM)
  logic        ram_pending;// a RAM request is latched, awaiting the engine
  logic        rom_pending;// a ROM request is latched, awaiting the engine
  logic        wr_taken;   // write byte accepted by the engine (1 -> stop offering)
  logic        init_dev;   // enter-QPI pass: 0 = PSRAM (CSN0), 1 = flash (CSN1)

  wire eng_idle = eng_status[0];
  wire ce_rise  = ramCE  & ~ramCE_q;
  wire rce_rise = romCE  & ~romCE_q;

  // The RD/WR ISSUE and WAIT states drive identical engine stimulus (cmd,
  // addr, lengths, tx/rx data) for the whole transaction — only the qrd/qwr
  // strobe and the state transition differ between ISSUE and WAIT. Hoist
  // the shared assignments out of the case so they are written once.
  wire rd_active   = (state == S_RD_ISSUE)  || (state == S_RD_WAIT);
  wire wr_active   = (state == S_WR_ISSUE)  || (state == S_WR_WAIT);
  wire frd_active  = (state == S_FRD_ISSUE) || (state == S_FRD_WAIT);
  // Both enter-QPI passes (PSRAM then flash) share one 3-state sequence,
  // selected by init_dev. init_active groups those states for the CS mux —
  // CSN1 is selected only on the flash pass (init_dev = 1).
  wire init_active = (state == S_INIT_ISSUE) || (state == S_INIT_BUSY) || (state == S_INIT_IDLE);

  // Combinational next-state + engine stimulus.
  always_comb begin
    state_next   = state;

    eng_cmd      = 32'h0;
    eng_cmd_len  = 6'd0;
    eng_addr     = 32'h0;
    eng_addr_len = 6'd0;
    eng_data_len = 16'd0;
    eng_dummy_rd = 16'd0;
    eng_wr       = 1'b0;
    eng_qrd      = 1'b0;
    eng_qwr      = 1'b0;
    eng_tx_data  = 32'h0;
    eng_tx_valid = 1'b0;
    eng_rx_ready = 1'b0;
    ready        = 1'b0;
    romReady     = 1'b0;

    // 0xEB quad fast-read. The engine reads spi_cmd/spi_addr/the length and
    // dummy inputs throughout CMD/ADDR/DUMMY/DATA_RX, so they must remain
    // stable for the whole transaction (ISSUE *and* WAIT). The PSRAM RAM read
    // (rd_active) and the flash ROM read (frd_active) issue the *same* 0xEB
    // quad read — the flash is a read-only PSRAM on CSN1 — differing only in
    // the address source (romaddr_q, already a full 24-bit flash offset) and
    // the dummy count (FRD_DUMMY); the chip-select (CSN1) is muxed separately
    // via eng_csreg. Both are strobed with eng_qrd (below) so the engine runs
    // SPI_QUAD. They are mutually exclusive states, so one shared block covers
    // both.
    if (rd_active || frd_active) begin
      eng_cmd      = CMD_READ_QUAD;
      eng_cmd_len  = CMD_LEN;
      eng_addr     = frd_active ? {romaddr_q, 8'h00}      // flash: full 24-bit offset
                                : {PSRAM_BANK, addr_q, 8'h00};  // RAM: 16-bit + bank
      eng_addr_len = ADDR_LEN;
      eng_data_len = DATA_LEN;
      eng_dummy_rd = frd_active ? FRD_DUMMY[15:0] : QRD_DUMMY[15:0];
      eng_rx_ready = 1'b1;
    end else if (wr_active) begin
      // 0x38 quad write — same: hold parameters + tx data across the whole
      // transaction.
      eng_cmd      = CMD_WRITE_QUAD;
      eng_cmd_len  = CMD_LEN;
      eng_addr     = {PSRAM_BANK, addr_q, 8'h00};
      eng_addr_len = ADDR_LEN;
      eng_data_len = DATA_LEN;
      eng_tx_data  = {wdata_q, 24'h0};         // byte, left-justified
      eng_tx_valid = ~wr_taken;                // offer the byte exactly once
    end

    unique case (state)
      // Latch the SCK divider, then kick off init.
      S_RST: state_next = S_INIT_ISSUE;

      // Enter-QPI, run twice on one shared 3-state sequence: pass 0 puts the
      // PSRAM into QPI (0x35 on CSN0), pass 1 puts the flash into QPI (0x38 on
      // CSN1). init_dev selects the opcode here and the CS via eng_csreg; it
      // flips 0->1 after the first pass completes (sequential block below).
      // Both commands go out single-lane (eng_wr / SPI_STD).
      S_INIT_ISSUE: begin
        eng_cmd     = init_dev ? CMD_FLASH_ENTER_QPI : CMD_ENTER_QPI;
        eng_cmd_len = CMD_LEN;
        eng_wr      = 1'b1;        // standard (single-lane) command
        state_next  = S_INIT_BUSY;
      end
      // Command-only transactions produce no `eot`; track idle instead.
      S_INIT_BUSY: if (!eng_idle) state_next = S_INIT_IDLE;
      // After the PSRAM pass (init_dev=0) loop back for the flash pass; after
      // the flash pass (init_dev=1) both devices are in QPI — go operational.
      S_INIT_IDLE: if (eng_idle)  state_next = init_dev ? S_IDLE : S_INIT_ISSUE;

      // Wait for a CPU access, then arbitrate. Fixed priority: **RAM wins a
      // same-cycle tie over ROM.** Rationale: a CPU RAM access must close
      // inside the ~1 MHz cycle budget (ADR 0004 early-trigger), whereas ROM
      // fetches are sequential and will be amortised by the task-2 prefetch
      // buffer, so a one-transaction ROM stall is cheap. The two requests are
      // latched independently (ram_pending / rom_pending) so a request that
      // arrives while the engine is busy is serviced when it frees — this is
      // what serialises concurrent RAM+ROM traffic onto the single engine.
      S_IDLE: begin
        if (ram_pending)      state_next = we_q ? S_WR_ISSUE : S_RD_ISSUE;
        else if (rom_pending) state_next = S_FRD_ISSUE;
      end

      // Only the qrd strobe is pulsed, in ISSUE, while the engine is still
      // in IDLE; the shared stimulus above already covers both states.
      S_RD_ISSUE: begin
        eng_qrd    = 1'b1;                      // strobe (engine in IDLE)
        state_next = S_RD_WAIT;
      end
      S_RD_WAIT: if (eng_eot) state_next = S_DONE;

      // Only the qwr strobe is pulsed, in ISSUE, while the engine is still
      // in IDLE; the shared stimulus above already covers both states.
      S_WR_ISSUE: begin
        eng_qwr    = 1'b1;                      // strobe (engine in IDLE)
        state_next = S_WR_WAIT;
      end
      S_WR_WAIT: if (eng_eot) state_next = S_DONE;

      S_DONE: begin
        ready      = 1'b1;
        state_next = S_IDLE;
      end

      // Flash 0xEB QPI read. Mirrors the PSRAM RD path exactly — strobes the
      // *quad* read (eng_qrd) so the engine runs SPI_QUAD; shared stimulus
      // above holds the cmd/addr/dummy across ISSUE and WAIT. Only the address
      // source, dummy count and CS (CSN1) differ from the PSRAM read.
      S_FRD_ISSUE: begin
        eng_qrd    = 1'b1;                      // strobe (engine in IDLE)
        state_next = S_FRD_WAIT;
      end
      S_FRD_WAIT: if (eng_eot) state_next = S_FRD_DONE;

      S_FRD_DONE: begin
        romReady   = 1'b1;
        state_next = S_IDLE;
      end

      default: state_next = S_RST;
    endcase
  end

  assign eng_clkdiv_valid = (state == S_RST);

  // Sequential state + datapath registers.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_RST;
      addr_q      <= 16'h0;
      wdata_q     <= 8'h0;
      we_q        <= 1'b0;
      rdata_q     <= 8'h0;
      romaddr_q   <= 24'h0;
      romdata_q   <= 8'h0;
      ramCE_q     <= 1'b0;
      romCE_q     <= 1'b0;
      ram_pending <= 1'b0;
      rom_pending <= 1'b0;
      wr_taken    <= 1'b0;
      init_dev    <= 1'b0;
    end else begin
      state   <= state_next;
      ramCE_q <= ramCE;
      romCE_q <= romCE;

      // Advance from the PSRAM enter-QPI pass to the flash pass exactly once,
      // when the first pass completes (engine idle in S_INIT_IDLE, init_dev=0).
      if (state == S_INIT_IDLE && eng_idle && !init_dev)
        init_dev <= 1'b1;

      // Latch each request's parameters on its rising edge (any state, so a
      // request arriving while the engine is busy is remembered), and raise the
      // matching pending flag. The flag is cleared when S_IDLE launches that
      // request's transaction. Set takes precedence over clear (a fresh trigger
      // and its own launch cannot coincide — the flag must be set first).
      if (ce_rise) begin
        addr_q  <= ramAddr;
        wdata_q <= ramDin;
        we_q    <= ramWE;
      end
      if (rce_rise)
        romaddr_q <= romAddr;

      if (ce_rise)
        ram_pending <= 1'b1;
      else if (state == S_IDLE && ram_pending)
        ram_pending <= 1'b0;

      if (rce_rise)
        rom_pending <= 1'b1;
      else if (state == S_IDLE && state_next == S_FRD_ISSUE)
        rom_pending <= 1'b0;

      // One-shot write-data handshake: arm on issue, latch once the engine
      // accepts the byte so it is not re-transmitted.
      if (state == S_WR_ISSUE)
        wr_taken <= 1'b0;
      else if (eng_tx_valid && eng_tx_ready)
        wr_taken <= 1'b1;

      // Capture the returned byte (low 8 bits of the rx shift register).
      if (state == S_RD_WAIT && eng_rx_valid && eng_rx_ready)
        rdata_q <= eng_rx_data[7:0];
      if (state == S_FRD_WAIT && eng_rx_valid && eng_rx_ready)
        romdata_q <= eng_rx_data[7:0];
    end
  end

  assign ramDout = rdata_q;
  assign romDout = romdata_q;

  // ----------------------------------------------------------------------- //
  //  Pad mapping + per-lane output enable
  // ----------------------------------------------------------------------- //
  assign cs_n       = eng_csn0;
  assign cs_flash_n = eng_csn1;
  assign sio_o      = {eng_sdo3, eng_sdo2, eng_sdo1, eng_sdo0};

  // Engine hardware CS mux select: PSRAM on CSN0 (0001) for RAM traffic + its
  // enter-QPI pass, flash on CSN1 (0010) for *any* flash transaction — the
  // flash enter-QPI pass (init_active while init_dev=1) and the 0xEB read
  // (frd_active). The engine gates the selected csn low with spi_cs, so only
  // one device is ever asserted.
  wire flash_active = frd_active || (init_active && init_dev);
  assign eng_csreg = flash_active ? 4'b0010 : 4'b0001;

  // Boot gate: asserted once the FSM is past the enter-QPI init sequence
  // (not S_RST and not one of the S_INIT_* states). See the port comment.
  assign init_done = (state != S_RST) && !init_active;

  // Derive the lane output-enables the engine doesn't provide:
  //   std SPI  : drive SIO0, read SIO1   -> 0001
  //   quad TX  : drive all four lanes    -> 1111
  //   quad RX  : tristate (reading)      -> 0000
  always_comb begin
    unique case (eng_mode)
      SPI_STD:     sio_oe = 4'b0001;
      SPI_QUAD_TX: sio_oe = 4'b1111;
      SPI_QUAD_RX: sio_oe = 4'b0000;
      default:     sio_oe = 4'b0000;
    endcase
  end

  // ----------------------------------------------------------------------- //
  //  Vendored PULP serial engine
  // ----------------------------------------------------------------------- //
  spi_master_controller u_engine (
    .clk                    (clk),
    .rstn                   (rst_n),
    .eot                    (eng_eot),
    .spi_clk_div            (CLK_DIV),
    .spi_clk_div_valid      (eng_clkdiv_valid),
    .spi_status             (eng_status),
    .spi_addr               (eng_addr),
    .spi_addr_len           (eng_addr_len),
    .spi_cmd                (eng_cmd),
    .spi_cmd_len            (eng_cmd_len),
    .spi_data_len           (eng_data_len),
    .spi_dummy_rd           (eng_dummy_rd),
    .spi_dummy_wr           (16'd0),
    .spi_csreg              (eng_csreg),     // CSN0 (PSRAM) or CSN1 (flash)
    .spi_swrst              (1'b0),
    .spi_rd                 (1'b0),          // standard (single-I/O) read unused
    .spi_wr                 (eng_wr),
    .spi_qrd                (eng_qrd),
    .spi_qwr                (eng_qwr),
    .spi_ctrl_data_tx       (eng_tx_data),
    .spi_ctrl_data_tx_valid (eng_tx_valid),
    .spi_ctrl_data_tx_ready (eng_tx_ready),
    .spi_ctrl_data_rx       (eng_rx_data),
    .spi_ctrl_data_rx_valid (eng_rx_valid),
    .spi_ctrl_data_rx_ready (eng_rx_ready),
    .spi_clk                (sck),
    .spi_csn0               (eng_csn0),
    .spi_csn1               (eng_csn1),
    .spi_csn2               (),
    .spi_csn3               (),
    .spi_mode               (eng_mode),
    .spi_sdo0               (eng_sdo0),
    .spi_sdo1               (eng_sdo1),
    .spi_sdo2               (eng_sdo2),
    .spi_sdo3               (eng_sdo3),
    .spi_sdi0               (sio_i[0]),
    .spi_sdi1               (sio_i[1]),
    .spi_sdi2               (sio_i[2]),
    .spi_sdi3               (sio_i[3])
  );

endmodule

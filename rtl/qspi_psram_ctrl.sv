// SPDX-License-Identifier: Solderpad-0.51
//
// qspi_psram_ctrl — SRAM-style bus <-> QSPI PSRAM bridge
// ======================================================
//
// Bridges the C64 system's existing SRAM-style memory bus to an external
// QSPI PSRAM (APS6404L-class) using the vendored PULP `spi_master_controller`
// serial engine (see ../ip/pulp/). Phase-2 / WS-P2-1; ADR 0004.
//
// This is the *standalone* controller. RTL integration into chip_core /
// c64_system is WS-P2-2 and is intentionally NOT done here.
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
// Reset initialisation: a single 0x35 "Enter Quad (QPI) mode" command is issued
// (single-lane) before any access, so all later commands go out over 4 lanes.
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
    parameter logic [7:0]  PSRAM_BANK = 8'h00 // high byte of the 24-bit PSRAM address
) (
    input  logic        clk,
    input  logic        rst_n,

    // SRAM-style bus (memory side)
    input  logic [15:0] ramAddr,
    input  logic [7:0]  ramDin,    // CPU -> memory (write data)
    input  logic        ramCE,
    input  logic        ramWE,     // 1 = write, 0 = read
    output logic [7:0]  ramDout,   // memory -> CPU (read data)
    output logic        ready,     // 1-cycle done strobe; ramDout valid

    // QSPI PSRAM pads
    output logic        cs_n,      // chip select, active low (always driven)
    output logic        sck,       // serial clock            (always driven)
    output logic [3:0]  sio_o,     // data driven onto the lanes
    output logic [3:0]  sio_oe,    // per-lane output enable
    input  logic [3:0]  sio_i      // data sampled from the lanes
);

  // QPI command opcodes (left-justified into spi_cmd[31:24]).
  localparam logic [31:0] CMD_ENTER_QPI = 32'h35 << 24;
  localparam logic [31:0] CMD_READ_QUAD = 32'hEB << 24;
  localparam logic [31:0] CMD_WRITE_QUAD = 32'h38 << 24;

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
  logic        eng_csn0;
  logic        eng_clkdiv_valid;

  // ----------------------------------------------------------------------- //
  //  Wrapper FSM
  // ----------------------------------------------------------------------- //
  typedef enum logic [3:0] {
    S_RST,
    S_INIT_ISSUE,
    S_INIT_BUSY,
    S_INIT_IDLE,
    S_IDLE,
    S_RD_ISSUE,
    S_RD_WAIT,
    S_WR_ISSUE,
    S_WR_WAIT,
    S_DONE
  } state_t;

  state_t      state, state_next;

  logic [15:0] addr_q;     // latched access address
  logic [7:0]  wdata_q;    // latched write data
  logic [7:0]  rdata_q;    // captured read data
  logic        ramCE_q;    // for rising-edge detection
  logic        wr_taken;   // write byte accepted by the engine (1 -> stop offering)

  wire eng_idle = eng_status[0];
  wire ce_rise  = ramCE & ~ramCE_q;

  // The RD/WR ISSUE and WAIT states drive identical engine stimulus (cmd,
  // addr, lengths, tx/rx data) for the whole transaction — only the qrd/qwr
  // strobe and the state transition differ between ISSUE and WAIT. Hoist
  // the shared assignments out of the case so they are written once.
  wire rd_active = (state == S_RD_ISSUE) || (state == S_RD_WAIT);
  wire wr_active = (state == S_WR_ISSUE) || (state == S_WR_WAIT);

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

    // 0xEB quad fast-read. The engine reads spi_cmd/spi_addr/the length and
    // dummy inputs throughout CMD/ADDR/DUMMY/DATA_RX, so they must remain
    // stable for the whole transaction (ISSUE *and* WAIT).
    if (rd_active) begin
      eng_cmd      = CMD_READ_QUAD;
      eng_cmd_len  = CMD_LEN;
      eng_addr     = {PSRAM_BANK, addr_q, 8'h00};  // 24-bit addr, left-justified
      eng_addr_len = ADDR_LEN;
      eng_data_len = DATA_LEN;
      eng_dummy_rd = QRD_DUMMY[15:0];
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

      // Issue 0x35 (single-lane) to enter QPI mode.
      S_INIT_ISSUE: begin
        eng_cmd     = CMD_ENTER_QPI;
        eng_cmd_len = CMD_LEN;
        eng_wr      = 1'b1;        // standard (single-lane) command
        state_next  = S_INIT_BUSY;
      end
      // Command-only transactions produce no `eot`; track idle instead.
      S_INIT_BUSY: if (!eng_idle) state_next = S_INIT_IDLE;
      S_INIT_IDLE: if (eng_idle)  state_next = S_IDLE;

      // Wait for a CPU access.
      S_IDLE: if (ce_rise) state_next = ramWE ? S_WR_ISSUE : S_RD_ISSUE;

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

      default: state_next = S_RST;
    endcase
  end

  assign eng_clkdiv_valid = (state == S_RST);

  // Sequential state + datapath registers.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_RST;
      addr_q   <= 16'h0;
      wdata_q  <= 8'h0;
      rdata_q  <= 8'h0;
      ramCE_q  <= 1'b0;
      wr_taken <= 1'b0;
    end else begin
      state   <= state_next;
      ramCE_q <= ramCE;

      if (state == S_IDLE && ce_rise) begin
        addr_q  <= ramAddr;
        wdata_q <= ramDin;
      end

      // One-shot write-data handshake: arm on issue, latch once the engine
      // accepts the byte so it is not re-transmitted.
      if (state == S_WR_ISSUE)
        wr_taken <= 1'b0;
      else if (eng_tx_valid && eng_tx_ready)
        wr_taken <= 1'b1;

      // Capture the returned byte (low 8 bits of the rx shift register).
      if (state == S_RD_WAIT && eng_rx_valid && eng_rx_ready)
        rdata_q <= eng_rx_data[7:0];
    end
  end

  assign ramDout = rdata_q;

  // ----------------------------------------------------------------------- //
  //  Pad mapping + per-lane output enable
  // ----------------------------------------------------------------------- //
  assign cs_n  = eng_csn0;
  assign sio_o = {eng_sdo3, eng_sdo2, eng_sdo1, eng_sdo0};

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
    .spi_csreg              (4'b0001),       // single chip select on CSN0
    .spi_swrst              (1'b0),
    .spi_rd                 (1'b0),
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
    .spi_csn1               (),
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

-- C64 system integrator — tapeout subset
--
-- Simplified from fpga64_sid_iec.vhd (Peter Wendrich / Alexey Melnikov):
--   - 32 MHz clock, 32-state cycle sequencer (same as original)
--   - No SID, no CIA2, no IEC, no DMA, no turbo, no keyboard
--   - No cartridge (game/exrom hardwired inactive)
--   - External ROM data ports (no internal dprom)
--   - CIA1 interface exposed as ports (not instantiated here, because
--     mos6526 is Verilog and GHDL can't resolve cross-language components)
--
-- Subsystems instantiated here (all VHDL):
--   T65 CPU (via cpu_6510 wrapper)
--   VIC-II (video_vicii_656x, PAL 6569 mode)
--   c64_buslogic (simplified PLA / memory map)
--   Color RAM (1024 × 4-bit, via spram)
--
-- The parent module (chip_core.sv) instantiates both this entity AND
-- mos6526.v, wiring the CIA interface ports between them.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.std_logic_unsigned.ALL;
use IEEE.numeric_std.ALL;

entity c64_system is
    port (
        clk32       : in  std_logic;
        reset_n     : in  std_logic;

        -- External RAM interface
        ramAddr     : out unsigned(15 downto 0);
        ramDin      : in  unsigned(7 downto 0);
        ramDout     : out unsigned(7 downto 0);
        ramCE       : out std_logic;
        ramWE       : out std_logic;

        -- Early PSRAM trigger (bulk-RAM path). Fires one clean pulse at the
        -- start of the period, using the CPU address/write flag (both stable
        -- from state 0 since the CPU only advances on enableCpu at state 31),
        -- so a ~500 ns quad read closes before the CPU samples at state 31.
        -- Gated by the CPU-path RAM decode. ZP/stack keeps the late ramCE.
        psramCE     : out std_logic;
        psramAddr   : out unsigned(15 downto 0);
        psramWE     : out std_logic;

        -- External ROM data
        kernalData  : in  unsigned(7 downto 0);
        basicData   : in  unsigned(7 downto 0);
        chargenData : in  unsigned(7 downto 0);
        romAddr     : out unsigned(15 downto 0);

        -- ROM chip selects
        cs_kernal   : out std_logic;
        cs_basic    : out std_logic;
        cs_chargen  : out std_logic;

        -- VIC video output
        hsync       : out std_logic;
        vsync       : out std_logic;
        colorIndex  : out unsigned(3 downto 0);

        -- CIA1 register interface (active signals go to mos6526 in SV)
        cia1_cs     : out std_logic;
        cia1_rw     : out std_logic;
        cia1_rs     : out unsigned(3 downto 0);
        cia1_din    : out unsigned(7 downto 0);
        cia1_dout   : in  unsigned(7 downto 0);
        cia1_phi2_p : out std_logic;
        cia1_phi2_n : out std_logic;
        cia1_irq_n  : in  std_logic;

        -- CPU debug
        cpuAddr_o   : out unsigned(15 downto 0);
        cpuRW_o     : out std_logic;

        -- Active-high reset output (synced to clk32)
        reset_o     : out std_logic
    );
end c64_system;

architecture rtl of c64_system is

    -- System state machine
    type sysCycleDef is (
        CYCLE_EXT0, CYCLE_EXT1, CYCLE_EXT2, CYCLE_EXT3,
        CYCLE_DMA0, CYCLE_DMA1, CYCLE_DMA2, CYCLE_DMA3,
        CYCLE_EXT4, CYCLE_EXT5, CYCLE_EXT6, CYCLE_EXT7,
        CYCLE_VIC0, CYCLE_VIC1, CYCLE_VIC2, CYCLE_VIC3,
        CYCLE_CPU0, CYCLE_CPU1, CYCLE_CPU2, CYCLE_CPU3,
        CYCLE_CPU4, CYCLE_CPU5, CYCLE_CPU6, CYCLE_CPU7,
        CYCLE_CPU8, CYCLE_CPU9, CYCLE_CPUA, CYCLE_CPUB,
        CYCLE_CPUC, CYCLE_CPUD, CYCLE_CPUE, CYCLE_CPUF
    );

    signal sysCycle     : sysCycleDef := sysCycleDef'low;
    signal preCycle     : sysCycleDef := sysCycleDef'low;
    signal rfsh_cycle   : unsigned(1 downto 0);

    signal phi0_cpu     : std_logic;
    signal cpuHasBus    : std_logic;

    signal baLoc        : std_logic;
    signal ba_dma       : std_logic;
    signal aec          : std_logic;

    signal enableCpu    : std_logic;
    signal enableVic    : std_logic;
    signal enablePixel  : std_logic;

    signal irq_vic      : std_logic;

    signal systemWe     : std_logic;
    signal pulseWr_io   : std_logic;
    signal systemAddr   : unsigned(15 downto 0);

    signal cs_vic_int   : std_logic;
    signal cs_color_int : std_logic;
    signal cs_cia1_int  : std_logic;
    signal cs_ram_int   : std_logic;
    signal cpu_cs_ram_int : std_logic;
    signal cs_kernal_int: std_logic;
    signal cs_basic_int : std_logic;
    signal cs_chargen_int: std_logic;

    signal cpuWe        : std_logic;
    signal cpuAddr      : unsigned(15 downto 0);
    signal cpuDi        : unsigned(7 downto 0);
    signal cpuDo        : unsigned(7 downto 0);
    signal cpuIO        : unsigned(7 downto 0);

    signal io_enable    : std_logic;
    signal cpu_cyc      : std_logic;
    signal cpu_cyc_s    : std_logic_vector(1 downto 0);

    signal reset        : std_logic := '1';

    signal enableCia_p  : std_logic;
    signal enableCia_n  : std_logic;

    -- VIC signals
    signal vicColorIndex: unsigned(3 downto 0);
    signal vicBus       : unsigned(7 downto 0);
    signal vicDi        : unsigned(7 downto 0);
    signal vicDiAec     : unsigned(7 downto 0);
    signal vicAddr      : unsigned(15 downto 0);
    signal vicData      : unsigned(7 downto 0);
    signal lastVicDi    : unsigned(7 downto 0);
    signal colorData    : unsigned(3 downto 0);
    signal colorDataAec : unsigned(3 downto 0);

begin

    -- -----------------------------------------------------------------------
    -- System cycle sequencer
    -- -----------------------------------------------------------------------
    sysCycle <= preCycle;

    process(clk32)
    begin
        if rising_edge(clk32) then
            preCycle <= sysCycleDef'succ(preCycle);
            if preCycle = sysCycleDef'high then
                preCycle <= sysCycleDef'low;
                rfsh_cycle <= rfsh_cycle + 1;
            end if;
        end if;
    end process;

    process(clk32)
    begin
        if rising_edge(clk32) then
            if preCycle = sysCycleDef'high then
                reset <= not reset_n;
            end if;
        end if;
    end process;

    reset_o <= reset;

    -- PHI0 clock emulation
    process(clk32)
    begin
        if rising_edge(clk32) then
            if sysCycle = sysCycleDef'pred(CYCLE_CPU0) then
                phi0_cpu <= '1';
                if baLoc = '1' or cpuWe = '1' then
                    cpuHasBus <= '1';
                end if;
            end if;
            if sysCycle = sysCycleDef'high then
                phi0_cpu <= '0';
                cpuHasBus <= '0';
            end if;
        end if;
    end process;

    -- Enable signal generation
    process(clk32)
    begin
        if rising_edge(clk32) then
            enableVic <= '0';
            enableCia_n <= '0';
            enableCia_p <= '0';

            case sysCycle is
                when CYCLE_VIC2 =>
                    enableVic <= '1';
                when CYCLE_CPUE =>
                    enableVic <= '1';
                when CYCLE_CPUC =>
                    enableCia_n <= '1';
                when CYCLE_CPUF =>
                    enableCia_p <= '1';
                when others =>
                    null;
            end case;
        end if;
    end process;

    -- Pixel timing
    process(clk32)
    begin
        if rising_edge(clk32) then
            enablePixel <= '0';
            if sysCycle = CYCLE_VIC2
            or sysCycle = CYCLE_EXT2
            or sysCycle = CYCLE_DMA2
            or sysCycle = CYCLE_EXT6
            or sysCycle = CYCLE_CPU2
            or sysCycle = CYCLE_CPU6
            or sysCycle = CYCLE_CPUA
            or sysCycle = CYCLE_CPUE then
                enablePixel <= '1';
            end if;
        end if;
    end process;

    -- CPU enable and I/O timing
    cpu_cyc <= '1' when sysCycle = CYCLE_CPUC and
               (io_enable = '1' or cs_ram_int = '1' or cs_kernal_int = '1' or
                cs_basic_int = '1' or cs_chargen_int = '1')
               else '0';

    process(clk32)
    begin
        if rising_edge(clk32) then
            cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc;
            enableCpu <= cpu_cyc_s(1);
            io_enable <= io_enable and not enableCpu;

            if sysCycle = CYCLE_EXT0 then
                io_enable <= '1';
            end if;
        end if;
    end process;

    -- Write pulse for I/O registers
    process(clk32)
    begin
        if rising_edge(clk32) then
            pulseWr_io <= '0';
            if cpuWe = '1' then
                if sysCycle = CYCLE_CPUC then
                    pulseWr_io <= '1';
                end if;
            end if;
        end if;
    end process;

    -- -----------------------------------------------------------------------
    -- Color RAM
    -- -----------------------------------------------------------------------
    colorram: entity work.spram
    generic map (
        DATA_WIDTH => 4,
        ADDR_WIDTH => 10
    )
    port map (
        clk  => clk32,
        we   => cs_color_int and pulseWr_io,
        addr => systemAddr(9 downto 0),
        data => cpuDo(3 downto 0),
        q    => colorData
    );

    -- -----------------------------------------------------------------------
    -- Bus logic / PLA
    -- -----------------------------------------------------------------------
    buslogic: entity work.c64_buslogic
    port map (
        clk         => clk32,
        reset       => reset,

        cpuHasBus   => cpuHasBus,
        aec         => aec,

        ramData     => ramDin,
        chargenData => chargenData,
        kernalData  => kernalData,
        basicData   => basicData,

        bankSwitch  => cpuIO(2 downto 0),

        cpuWe       => cpuWe,
        cpuAddr     => cpuAddr,
        cpuData     => cpuDo,
        vicAddr     => vicAddr,
        vicData     => vicData,
        colorData   => colorData,
        cia1Data    => cia1_dout,
        lastVicData => lastVicDi,

        io_enable   => io_enable,

        systemWe    => systemWe,
        systemAddr  => systemAddr,
        dataToCpu   => cpuDi,
        dataToVic   => vicDi,

        cs_vic      => cs_vic_int,
        cs_color    => cs_color_int,
        cs_cia1     => cs_cia1_int,
        cs_ram      => cs_ram_int,
        cpu_cs_ram  => cpu_cs_ram_int,
        cs_kernal   => cs_kernal_int,
        cs_basic    => cs_basic_int,
        cs_chargen  => cs_chargen_int
    );

    -- -----------------------------------------------------------------------
    -- VIC-II
    -- -----------------------------------------------------------------------
    process(clk32)
    begin
        if rising_edge(clk32) then
            if phi0_cpu = '1' then
                if cpuWe = '1' and cs_vic_int = '1' then
                    vicBus <= cpuDo;
                else
                    vicBus <= x"FF";
                end if;
            end if;
        end if;
    end process;

    vicDiAec <= vicBus when aec = '0' else vicDi;
    colorDataAec <= cpuDi(3 downto 0) when aec = '0' else colorData;

    vic: entity work.video_vicii_656x
    generic map (
        registeredAddress => true,
        emulateRefresh    => true,
        emulateLightpen   => true,
        emulateGraphics   => true
    )
    port map (
        clk        => clk32,
        reset      => reset,
        enaPixel   => enablePixel,
        enaData    => enableVic,
        phi        => phi0_cpu,

        baSync     => '0',
        ba         => baLoc,
        ba_dma     => ba_dma,

        mode6569   => '1',
        mode6567old=> '0',
        mode6567R8 => '0',
        mode6572   => '0',
        variant    => "00",

        turbo_en   => '0',
        turbo_state=> open,

        cs         => cs_vic_int,
        we         => cpuWe,
        lp_n       => '1',

        aRegisters => cpuAddr(5 downto 0),
        diRegisters=> cpuDo,
        di         => vicDiAec,
        diColor    => colorDataAec,
        do         => vicData,

        vicAddr    => vicAddr(13 downto 0),
        addrValid  => aec,

        hsync      => hsync,
        vsync      => vsync,
        colorIndex => vicColorIndex,

        irq_n      => irq_vic
    );

    vicAddr(15 downto 14) <= "00";

    process(clk32)
    begin
        if rising_edge(clk32) then
            if sysCycle = CYCLE_VIC3 then
                lastVicDi <= vicDi;
            end if;
        end if;
    end process;

    -- -----------------------------------------------------------------------
    -- CIA1 interface (exposed as ports, instantiated in chip_core.sv)
    -- -----------------------------------------------------------------------
    cia1_cs     <= cs_cia1_int;
    cia1_rw     <= not cpuWe;
    cia1_rs     <= cpuAddr(3 downto 0);
    cia1_din    <= cpuDo;
    cia1_phi2_p <= enableCia_p;
    cia1_phi2_n <= enableCia_n;

    -- -----------------------------------------------------------------------
    -- CPU (6510)
    -- -----------------------------------------------------------------------
    cpu: entity work.cpu_6510
    port map (
        clk    => clk32,
        reset  => reset,
        enable => enableCpu,
        nmi_n  => '1',
        irq_n  => cia1_irq_n and irq_vic,
        rdy    => baLoc,

        di     => cpuDi,
        addr   => cpuAddr,
        do     => cpuDo,
        we     => cpuWe,

        diIO   => cpuIO(7) & cpuIO(6) & cpuIO(5) & '0' & cpuIO(3) & "111",
        doIO   => cpuIO
    );

    -- -----------------------------------------------------------------------
    -- External interfaces
    -- -----------------------------------------------------------------------
    ramDout <= cpuDo;
    ramAddr <= systemAddr;
    ramWE   <= systemWe when sysCycle >= CYCLE_CPU0 else '0';
    ramCE   <= cs_ram_int when sysCycle = CYCLE_VIC0 or cpu_cyc = '1' else '0';

    -- Early PSRAM trigger: one clean pulse at the start of the period (state 0)
    -- for CPU RAM accesses, giving the quad read the full ~870 ns budget to the
    -- state-31 CPU sample. cpuAddr/cpuWe/cpuDo are stable from state 0 (the CPU
    -- is paused between enableCpu pulses), so read and write both trigger here.
    psramCE   <= cpu_cs_ram_int when sysCycle = CYCLE_EXT0 else '0';
    psramAddr <= cpuAddr;
    psramWE   <= cpuWe;

    romAddr    <= systemAddr;
    cs_kernal  <= cs_kernal_int;
    cs_basic   <= cs_basic_int;
    cs_chargen <= cs_chargen_int;

    colorIndex <= vicColorIndex;

    cpuAddr_o <= cpuAddr;
    cpuRW_o   <= not cpuWe;

end architecture;

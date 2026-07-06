-- C64 bus logic / PLA decode — tapeout subset
--
-- Simplified from fpga64_buslogic.vhd (Peter Wendrich):
--   - No cartridge (game/exrom hardwired inactive)
--   - No dprom instances (ROMs are external, data comes in on ports)
--   - No CIA2 chip-select (only CIA1)
--   - No BIOS selection or ROM loading
--   - Separate chip-selects for KERNAL, BASIC, chargen ROMs
--
-- Memory map (with bankSwitch = "111", default state):
--   $0000-$1FFF: RAM (8KB on tapeout)
--   $2000-$9FFF: open bus (no RAM backing)
--   $A000-$BFFF: BASIC ROM
--   $C000-$CFFF: open bus
--   $D000-$D3FF: VIC-II registers
--   $D400-$D7FF: SID space (returns $FF, no SID)
--   $D800-$DBFF: Color RAM
--   $DC00-$DCFF: CIA1
--   $DD00-$DDFF: open bus (no CIA2)
--   $DE00-$DFFF: open bus (no I/O expansion)
--   $E000-$FFFF: KERNAL ROM

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity c64_buslogic is
    port (
        clk         : in std_logic;
        reset       : in std_logic;

        cpuHasBus   : in std_logic;
        aec         : in std_logic;

        ramData     : in unsigned(7 downto 0);
        chargenData : in unsigned(7 downto 0);
        kernalData  : in unsigned(7 downto 0);
        basicData   : in unsigned(7 downto 0);

        bankSwitch  : in unsigned(2 downto 0);

        cpuWe       : in std_logic;
        cpuAddr     : in unsigned(15 downto 0);
        cpuData     : in unsigned(7 downto 0);
        vicAddr     : in unsigned(15 downto 0);
        vicData     : in unsigned(7 downto 0);
        colorData   : in unsigned(3 downto 0);
        cia1Data    : in unsigned(7 downto 0);
        lastVicData : in unsigned(7 downto 0);

        io_enable   : in std_logic;

        systemWe    : out std_logic;
        systemAddr  : out unsigned(15 downto 0);
        dataToCpu   : out unsigned(7 downto 0);
        dataToVic   : out unsigned(7 downto 0);

        cs_vic      : out std_logic;
        cs_color    : out std_logic;
        cs_cia1     : out std_logic;
        cs_ram      : out std_logic;
        -- CPU-path RAM decode, valid regardless of who holds the bus (unlike
        -- cs_ram, which is muxed to the VIC during phi1). Used by c64_system
        -- to gate the early PSRAM trigger at the start of the period.
        cpu_cs_ram  : out std_logic;
        cs_kernal   : out std_logic;
        cs_basic    : out std_logic;
        cs_chargen  : out std_logic
    );
end c64_buslogic;

architecture rtl of c64_buslogic is
    signal cs_CharLoc     : std_logic;
    signal cs_kernalLoc   : std_logic;
    signal cs_basicLoc    : std_logic;
    signal cs_ramLoc      : std_logic;
    signal cs_vicLoc      : std_logic;
    signal cs_colorLoc    : std_logic;
    signal cs_cia1Loc     : std_logic;
    signal vicCharLoc     : std_logic;

    signal currentAddr    : unsigned(15 downto 0);

    -- Single source of truth for "does this CPU access target main RAM?"
    -- (RAM vs ROM/I/O), from the address, write flag and bank-switch bits.
    -- Used both by the muxed decode below (the cpuHasBus branch drives
    -- cs_ramLoc from it) and by the ungated cpu_cs_ram output that gates the
    -- early PSRAM trigger — so the two can never drift. Encodes the C64 PLA
    -- RAM regions.
    function cpu_ram_sel(addr : unsigned(15 downto 0);
                         we   : std_logic;
                         bank : unsigned(2 downto 0)) return std_logic is
    begin
        case addr(15 downto 12) is
        when X"E" | X"F" =>              -- RAM unless a KERNAL read
            if not (we = '0' and bank(1) = '1') then
                return '1';
            end if;
        when X"D" =>
            if bank(1) = '0' and bank(0) = '0' then
                return '1';              -- RAM banked in over $Dxxx
            elsif bank(2) = '1' then
                return '0';              -- I/O space (VIC/SID/color/CIA)
            elsif we = '1' then
                return '1';              -- RAM on write, chargen on read
            end if;
        when X"A" | X"B" =>              -- RAM unless a BASIC read
            if not (we = '0' and bank(1) = '1' and bank(0) = '1') then
                return '1';
            end if;
        when others =>
            return '1';                  -- $0000-$9FFF, $C000-$CFFF: RAM
        end case;
        return '0';
    end function;
begin

    -- Data-to-CPU mux
    process(ramData, vicData, colorData, cia1Data,
            chargenData, kernalData, basicData,
            cs_kernalLoc, cs_basicLoc, cs_CharLoc,
            cs_ramLoc, cs_vicLoc, cs_colorLoc,
            cs_cia1Loc, lastVicData)
    begin
        dataToCpu <= lastVicData;
        if cs_CharLoc = '1' then
            dataToCpu <= chargenData;
        elsif cs_kernalLoc = '1' then
            dataToCpu <= kernalData;
        elsif cs_basicLoc = '1' then
            dataToCpu <= basicData;
        elsif cs_ramLoc = '1' then
            dataToCpu <= ramData;
        elsif cs_vicLoc = '1' then
            dataToCpu <= vicData;
        elsif cs_colorLoc = '1' then
            dataToCpu(7 downto 4) <= x"F";
            dataToCpu(3 downto 0) <= colorData;
        elsif cs_cia1Loc = '1' then
            dataToCpu <= cia1Data;
        end if;
    end process;

    -- Address decode / PLA emulation
    -- No cartridge: game='1', exrom='1' (inactive), so ultimax='0'
    process(cpuHasBus, cpuAddr, cpuWe, bankSwitch, aec, vicAddr)
    begin
        currentAddr <= (others => '1');
        systemWe <= '0';
        vicCharLoc <= '0';
        cs_CharLoc <= '0';
        cs_kernalLoc <= '0';
        cs_basicLoc <= '0';
        cs_ramLoc <= '0';
        cs_vicLoc <= '0';
        cs_colorLoc <= '0';
        cs_cia1Loc <= '0';

        if cpuHasBus = '1' then
            currentAddr <= cpuAddr;
            -- RAM select from the shared decode; the case below only picks the
            -- non-RAM selects (ROM / I/O / chargen).
            cs_ramLoc <= cpu_ram_sel(cpuAddr, cpuWe, bankSwitch);
            case cpuAddr(15 downto 12) is
            when X"E" | X"F" =>
                if cpuWe = '0' and bankSwitch(1) = '1' then
                    cs_kernalLoc <= '1';
                end if;
            when X"D" =>
                if bankSwitch(1) = '0' and bankSwitch(0) = '0' then
                    null; -- RAM (cs_ramLoc set above)
                elsif bankSwitch(2) = '1' then
                    case cpuAddr(11 downto 8) is
                        when X"0" | X"1" | X"2" | X"3" =>
                            cs_vicLoc <= '1';
                        when X"4" | X"5" | X"6" | X"7" =>
                            null; -- SID space: no SID, returns open bus
                        when X"8" | X"9" | X"A" | X"B" =>
                            cs_colorLoc <= '1';
                        when X"C" =>
                            cs_cia1Loc <= '1';
                        when X"D" =>
                            null; -- CIA2 space: no CIA2
                        when others =>
                            null; -- $DE00/$DF00: no I/O expansion
                    end case;
                else
                    if cpuWe = '0' then
                        cs_CharLoc <= '1';
                    end if;
                end if;
            when X"A" | X"B" =>
                if cpuWe = '0' and bankSwitch(1) = '1' and bankSwitch(0) = '1' then
                    cs_basicLoc <= '1';
                end if;
            when others =>
                null; -- RAM (cs_ramLoc set above)
            end case;

            systemWe <= cpuWe;
        else
            -- VIC has the bus
            if aec = '1' then
                currentAddr <= vicAddr;
            else
                currentAddr <= cpuAddr;
            end if;

            -- VIC character ROM access: bank 0, address $1000-$1FFF
            if vicAddr(14 downto 12) = "001" then
                vicCharLoc <= '1';
            else
                cs_ramLoc <= '1';
            end if;
        end if;
    end process;

    cs_ram     <= cs_ramLoc;
    cs_vic     <= cs_vicLoc and io_enable;
    cs_color   <= cs_colorLoc and io_enable;
    cs_cia1    <= cs_cia1Loc and io_enable;
    cs_kernal  <= cs_kernalLoc;
    cs_basic   <= cs_basicLoc;
    cs_chargen <= cs_CharLoc or vicCharLoc;

    dataToVic  <= chargenData when vicCharLoc = '1' else ramData;
    systemAddr <= currentAddr;

    -- CPU-path RAM decode, independent of cpuHasBus (unlike cs_ram, which is
    -- muxed to the VIC during phi1). cpuAddr/cpuWe/bankSwitch are stable for
    -- the whole period (the CPU only advances on enableCpu at state 31), so
    -- this is valid from state 0 — when the early PSRAM trigger fires, before
    -- the shared cs_ram has switched from the VIC to the CPU.
    cpu_cs_ram <= cpu_ram_sel(cpuAddr, cpuWe, bankSwitch);

end architecture;

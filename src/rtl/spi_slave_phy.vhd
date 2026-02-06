library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_slave_phy is
  port (
    clk_sys       : in  std_logic;
    rst_n         : in  std_logic;

    spi_sclk      : in  std_logic;  -- Mode 0: sample MOSI on rising edge
    spi_mosi      : in  std_logic;
    spi_cs_n      : in  std_logic;
    spi_miso      : out std_logic;  -- Mode 0: shift out changes on falling edge (observed by master on rising)

    rx_byte_valid : out std_logic;  -- 1 clk_sys pulse
    rx_byte       : out std_logic_vector(7 downto 0);

    tx_byte       : in  std_logic_vector(7 downto 0);
    tx_byte_load  : in  std_logic   -- level: can be held high
  );
end entity;

architecture rtl of spi_slave_phy is

  -- Synchronizers into clk_sys domain
  signal sclk_ff0, sclk_ff1 : std_logic := '0';
  signal cs_ff0,   cs_ff1   : std_logic := '1';
  signal mosi_ff0, mosi_ff1 : std_logic := '0';

  -- Edge detect (clk_sys domain)
  signal sclk_prev : std_logic := '0';
  signal cs_prev   : std_logic := '1';

  signal sclk_rise : std_logic := '0';
  signal sclk_fall : std_logic := '0';
  signal cs_fall   : std_logic := '0';
  signal cs_rise   : std_logic := '0';

  -- Data path
  signal bit_cnt    : unsigned(2 downto 0) := (others => '0'); -- counts SCLK rising edges within a byte
  signal shift_in   : std_logic_vector(7 downto 0) := (others => '0');
  signal shift_out  : std_logic_vector(7 downto 0) := (others => '0');

  signal rx_byte_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_pulse_r : std_logic := '0';

begin

  -- MISO is MSB of shift_out; shift_out is updated only on clk_sys
  spi_miso <= shift_out(7);

  rx_byte_valid <= rx_pulse_r;
  rx_byte       <= rx_byte_r;

  process(clk_sys, rst_n)
    variable next_rx : std_logic_vector(7 downto 0);
  begin
    if rst_n = '0' then
      -- Sync regs
      sclk_ff0 <= '0'; sclk_ff1 <= '0';
      cs_ff0   <= '1'; cs_ff1   <= '1';
      mosi_ff0 <= '0'; mosi_ff1 <= '0';

      sclk_prev <= '0';
      cs_prev   <= '1';

      sclk_rise <= '0';
      sclk_fall <= '0';
      cs_fall   <= '0';
      cs_rise   <= '0';

      -- Datapath
      bit_cnt    <= (others => '0');
      shift_in   <= (others => '0');
      shift_out  <= (others => '0');
      rx_byte_r  <= (others => '0');
      rx_pulse_r <= '0';

    elsif rising_edge(clk_sys) then
      -- Default pulse low each clk_sys cycle
      rx_pulse_r <= '0';

      -- 2FF synchronize external pins
      sclk_ff0 <= spi_sclk;  sclk_ff1 <= sclk_ff0;
      cs_ff0   <= spi_cs_n;  cs_ff1   <= cs_ff0;
      mosi_ff0 <= spi_mosi;  mosi_ff1 <= mosi_ff0;

      -- Edge detect based on previous synchronized values
      sclk_rise <= '0';
      sclk_fall <= '0';
      cs_fall   <= '0';
      cs_rise   <= '0';

      if (sclk_prev = '0' and sclk_ff1 = '1') then sclk_rise <= '1'; end if;
      if (sclk_prev = '1' and sclk_ff1 = '0') then sclk_fall <= '1'; end if;
      if (cs_prev   = '1' and cs_ff1   = '0') then cs_fall   <= '1'; end if;
      if (cs_prev   = '0' and cs_ff1   = '1') then cs_rise   <= '1'; end if;

      sclk_prev <= sclk_ff1;
      cs_prev   <= cs_ff1;

      -- If CS is high (inactive), hold everything in reset state
      if cs_ff1 = '1' then
        bit_cnt   <= (others => '0');
        shift_in  <= (others => '0');
        shift_out <= (others => '0');

      else
        -- CS just asserted low: preload MISO byte so first bit is valid before first SCLK rising edge
        if cs_fall = '1' then
          bit_cnt  <= (others => '0');
          shift_in <= (others => '0');

          if tx_byte_load = '1' then
            shift_out <= tx_byte;
          else
            shift_out <= (others => '0');
          end if;
        end if;

        -- Sample MOSI on SCLK rising edges (Mode 0)
        if sclk_rise = '1' then
          next_rx := shift_in(6 downto 0) & mosi_ff1;
          shift_in <= next_rx;

          if bit_cnt = "111" then
            -- Completed byte
            rx_byte_r  <= next_rx;
            rx_pulse_r <= '1';
            bit_cnt    <= (others => '0');
          else
            bit_cnt <= bit_cnt + 1;
          end if;
        end if;

        -- Update shift_out on SCLK falling edges (Mode 0)
        if sclk_fall = '1' then
          -- After a complete byte, bit_cnt has been reset to 0 on the last rising edge.
          -- The falling edge after that is where we load the next byte (if any).
          if bit_cnt = "000" then
            if tx_byte_load = '1' then
              shift_out <= tx_byte;
            else
              shift_out <= (others => '0');
            end if;
          else
            -- Shift left, MSB-first
            shift_out <= shift_out(6 downto 0) & '0';
          end if;
        end if;

        -- CS rising edge: optionally clear (already handled by cs_ff1='1' branch next cycle)
        if cs_rise = '1' then
          bit_cnt  <= (others => '0');
          shift_in <= (others => '0');
          -- shift_out will be cleared when cs_ff1 becomes '1' (same or next cycle depending on sync)
        end if;

      end if;
    end if;
  end process;

end architecture;

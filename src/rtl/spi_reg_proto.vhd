-- spi_reg_proto.vhd
--
-- SPI register protocol layer (Option A) sitting above spi_slave_phy.
-- Consumes rx_byte_valid/rx_byte and produces:
--   - reg read requests + index
--   - reg write strobes + index + 32-bit data (little-endian on wire)
-- Drives tx_byte for MISO with 1-byte turnaround for reads:
--   MISO during CMD byte = dummy (0x00)
--   then DATA0..DATA3 (little-endian) for the next 4 bytes.
--
-- Notes:
-- - tx_byte_load is driven '1' continuously (simple level handshake).
-- - CS rising resets the parser; incomplete commands are discarded.
-- - A bad_cmd_pulse is generated if CS rises mid-command (optional hook for STATUS.BAD_CMD).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_reg_proto is
  port (
    clk_sys  : in  std_logic;
    rst_n    : in  std_logic;

    -- raw CS from top-level (same pin that goes to spi_slave_phy)
    spi_cs_n : in  std_logic;

    -- from spi_slave_phy (clk_sys domain)
    rx_byte_valid : in  std_logic;
    rx_byte       : in  std_logic_vector(7 downto 0);

    -- to spi_slave_phy
    tx_byte      : out std_logic_vector(7 downto 0);
    tx_byte_load : out std_logic;

    -- to reg_file
    rd_req  : out std_logic;                      -- 1-cycle pulse
    rd_idx  : out std_logic_vector(6 downto 0);   -- REG_IDX
    rd_data : in  std_logic_vector(31 downto 0);  -- read value (assumed valid shortly after rd_req)

    wr_en   : out std_logic;                      -- 1-cycle pulse
    wr_idx  : out std_logic_vector(6 downto 0);   -- REG_IDX
    wr_data : out std_logic_vector(31 downto 0);  -- assembled little-endian

    -- optional status hook
    bad_cmd_pulse : out std_logic                 -- 1-cycle pulse on CS-rise mid-command
  );
end entity;

architecture rtl of spi_reg_proto is

  type state_t is (
    ST_IDLE,        -- waiting for CS low
    ST_GET_CMD,     -- expecting CMD byte
    ST_WR_D0, ST_WR_D1, ST_WR_D2, ST_WR_D3, -- collecting write data bytes
    ST_RD_LOAD,     -- latch rd_data and prime DATA0
    ST_RD_B1, ST_RD_B2, ST_RD_B3,           -- advance DATA1..3 based on rx_byte_valid
    ST_DONE         -- ignore bytes until CS rises
  );

  signal st : state_t := ST_IDLE;

  -- CS synchronizer / edge detect (clk_sys domain)
  signal cs_ff0, cs_ff1 : std_logic := '1';
  signal cs_prev        : std_logic := '1';
  signal cs_rise        : std_logic := '0';
  signal cs_fall        : std_logic := '0';

  -- decoded command
  signal cmd_rw  : std_logic := '0'; -- 1=write, 0=read
  signal cmd_idx : std_logic_vector(6 downto 0) := (others => '0');

  -- write assembly
  signal w_d0, w_d1, w_d2, w_d3 : std_logic_vector(7 downto 0) := (others => '0');

  -- read data latch and byte pointer
  signal rd_latched : std_logic_vector(31 downto 0) := (others => '0');

  -- tx byte register
  signal tx_b : std_logic_vector(7 downto 0) := (others => '0');

  -- bookkeeping: are we mid-command (for BAD_CMD on CS rise)?
  signal in_cmd : std_logic := '0';

begin

  -- simple: always keep load asserted; spi_slave_phy will load tx_byte at byte boundaries
  tx_byte      <= tx_b;
  tx_byte_load <= '1';

  process(clk_sys, rst_n)
  begin
    if rst_n = '0' then
      st <= ST_IDLE;

      cs_ff0 <= '1'; cs_ff1 <= '1';
      cs_prev <= '1';
      cs_rise <= '0';
      cs_fall <= '0';

      cmd_rw  <= '0';
      cmd_idx <= (others => '0');

      w_d0 <= (others => '0');
      w_d1 <= (others => '0');
      w_d2 <= (others => '0');
      w_d3 <= (others => '0');

      rd_latched <= (others => '0');

      tx_b <= (others => '0');

      rd_req <= '0';
      rd_idx <= (others => '0');

      wr_en   <= '0';
      wr_idx  <= (others => '0');
      wr_data <= (others => '0');

      bad_cmd_pulse <= '0';
      in_cmd <= '0';

    elsif rising_edge(clk_sys) then
      -- defaults (pulses)
      rd_req <= '0';
      wr_en  <= '0';
      bad_cmd_pulse <= '0';

      -- sync CS
      cs_ff0 <= spi_cs_n;
      cs_ff1 <= cs_ff0;

      cs_rise <= '0';
      cs_fall <= '0';
      if (cs_prev = '0' and cs_ff1 = '1') then cs_rise <= '1'; end if;
      if (cs_prev = '1' and cs_ff1 = '0') then cs_fall <= '1'; end if;
      cs_prev <= cs_ff1;

      -- CS falling: start of transaction, prime dummy MISO byte
      if cs_fall = '1' then
        st <= ST_GET_CMD;
        tx_b <= x"00";      -- dummy during CMD byte
        in_cmd <= '0';
      end if;

      -- CS rising: end of transaction, reset and (optionally) flag bad cmd if mid-command
      if cs_rise = '1' then
        if in_cmd = '1' then
          bad_cmd_pulse <= '1';
        end if;
        st <= ST_IDLE;
        tx_b <= x"00";
        in_cmd <= '0';
      end if;

      -- If CS is high, stay idle (ignore rx_byte_valid)
      if cs_ff1 = '1' then
        -- nothing else
        null;
      else
        -- main FSM driven by rx_byte_valid (byte boundaries)
        case st is

          when ST_IDLE =>
            -- shouldn't be here while CS low, but keep safe
            st <= ST_GET_CMD;
            tx_b <= x"00";
            in_cmd <= '0';

          when ST_GET_CMD =>
            if rx_byte_valid = '1' then
              -- CMD[7]=RW, CMD[6:0]=REG_IDX
              cmd_rw  <= rx_byte(7);
              cmd_idx <= rx_byte(6 downto 0);
              in_cmd  <= '1';

              if rx_byte(7) = '1' then
                -- WRITE: next 4 bytes are data0..3
                st <= ST_WR_D0;
                tx_b <= x"00"; -- don't care during writes; keep 0
              else
                -- READ: request data, then next transmitted byte must be DATA0
                rd_idx <= rx_byte(6 downto 0);
                rd_req <= '1';
                st <= ST_RD_LOAD;
                -- tx_b stays 0 during CMD byte; DATA0 will be loaded in ST_RD_LOAD
              end if;
            end if;

          when ST_WR_D0 =>
            if rx_byte_valid = '1' then
              w_d0 <= rx_byte;
              st   <= ST_WR_D1;
            end if;

          when ST_WR_D1 =>
            if rx_byte_valid = '1' then
              w_d1 <= rx_byte;
              st   <= ST_WR_D2;
            end if;

          when ST_WR_D2 =>
            if rx_byte_valid = '1' then
              w_d2 <= rx_byte;
              st   <= ST_WR_D3;
            end if;

          when ST_WR_D3 =>
            if rx_byte_valid = '1' then
              w_d3 <= rx_byte;

              -- assemble little-endian into 32-bit word
              wr_idx  <= cmd_idx;
              wr_en   <= '1';

              -- Correct assembly: DATA0 is [7:0], DATA3 is [31:24]
              -- So word = DATA3:DATA2:DATA1:DATA0 in vector(31 downto 0)
              wr_data <= (rx_byte & w_d2 & w_d1 & w_d0);

              st <= ST_DONE;
              in_cmd <= '0';
            end if;

          when ST_RD_LOAD =>
            -- allow 1 clk_sys for rd_data to settle (from reg_file)
            rd_latched <= rd_data;

            -- prime DATA0 for the *next* SPI byte after CMD
            tx_b <= rd_data(7 downto 0);

            -- after the next received byte (first MOSI dummy), we should advance to DATA1
            st <= ST_RD_B1;
            in_cmd <= '0';

          when ST_RD_B1 =>
            if rx_byte_valid = '1' then
              tx_b <= rd_latched(15 downto 8);
              st   <= ST_RD_B2;
            end if;

          when ST_RD_B2 =>
            if rx_byte_valid = '1' then
              tx_b <= rd_latched(23 downto 16);
              st   <= ST_RD_B3;
            end if;

          when ST_RD_B3 =>
            if rx_byte_valid = '1' then
              tx_b <= rd_latched(31 downto 24);
              st   <= ST_DONE;
            end if;

          when ST_DONE =>
            -- ignore everything until CS rises (transaction boundary)
            null;

        end case;
      end if;

    end if;
  end process;

end architecture;

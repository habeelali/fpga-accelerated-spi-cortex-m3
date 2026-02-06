library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_spi_slave_phy is
end entity;

architecture tb of tb_spi_slave_phy is
  -- Clocks
  constant T_CLK_SYS  : time := 20 ns;  -- 50 MHz sys clock

  constant T_SCLK     : time := 500 ns; -- 2 MHz SCLK period
  constant T_HALF     : time := T_SCLK / 2;

  constant ABORT_BYTE : std_logic_vector(7 downto 0) := x"F0";

  -- DUT signals
  signal clk_sys       : std_logic := '0';
  signal rst_n         : std_logic := '0';

  signal spi_sclk      : std_logic := '0';
  signal spi_mosi      : std_logic := '0';
  signal spi_cs_n      : std_logic := '1';
  signal spi_miso      : std_logic;

  signal rx_byte_valid : std_logic;
  signal rx_byte       : std_logic_vector(7 downto 0);

  signal tx_byte       : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_byte_load  : std_logic := '0';

  -- Scoreboard
  type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
  constant EXPECT_RX : byte_arr(0 to 1) := (x"A5", x"3C");

  signal rx_count : integer := 0;

  -- Helper: hex string without to_hstring dependency
  function hex2(x : std_logic_vector(7 downto 0)) return string is
    constant H : string := "0123456789ABCDEF";
    variable s : string(1 to 2);
    variable v : integer;
  begin
    v := to_integer(unsigned(x(7 downto 4)));
    s(1) := H(v+1);
    v := to_integer(unsigned(x(3 downto 0)));
    s(2) := H(v+1);
    return s;
  end function;

  -- Utility procedure: drive SPI Mode0 and sample MISO like a master.
  procedure spi_xfer_byte(
    signal sclk       : out std_logic;
    signal mosi       : out std_logic;
    signal miso       : in  std_logic;
    constant mosi_byte: in  std_logic_vector(7 downto 0);
    variable miso_byte: out std_logic_vector(7 downto 0)
  ) is
    variable mb : std_logic_vector(7 downto 0) := (others => '0');
  begin
    -- idle low
    sclk <= '0';
    wait for T_HALF;

    for i in 7 downto 0 loop
      -- setup MOSI while clock low
      mosi <= mosi_byte(i);
      wait for T_HALF;

      -- rising edge: slave samples MOSI; master samples MISO
      sclk <= '1';
      wait for T_HALF/4;
      mb(i) := miso;
      wait for T_HALF - T_HALF/4;

      -- falling edge: slave updates MISO
      sclk <= '0';
      wait for T_HALF;
    end loop;

    miso_byte := mb;
  end procedure;

begin
  -- DUT instance
  dut: entity work.spi_slave_phy
    port map (
      clk_sys       => clk_sys,
      rst_n         => rst_n,
      spi_sclk      => spi_sclk,
      spi_mosi      => spi_mosi,
      spi_cs_n      => spi_cs_n,
      spi_miso      => spi_miso,
      rx_byte_valid => rx_byte_valid,
      rx_byte       => rx_byte,
      tx_byte       => tx_byte,
      tx_byte_load  => tx_byte_load
    );

  -- clk_sys generator
  p_clk: process
  begin
    while true loop
      clk_sys <= '0';
      wait for T_CLK_SYS/2;
      clk_sys <= '1';
      wait for T_CLK_SYS/2;
    end loop;
  end process;

  -- RX monitor
  p_rx_monitor: process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if rx_byte_valid = '1' then
        assert rx_count <= EXPECT_RX'high
          report "Received more bytes than expected"
          severity failure;

        assert rx_byte = EXPECT_RX(rx_count)
          report "RX byte mismatch idx=" & integer'image(rx_count) &
                 " exp=0x" & hex2(EXPECT_RX(rx_count)) &
                 " got=0x" & hex2(rx_byte)
          severity failure;

        rx_count <= rx_count + 1;
      end if;
    end if;
  end process;

  -- Stimulus
  p_stim: process
    variable miso_cap : std_logic_vector(7 downto 0);
    variable before_abort_count : integer;
  begin
    -- Reset
    spi_cs_n <= '1';
    spi_sclk <= '0';
    spi_mosi <= '0';
    tx_byte <= x"00";
    tx_byte_load <= '0';

    rst_n <= '0';
    wait for 200 ns;
    rst_n <= '1';
    wait for 200 ns;

    -- Provide constant TX byte and hold load high (level handshake)
    tx_byte <= x"5A";
    tx_byte_load <= '1';

    -- Transaction: send two bytes
    spi_cs_n <= '0';
    wait for 200 ns;

    spi_xfer_byte(spi_sclk, spi_mosi, spi_miso, x"A5", miso_cap);
    assert miso_cap = x"5A"
      report "MISO mismatch (byte1) exp=0x5A got=0x" & hex2(miso_cap)
      severity failure;

    spi_xfer_byte(spi_sclk, spi_mosi, spi_miso, x"3C", miso_cap);
    assert miso_cap = x"5A"
      report "MISO mismatch (byte2) exp=0x5A got=0x" & hex2(miso_cap)
      severity failure;

    spi_cs_n <= '1';
    wait for 10 us; -- allow rx pulses through clk_sys domain

    assert rx_count = 2
      report "Expected 2 RX bytes, got " & integer'image(rx_count)
      severity failure;

    -- Abort test: drop CS mid-byte and ensure no extra rx bytes appear
    before_abort_count := rx_count;

    spi_cs_n <= '0';
    wait for 200 ns;

    -- Send 4 bits then abort
    for i in 7 downto 4 loop
      spi_mosi <= ABORT_BYTE(i);
      wait for T_HALF;
      spi_sclk <= '1';
      wait for T_HALF;
      spi_sclk <= '0';
      wait for T_HALF;
    end loop;

    spi_cs_n <= '1';
    wait for 10 us;

    assert rx_count = before_abort_count
      report "Abort mid-byte produced a byte (unexpected)"
      severity failure;

    report "PASS: spi_slave_phy standalone tests passed." severity note;
    stop(0);   -- or finish;


    -- Portable simulation stop
    assert false report "End of simulation" severity failure;
  end process;

end architecture;

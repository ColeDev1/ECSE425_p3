library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cache_tb is
end cache_tb;

architecture behavior of cache_tb is

component cache is
generic(
    ram_size : INTEGER := 32768
);
port(
    clock : in std_logic;
    reset : in std_logic;

    -- Avalon interface --
    s_addr : in std_logic_vector (31 downto 0);
    s_read : in std_logic;
    s_readdata : out std_logic_vector (31 downto 0);
    s_write : in std_logic;
    s_writedata : in std_logic_vector (31 downto 0);
    s_waitrequest : out std_logic; 

    m_addr : out integer range 0 to ram_size-1;
    m_read : out std_logic;
    m_readdata : in std_logic_vector (7 downto 0);
    m_write : out std_logic;
    m_writedata : out std_logic_vector (7 downto 0);
    m_waitrequest : in std_logic
);
end component;

component memory is 
GENERIC(
    ram_size : INTEGER := 32768;
    mem_delay : time := 10 ns;
    clock_period : time := 1 ns
);
PORT (
    clock: IN STD_LOGIC;
    writedata: IN STD_LOGIC_VECTOR (7 DOWNTO 0);
    address: IN INTEGER RANGE 0 TO ram_size-1;
    memwrite: IN STD_LOGIC;
    memread: IN STD_LOGIC;
    readdata: OUT STD_LOGIC_VECTOR (7 DOWNTO 0);
    waitrequest: OUT STD_LOGIC
);
end component;
	
-- test signals 
signal reset : std_logic := '0';
signal clk : std_logic := '0';
constant clk_period : time := 1 ns;

signal s_addr : std_logic_vector (31 downto 0);
signal s_read : std_logic;
signal s_readdata : std_logic_vector (31 downto 0);
signal s_write : std_logic;
signal s_writedata : std_logic_vector (31 downto 0);
signal s_waitrequest : std_logic;

signal m_addr : integer range 0 to 2147483647;
signal m_read : std_logic;
signal m_readdata : std_logic_vector (7 downto 0);
signal m_write : std_logic;
signal m_writedata : std_logic_vector (7 downto 0);
signal m_waitrequest : std_logic; 

begin

-- Connect the components which we instantiated above to their
-- respective signals.
dut: cache 
port map(
    clock => clk,
    reset => reset,

    s_addr => s_addr,
    s_read => s_read,
    s_readdata => s_readdata,
    s_write => s_write,
    s_writedata => s_writedata,
    s_waitrequest => s_waitrequest,

    m_addr => m_addr,
    m_read => m_read,
    m_readdata => m_readdata,
    m_write => m_write,
    m_writedata => m_writedata,
    m_waitrequest => m_waitrequest
);

MEM : memory
port map (
    clock => clk,
    writedata => m_writedata,
    address => m_addr,
    memwrite => m_write,
    memread => m_read,
    readdata => m_readdata,
    waitrequest => m_waitrequest
);
				

clk_process : process
begin
  clk <= '0';
  wait for clk_period/2;
  clk <= '1';
  wait for clk_period/2;
end process;

test_process : process
--=======================================================================================================
	--Memory Instantiations:
	
	--Memory locations A and C will be mapped to the same set, but contain different tags 
	
		--Memory location A: "0x00001010" => Tag "0b001000" Idx "0b00001" Off "0b00"
	variable A : INTEGER := 4112;
	
		--Memory location C: "0x00002010" => Tag "0b010000" Idx "0b00001" Off "0b00"
	variable C : INTEGER :=	8208;
	
	--Memory locations B will be mapped to a different set in the cache
	
		--Memory location B" "0x00001020" => Tag "0b001000" Idx "0b00010" Off "0b00"
	variable B : INTEGER := 4128;
--=======================================================================================================	
begin
	--Initialize all the inputs as 0
	s_read <= '0';
	s_write <= '0';
	s_addr <= std_logic_vector(to_unsigned(0, 32));
	s_writedata <= std_logic_vector(to_unsigned(0, 32));
--=======================================================================================================
	-- Test Case Execution:
	
	--Note: We can check rising_edge(waitrequest) to check for next time we can read/write to $
	-- For each of the 10 tests, we will:
	-- 1) Check that waitrequest signal is high (meaning its ready to accept a new operation initially)
	-- 2) Setup read or write operation
	-- 3) wait until rising_edge(waitrequest) (Indicating read data valid or write request completed)
	-- 4) assert to check that the expected behavior occured...
	-- 5) Additionally, on dirty evictions, we will check to make sure MM is updated accordingly
--=======================================================================================================
	
	--Test Case 1:
	--Writing "00" Tag Mismatch Case: Writing to memory address B not yet in $
	wait for 1 ns;
	s_addr <= std_logic_vector(to_unsigned(B, 32));
	s_writedata <= std_logic_vector(to_unsigned(54, 32));
	s_write <= '1';
	wait until rising_edge(s_waitrequest);
	
	--Read from cache at location B to verify data is as expected...
	s_write <= '0';
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	assert s_readdata = X"00000036"; report "Writing 00 Tag Mismatch Case: Data not properly written" severity error;
	s_read <= '0';
--=======================================================================================================	
	
	--Test Case 2:
	--Reading "00" Tag Mismatch Case: Reading from  memory address A not yet in $
	s_addr <= std_logic_vector(to_unsigned(A, 32));
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	--Junk data at this memory location. Only reason we know the value is because we know how the SRAM is initialized in memory.vhd
	--ram_block(i) <= std_logic_vector(to_unsigned(i, 8)), so for memory location A, 
	--This is assigned the junk value "0x10", then subsequent blocks have byte values increasing by 1 (eg "0x11", "0x12", ...)
	assert s_readdata = X"13121110" report "Reading 00 Tag Mismatch Case: Data not updated from MM properly" severity error;
--=======================================================================================================	
	
	--Test Case 3:
	--Reading "10" Tag Match Case: Reading from memory address A already in $
	s_addr <= std_logic_vector(to_unsigned(A, 32));
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"13121110" report "Reading 10 Tag Match Case: Cache data does not match" severity error;

--=======================================================================================================
	
	--Test Case 4:
	--Writing "10" Tag Match Case: Writing to memory address A already in $
	s_addr <= std_logic_vector(to_unsigned(A, 32));
	s_writedata <= std_logic_vector(to_unsigned(33, 32));
	s_write <= '1';
	wait until rising_edge(s_waitrequest);
	
	--Reading from the $ location to ensure data written properly
	s_write <= '0';
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"00000021" report "Writing 10 Tag Match Case: Cache data not updated properly" severity error;
--=======================================================================================================	
	
	--Test Case 5:
	--Reading "11" Tag Match Case: Reading from memory address A that is dirty
	s_addr <= std_logic_vector(to_unsigned(A, 32));
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"00000021" report "Reading 11 Tag Match Case: Cache data does not match" severity error;
--=======================================================================================================	
	
	--Test Case 6:
	--Writing "11" Tag Match Case: Writing to memory address A that is dirty
	s_addr <= std_logic_vector(to_unsigned(A, 32));
	s_writedata <= std_logic_vector(to_unsigned(34, 32));
	s_write <= '1';
	wait until rising_edge(s_waitrequest);
	
	--Reading from the $ location to ensure data written properly
	s_write <= '0';
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"00000022" report "Writing 11 Tag Match Case: Cache not updated properly" severity error;
--=======================================================================================================	
	
	--Test Case 7:
	--Reading "11" Tag Mismatch Case: Reading from memory address C, need to update $ (dirty EVICTION)
	s_addr <= std_logic_vector(to_unsigned(C, 32));
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	--Checking cache properly updated
	assert s_readdata = X"13121110" report "Reading 11 Tag Mismatch Case: Cache not updated properly" severity error;
--=======================================================================================================
	
	--Test Case 8:
	--Checking to ensure dirty EVICTION from test case 7 properly updated MM location
	--Reading "10" Tag Mismatch Case: Reading from memory address A, but tag mismatch on clean block in $ (clean EVICTION)
	s_addr <= std_logic_vector(to_unsigned(A, 32));
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"00000022" report "Reading 10 Tag Mismatch Case: dirty block not updated in MM properly." severity error;
--=======================================================================================================
	
	--Test Case 9:
	--Writing "10" Tag Mismatch Case: Writing to memory address C, but tag mismatch on clean $ block (clean EVICTION)
	s_addr <= std_logic_vector(to_unsigned(C, 32));
	s_writedata <= std_logic_vector(to_unsigned(83, 32));
	s_write <= '1';
	wait until rising_edge(s_waitrequest);
	
	--Reading from the memory location to ensure data written properly
	s_write <= '0';
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"00000053" report "Writing 10 Tag Mismatch Case: Data not updated properly" severity error;
--=======================================================================================================
	
	--Test Case 10:
	--Writing "11" Tag Mismatch Case: Writing to memory address A, but tag mismatch on dirty block (dirty EVICTION)
	s_addr <= std_logic_vector(to_unsigned(A, 32));
	s_writedata <= std_logic_vector(to_unsigned(35, 32));
	s_write <= '1';
	wait until rising_edge(s_waitrequest);
	
	--Reading from the $ location to ensure data written properly
	s_write <= '0';
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"00000023" report "Writing 11 Tag Mismatch Case: Data not updated properly" severity error;
	
	--Checking to ensure dirty EVICTION properly updated MM location
	--Read block C back into cache. If MM properly updated, the read block will be what was saved previously (0x53)
	s_addr <= std_logic_vector(to_unsigned(C, 32));
	s_read <= '1';
	wait until rising_edge(s_waitrequest);
	s_read <= '0';
	assert s_readdata = X"00000053" report "Writing 11 Tag Mismatch Case: MM not properly updated due to dirty EVICTION" severity error;
--=======================================================================================================	
	--end testbench
	wait;
--=======================================================================================================
end process;	
end;
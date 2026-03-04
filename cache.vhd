library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cache is
generic(
	ram_size : INTEGER := 32768; -- Bytes
	cache_size_byte : INTEGER := 512; -- Bytes
	num_of_blocks: INTEGER := 32;
	block_size : INTEGER := 128; -- bits
	
	cache_delay : time := 10 ns;
	clock_period : time := 1 ns

);
port(
	clock : in std_logic;
	reset : in std_logic;
	
	-- Avalon interface --
	--31 downto 16 useless
	--15 downto 9 tag
	--8 downto 4  block index
	--3 downto 2 word offset
	s_addr : in std_logic_vector (31 downto 0);
	s_read : in std_logic;
	s_readdata : out std_logic_vector (31 downto 0);
	s_write : in std_logic;
	s_writedata : in std_logic_vector (31 downto 0);
	s_waitrequest : out std_logic; 
    
    -- Memory 
	m_addr : out integer range 0 to ram_size-1;
	m_read : out std_logic;
	m_readdata : in std_logic_vector (7 downto 0);
	m_write : out std_logic;
	m_writedata : out std_logic_vector (7 downto 0);
	m_waitrequest : in std_logic
);
end cache;

architecture arch of cache is
--(135 = valid)
--(134 = Dirty)
--(133-128 = tag)
--(127-0 = DATA )
--(127-96 byte 3)
--(95-64 byte 2)
--(63-32 byte 1)
--(31-0 byte 0)
--access the below array simply like this cache_block(block #)(line indices)
TYPE CACHE IS ARRAY(num_of_blocks-1 downto 0) OF STD_LOGIC_VECTOR(135 downto 0);
signal cache_block: CACHE; 
signal write_waitreq_reg: STD_LOGIC := '1';
signal read_waitreq_reg: STD_LOGIC := '1';

type state_type is (IDLE,READING,READ_READY,WRITING,MISS,READ_HIT,WRITE_HIT, EVICTION);
signal state: state_type;
signal next_state: state_type;

-- Sub-FSM for moving blocks
type memory_access_state is (
    mem_1, mem_2, mem_3, mem_4, 
    mem_5, mem_6, mem_7, mem_8, 
    mem_9, mem_10, mem_11, mem_12, 
    mem_13, mem_14, mem_15, mem_16
);
signal mem_state: memory_access_state := mem_1;
signal next_mem_state : memory_access_state;

signal block_number: integer range 0 to num_of_blocks-1;
signal Read_NotWrite: std_logic;


begin

-- make circuits here
process (clock, reset)
begin
	if reset = '1' then
		state <= IDLE;
		mem_state <= mem_1;
	elsif (clock'event and clock = '1') then
		state <= next_state;
		mem_state <= next_mem_state;
	end if;
end process;

-- The simulation was not updating the state so I added other triggers
avalon_structure_proc : process (state, reset, s_addr, s_read, s_write, s_writedata,
 m_waitrequest, m_readdata, cache_block, block_number, Read_NotWrite, next_mem_state,
  reset)

begin
-- The simulation was showing U for these signals, adding default values solved this
	next_state <= state;
	next_mem_state <= mem_state;
	m_read <= '0';
	m_write <= '0';
	m_addr <= 0;
	m_writedata <= "00000000";
	s_waitrequest <= '1';
	
	case state is
		when IDLE =>
			s_waitrequest <= '1';
			block_number <= to_integer(unsigned(std_logic_vector'(s_addr(8 downto 4))));
			if s_read = '1' then 
				next_state <= READING;
				Read_NotWrite <= '1';
			elsif s_write = '1' then
				next_state <= WRITING;
				Read_NotWrite <= '0';
			else
				Read_NotWrite <= '-';
				next_state <= IDLE;
			end if;
			
		when READING =>	
			--condition here must be combinational logic between s_addr(31 downto something) and cacheArray(something downto 31 less than something)
			if cache_block(block_number)(135) = '1' and cache_block(block_number)(133 downto 128) = s_addr(14 downto 9) then -- valid plus tag match 
				next_state <= READ_HIT;
			elsif (cache_block(block_number)(135) = '1' and cache_block(block_number)(133 downto 128) /= s_addr(14 downto 9) and cache_block(block_number)(135) = '1') then  --tag mismatch and dirty
				--write to main memory
				next_state <= EVICTION;
				next_mem_state <= mem_1;
			else	
				next_state <= MISS;
				next_mem_state <= mem_1;
			end if;
			
		when READ_HIT =>
			--this state is just reading from cache
			next_state <= READ_READY;
			if s_addr(3 downto 2) = "00" then
				s_readdata <= cache_block(block_number)(31 downto 0);
			elsif s_addr(3 downto 2) = "01" then
				s_readdata <= cache_block(block_number)(63 downto 32);
			elsif s_addr(3 downto 2) = "10" then
				s_readdata <= cache_block(block_number)(95 downto 64);
			elsif s_addr(3 downto 2) = "11" then
				s_readdata <= cache_block(block_number)(127 downto 96);
			end if;
			s_waitrequest <= '0';
			
		when MISS =>
		--within this state there are 16 sub states, these represent stalling
		-- because memory only output bytes and we only write 4 words at a time we must go through all the bytes.
		
			case mem_state is 

				when mem_1 => 
					m_addr <= to_integer(unsigned(std_logic_vector'(s_addr(14 downto 4) & "0000")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_2;
						m_read <= '0';
						cache_block(block_number)(7 downto 0) <= m_readdata;
					else
						next_mem_state <= mem_1;
					end if;

				when mem_2 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "0001")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_3;
						m_read <= '0';
						cache_block(block_number)(15 downto 8) <= m_readdata;
					else
						next_mem_state <= mem_2;
					end if;

				when mem_3 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "0010")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_4;
						m_read <= '0';
						cache_block(block_number)(23 downto 16) <= m_readdata;
					else
						next_mem_state <= mem_3;
					end if;

				when mem_4 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "0011")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_5;
						m_read <= '0';
						cache_block(block_number)(31 downto 24) <= m_readdata;
					else
						next_mem_state <= mem_4;
					end if;

				when mem_5 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "0100")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_6;
						m_read <= '0';
						cache_block(block_number)(39 downto 32) <= m_readdata;
					else
						next_mem_state <= mem_5;
					end if;

				when mem_6 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "0101")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_7;
						m_read <= '0';
						cache_block(block_number)(47 downto 40) <= m_readdata;
					else
						next_mem_state <= mem_6;
					end if;

				when mem_7 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "0110")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_8;
						m_read <= '0';
						cache_block(block_number)(55 downto 48) <= m_readdata;
					else
						next_mem_state <= mem_7;
					end if;

				when mem_8 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "0111")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_9;
						m_read <= '0';
						cache_block(block_number)(63 downto 56) <= m_readdata;
					else
						next_mem_state <= mem_8;
					end if;

				when mem_9 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1000")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_10;
						m_read <= '0';
						cache_block(block_number)(71 downto 64) <= m_readdata;
					else
						next_mem_state <= mem_9;
					end if;

				when mem_10 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1001")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_11;
						m_read <= '0';
						cache_block(block_number)(79 downto 72) <= m_readdata;
					else
						next_mem_state <= mem_10;
					end if;

				when mem_11 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1010")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_12;
						m_read <= '0';
						cache_block(block_number)(87 downto 80) <= m_readdata;
					else
						next_mem_state <= mem_11;
					end if;

				when mem_12 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1011")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_13;
						m_read <= '0';
						cache_block(block_number)(95 downto 88) <= m_readdata;
					else
						next_mem_state <= mem_12;
					end if;

				when mem_13 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1100")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_14;
						m_read <= '0';
						cache_block(block_number)(103 downto 96) <= m_readdata;
					else
						next_mem_state <= mem_13;
					end if;

				when mem_14 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1101")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_15;
						m_read <= '0';
						cache_block(block_number)(111 downto 104) <= m_readdata;
					else
						next_mem_state <= mem_14;
					end if;

				when mem_15 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1110")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_16;
						m_read <= '0';
						cache_block(block_number)(119 downto 112) <= m_readdata;
					else
						next_mem_state <= mem_15;
					end if;

				when mem_16 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( s_addr(14 downto 4) & "1111")));
					m_read <= '1';
					next_state <= MISS;
					if (m_waitrequest = '0') then
						next_mem_state <= mem_1;
	
						m_read <= '0';
						cache_block(block_number)(135 downto 134) <= "10"; 
						cache_block(block_number)(127 downto 120) <= m_readdata;
						
						if (Read_NotWrite = '1') then
							if s_addr(3 downto 2) = "00" then
								s_readdata <= cache_block(block_number)(31 downto 0);
							elsif s_addr(3 downto 2) = "01" then
								s_readdata <= cache_block(block_number)(63 downto 32);
							elsif s_addr(3 downto 2) = "10" then
								s_readdata <= cache_block(block_number)(95 downto 64);
							elsif s_addr(3 downto 2) = "11" then
								s_readdata <= m_readdata & cache_block(block_number)(119 downto 96);
							end if;
							next_state <= READ_READY;
							s_waitrequest <= '0';
						else 
							next_state <= WRITE_HIT;
						end if;
						
					else
						next_mem_state <= mem_16;
					end if;

				when others => 
					next_mem_state <= mem_1;
					next_state <= IDLE;

			end case;			
				
		when READ_READY =>
			--this state is to create a 1 clock cycle buffer to read the read_data
			next_state <= IDLE;

		
		when EVICTION =>
		--in this state we are writing to cache to save a dirty line

			case mem_state is 

				when mem_1 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0000")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(7 downto 0);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_2;
						m_write <= '0';
					else
						next_mem_state <= mem_1;
					end if;

				when mem_2 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0001")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(15 downto 8);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_3;
						m_write <= '0';
					else
						next_mem_state <= mem_2;
					end if;

				when mem_3 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0010")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(23 downto 16);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_4;
						m_write <= '0';
					else
						next_mem_state <= mem_3;
					end if;

				when mem_4 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0011")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(31 downto 24);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_5;
						m_write <= '0';
					else
						next_mem_state <= mem_4;
					end if;

				when mem_5 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0100")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(39 downto 32);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_6;
						m_write <= '0';
					else
						next_mem_state <= mem_5;
					end if;

				when mem_6 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0101")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(47 downto 40);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_7;
						m_write <= '0';
					else
						next_mem_state <= mem_6;
					end if;

				when mem_7 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0110")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(55 downto 48);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_8;
						m_write <= '0';
					else
						next_mem_state <= mem_7;
					end if;

				when mem_8 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "0111")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(63 downto 56);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_9;
						m_write <= '0';
					else
						next_mem_state <= mem_8;
					end if;

				when mem_9 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1000")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(71 downto 64);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_10;
						m_write <= '0';
					else
						next_mem_state <= mem_9;
					end if;

				when mem_10 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1001")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(79 downto 72);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_11;
						m_write <= '0';
					else
						next_mem_state <= mem_10;
					end if;

				when mem_11 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1010")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(87 downto 80);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_12;
						m_write <= '0';
					else
						next_mem_state <= mem_11;
					end if;

				when mem_12 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1011")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(95 downto 88);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_13;
						m_write <= '0';
					else
						next_mem_state <= mem_12;
					end if;

				when mem_13 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1100")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(103 downto 96);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_14;
						m_write <= '0';
					else
						next_mem_state <= mem_13;
					end if;

				when mem_14 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1101")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(111 downto 104);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_15;
						m_write <= '0';
					else
						next_mem_state <= mem_14;
					end if;

				when mem_15 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1110")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(119 downto 112);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_16;
						m_write <= '0';
					else
						next_mem_state <= mem_15;
					end if;

				when mem_16 => 
					m_addr <= to_integer(unsigned(std_logic_vector'( 
							  cache_block(block_number)(133 downto 128) &
							  s_addr(8 downto 4) &
							  "1111")));
					m_write <= '1';
					next_state <= EVICTION;
					m_writedata <= cache_block(block_number)(127 downto 120);
					if (m_waitrequest = '0') then
						next_mem_state <= mem_1;
						
						next_state <= MISS;
						m_write <= '0';
						s_waitrequest <= '0';
						cache_block(block_number)(135) <= '0'; --set dirty to 0
					else
						next_mem_state <= mem_16;
					end if;

				when others =>
					next_mem_state <= mem_1;
					next_state <= IDLE;

			end case;
			
		
		when WRITING =>
			
			if cache_block(block_number)(135) = '1' and cache_block(block_number)(133 downto 128) = s_addr(14 downto 9) then
				next_state <= WRITE_HIT;
			elsif cache_block(block_number)(135) = '1' and cache_block(block_number)(133 downto 128) /= s_addr(14 downto 9) and cache_block(block_number)(135) = '1' then
				next_state <= EVICTION;
			else -- valid = 0,	
				next_state <= MISS;
			end if;
		
		when WRITE_HIT =>
			--write to cache 
			--set dirty bit to 1
			if s_addr(3 downto 2) = "00" then
				cache_block(block_number)(31 downto 0) <= s_writedata;
			elsif s_addr(3 downto 2) = "01" then
				cache_block(block_number)(63 downto 32) <= s_writedata;
			elsif s_addr(3 downto 2) = "10" then
				cache_block(block_number)(95 downto 64) <= s_writedata;
			elsif s_addr(3 downto 2) = "11" then
				cache_block(block_number)(127 downto 96) <= s_writedata;
			end if;
			cache_block(block_number)(135) <= '1';
			
	end case;
end process avalon_structure_proc;


end arch;

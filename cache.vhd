library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cache is
generic(
    ram_size : INTEGER := 32768; -- Bytes
    cache_size_byte : INTEGER := 512; -- Bytes
    num_of_blocks: INTEGER := 32;
    block_size : INTEGER := 128 -- bits
);
port(
    clock : in std_logic;
    reset : in std_logic;
    
    -- Avalon interface --
    --31 downto 15 useless
    --14 downto 9 tag
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
TYPE CACHE IS ARRAY(num_of_blocks-1 downto 0) OF STD_LOGIC_VECTOR(135 downto 0);
signal cache_block: CACHE; 
signal next_cache_block: CACHE;

--All signals that needed to be clocked are now clocked. Our issues were coming from premature updating 
--Due to all of our signals being combinational rather than acting like registers

type state_type is (IDLE,READING,READ_READY,WRITING,MISS,READ_HIT,WRITE_HIT, WRITE_READY, EVICTION);
signal state: state_type := IDLE;
signal next_state: state_type := IDLE;

--Denotes which of the 32 blocks we are working with
signal block_number: integer range 0 to num_of_blocks-1 := 0;
signal next_block_number: integer range 0 to num_of_blocks-1 := 0;

--Specificially for EVICTION and MISS policies: Only move the data to the s_readdata bus when we are reading
signal Read_NotWrite: std_logic := '-' ;
signal next_Read_NotWrite: std_logic := '-';

--For misses: Calculate a base address we can use with a suitable offset (byte_counter) to read from
signal base_addr  : integer range 0 to ram_size-1 := 0;
signal next_base_addr : integer range 0 to ram_size-1 := 0;

--For evictions: Calculate a base address we can use with a suitable offset (byte_counter) to write to
signal evict_addr : integer range 0 to ram_size-1 := 0;
signal next_evict_addr : integer range 0 to ram_size-1 := 0;

signal latched_addr : std_logic_vector(31 downto 0) := (others => '0');
signal next_latched_addr : std_logic_vector(31 downto 0) := (others => '0');

--Offset for the evition and base addrs
signal byte_counter      : integer range 0 to 15 := 0;
signal next_byte_counter : integer range 0 to 15 := 0;
begin

--Clocked process. On reset, all signals go back to default values. Data in cache becomes invalid and clean
--For future: perhaps we should run through all blocks and if they are dirty we can write to MM to save changes
process (clock, reset)
begin
    if reset = '1' then
        state <= IDLE;
        byte_counter <= 0;
        block_number <= 0;
        base_addr <= 0;
        evict_addr <= 0;
        Read_NotWrite <= '-';
        latched_addr <= (others => '0');

        for i in 0 to num_of_blocks-1 loop
            cache_block(i)(135) <= '0'; -- valid bit
            cache_block(i)(134) <= '0'; -- dirty bit
        end loop;
         
    elsif rising_edge(clock) then
        state <= next_state;
        byte_counter <= next_byte_counter;
        block_number <= next_block_number;
        base_addr <= next_base_addr;
        evict_addr <= next_evict_addr;
        Read_NotWrite <= next_Read_NotWrite;
        cache_block <= next_cache_block;
        latched_addr <= next_latched_addr;
    end if;
end process;

--FSM Logic
avalon_structure_proc : process (state, s_addr, cache_block, byte_counter, m_waitrequest, Read_NotWrite, block_number, base_addr, evict_addr, latched_addr)
begin
    -- Default values
    m_read <= '0';
    m_write <= '0';
    m_addr <= 0;
    m_writedata <= "00000000";
    s_waitrequest <= '1';
	 
	 --Note: This line causes the readdata to ONLY BE AVAILABLE FOR THE ONE CC THAT THE WAITREQUEST PULSES LOW
	 --For the grader's sake, or anyone reading this, if this line were to be removed, the readdata signal would be valid longer than the designated CC
	 --Another note: For our testbench, we wait for the falling edge of the wait request to so that we can read the data in the low CC of waitrequest 
	 --Allows us to assert that the data is correct for the given read request :)
    s_readdata <= (others => '0');
    
    -- Default next-state values (no change unless explicitly assigned at a state's combinational logic level)
    next_state <= state;
    next_byte_counter <= byte_counter;
    next_block_number <= block_number;
    next_base_addr <= base_addr;
    next_evict_addr <= evict_addr;
    next_Read_NotWrite <= Read_NotWrite;
    next_cache_block <= cache_block;
    next_latched_addr <= latched_addr;
    
    case state is
		--IDLE case: Wait for reads or writes	
        when IDLE =>
            s_waitrequest <= '1';
            next_block_number <= to_integer(unsigned(std_logic_vector'(s_addr(8 downto 4))));
            next_latched_addr <= s_addr;
            if s_read = '1' then 
                next_state <= READING;
                next_Read_NotWrite <= '1';
            elsif s_write = '1' then
                next_state <= WRITING;
                next_Read_NotWrite <= '0';
            else
                next_Read_NotWrite <= '-';
                next_state <= IDLE;
            end if;

        --READING case: Check if we can read. If so, go READ HIT. If not, deduce whether its an EVICTION or MISS.    
        when READING =>	
            if cache_block(block_number)(135) = '1' and 
            cache_block(block_number)(133 downto 128) = latched_addr(14 downto 9) then
                next_state <= READ_HIT;
                
            elsif (cache_block(block_number)(135) = '1' and
            cache_block(block_number)(133 downto 128) /= latched_addr(14 downto 9) and
            cache_block(block_number)(134) = '1') then
                next_state <= EVICTION;
                next_base_addr <= to_integer(unsigned(latched_addr(14 downto 4))) * 16;
                next_evict_addr <= to_integer(unsigned(std_logic_vector'(cache_block(block_number)(133 downto 128) & latched_addr(8 downto 4)))) * 16;
            else	
                next_state <= MISS;
                next_base_addr <= to_integer(unsigned(latched_addr(14 downto 4))) * 16;
            end if;

		--READ_HIT case: Return the desired block to the CPU    
        when READ_HIT =>
            next_state <= READ_READY;
            if latched_addr(3 downto 2) = "00" then
                s_readdata <= cache_block(block_number)(31 downto 0);
            elsif latched_addr(3 downto 2) = "01" then
                s_readdata <= cache_block(block_number)(63 downto 32);
            elsif latched_addr(3 downto 2) = "10" then
                s_readdata <= cache_block(block_number)(95 downto 64);
            elsif latched_addr(3 downto 2) = "11" then
                s_readdata <= cache_block(block_number)(127 downto 96);
            end if;
            s_waitrequest <= '0';

		--MISS: Loop through 16 bytes of the block and read from MM to update the $  
        when MISS =>
            m_addr <= base_addr + byte_counter;
            m_read <= '1';
            if (m_waitrequest = '0') then
				m_read <= '0';
                next_cache_block(block_number)(byte_counter * 8 + 7 downto byte_counter * 8) <= m_readdata;
                
                if (byte_counter = 15) then
                    next_byte_counter <= 0;
                    next_cache_block(block_number)(135) <= '1';
                    next_cache_block(block_number)(134) <= '0';
                    next_cache_block(block_number)(133 downto 128) <= latched_addr(14 downto 9);
                    
                    if (Read_NotWrite = '1') then
                        if latched_addr(3 downto 2) = "00" then
                            s_readdata <= next_cache_block(block_number)(31 downto 0);
                        elsif latched_addr(3 downto 2) = "01" then
                            s_readdata <= next_cache_block(block_number)(63 downto 32);
                        elsif latched_addr(3 downto 2) = "10" then
                            s_readdata <= next_cache_block(block_number)(95 downto 64);
                        elsif latched_addr(3 downto 2) = "11" then
                            s_readdata <= next_cache_block(block_number)(127 downto 96);
                        end if;
                        next_state <= READ_READY;
                        s_waitrequest <= '0';
                    else 
                        next_state <= WRITE_HIT;
                    end if;
                else
                    next_byte_counter <= byte_counter + 1;
                    next_state <= MISS;
                end if;
            end if;
        
		--READ_READY case: Just here for the 1 CC delay necessary in the avalon interface
        when READ_READY =>
            next_state <= IDLE;
        
		--WRITE_READY case: Just here for the 1 CC delay necessary in the avalon interface
        when WRITE_READY =>
            next_state <= IDLE;
        
		--EVICTION case: Loop through 16 bytes of the block and write to MM. Go to MISS state to refill this $ block.
        when EVICTION =>
            m_addr <= evict_addr + byte_counter;
            m_writedata <= cache_block(block_number)(byte_counter * 8 + 7 downto byte_counter * 8);
            m_write <= '1';
            
            if (m_waitrequest = '0') then
				m_write <= '0';
                if (byte_counter = 15) then
                    next_byte_counter <= 0;
                    next_state <= MISS;
                    next_cache_block(block_number)(134) <= '0';
                    next_cache_block(block_number)(133 downto 128) <= latched_addr(14 downto 9);
                else
                    next_byte_counter <= byte_counter + 1;
                    next_state <= EVICTION;
                end if;
            end if;

		--WRITING case: Check if we can write to cache location. If so, go to WRITE_HIT. If not, determine whether MISS or EVICTION.  
        when WRITING =>
            if cache_block(block_number)(135) = '1' and 
            cache_block(block_number)(133 downto 128) = latched_addr(14 downto 9) then
                next_state <= WRITE_HIT;
                
            elsif cache_block(block_number)(135) = '1' and 
            cache_block(block_number)(133 downto 128) /= latched_addr(14 downto 9) and
            cache_block(block_number)(134) = '1' then
                next_state <= EVICTION;
                next_base_addr <= to_integer(unsigned(latched_addr(14 downto 4))) * 16;
                next_evict_addr <= to_integer(unsigned(std_logic_vector'(cache_block(block_number)(133 downto 128) & latched_addr(8 downto 4)))) * 16;
            else
                next_state <= MISS;
                next_base_addr <= to_integer(unsigned(latched_addr(14 downto 4))) * 16;
            end if;

		--WRITE_HIT case: Write to desired cache location.  
        when WRITE_HIT =>
            next_state <= WRITE_READY;
            if latched_addr(3 downto 2) = "00" then
                next_cache_block(block_number)(31 downto 0) <= s_writedata;
            elsif latched_addr(3 downto 2) = "01" then
                next_cache_block(block_number)(63 downto 32) <= s_writedata;
            elsif latched_addr(3 downto 2) = "10" then
                next_cache_block(block_number)(95 downto 64) <= s_writedata;
            elsif latched_addr(3 downto 2) = "11" then
                next_cache_block(block_number)(127 downto 96) <= s_writedata;
            end if;
            next_cache_block(block_number)(134) <= '1'; --Update dirty bit
            s_waitrequest <= '0';
    end case;
end process avalon_structure_proc;

end arch;
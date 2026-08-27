library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_t80_firmware is
	generic (ROM_HEX : string := "epr-14084.hex");
end;

architecture sim of tb_t80_firmware is
	type rom_t is array (0 to 32767) of std_logic_vector(7 downto 0);
	type ram_t is array (natural range <>) of std_logic_vector(7 downto 0);
	impure function load_rom(path : string) return rom_t is
		file f : text open read_mode is path;
		variable l : line; variable v : std_logic_vector(7 downto 0);
		variable r : rom_t := (others => x"FF"); variable i : natural := 0;
	begin
		while not endfile(f) loop
			readline(f, l); hread(l, v);
			if i <= r'high then r(i) := v; end if;
			i := i + 1;
		end loop;
		assert i = r'length report "EPR-14084 ROM image must contain 32768 bytes" severity failure;
		return r;
	end;
	signal rom : rom_t := load_rom(ROM_HEX);
	signal private_ram : ram_t(0 to 8191) := (others => x"00");
	signal shared_ram : ram_t(0 to 2047) := (others => x"00");
	signal clk : std_logic := '0'; signal reset_n : std_logic := '0';
	signal m1_n,mreq_n,iorq_n,rd_n,wr_n : std_logic;
	signal a : std_logic_vector(15 downto 0); signal di,dout : std_logic_vector(7 downto 0);
begin
	clk <= not clk after 5 ns;
	dut: entity work.T80s port map(RESET_n=>reset_n,CLK=>clk,CEN=>'1',WAIT_n=>'1',INT_n=>'1',NMI_n=>'1',BUSRQ_n=>'1',
		M1_n=>m1_n,MREQ_n=>mreq_n,IORQ_n=>iorq_n,RD_n=>rd_n,WR_n=>wr_n,RFSH_n=>open,HALT_n=>open,BUSAK_n=>open,
		OUT0=>'0',A=>a,DI=>di,DO=>dout,REG=>open,DIRSet=>'0',DIR=>(others=>'0'),ISet_out=>open);

	process(all) variable ai : natural; begin
		ai := to_integer(unsigned(a)); di <= x"FF";
		if mreq_n='0' and rd_n='0' then
			if ai < 16#8000# then di <= rom(ai);
			elsif ai < 16#A000# then di <= private_ram(ai-16#8000#);
			elsif ai >= 16#C000# and ai < 16#C800# then di <= shared_ram(ai-16#C000#);
			end if;
		end if;
	end process;

	process(clk) variable ai : natural; begin
		if rising_edge(clk) then
			ai := to_integer(unsigned(a));
			if mreq_n='0' and wr_n='0' then
				if ai >= 16#8000# and ai < 16#A000# then private_ram(ai-16#8000#) <= dout;
				elsif ai >= 16#C000# and ai < 16#C800# then shared_ram(ai-16#C000#) <= dout;
				end if;
			end if;
			if iorq_n='0' and m1_n='1' and (rd_n='0' or wr_n='0') then
				assert ai mod 256 = 16#60# and wr_n='0' and dout=x"00"
					report "unexpected first EPR-14084 IO transaction" severity failure;
				report "PASS EPR-14084 first unresolved IO port=" & integer'image(ai mod 256) &
					" write=" & boolean'image(wr_n='0') & " data=" & integer'image(to_integer(unsigned(dout))) severity note;
				std.env.stop;
			end if;
		end if;
	end process;
	process begin reset_n <= '0'; wait for 80 ns; reset_n <= '1'; wait for 5 ms;
		assert false report "EPR-14084 firmware did not reach an IO transaction" severity failure;
	end process;
end;

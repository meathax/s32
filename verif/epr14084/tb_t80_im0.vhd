library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_t80_im0 is end;
architecture sim of tb_t80_im0 is
	signal clk : std_logic := '0'; signal reset_n : std_logic := '0';
	signal int_n : std_logic := '1'; signal m1_n,mreq_n,iorq_n,rd_n,wr_n,halt_n : std_logic;
	signal a : std_logic_vector(15 downto 0); signal di,dout : std_logic_vector(7 downto 0);
	signal saw_ack : boolean := false;
begin
	clk <= not clk after 5 ns;
	di <= x"CF" when iorq_n='0' and m1_n='0' else
		x"FB" when a=x"0000" else x"00" when a=x"0001" else x"76" when a=x"0002" else x"00";
	dut: entity work.T80s port map(RESET_n=>reset_n,CLK=>clk,CEN=>'1',WAIT_n=>'1',INT_n=>int_n,NMI_n=>'1',BUSRQ_n=>'1',
		M1_n=>m1_n,MREQ_n=>mreq_n,IORQ_n=>iorq_n,RD_n=>rd_n,WR_n=>wr_n,RFSH_n=>open,HALT_n=>halt_n,BUSAK_n=>open,
		OUT0=>'0',A=>a,DI=>di,DO=>dout,REG=>open,DIRSet=>'0',DIR=>(others=>'0'),ISet_out=>open);
	process(clk) begin if rising_edge(clk) then
		if iorq_n='0' and m1_n='0' then saw_ack <= true; end if;
		if saw_ack and mreq_n='0' and rd_n='0' and a=x"0008" then
			report "PASS T80 IM0 external opcode" severity note; std.env.stop;
		end if;
	end if; end process;
	process begin wait for 40 ns; reset_n<='1'; wait until halt_n='0'; int_n<='0'; wait for 10 us; assert false report "T80 IM0 timeout" severity failure; end process;
end;

`timescale 1ns/1ps
module tb_bus;
	reg clk=0, reset=1; always #5 clk=!clk;
	reg [15:0] a; reg [7:0] dout; wire [7:0] din; reg mn=1,in_=1,rn=1,wn=1,m1=1;
	reg rwe=0; reg [14:0] ra; reg [7:0] rd;
	reg he=0,hw=0; reg [9:0] ha; reg [1:0] hb=0; reg [15:0] hd; wire [15:0] hr;
	reg cn=0,fg=0,zfg=0,ack=0; reg [7:0] iod=0; wire waitn,req,iw,dma,dlc,unk; wire [7:0] ia,io;
	epr14084_bus d(.clk(clk),.reset(reset),.cpu_addr(a),.cpu_dout(dout),.cpu_din(din),
	.cpu_mreq_n(mn),.cpu_iorq_n(in_),.cpu_rd_n(rn),.cpu_wr_n(wn),.cpu_m1_n(m1),.cpu_wait_n(waitn),
	.rom_we(rwe),.rom_addr(ra),.rom_data(rd),.host_en(he),.host_we(hw),.host_addr(ha),.host_be(hb),.host_wdata(hd),.host_rdata(hr),
	.cn(cn),.fg(fg),.zfg(zfg),.io_req(req),.io_write(iw),.io_addr(ia),.io_wdata(io),.io_ack(ack),.io_rdata(iod),
	.io_dma_window(dma),.io_dlc_window(dlc),.io_unknown_latch(unk));
	task mw(input[15:0] x,input[7:0] v); begin a=x;dout=v;mn=0;wn=0; @(posedge clk); #1; mn=1;wn=1; end endtask
	task mr(input[15:0] x,input[7:0] v); begin a=x;mn=0;rn=0;#1;if(din!==v)$fatal;mn=1;rn=1;end endtask
	initial begin
		#12; reset=0; ra=3;rd=8'hc3;rwe=1;@(posedge clk);#1;rwe=0;mr(16'h0003,8'hc3);
		mw(16'h8123,8'h5a);mr(16'h8123,8'h5a); mw(16'hc320,8'h11);mw(16'hc321,8'ha6);
		ha=10'h190;he=1;@(posedge clk);#1;if(hr!==16'ha611)$fatal;
		hd=16'h3c72;hb=2'b01;hw=1;@(posedge clk);#1;hw=0;he=0;mr(16'hc320,8'h72);mr(16'hc321,8'ha6);
		he=1;hw=1;hb=2'b10;@(posedge clk);#1;hw=0;he=0;mr(16'hc320,8'h72);mr(16'hc321,8'h3c);
		in_=0;rn=0;a=16'h0024;#1;if(!req||!dlc||waitn)$fatal;ack=1;iod=8'h77;#1;if(!waitn||din!=8'h77)$fatal;
		a=16'h0017;#1;if(!unk)$fatal; in_=1;rn=1;ack=0;
		// IM0 interrupt acknowledge is externally acknowledged and supplies DI.
		in_=0;m1=0;iod=8'hcf;#1;if(waitn||din!=8'hcf)$fatal;ack=1;#1;if(!waitn)$fatal;in_=1;m1=1;
		$display("PASS epr14084 bus");$finish;
	end
endmodule

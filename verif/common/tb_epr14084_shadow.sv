`timescale 1ns/1ps
module tb_epr14084_shadow;
reg clk=0,rst=1;always #5 clk=~clk;
wire first;wire[7:0]data;
s32_epr14084_shadow #(.ENABLE_NATIVE_SHADOW(1'b1)) dut(.clk(clk),.rst(rst),.ce(1'b1),
 .rom_we(1'b0),.rom_addr(15'b0),.rom_data(8'b0),.host_en(1'b0),.host_we(1'b0),.host_addr(10'b0),.host_be(2'b0),.host_wdata(16'b0),.host_rdata(),
 .cn(1'b0),.fg(1'b0),.zfg(1'b0),.io_req(),.io_write(),.io_addr(),.io_wdata(),.io_ack(1'b0),.io_rdata(8'b0),.int_n(1'b1),
 .dma_window(),.dlc_window(),.unknown_latch(),.authoritative_host_rdata(16'b0),.ram_diverged(),
 .first_out60(first),.first_out60_data(data));
initial begin repeat(3)@(posedge clk);rst=0;
 force dut.io_req=1;force dut.io_write=1;force dut.io_addr=8'h60;force dut.io_wdata=8'h00;
 @(posedge clk);#1;if(!first||data!==0)$fatal(1,"first OUT60 barrier missing");
 force dut.io_wdata=8'hff;@(posedge clk);#1;if(data!==0)$fatal(1,"first OUT60 barrier overwritten");
 $display("EPR14084 SHADOW PASS");$finish;end
endmodule

`timescale 1ns/1ps
module tb_darkedge_hle;
import s32_pkg::*;
reg clk=0,rst=1,vblank=0;
always #5 clk=~clk;
wire req,we; wire [15:0] addr,wdata; wire [1:0] be;
wire ack=req;
wire [15:0] rdata=(addr==(16'hA12C>>1))?16'h0001:16'h0000;
integer step=0,errors=0;
s32_prot_darkedge dut(.clk(clk),.rst(rst),.enable(1'b1),.vblank(vblank),
 .wram_req(req),.wram_we(we),.wram_addr(addr),.wram_wdata(wdata),
 .wram_be(be),.wram_rdata(rdata),.wram_ack(ack));
task check(input ok); if(!ok) begin errors=errors+1;$display("FAIL step=%0d addr=%04x we=%b data=%04x be=%b",step,addr,we,wdata,be);end endtask
always @(negedge clk) if(!rst&&req) begin
 case(step)
  0:check(we&&addr==(16'hF072>>1)&&wdata==0&&be==2'b11);
  1:check(we&&addr==(16'hF082>>1)&&wdata==0&&be==2'b11);
  2:check(!we&&addr==(16'hA12C>>1));
  3:check(we&&addr==(16'hA12C>>1)&&wdata==0&&be==2'b01);
  4:check(we&&addr==(16'hA12E>>1)&&wdata==1&&be==2'b01);
  default:begin errors=errors+1;$display("FAIL extra request");end
 endcase
 step=step+1;
end
initial begin repeat(3)@(negedge clk);rst=0;@(negedge clk);vblank=1;@(negedge clk);vblank=0;repeat(10)@(negedge clk);
 if(step!=5||errors)$fatal(1,"Dark Edge HLE failed steps=%0d errors=%0d",step,errors);
 $display("DARK EDGE HLE PASS");$finish;end
endmodule

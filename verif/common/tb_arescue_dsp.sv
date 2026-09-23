// Directed test for the documented Air Rescue uPD7725 register HLE.
module tb_arescue_dsp;

logic clk = 1'b0;
logic rst = 1'b1;
logic enable = 1'b1;
logic cpu_rd = 1'b0;
logic cpu_wr = 1'b0;
logic [1:0] addr = 2'd0;
logic [15:0] wdata = 16'h0000;
logic [1:0] be = 2'b00;
wire [15:0] rdata;

always #5 clk = ~clk;

s32_prot_arescue_dsp dut (
    .clk(clk), .rst(rst), .enable(enable),
    .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .addr(addr),
    .wdata(wdata), .be(be), .rdata(rdata)
);

initial begin
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst <= 1'b0;

    // Seed io2 and verify MAME COMBINE_DATA byte-lane behavior.  MAME's
    // command scratch register is io1 (the source expression is [2/2]); io2
    // remains an independent returned word.
    @(negedge clk);
    addr <= 2'd2; wdata <= 16'h1234; be <= 2'b11; cpu_wr <= 1'b1;
    @(negedge clk);
    cpu_wr <= 1'b0;
    @(negedge clk);
    addr <= 2'd2; wdata <= 16'h00aa; be <= 2'b01; cpu_wr <= 1'b1;
    @(negedge clk);
    cpu_wr <= 1'b0;
    @(negedge clk);
    addr <= 2'd2; cpu_rd <= 1'b1;
    @(posedge clk);
    #1;
    if (rdata != 16'h12aa)
        $fatal(1, "initial low-byte combine returned %04x, expected 12aa", rdata);
    @(negedge clk);
    cpu_rd <= 1'b0;

    // Issue MAME command 3 through io0.
    @(negedge clk);
    addr <= 2'd0; wdata <= 16'h0003; be <= 2'b11; cpu_wr <= 1'b1;
    @(negedge clk);
    cpu_wr <= 1'b0;

    // Offset 2 command 3 sets io0=0x8000 and io1=1; the returned offset-2
    // word is the unchanged io2 value.
    addr <= 2'd2; cpu_rd <= 1'b1;
    @(posedge clk);
    #1;
    if (rdata != 16'h12aa)
        $fatal(1, "command 3 returned %04x, expected 12aa", rdata);
    @(negedge clk);
    cpu_rd <= 1'b0;

    // Verify the command status; the command itself overwrites io2 with one.
    @(negedge clk);
    addr <= 2'd0; cpu_rd <= 1'b1;
    @(posedge clk);
    #1;
    if (rdata != 16'h8000)
        $fatal(1, "command 3 status %04x, expected 8000", rdata);
    @(negedge clk);
    cpu_rd <= 1'b0;

    @(negedge clk);
    addr <= 2'd1; cpu_rd <= 1'b1;
    @(posedge clk);
    #1;
    if (rdata != 16'h0001)
        $fatal(1, "command 3 scratch %04x, expected 0001", rdata);
    @(negedge clk);
    cpu_rd <= 1'b0;

    // Command 6 computes io0=4*io1 but returns io2.
    @(negedge clk);
    addr <= 2'd1; wdata <= 16'h0007; be <= 2'b11; cpu_wr <= 1'b1;
    @(negedge clk);
    cpu_wr <= 1'b0;
    @(negedge clk);
    addr <= 2'd0; wdata <= 16'h0006; be <= 2'b11; cpu_wr <= 1'b1;
    @(negedge clk);
    cpu_wr <= 1'b0;
    @(negedge clk);
    addr <= 2'd2; cpu_rd <= 1'b1;
    @(posedge clk);
    #1;
    if (rdata != 16'h12aa)
        $fatal(1, "command 6 returned %04x, expected 12aa", rdata);
    @(negedge clk);
    cpu_rd <= 1'b0;

    @(negedge clk);
    addr <= 2'd0; cpu_rd <= 1'b1;
    @(posedge clk);
    #1;
    if (rdata != 16'h001c)
        $fatal(1, "command 6 status %04x, expected 001c", rdata);
    @(negedge clk);
    cpu_rd <= 1'b0;

    // Offset 3 is the fourth word in MAME's 0xa00000-0xa00007 map.
    @(negedge clk);
    addr <= 2'd3; wdata <= 16'h55aa; be <= 2'b11; cpu_wr <= 1'b1;
    @(negedge clk);
    cpu_wr <= 1'b0;
    @(negedge clk);
    addr <= 2'd3; cpu_rd <= 1'b1;
    @(posedge clk);
    #1;
    if (rdata != 16'h55aa)
        $fatal(1, "offset 3 returned %04x, expected 55aa", rdata);
    @(negedge clk);
    cpu_rd <= 1'b0;

    $display("Air Rescue DSP HLE PASS");
    $finish;
end

endmodule

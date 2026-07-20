`timescale 1ns/1ps

module tb_video_mode;
reg clk = 1'b0;
reg rst = 1'b1;
reg mode_416 = 1'b1;
always #5 clk = ~clk;

wire ce_pix, mode_active;
wire [8:0] hcnt, vcnt;
wire hb, vb, hs, vs, vb_start, vb_end;

s32_video dut (
    .clk(clk), .rst(rst), .mode_416(mode_416),
    .ce_pix(ce_pix), .mode_active(mode_active),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(hb), .vblank(vb),
    .hsync(hs), .vsync(vs), .vblank_start(vb_start), .vblank_end(vb_end)
);

integer errors = 0;
integer cycles = 0;
reg saw_416_end = 1'b0;
reg saw_320_end = 1'b0;

always @(posedge clk) begin
    cycles <= cycles + 1;
    if (ce_pix && hcnt == 9'd511) saw_416_end <= 1'b1;
    if (ce_pix && hcnt == 9'd409) saw_320_end <= 1'b1;
end

initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
    wait (vcnt == 9'd3 && hcnt == 9'd100);
    mode_416 = 1'b0;
    repeat (200) @(posedge clk);
    if (mode_active !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL width changed within a live frame");
    end
    wait (mode_active == 1'b0);
    wait (vcnt == 9'd3 && hcnt == 9'd100);
    mode_416 = 1'b1;
    repeat (200) @(posedge clk);
    if (mode_active !== 1'b0) begin
        errors = errors + 1;
        $display("  FAIL 320 width changed within a live frame");
    end
    wait (mode_active == 1'b1);
    if (!saw_416_end || !saw_320_end) begin
        errors = errors + 1;
        $display("  FAIL missing complete-width line endpoints 416=%0d 320=%0d",
                 saw_416_end, saw_320_end);
    end
    if (errors == 0) $display("VIDEO MODE LATCH PASS");
    else             $display("VIDEO MODE LATCH FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #30000000;
    $display("VIDEO MODE LATCH FAIL (timeout)");
    $finish;
end
endmodule

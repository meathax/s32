//============================================================================
// Focused test: synthesis-friendly shared sprite scale divider.
// Checks result equality against the simulator's unsigned division operator
// and enforces the fixed 40-clock two-axis latency.
//============================================================================
`timescale 1ns/1ps

module tb_sprite_div;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;
reg start = 0;
reg [19:0] ynum = 0, xnum = 0;
reg  [9:0] yden = 1, xden = 1;
wire busy, done;
wire [19:0] yquot, xquot;

s32_sprite_scale_div dut (
    .clk(clk), .rst(rst), .start(start),
    .ynum(ynum), .yden(yden), .xnum(xnum), .xden(xden),
    .busy(busy), .done(done), .yquot(yquot), .xquot(xquot)
);

integer errors = 0;
integer tests = 0;
integer seed = 32'h5386a032;
integer cycles;
reg [19:0] want_y, want_x;

task run_pair(
    input [19:0] yn,
    input  [9:0] yd,
    input [19:0] xn,
    input  [9:0] xd
);
begin
    want_y = yn / yd;
    want_x = xn / xd;
    @(negedge clk);
    ynum = yn; yden = yd;
    xnum = xn; xden = xd;
    start = 1'b1;
    @(posedge clk); #1;
    @(negedge clk); start = 1'b0;

    cycles = 0;
    while (!done && cycles < 45) begin
        @(posedge clk); #1;
        cycles = cycles + 1;
    end
    tests = tests + 1;
    if (cycles != 40) begin
        errors = errors + 1;
        $display("  FAIL latency=%0d want=40 yn=%0d/%0d xn=%0d/%0d",
                 cycles, yn, yd, xn, xd);
    end
    if (yquot !== want_y || xquot !== want_x) begin
        errors = errors + 1;
        $display("  FAIL result y=%0d want=%0d x=%0d want=%0d",
                 yquot, want_y, xquot, want_x);
    end
    if (busy !== 1'b0 || done !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL completion busy=%b done=%b", busy, done);
    end
end
endtask

integer i;
reg [7:0] srch;
reg [5:0] srcw;
reg [9:0] dh, dw;
initial begin
    repeat (4) @(posedge clk);
    rst = 0;

    // Directed limits, exact divisions, and truncating divisions.
    run_pair(20'd1024,   10'd1,    20'd8192,   10'd8);
    run_pair(20'd261120, 10'd1,    20'd516096, 10'd1);
    run_pair(20'd261120, 10'd1023, 20'd516096, 10'd1023);
    run_pair(20'd7168,   10'd13,   20'd19456,  10'd37);
    run_pair(20'd255000, 10'd511,  20'd503000, 10'd997);

    // Cover every legal destination divisor while cycling through all legal
    // source-height/width fields and both 4/8-bpp horizontal numerators.
    for (i = 1; i <= 1023; i = i + 1) begin
        srch = ((i - 1) % 255) + 1;
        srcw = ((i - 1) % 63) + 1;
        dh = i[9:0];
        dw = (1024 - i);
        run_pair({2'b0, srch, 10'b0}, dh,
                 i[0] ? {2'b0, srcw, 12'b0} : {1'b0, srcw, 13'b0}, dw);
    end

    // Deterministic constrained-random coverage over the same legal domains.
    for (i = 0; i < 1024; i = i + 1) begin
        srch = ($unsigned($random(seed)) % 255) + 1;
        srcw = ($unsigned($random(seed)) % 63) + 1;
        dh = ($unsigned($random(seed)) % 1023) + 1;
        dw = ($unsigned($random(seed)) % 1023) + 1;
        run_pair({2'b0, srch, 10'b0}, dh,
                 i[0] ? {2'b0, srcw, 12'b0} : {1'b0, srcw, 13'b0}, dw);
    end

    if (errors == 0) $display("SPRITE DIV PASS (%0d pairs)", tests);
    else             $display("SPRITE DIV FAIL (%0d errors, %0d pairs)", errors, tests);
    $finish;
end

initial begin
    #2000000;
    $display("SPRITE DIV FAIL (timeout)");
    $finish;
end

endmodule

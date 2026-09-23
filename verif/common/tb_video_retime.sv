// Self-checking TB for s32_video_retime (direct-video uniform-CE output).
// Replicates the s32_video.sv fractional CE generator (clk_sys domain,
// emulated on every 2nd clk_ram edge) and checks:
//   1. output CE spacing is exactly 15 clk_ram (320 mode) / 12 (416 mode),
//      i.e. the 8/7-alternating source jitter is fully removed
//   2. no source pixel is duplicated or dropped (rgb carries a pixel index)
//   3. behaviour holds across HSync grid re-anchoring for > 3 full lines
`timescale 1ns/1ps
module tb_video_retime;

reg clk;
always #5 clk = ~clk;      // "clk_ram"
reg half;                  // half==1 edge emulates a clk_sys posedge

reg mode_416;
reg rst;

// ---- source model (clk_sys domain, mirrors s32_video.sv) ----
reg  [7:0]  ce_acc;
reg         ce_pix;
wire [7:0]  ce_add = mode_416 ? 8'd40 : 8'd32;
reg  [8:0]  hcnt;
wire [8:0]  htotal = mode_416 ? 9'd511 : 9'd409;
wire [8:0]  hdisp  = mode_416 ? 9'd415 : 9'd319;
reg  [23:0] pix_idx;
reg         hs;
reg  [23:0] rgb;
reg         de;

always @(posedge clk) begin
    half <= ~half;
    if (half) begin // emulated clk_sys posedge
        logic [8:0] s;
        s = ce_acc + ce_add;
        ce_pix <= (s >= 9'd240);
        ce_acc <= (s >= 9'd240) ? (s[7:0] - 8'd240) : s[7:0];
        if (ce_pix) begin
            pix_idx <= pix_idx + 1'd1;
            rgb     <= pix_idx + 1'd1;
            if (hcnt == htotal) hcnt <= 0;
            else hcnt <= hcnt + 1'd1;
            hs <= (hcnt >= hdisp + 9'd24) && (hcnt < hdisp + 9'd56);
            de <= (hcnt < hdisp);
        end
        if (rst) begin
            ce_acc <= 0; ce_pix <= 0; hcnt <= 0; pix_idx <= 0;
            rgb <= 0; hs <= 0; de <= 0;
        end
    end
end

// ---- DUT ----
wire        o_ce, o_hs, o_vs, o_de;
wire [23:0] o_rgb;
s32_video_retime dut (
    .clk(clk), .rst(rst), .mode_416(mode_416), .bypass(1'b0),
    .raw_ce(ce_pix), .raw_rgb(rgb), .raw_hs(hs), .raw_vs(1'b0), .raw_de(de),
    .ce(o_ce), .rgb(o_rgb), .hs(o_hs), .vs(o_vs), .de(o_de)
);

// The CRT Adjust branch deliberately keeps its fractional read cadence.  The
// bypass instance must still emit exactly one settled sample per source tick;
// unlike the normal instance, its CE spacing is intentionally non-uniform.
wire        b_ce, b_hs, b_vs, b_de;
wire [23:0] b_rgb;
s32_video_retime dut_bypass (
    .clk(clk), .rst(rst), .mode_416(mode_416), .bypass(1'b1),
    .raw_ce(ce_pix), .raw_rgb(rgb), .raw_hs(hs), .raw_vs(1'b0), .raw_de(de),
    .ce(b_ce), .rgb(b_rgb), .hs(b_hs), .vs(b_vs), .de(b_de)
);

// ---- checkers ----
integer spacing;
integer last_val;
integer errors;
integer ticks;
integer settle;
integer bypass_last_val;
integer bypass_ticks;
wire [3:0] exp_period = mode_416 ? 4'd12 : 4'd15;

always @(posedge clk) begin
    spacing <= spacing + 1;
    if (o_ce) begin
        ticks <= ticks + 1;
        if (settle > 2 && ticks > 4) begin
            // spacing resets to 0 on the tick cycle, so it reads period-1
            if (spacing != {28'd0, exp_period} - 1) begin
                errors <= errors + 1;
                $display("FAIL: mode_416=%0d spacing %0d != %0d at tick %0d",
                         mode_416, spacing + 1, exp_period, ticks);
            end
            if (last_val >= 0 && {8'd0, o_rgb} != (last_val + 1) % (1<<24)) begin
                errors <= errors + 1;
                $display("FAIL: mode_416=%0d pixel seq %0d -> %0d (dup/drop) tick %0d",
                         mode_416, last_val, o_rgb, ticks);
            end
            if (o_hs !== hs || o_vs !== 1'b0 || o_de !== de) begin
                errors <= errors + 1;
                $display("FAIL: mode_416=%0d sideband mismatch hs=%0d/%0d vs=%0d de=%0d/%0d tick %0d",
                         mode_416, o_hs, hs, o_vs, o_de, de, ticks);
            end
        end
        last_val <= {8'd0, o_rgb};
        spacing <= 0;
    end
    if (b_ce) begin
        bypass_ticks <= bypass_ticks + 1;
        if (settle > 2 && bypass_ticks > 4) begin
            if (bypass_last_val >= 0 && {8'd0, b_rgb} != (bypass_last_val + 1) % (1<<24)) begin
                errors <= errors + 1;
                $display("FAIL: mode_416=%0d bypass pixel seq %0d -> %0d (dup/drop) tick %0d",
                         mode_416, bypass_last_val, b_rgb, bypass_ticks);
            end
            if (b_hs !== hs || b_vs !== 1'b0 || b_de !== de) begin
                errors <= errors + 1;
                $display("FAIL: mode_416=%0d bypass sideband mismatch hs=%0d/%0d vs=%0d de=%0d/%0d tick %0d",
                         mode_416, b_hs, hs, b_vs, b_de, de, bypass_ticks);
            end
        end
        bypass_last_val <= {8'd0, b_rgb};
    end
end

task run_mode(input m);
    begin
        mode_416 = m; rst = 1; settle = 0; last_val = -1; ticks = 0;
        bypass_last_val = -1; bypass_ticks = 0;
        repeat (50) @(posedge clk);
        rst = 0;
        // The first HSync anchor after reset may correct the free-running
        // grid phase by one clk once (a single odd-length boot pixel); every
        // later anchor is an exact no-op because the line length (6150/6144
        // clk) is a multiple of the pixel period.  Start checking only after
        // that first lock (> 2 lines).
        repeat (13000) @(posedge clk);
        settle = 3;
        // > 3 full lines (410*15 = 6150 / 512*12 = 6144 clk per line)
        repeat (25000) @(posedge clk);
    end
endtask

initial begin
    clk = 1'b0;
    half = 1'b0;
    mode_416 = 1'b0;
    rst = 1'b1;
    ce_acc = 8'd0;
    ce_pix = 1'b0;
    hcnt = 9'd0;
    pix_idx = 24'd0;
    hs = 1'b0;
    rgb = 24'd0;
    de = 1'b0;
    spacing = 0;
    last_val = -1;
    errors = 0;
    ticks = 0;
    settle = 0;
    bypass_last_val = -1;
    bypass_ticks = 0;
    run_mode(0);   // 320-wide: jittered 8/7 source, expect uniform 15
    run_mode(1);   // 416-wide: uniform 6-clk_sys source, expect uniform 12
    if (errors == 0) $display("VIDEO RETIME PASS");
    else             $display("FAIL: %0d errors", errors);
    $finish;
end

endmodule

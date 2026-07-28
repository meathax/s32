//============================================================================
// Directed test: Alien 3 modern analog-stick aim conditioning
//   * radial inner deadzone and diagonal direction preservation
//   * precision-biased monotonic response curve
//   * 95%-throw outer saturation across the complete 8-bit cabinet ADC range
//   * centred inversion, player isolation, and adaptive filter settling
//============================================================================
`timescale 1ns/1ps

module tb_gun_aim;

reg clk = 1'b0;
always #5 clk = ~clk;

reg rst = 1'b1;
reg enable = 1'b0;
reg [7:0] p1_raw_x = 8'h00;
reg [7:0] p1_raw_y = 8'h00;
reg [7:0] p2_raw_x = 8'h00;
reg [7:0] p2_raw_y = 8'h00;
reg invert_x = 1'b0;
reg invert_y = 1'b0;
wire [7:0] p1_aim_x, p1_aim_y, p2_aim_x, p2_aim_y;

s32_gun_aim #(.TICK_BITS(4)) dut (
    .clk(clk), .rst(rst), .enable(enable),
    .p1_raw_x(p1_raw_x), .p1_raw_y(p1_raw_y),
    .p2_raw_x(p2_raw_x), .p2_raw_y(p2_raw_y),
    .invert_x(invert_x), .invert_y(invert_y),
    .p1_aim_x(p1_aim_x), .p1_aim_y(p1_aim_y),
    .p2_aim_x(p2_aim_x), .p2_aim_y(p2_aim_y)
);

integer errors = 0;
integer timeout;
reg [7:0] prior;

task automatic check(input condition, input [511:0] name);
begin
    if (condition !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL: %0s", name);
    end
end
endtask

task automatic settle;
begin
    repeat (1600) @(posedge clk);
    #1;
end
endtask

task automatic set_all_center;
begin
    p1_raw_x = 8'h00; p1_raw_y = 8'h00;
    p2_raw_x = 8'h00; p2_raw_y = 8'h00;
    invert_x = 1'b0; invert_y = 1'b0;
end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
    enable = 1'b1;
    settle();
    check(p1_aim_x == 8'h80 && p1_aim_y == 8'h80 &&
          p2_aim_x == 8'h80 && p2_aim_y == 8'h80,
          "zero raw input rests exactly at ADC center");

    // Cardinal and diagonal samples inside the radial center deadzone.
    p1_raw_x = 8'd10;
    settle();
    check(p1_aim_x == 8'h80 && p1_aim_y == 8'h80,
          "inner radius boundary remains centered");
    p1_raw_x = 8'd7;
    p1_raw_y = 8'd7;
    settle();
    check(p1_aim_x == 8'h80 && p1_aim_y == 8'h80,
          "diagonal inner deadzone is radial rather than per-axis");

    // The first code outside the deadzone is continuous, with no jump.
    p1_raw_x = 8'd11;
    p1_raw_y = 8'd0;
    settle();
    check(p1_aim_x == 8'd129,
          "first live radius produces the first positive ADC code");

    // Selected exact curve points also prove monotonic progression.
    p1_raw_x = 8'd32;
    settle();
    check(p1_aim_x == 8'd146, "curve radius 32 exact response");
    prior = p1_aim_x;
    p1_raw_x = 8'd64;
    settle();
    check(p1_aim_x == 8'd178 && p1_aim_x > prior,
          "curve radius 64 is precise and monotonic");
    prior = p1_aim_x;
    p1_raw_x = 8'd96;
    settle();
    check(p1_aim_x == 8'd218 && p1_aim_x > prior,
          "curve radius 96 accelerates toward the edge");

    // The outer saturation reaches full throw just before physical maximum.
    p1_raw_x = 8'd121;
    settle();
    check(p1_aim_x == 8'd254, "last live-band radius remains below saturation");
    p1_raw_x = 8'd122;
    settle();
    check(p1_aim_x == 8'hff, "outer saturation begins at about 95 percent throw");
    p1_raw_x = 8'd127;
    settle();
    check(p1_aim_x == 8'hff, "positive physical maximum stays saturated");
    p1_raw_x = 8'h80; // signed -128
    settle();
    check(p1_aim_x == 8'h00, "negative physical maximum reaches cabinet endpoint");

    // Equal diagonal components remain equal after radial scaling.
    p1_raw_x = 8'd64;
    p1_raw_y = 8'd64;
    settle();
    check(p1_aim_x == 8'd185 && p1_aim_y == 8'd185,
          "diagonal response preserves direction and shared magnitude");

    // Positive/negative and OSD inversion are centered mirrors.
    p1_raw_x = 8'd64;
    p1_raw_y = 8'd0;
    settle();
    check(p1_aim_x == 8'd178, "positive symmetry reference");
    p1_raw_x = 8'hc0; // signed -64
    settle();
    check(p1_aim_x == 8'd78 && ({1'b0, p1_aim_x} + 9'd178) == 9'd256,
          "negative response mirrors around center");
    p1_raw_x = 8'd64;
    invert_x = 1'b1;
    settle();
    check(p1_aim_x == 8'd78, "X inversion mirrors the conditioned response");
    invert_x = 1'b0;

    // P1/P2 are sampled together but processed independently by shared math.
    p1_raw_x = 8'h00; p1_raw_y = 8'h00;
    p2_raw_x = 8'hb0; // signed -80
    p2_raw_y = 8'd96;
    settle();
    check(p1_aim_x == 8'h80 && p1_aim_y == 8'h80,
          "P2 input does not leak into P1");
    check(p2_aim_x == 8'd47 && p2_aim_y == 8'd225,
          "P2 diagonal vector is conditioned independently");

    // Observe the first adaptive-filter update: large motion consumes half
    // the error, then converges to the full target without overshoot.
    enable = 1'b0;
    repeat (3) @(posedge clk);
    set_all_center();
    p1_raw_x = 8'd127;
    enable = 1'b1;
    timeout = 0;
    while (p1_aim_x == 8'h80 && timeout < 500) begin
        @(posedge clk);
        timeout = timeout + 1;
    end
    #1;
    check(timeout < 500 && p1_aim_x == 8'd192,
          "large sweep takes a responsive half-error first step");
    settle();
    check(p1_aim_x == 8'hff, "large sweep settles exactly at cabinet endpoint");

    p1_raw_x = 8'h00;
    timeout = 0;
    while (p1_aim_x == 8'hff && timeout < 500) begin
        @(posedge clk);
        timeout = timeout + 1;
    end
    #1;
    check(timeout < 500 && p1_aim_x == 8'd191,
          "return-to-center uses the symmetric fast step");
    settle();
    check(p1_aim_x == 8'h80, "return-to-center snaps exactly with no residual drift");

    // Disabling the gun profile cannot leave stale non-centered ADC values.
    p1_raw_x = 8'd127;
    settle();
    enable = 1'b0;
    @(posedge clk);
    #1;
    check(p1_aim_x == 8'h80 && p1_aim_y == 8'h80 &&
          p2_aim_x == 8'h80 && p2_aim_y == 8'h80,
          "disabled gun conditioner returns every channel to center");

    if (errors == 0)
        $display("GUN AIM PASS");
    else begin
        $display("GUN AIM FAIL: %0d errors", errors);
        $fatal(1);
    end
    $finish;
end

endmodule

module tb_s32_driving_controls;
    timeunit 1ns;
    timeprecision 1ps;

    logic       clk;
    logic       rst = 1'b1;
    logic       wheel_sample = 1'b0;
    logic       capture_wheel = 1'b1;
    logic [7:0] left_x = 8'h00;
    logic [7:0] paddle = 8'h80;
    logic [8:0] spinner = 9'h000;
    logic [24:0] mouse = 25'd0;
    logic [1:0] wheel_source = 2'd0;
    logic [1:0] steering_sensitivity = 2'd0;
    logic [7:0] right_y = 8'h00;
    logic       digital_accel = 1'b0;
    logic       digital_brake = 1'b0;
    logic       digital_left = 1'b0;
    logic       digital_right = 1'b0;
    wire  [7:0] wheel;
    wire  [7:0] accel;
    wire  [7:0] brake;

    s32_driving_controls dut (
        .clk(clk),
        .rst(rst),
        .wheel_sample(wheel_sample),
        .capture_wheel(capture_wheel),
        .left_x(left_x),
        .paddle(paddle),
        .spinner(spinner),
        .mouse(mouse),
        .wheel_source(wheel_source),
        .steering_sensitivity(steering_sensitivity),
        .right_y(right_y),
        .digital_accel(digital_accel),
        .digital_brake(digital_brake),
        .digital_left(digital_left),
        .digital_right(digital_right),
        .wheel(wheel),
        .accel(accel),
        .brake(brake)
    );

    always #1 clk = ~clk;

    // One real ADC sample: the only moment the wheel register may move.
    task automatic sample;
        begin
            @(negedge clk);
            wheel_sample = 1'b1;
            @(posedge clk);
            @(negedge clk);
            wheel_sample = 1'b0;
        end
    endtask

    task automatic expect_wheel(input [7:0] expected, input string what);
        if (wheel !== expected)
            $fatal(1, "%s: wheel=%02x expected=%02x", what, wheel, expected);
    endtask

    initial begin
        clk = 1'b0;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        #1;
        expect_wheel(8'h80, "reset centers wheel");

        // Rad Mobile's firmware rejects wheel samples that move more than
        // 0x40 per accepted sample (signed 8-bit compare, MAME-measured), so
        // a D-pad endpoint must arrive as a ramp, and releasing it must ramp
        // back instead of latching at full lock. The ramp advances once per
        // real ADC sample (wheel_sample), not once per frame.
        digital_right = 1'b1;
        sample; expect_wheel(8'hb8, "press right: first step");
        sample; sample;
        expect_wheel(8'hff, "press right: endpoint reached");

        digital_right = 1'b0;
        sample; expect_wheel(8'hc7, "release: springs back");
        sample; sample;
        expect_wheel(8'h80, "release: returns to center");

        digital_left = 1'b1;
        sample; expect_wheel(8'h48, "press left: first step");
        sample; sample;
        expect_wheel(8'h00, "press left: endpoint reached");
        digital_left = 1'b0;
        repeat (3) sample;
        expect_wheel(8'h80, "release left: returns to center");

        // Pedals stay combinational.
        digital_accel = 1'b1;
        #1;
        if (accel !== 8'hff || brake !== 8'h00)
            $fatal(1, "digital accel changed: accel=%02x brake=%02x", accel, brake);
        digital_accel = 1'b0;

        $display("PASS tb_s32_driving_controls");
        $finish;
    end
endmodule

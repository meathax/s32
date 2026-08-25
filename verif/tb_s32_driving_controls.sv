module tb_s32_driving_controls;
    timeunit 1ns;
    timeprecision 1ps;

    logic       clk;
    logic       rst = 1'b1;
    logic       vs = 1'b0;
    logic       capture_wheel = 1'b1;
    logic [7:0] left_x = 8'h00;
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
        .vs(vs),
        .capture_wheel(capture_wheel),
        .left_x(left_x),
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

    // One vsync tick: the only moment the wheel register may move.
    task automatic frame;
        begin
            @(negedge clk);
            vs = 1'b1;
            repeat (2) @(negedge clk);
            vs = 1'b0;
            repeat (2) @(negedge clk);
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
        // back instead of latching at full lock.
        digital_right = 1'b1;
        frame; expect_wheel(8'ha0, "press right: first step");
        frame; frame; frame;
        expect_wheel(8'hff, "press right: endpoint reached");

        digital_right = 1'b0;
        frame; expect_wheel(8'hdf, "release: springs back");
        frame; frame; frame;
        expect_wheel(8'h80, "release: returns to center");

        digital_left = 1'b1;
        frame; expect_wheel(8'h60, "press left: first step");
        frame; frame; frame;
        expect_wheel(8'h00, "press left: endpoint reached");
        digital_left = 1'b0;
        repeat (4) frame;
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

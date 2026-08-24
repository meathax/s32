module tb_s32_driving_controls;
    timeunit 1ns;
    timeprecision 1ps;

    logic       clk;
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

    task automatic drive_wheel(input [7:0] x);
        begin
            @(negedge clk);
            left_x = x;
            digital_left = 1'b0;
            digital_right = 1'b0;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic check_dpad(input bit left, input bit right, input [7:0] expected);
        begin
            @(negedge clk);
            digital_left = left;
            digital_right = right;
            left_x = 8'h00;
            @(posedge clk);
            @(negedge clk);
            if (wheel !== expected)
                $fatal(1, "D-pad steering mismatch: left=%0d right=%0d wheel=%02x expected=%02x",
                       left, right, wheel, expected);
        end
    endtask

    task automatic sample_current(input [7:0] x, input bit left, input bit right,
                                   input [7:0] expected);
        begin
            @(negedge clk);
            left_x = x;
            digital_left = left;
            digital_right = right;
            @(posedge clk);
            if (wheel !== expected)
                $fatal(1, "ADC sampled stale wheel: x=%02x left=%0d right=%0d wheel=%02x expected=%02x",
                       x, left, right, wheel, expected);
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        repeat (2) @(posedge clk);

        // Neutral -> full left -> full right between two ADC polls. A
        // positional wheel must deliver the newest coordinate, not the
        // previous largest excursion.
        drive_wheel(8'h00);
        drive_wheel(8'h80);
        drive_wheel(8'h7f);
        drive_wheel(8'h7f);

        // A fast movement can arrive between two clk_sys edges. The ADC
        // samples the live input on its write edge; it must not be held at
        // the previous queued coordinate.
        @(negedge clk);
        left_x = 8'h40;
        digital_left = 1'b0;
        digital_right = 1'b0;
        @(posedge clk);
        sample_current(8'h60, 1'b0, 1'b0, 8'hda);

        // The same edge contract applies when D-pad steering replaces an
        // analog position: the selected endpoint must reach the ADC now.
        @(negedge clk);
        left_x = 8'h40;
        digital_left = 1'b0;
        digital_right = 1'b0;
        @(posedge clk);
        sample_current(8'h00, 1'b1, 1'b0, 8'h00);

        check_dpad(1'b1, 1'b0, 8'h00);
        check_dpad(1'b0, 1'b1, 8'hff);
        check_dpad(1'b1, 1'b1, 8'h80);

        capture_wheel = 1'b0;
        digital_left = 1'b1;
        digital_right = 1'b0;
        left_x = 8'h40;
        @(posedge clk);
        #0;
        if (wheel !== 8'hba)
            $fatal(1, "non-Rad-Mobile direct wheel path changed: %02x", wheel);
        if (accel !== 8'h00 || brake !== 8'h00)
            $fatal(1, "released pedals changed: accel=%02x brake=%02x", accel, brake);

        $display("PASS tb_s32_driving_controls");
        $finish;
    end
endmodule

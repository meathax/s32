module tb_s32_driving_controls;
    timeunit 1ns;
    timeprecision 1ps;

    logic       clk;
    logic       rst = 1'b1;
    logic       capture_wheel = 1'b1;
    logic       wheel_sample = 1'b0;
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
        .capture_wheel(capture_wheel),
        .wheel_sample(wheel_sample),
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

    task automatic drive_wheel(input [7:0] x, input bit sample);
        begin
            @(negedge clk);
            left_x = x;
            digital_left = 1'b0;
            digital_right = 1'b0;
            wheel_sample = sample;
            #0;
            if (sample && wheel !== 8'hf9)
                $fatal(1, "latest-position sample lost: x=%02x wheel=%02x expected=f9", x, wheel);
            @(posedge clk);
            @(negedge clk);
            wheel_sample = 1'b0;
        end
    endtask

    task automatic check_dpad(input bit left, input bit right, input [7:0] expected);
        begin
            @(negedge clk);
            digital_left = left;
            digital_right = right;
            left_x = 8'h00;
            #0;
            @(posedge clk);
            @(negedge clk);
            if (wheel !== expected)
                $fatal(1, "D-pad steering mismatch: left=%0d right=%0d wheel=%02x expected=%02x",
                       left, right, wheel, expected);
        end
    endtask

    initial begin
        clk = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Neutral -> full left -> full right between two ADC polls. A
        // positional wheel must deliver the newest coordinate, not the
        // previous largest excursion.
        drive_wheel(8'h00, 1'b0);
        drive_wheel(8'h80, 1'b0);
        drive_wheel(8'h7f, 1'b0);
        drive_wheel(8'h7f, 1'b1);

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

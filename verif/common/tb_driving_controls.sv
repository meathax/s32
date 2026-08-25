`timescale 1ns/1ps

// Contract under test: the wheel output is a slew-limited position. Rad
// Mobile's firmware rejects any ADC wheel sample whose signed 8-bit delta
// from the previously accepted sample is outside [-0x40, +0x40], and never
// resynchronizes (MAME-measured). The wheel must therefore move toward the
// host target by at most WHEEL_STEP per vsync and must never cross the
// 00<->FF wrap. Pedals stay combinational.
module tb_driving_controls;
    reg        clk = 1'b0;
    reg        rst;
    reg        vs = 1'b0;
    reg        capture_wheel;
    reg  [7:0] left_x;
    reg  [7:0] right_y;
    reg        digital_accel;
    reg        digital_brake;
    reg        digital_left;
    reg        digital_right;
    wire [7:0] wheel;
    wire [7:0] accel;
    wire [7:0] brake;

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

    always #5 clk = ~clk;

    task automatic check(input condition, input [255:0] message);
        if (!condition) begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    // One video frame: pulse vs and let the wheel register take its step.
    // Every step is validated against the firmware acceptance window and the
    // no-wrap requirement.
    task automatic frame;
        reg [7:0] prev_w;
        reg signed [8:0] delta;
        begin
            @(negedge clk);
            prev_w = wheel;
            vs = 1'b1;
            repeat (2) @(negedge clk);
            vs = 1'b0;
            repeat (2) @(negedge clk);
            delta = $signed({1'b0, wheel}) - $signed({1'b0, prev_w});
            check(delta <= 9'sd64 && delta >= -9'sd64,
                  "per-frame wheel delta stays inside firmware window");
            check(!(prev_w < 8'h40 && wheel > 8'hc0) &&
                  !(prev_w > 8'hc0 && wheel < 8'h40),
                  "wheel never crosses the 00<->FF wrap in one frame");
        end
    endtask

    task automatic run_frames(input integer n);
        integer i;
        for (i = 0; i < n; i = i + 1) frame;
    endtask

    task automatic drive(input [7:0] right_y_value, input [31:0] buttons);
        right_y = right_y_value;
        digital_accel = buttons[4];
        digital_brake = buttons[5];
        #1;
    endtask

    initial begin
        left_x = 8'h00;
        right_y = 8'h00;
        digital_accel = 1'b0;
        digital_brake = 1'b0;
        digital_left = 1'b0;
        digital_right = 1'b0;
        capture_wheel = 1'b1;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        #1;

        check(wheel == 8'h80, "wheel resets to center");

        // Pedals remain combinational: unchanged behavior.
        drive(8'h00, 32'd0);
        check(accel == 8'h00 && brake == 8'h00,
              "center releases both pedals");
        drive(8'hc0, 32'd0); // -64: right stick halfway up
        check(accel == 8'h80 && brake == 8'h00,
              "right-stick up drives accelerator only");
        drive(8'h81, 32'd0); // -127: full up
        check(accel == 8'hff && brake == 8'h00,
              "full right-stick up saturates accelerator");
        drive(8'h40, 32'd0); // +64: right stick halfway down
        check(accel == 8'h00 && brake == 8'h80,
              "right-stick down drives brake only");
        drive(8'h7f, 32'd0); // +127: full down
        check(accel == 8'h00 && brake == 8'hff,
              "full right-stick down saturates brake");
        drive(8'h00, 32'h0000_0010); // A / B1
        check(accel == 8'hff && brake == 8'h00,
              "A is the full-scale digital accelerator");
        drive(8'h00, 32'h0000_0020); // B / B2
        check(accel == 8'h00 && brake == 8'hff,
              "B is the full-scale digital brake");
        drive(8'h00, 32'd0);

        // Small analog moves land in one frame.
        left_x = 8'h10; // +16 -> deadzone-adjusted 0x8a
        run_frames(1);
        check(wheel == 8'h8a, "small analog move lands in one frame");

        // Instant full-right D-pad press ramps: 8a->aa->ca->ea->ff.
        digital_right = 1'b1;
        run_frames(1);
        check(wheel == 8'haa, "D-pad right takes one WHEEL_STEP per frame");
        run_frames(3);
        check(wheel == 8'hff, "D-pad right reaches the endpoint");
        run_frames(1);
        check(wheel == 8'hff, "endpoint holds while pressed");

        // Release: must spring back to the analog coordinate (this is the
        // stuck-at-full-lock regression: ff -> 80 was previously one jump the
        // firmware rejected forever).
        digital_right = 1'b0;
        left_x = 8'h00;
        run_frames(1);
        check(wheel == 8'hdf, "release starts ramping back to center");
        run_frames(3);
        check(wheel == 8'h80, "release returns fully to center");

        // Instant full-left flick from center: 80->60->40->26->06.
        left_x = 8'h80; // -128 -> deadzone-adjusted 0x06
        run_frames(4);
        check(wheel == 8'h06, "fast flick left converges to target");

        // Fast oscillation never freezes: worst case one frame per direction.
        left_x = 8'h7f; // full right target 0xf9
        run_frames(1);
        left_x = 8'h80; // full left target 0x06
        run_frames(1);
        left_x = 8'h00;
        run_frames(8);
        check(wheel == 8'h80, "oscillation recovers to center");

        // Simultaneous D-pad directions target center.
        digital_left = 1'b1;
        digital_right = 1'b1;
        run_frames(8);
        check(wheel == 8'h80, "both directions return to center");
        digital_left = 1'b0;
        digital_right = 1'b0;

        // Non-capture profile still slews from the analog coordinate.
        capture_wheel = 1'b0;
        digital_left = 1'b1; // ignored without capture_wheel
        left_x = 8'h40;      // +64 -> deadzone-adjusted 0xba
        run_frames(2);
        check(wheel == 8'hba, "analog-only profile ignores D-pad and slews");
        digital_left = 1'b0;

        $display("PASS: System 32 driving controls");
        $finish;
    end
endmodule

// System 32 driving-cabinet input adapters.
// MiSTer analog-stick axes are signed -128..+127 with zero at rest.
module s32_driving_controls (
    input         clk,
    input         rst,
    input         vs,            // vertical sync: wheel slews once per rising edge
    input         capture_wheel,
    input   [7:0] left_x,
    input   [7:0] right_y,
    input         digital_accel,
    input         digital_brake,
    input         digital_left,
    input         digital_right,
    output  [7:0] wheel,
    output  [7:0] accel,
    output  [7:0] brake
);
    localparam [7:0] WHEEL_DZ = 8'd6;

    function automatic [7:0] wheel_deadzone(input [7:0] raw);
        logic [7:0] v;
        begin
            v = raw ^ 8'h80;
            // This is algebraically the same subtractive deadzone as
            // 128 + ((v - 128) +/- WHEEL_DZ), expressed in offset-binary so
            // every intermediate and the ADC result remain explicitly 8-bit.
            if (v >= (8'd128 - WHEEL_DZ) && v <= (8'd128 + WHEEL_DZ))
                wheel_deadzone = 8'h80;
            else if (v > 8'd128)
                wheel_deadzone = v - WHEEL_DZ;
            else
                wheel_deadzone = v + WHEEL_DZ;
        end
    endfunction

    wire [7:0] wheel_analog = wheel_deadzone(left_x);
    // Positional-wheel driving profiles use absolute endpoints for D-pad
    // overrides; simultaneous directions return to center.
    wire [7:0] wheel_digital = (digital_left && digital_right) ? 8'h80 :
                                digital_left ? 8'h00 :
                                digital_right ? 8'hff : wheel_analog;
    wire [7:0] wheel_target = capture_wheel ? wheel_digital : wheel_analog;

    // Rad Mobile's firmware validates every wheel ADC sample against the last
    // accepted one and rejects the new sample forever when the signed 8-bit
    // difference is outside [-0x40, +0x40] (measured in MAME by forcing
    // ANALOG1: 0x50->0x90 accepted, 0x90->0xD1 rejected, 0xD0->0x10 accepted
    // through the wrap, and a rejected value stays rejected for 120+ frames).
    // A real potentiometer wheel can never jump, so host sticks and D-pad
    // endpoints must be slew-limited toward the target. 0x20 per frame keeps
    // consecutive firmware samples within tolerance even at half-rate
    // sampling, and the linear ramp never crosses the 00<->FF wrap that the
    // firmware's signed compare would accept as a small step (that wrap
    // acceptance is what latched the D-pad at full lock).
    localparam [7:0] WHEEL_STEP = 8'h20;

    reg [7:0] wheel_q = 8'h80;
    reg       vs_d = 1'b0;
    wire signed [8:0] wheel_diff =
        $signed({1'b0, wheel_target}) - $signed({1'b0, wheel_q});
    always @(posedge clk) begin
        vs_d <= vs;
        if (rst) begin
            wheel_q <= 8'h80;
        end
        else if (vs && !vs_d) begin
            if (wheel_diff > $signed({1'b0, WHEEL_STEP}))
                wheel_q <= wheel_q + WHEEL_STEP;
            else if (wheel_diff < -$signed({1'b0, WHEEL_STEP}))
                wheel_q <= wheel_q - WHEEL_STEP;
            else
                wheel_q <= wheel_target;
        end
    end

    wire signed [8:0] stick_y =
        $signed({right_y[7], right_y});
    wire [8:0] accel_mag = (stick_y < 0) ? -stick_y : 9'd0;
    wire [8:0] brake_mag = (stick_y > 0) ?  stick_y : 9'd0;

    function automatic [7:0] pedal(input [8:0] magnitude);
        pedal = (magnitude >= 9'd127) ? 8'hff : {magnitude[6:0], 1'b0};
    endfunction

    // The MSM6253 captures wheel_q on its accepted channel-load write;
    // wheel_q only changes on the vsync tick, so every conversion sees one
    // stable, slew-limited coordinate.
    assign wheel = wheel_q;

    assign accel = digital_accel ? 8'hff : pedal(accel_mag);
    assign brake = digital_brake ? 8'hff : pedal(brake_mag);
endmodule

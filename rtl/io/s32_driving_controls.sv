// System 32 driving-cabinet input adapters.
// MiSTer analog-stick axes are signed -128..+127 with zero at rest.
module s32_driving_controls (
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
    wire [7:0] wheel_live = capture_wheel ? wheel_digital : wheel_analog;

    wire signed [8:0] stick_y =
        $signed({right_y[7], right_y});
    wire [8:0] accel_mag = (stick_y < 0) ? -stick_y : 9'd0;
    wire [8:0] brake_mag = (stick_y > 0) ?  stick_y : 9'd0;

    function automatic [7:0] pedal(input [8:0] magnitude);
        pedal = (magnitude >= 9'd127) ? 8'hff : {magnitude[6:0], 1'b0};
    endfunction

    // MSM6253 captures the selected analog input on its accepted channel-load
    // write. Keep this path live so a host update between clk_sys edges is
    // visible on that write edge; a queued coordinate would sample the prior
    // position and can mask a newly pressed D-pad direction.
    assign wheel = wheel_live;

    assign accel = digital_accel ? 8'hff : pedal(accel_mag);
    assign brake = digital_brake ? 8'hff : pedal(brake_mag);
endmodule

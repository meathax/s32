// System 32 driving-cabinet input adapters.
// MiSTer analog-stick axes are signed -128..+127 with zero at rest.
module s32_driving_controls (
    input         clk,
    input         rst,
    input         capture_wheel,
    input         wheel_sample,
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
    // Rad Mobile's cabinet wheel is an absolute position. D-pad overrides
    // are scoped to that profile; simultaneous directions return to center.
    wire [7:0] wheel_digital = (digital_left && digital_right) ? 8'h80 :
                                digital_left ? 8'h00 :
                                digital_right ? 8'hff : wheel_analog;
    wire [7:0] wheel_live = capture_wheel ? wheel_digital : wheel_analog;

    reg [7:0] wheel_latest;
    reg [7:0] wheel_pending;
    reg       wheel_pending_valid;

    wire signed [8:0] stick_y =
        $signed({right_y[7], right_y});
    wire [8:0] accel_mag = (stick_y < 0) ? -stick_y : 9'd0;
    wire [8:0] brake_mag = (stick_y > 0) ?  stick_y : 9'd0;

    function automatic [7:0] pedal(input [8:0] magnitude);
        pedal = (magnitude >= 9'd127) ? 8'hff : {magnitude[6:0], 1'b0};
    endfunction

    // Rad Mobile polls MSM6253 more slowly than the controller reports new
    // positions. Hold the newest unconsumed coordinate until channel 0 loads;
    // a peak detector would discard a newer, less-extreme steering position.
    assign wheel = (capture_wheel && wheel_pending_valid)
                 ? wheel_pending : wheel_live;

    always @(posedge clk) begin
        if (rst) begin
            wheel_latest       <= 8'h80;
            wheel_pending      <= 8'h80;
            wheel_pending_valid <= 1'b0;
        end
        else if (!capture_wheel) begin
            wheel_latest       <= wheel_live;
            wheel_pending      <= wheel_live;
            wheel_pending_valid <= 1'b0;
        end
        else if (wheel_sample) begin
            // MSM6253 captures pre-edge wheel. If the stick moved again,
            // retain the current coordinate for the following conversion.
            wheel_latest <= wheel_live;
            wheel_pending <= wheel_live;
            wheel_pending_valid <= (wheel_live != wheel);
        end
        else if (wheel_live != wheel_latest) begin
            wheel_latest <= wheel_live;
            wheel_pending <= wheel_live;
            wheel_pending_valid <= 1'b1;
        end
    end

    assign accel = digital_accel ? 8'hff : pedal(accel_mag);
    assign brake = digital_brake ? 8'hff : pedal(brake_mag);
endmodule

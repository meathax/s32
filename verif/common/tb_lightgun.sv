`timescale 1ns/1ps

module tb_lightgun;
    reg        clk = 1'b0;
    reg        rst;
    reg        vs;
    reg  [8:0] screen_width;
    reg  [8:0] screen_height;
    reg  [1:0] rotate;
    reg  [1:0] sensitivity;
    reg [15:0] joyana;
    reg  [3:0] joy_dir;
    reg  [7:0] mouse_dx;
    reg  [7:0] mouse_dy;
    reg        mouse_strobe;
    wire [8:0] gun_x;
    wire [8:0] gun_y;
    wire [7:0] adc_x;
    wire [7:0] adc_y;
    wire       gun_strobe;

    s32_lightgun dut (
        .clk(clk), .rst(rst), .vs(vs),
        .screen_width(screen_width), .screen_height(screen_height),
        .rotate(rotate), .sensitivity(sensitivity), .joyana(joyana),
        .joy_dir(joy_dir), .mouse_dx(mouse_dx), .mouse_dy(mouse_dy),
        .mouse_strobe(mouse_strobe), .gun_x(gun_x), .gun_y(gun_y),
        .adc_x(adc_x), .adc_y(adc_y), .gun_strobe(gun_strobe)
    );

    always #5 clk = ~clk;

    task automatic check(input condition, input [255:0] message);
        if (!condition) begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task automatic set_analog(input [15:0] value);
        @(negedge clk);
        joyana = value;
        @(posedge clk);
        #1;
    endtask

    task automatic mouse_report(input [7:0] dx, input [7:0] dy);
        @(negedge clk);
        mouse_dx = dx;
        mouse_dy = dy;
        mouse_strobe = 1'b1;
        @(posedge clk);
        #1;
        mouse_strobe = 1'b0;
    endtask

    task automatic dpad_frame(input [3:0] value);
        @(negedge clk);
        vs = 1'b0;
        @(posedge clk);
        #1;
        joy_dir = value;
        vs = 1'b1;
        @(posedge clk);
        #1;
        vs = 1'b0;
        joy_dir = 4'd0;
    endtask

    initial begin
        screen_width  = 9'd320;
        screen_height = 9'd224;
        rotate        = 2'b00;
        sensitivity   = 2'd0;
        joyana        = 16'd0;
        joy_dir       = 4'd0;
        mouse_dx      = 8'd0;
        mouse_dy      = 8'd0;
        mouse_strobe  = 1'b0;
        vs            = 1'b0;
        rst           = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        #1;

        check(gun_x == 9'd160 && gun_y == 9'd112,
              "reset starts at the native raster centre");
        check(adc_x == 8'h80 && adc_y == 8'h80 && !gun_strobe,
              "reset exposes centred offset-binary ADC values");

        set_analog(16'h007f); // X=+127, Y=0
        check(adc_x == 8'hff && adc_y == 8'h80,
              "signed host X axis maps to the full ADC range");
        check(gun_x == 9'd318 && gun_y == 9'd112 && gun_strobe,
              "absolute analog coordinates use JTFRAME 8-bit scaling");

        set_analog(16'h7f00); // X=0, Y=+127
        check(adc_x == 8'h80 && adc_y == 8'hff,
              "signed host Y axis maps independently");
        check(gun_x == 9'd160 && gun_y == 9'd223,
              "native height scaling reaches the last active row");

        // Relative mouse motion is accumulated and clamped in native pixels.
        set_analog(16'h0000);
        mouse_report(8'd20, 8'd5);
        check(gun_x == 9'd180 && gun_y == 9'd107,
              "JTFRAME mouse deltas move the absolute sight");
        check(adc_x == 8'd143 && adc_y == 8'd122,
              "relative positions convert back to exact ADC endpoints");
        mouse_report(8'h80, 8'h80); // -128 X, -128 Y: clamp both ends
        check(gun_x == 9'd52 && gun_y == 9'd223,
              "relative motion uses signed deltas and clamps to the raster");

        // A clockwise rotation maps +X into positive screen Y in the same
        // convention as jtframe_mouse_rotation.
        rotate = 2'b01;
        mouse_report(8'd5, 8'd0);
        check(gun_x == 9'd52 && gun_y == 9'd218,
              "relative rotation preserves JTFRAME orientation semantics");
        rotate = 2'b00;

        // D-pad motion is sampled once per VSync edge and uses sensitivity 0's
        // JTFRAME base step of seven pixels.
        sensitivity = 2'd0;
        dpad_frame(4'b0001); // right
        check(gun_x == 9'd59 && gun_y == 9'd218 && gun_strobe,
              "d-pad right advances once per VSync");
        sensitivity = 2'd1; // base +2 = 9
        dpad_frame(4'b0100); // up
        check(gun_x == 9'd59 && gun_y == 9'd209,
              "sensitivity and up/down direction match JTFRAME");

        // Mode changes retain a valid position but clamp it to the new width.
        set_analog(16'h007f);
        screen_width = 9'd320;
        #1;
        screen_width = 9'd416;
        set_analog(16'h0000);
        set_analog(16'h007f);
        check(gun_x == 9'd414 && adc_x == 8'hff,
              "416-wide native mode scales without truncating the ADC");

        $display("LIGHTGUN PASS");
        $finish;
    end
endmodule

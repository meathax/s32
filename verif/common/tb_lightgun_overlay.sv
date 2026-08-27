`timescale 1ns/1ps

module tb_lightgun_overlay;
    reg        clk = 1'b0;
    reg        rst;
    reg        pxl_cen;
    reg        hs;
    reg        vs;
    reg        de;
    reg  [8:0] screen_width;
    reg  [8:0] screen_height;
    reg  [8:0] gun1_x, gun1_y, gun2_x, gun2_y;
    reg        gun1_en, gun2_en, border_en, crosshair_en;
    reg [23:0] rgb_in;
    wire [23:0] rgb_out;
    wire [8:0] raster_x, raster_y;

    s32_lightgun_overlay #(.BORDER_WIDTH(1)) dut (
        .clk(clk), .rst(rst), .pxl_cen(pxl_cen), .hs(hs), .vs(vs), .de(de),
        .screen_width(screen_width), .screen_height(screen_height),
        .gun1_x(gun1_x), .gun1_y(gun1_y), .gun2_x(gun2_x), .gun2_y(gun2_y),
        .gun1_en(gun1_en), .gun2_en(gun2_en), .border_en(border_en),
        .crosshair_en(crosshair_en), .rgb_in(rgb_in), .rgb_out(rgb_out),
        .raster_x(raster_x), .raster_y(raster_y)
    );

    always #5 clk = ~clk;

    task automatic check(input condition, input [255:0] message);
        if (!condition) begin
            $display("FAIL: %0s (x=%0d y=%0d rgb=%h)",
                     message, raster_x, raster_y, rgb_out);
            $fatal(1);
        end
    endtask

    task automatic pixel(input [23:0] colour, input [8:0] expected_x,
                         input [8:0] expected_y, input [23:0] expected_rgb);
        @(negedge clk);
        de     = 1'b1;
        rgb_in = colour;
        @(posedge clk);
        #1;
        check(raster_x == expected_x && raster_y == expected_y &&
              rgb_out == expected_rgb, "native RGB and raster phase");
    endtask

    task automatic line_end;
        @(negedge clk);
        de = 1'b0;
        @(posedge clk);
        #1;
    endtask

    integer line;
    integer column;
    initial begin
        pxl_cen      = 1'b1;
        hs           = 1'b0;
        vs           = 1'b0;
        de           = 1'b0;
        screen_width = 9'd16;
        screen_height= 9'd8;
        gun1_x       = 9'd4;
        gun1_y       = 9'd4;
        gun2_x       = 9'd12;
        gun2_y       = 9'd4;
        gun1_en      = 1'b1;
        gun2_en      = 1'b0;
        border_en    = 1'b1;
        crosshair_en = 1'b1;
        rgb_in       = 24'h123456;
        rst          = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;

        // Walk five native lines.  The first pixel is a white Sinden border;
        // line four reaches the JTFRAME 8x8 crosshair footprint.
        for (line = 0; line <= 4; line = line + 1) begin
            pixel(24'h123456, 9'd0, line[8:0], 24'hffffff);
            for (column = 1; column < 16; column = column + 1) begin
                if (line == 4 && column == 6)
                    pixel(24'h123456, column[8:0], line[8:0], 24'hffffff);
                else if (line == 4 && (column == 7 || column == 8))
                    pixel(24'h123456, column[8:0], line[8:0], 24'h000000);
                else if (line == 4 && column == 9)
                    pixel(24'h123456, column[8:0], line[8:0], 24'hffffff);
                else
                    pixel(24'h123456, column[8:0], line[8:0],
                          (line == 0 || column == 15) ? 24'hffffff : 24'h123456);
            end
            line_end();
        end

        // Disable both decorations on the next line.  RGB and raster timing
        // must pass through unchanged, including the active x=0 pixel.
        border_en    = 1'b0;
        crosshair_en = 1'b0;
        pixel(24'h0a0b0c, 9'd0, 9'd5, 24'h0a0b0c);

        $display("LIGHTGUN OVERLAY PASS");
        $finish;
    end
endmodule

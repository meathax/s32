module tb_lightgun_overlay_native;
    reg clk;
    reg rst;
    wire ce_pix, hb, vb, hs, vs;
    wire mode_active, vblank_start, vblank_end;
    wire [8:0] hcnt, vcnt;
    wire [8:0] raster_x, raster_y;
    wire [23:0] rgb_out;

    s32_video video (
        .clk(clk), .rst(rst), .mode_416(1'b0),
        .ce_pix(ce_pix), .mode_active(mode_active), .hcnt(hcnt), .vcnt(vcnt),
        .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
        .vblank_start(vblank_start),
        .vblank_end(vblank_end)
    );

    s32_lightgun_overlay #(.BORDER_WIDTH(4)) overlay (
        .clk(clk), .rst(rst), .pxl_cen(ce_pix), .hs(hs), .vs(vs),
        .de(~(hb | vb)), .screen_width(9'd320), .screen_height(9'd224),
        .gun1_x(9'd160), .gun1_y(9'd112), .gun2_x(9'd0), .gun2_y(9'd0),
        .gun1_en(1'b1), .gun2_en(1'b0), .border_en(1'b1),
        .crosshair_en(1'b0), .rgb_in(24'h123456), .rgb_out(rgb_out),
        .raster_x(raster_x), .raster_y(raster_y)
    );

    always #5 clk = ~clk;

    integer active_count;
    integer white_count;
    integer frame_count;
    always @(posedge clk) begin
        if (vblank_start && !vb)
            $fatal(1, "vblank_start did not align with vblank");
        if (ce_pix && !hb && !vb) begin
            if (mode_active || hcnt >= 9'd410 || vcnt >= 9'd262)
                $fatal(1, "unexpected 320-mode timing state");
            if (raster_x >= 9'd320 || raster_y >= 9'd224)
                $fatal(1, "native raster coordinate escaped active bounds");
            active_count <= active_count + 1;
            if (rgb_out == 24'hffffff)
                white_count <= white_count + 1;
        end
        if (vblank_end) begin
            frame_count <= frame_count + 1;
            if (frame_count == 1) begin
                $display("NATIVE active=%0d white=%0d", active_count, white_count);
                if (active_count != 143360 || white_count != 8576)
                    $fatal(1, "native border geometry invalid");
                $display("NATIVE OVERLAY PASS");
                $finish;
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        active_count = 0;
        white_count = 0;
        frame_count = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        #100000000;
        $fatal(1, "timeout");
    end
endmodule

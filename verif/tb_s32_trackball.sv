`timescale 1ns/1ps
module tb_s32_trackball;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg enable = 1'b1;
    reg frame_tick = 1'b0;
    reg cs = 1'b0;
    reg we = 1'b0;
    reg [2:0] player = 3'd0;
    reg [1:0] addr = 2'd0;
    wire [7:0] rdata;
    reg [7:0] p1_x = 8'd0, p1_y = 8'd0;
    reg [7:0] p2_x = 8'd0, p2_y = 8'd0;
    reg [7:0] p3_x = 8'd0, p3_y = 8'd0;
    reg [3:0] p1_dir = 4'd0, p2_dir = 4'd0, p3_dir = 4'd0;
    reg signed [8:0] mouse_dx = 9'sd0, mouse_dy = 9'sd0;
    reg mouse_strobe = 1'b0;
    reg invert_y = 1'b0;

    s32_trackball_adapter dut (
        .clk(clk), .rst(rst), .enable(enable), .frame_tick(frame_tick),
        .cs(cs), .we(we), .player(player), .addr(addr), .rdata(rdata),
        .p1_x(p1_x), .p1_y(p1_y), .p2_x(p2_x), .p2_y(p2_y),
        .p3_x(p3_x), .p3_y(p3_y),
        .p1_dir(p1_dir), .p2_dir(p2_dir), .p3_dir(p3_dir),
        .mouse_dx(mouse_dx), .mouse_dy(mouse_dy),
        .mouse_strobe(mouse_strobe),
        .invert_y(invert_y)
    );

    task automatic frame;
        begin
            @(negedge clk); frame_tick = 1'b1;
            @(posedge clk); #1; frame_tick = 1'b0;
        end
    endtask

    task automatic reset_player(input [2:0] p);
        begin
            @(negedge clk);
            player = p; addr = 2'd0; cs = 1'b1; we = 1'b1;
            @(posedge clk); #1; cs = 1'b0; we = 1'b0;
        end
    endtask

    task automatic mouse_report(input signed [8:0] dx, input signed [8:0] dy);
        begin
            @(negedge clk);
            mouse_dx = dx; mouse_dy = dy; mouse_strobe = 1'b1;
            @(posedge clk); #1; mouse_strobe = 1'b0;
        end
    endtask

    task automatic read_byte(input [2:0] p, input [1:0] a, output [7:0] value);
        begin
            player = p; addr = a; #1; value = rdata;
        end
    endtask

    task automatic expect_byte(input [7:0] got, input [7:0] want, input [255:0] label);
        begin
            if (got !== want) begin
                $display("FAIL %0s got=%02x want=%02x", label, got, want);
                $finish(1);
            end
        end
    endtask

    reg [7:0] value;
    initial begin
        repeat (2) @(posedge clk);
        rst = 1'b0;

        // Native relative reports update immediately. X is reversed while Y
        // remains positive-down, matching the SegaSonic TRACKX/TRACKY map.
        reset_player(3'd0);
        mouse_report(9'sd6, 9'sd2);
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'hfa, "mouse X low");
        read_byte(3'd0, 2'd1, value); expect_byte(value, 8'h0f, "mouse X high");
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'h02, "mouse Y low");
        read_byte(3'd0, 2'd3, value); expect_byte(value, 8'h00, "mouse Y high");
        read_byte(3'd1, 2'd0, value); expect_byte(value, 8'h00, "mouse player 2 isolation");
        read_byte(3'd2, 2'd2, value); expect_byte(value, 8'h00, "mouse player 3 isolation");

        // Reports are accumulated individually, not sampled only at VBlank.
        mouse_report(-9'sd3, 9'sd1);
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'hfd, "mouse burst X");
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'h03, "mouse burst Y");

        // A frame-paced analog sample can coexist with mouse motion without
        // replaying the previous mouse report.
        p1_x = 8'h40;
        frame();
        p1_x = 8'h00;
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'hed, "mouse plus analog X");

        // The adapter gate is a hard boundary for non-trackball profiles.
        enable = 1'b0;
        mouse_report(9'sd20, 9'sd20);
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'h00, "disabled mouse X");
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'h00, "disabled mouse Y");
        enable = 1'b1;

        // Full-right analog motion is +64 input, then the documented X reverse
        // makes the 12-bit counter move -16: 0x1000 - 0x10 = 0xff0.
        p1_x = 8'h40;
        frame();
        p1_x = 8'h00;
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'hf0, "analog X low");
        read_byte(3'd0, 2'd1, value); expect_byte(value, 8'h0f, "analog X high");

        // Positive Y is down; no X/Y cross-talk.
        p1_y = 8'h40;
        frame();
        p1_y = 8'h00;
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'h10, "analog Y low");
        read_byte(3'd0, 2'd3, value); expect_byte(value, 8'h00, "analog Y high");

        // D-pad uses the MAME keydelta-equivalent step and overrides analog.
        reset_player(3'd0);
        p1_dir = 4'b0001; // right in {down,up,left,right}
        frame();
        p1_dir = 4'd0;
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'he2, "dpad X low");
        read_byte(3'd0, 2'd1, value); expect_byte(value, 8'h0f, "dpad X high");

        reset_player(3'd0);
        p1_dir = 4'b1000; // down
        frame();
        p1_dir = 4'd0;
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'h1e, "dpad Y low");

        // Opposing directions cancel, rather than adding a hidden analog step.
        reset_player(3'd0);
        p1_x = 8'h40; p1_dir = 4'b0011;
        frame();
        p1_x = 8'h00; p1_dir = 4'd0;
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'h00, "opposing X cancel");

        // Player 2 has an independent counter window.
        p2_x = 8'h40;
        frame();
        p2_x = 8'h00;
        read_byte(3'd1, 2'd0, value); expect_byte(value, 8'hf0, "player 2 X low");
        read_byte(3'd0, 2'd0, value); expect_byte(value, 8'h00, "player 1 isolation");

        invert_y = 1'b1;
        reset_player(3'd0);
        mouse_report(9'sd0, 9'sd2);
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'hfe, "inverted mouse Y low");
        read_byte(3'd0, 2'd3, value); expect_byte(value, 8'h0f, "inverted mouse Y high");

        reset_player(3'd0);
        p1_y = 8'h40;
        frame();
        p1_y = 8'h00;
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'hf0, "inverted analog Y low");
        read_byte(3'd0, 2'd3, value); expect_byte(value, 8'h0f, "inverted analog Y high");

        reset_player(3'd0);
        p1_dir = 4'b1000;
        frame();
        p1_dir = 4'd0;
        read_byte(3'd0, 2'd2, value); expect_byte(value, 8'he2, "inverted dpad Y low");

        invert_y = 1'b0;

        $display("PASS tb_s32_trackball");
        $finish;
    end
endmodule

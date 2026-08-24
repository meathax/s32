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

    s32_trackball_adapter dut (
        .clk(clk), .rst(rst), .enable(enable), .frame_tick(frame_tick),
        .cs(cs), .we(we), .player(player), .addr(addr), .rdata(rdata),
        .p1_x(p1_x), .p1_y(p1_y), .p2_x(p2_x), .p2_y(p2_y),
        .p3_x(p3_x), .p3_y(p3_y),
        .p1_dir(p1_dir), .p2_dir(p2_dir), .p3_dir(p3_dir)
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

        $display("PASS tb_s32_trackball");
        $finish;
    end
endmodule

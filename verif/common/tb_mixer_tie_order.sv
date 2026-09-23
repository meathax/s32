`timescale 1ns/1ps

module tb_mixer_tie_order;
reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;
reg reg_we = 0;
reg [5:0] reg_addr = 0;
reg [15:0] reg_wdata = 0;
reg [8:0] disp_x = 0;
reg [13:0] nbg0 = 0, nbg1 = 0, nbg3 = 0;
reg [15:0] sprite = 16'hffff;
reg sprite_over_nbg0 = 0;
wire [23:0] rgb;

s32_mixer dut (
    .clk(clk), .rst(rst), .reg_we(reg_we), .reg_addr(reg_addr),
    .reg_wdata(reg_wdata), .reg_be(2'b11), .reg_rdata(),
    .reg_raddr(6'd0), .reg_r4e(), .disp_x(disp_x), .disp_y(9'd0),
    .disp_active(1'b1), .frame_latch(1'b0), .display_en(1'b1),
    .flip_y(1'b0), .layer_off(6'd0),
    .sprite_over_nbg0(sprite_over_nbg0), .bg_ctrl(16'd0),
    .px_text(14'd0), .px_nbg0(nbg0), .px_nbg1(nbg1),
    .px_nbg2(14'd0), .px_nbg3(nbg3), .px_bmp(14'd0),
    .spr_pix(sprite), .pal_addr(), .pal_data(16'd0), .rgb(rgb)
);

task write_reg(input [5:0] address, input [15:0] value);
    @(negedge clk);
    reg_addr = address;
    reg_wdata = value;
    reg_we = 1;
    @(negedge clk);
    reg_we = 0;
endtask

task check_winner(input [3:0] expected, input string label);
    @(negedge clk);
    disp_x = disp_x + 9'd1;
    repeat (5) @(negedge clk);
    if (dut.bestsel_hold !== expected)
        $fatal(1, "%0s: winner=%0d expected=%0d", label,
               dut.bestsel_hold, expected);
endtask

initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    write_reg(6'h10, 16'd0); // text off
    write_reg(6'h13, 16'd0); // NBG2 off
    write_reg(6'h14, 16'd0); // NBG3 off
    write_reg(6'h15, 16'd0); // bitmap off
    write_reg(6'h26, 16'h0009); // shift 13, mask 3

    // Rad Mobile bezel: NBG0 and group-0 car both code E.
    write_reg(6'h00, 16'h000e);
    write_reg(6'h11, 16'h000e);
    write_reg(6'h12, 16'd0);
    nbg0 = 14'h2001;
    sprite = 16'h8001;
    check_winner(4'd1, "Rad Mobile NBG0 bezel");

    // SegaSonic opening: group-0 vehicle and NBG0 terrain both code E.
    // This profile reverses the tie while Rad Mobile keeps its bezel in front.
    sprite_over_nbg0 = 1;
    check_winner(4'd6, "SegaSonic vehicle above NBG0 terrain");
    sprite_over_nbg0 = 0;
    check_winner(4'd1, "Rad Mobile tie restored");

    // SegaSonic player body: group 2 and NBG1 floor both code C.
    write_reg(6'h02, 16'h000c);
    write_reg(6'h11, 16'd0);
    write_reg(6'h12, 16'h000c);
    nbg0 = 0;
    nbg1 = 14'h2002;
    sprite = 16'hc001;
    check_winner(4'd6, "SegaSonic sprite above NBG1");

    write_reg(6'h12, 16'h000d);
    check_winner(4'd2, "higher-priority NBG1");

    // Jurassic Park cave approach: group-0 scenery and NBG3 both code A.
    // The earlier sprite rank 0 exposed only a shrinking rectangular patch
    // of the scenery as NBG3 covered the equal-code sprite pixels.
    write_reg(6'h00, 16'h000a);
    write_reg(6'h12, 16'd0);
    write_reg(6'h14, 16'h036a);
    nbg1 = 0;
    nbg3 = 14'h2003;
    sprite = 16'h8001;
    check_winner(4'd6, "Jurassic Park scenery above NBG3");

    write_reg(6'h14, 16'h036b);
    check_winner(4'd4, "higher-priority NBG3");

    // Alien 3 B1F meat locker: group-2 enemies and NBG0 walls both code B.
    // A global NBG0-first tie order hides the enemies behind the arches.
    write_reg(6'h26, 16'hbe4d); // group from sprite bits 13:12
    write_reg(6'h02, 16'h001b); // group 2 priority B
    write_reg(6'h11, 16'h014b); // NBG0 priority B
    write_reg(6'h14, 16'd0);
    nbg0 = 14'h2001;
    nbg3 = 0;
    sprite = 16'ha001;          // opaque group-2 pixel
    check_winner(4'd1, "default NBG0 tie order");
    sprite_over_nbg0 = 1;
    check_winner(4'd6, "Alien 3 sprite above NBG0");
    write_reg(6'h11, 16'h014c);
    check_winner(4'd1, "Alien 3 higher-priority NBG0");

    $display("MIXER TIE ORDER PASS");
    $finish;
end
endmodule

//============================================================================
// Alien 3 sprite-field workload timing.
//
// A MAME capture of Alien 3 in two-player play (verif/mame object-list dump)
// shows a steady ~103 drawn objects, ~2800 destination rows and ~100k
// destination pixels per field, dominated by a full-screen 8x8 grid of scaled
// background objects.  The dedicated build must render a field of that size
// inside one 60 Hz frame; if it cannot, the sprite controller collapses two
// vblanks into one and consecutive rendered fields land on the SAME object
// list phase, which is what makes Alien 3's alternating P1/P2 HUD flicker even
// with two-field scanout persistence enabled.
//
// This bench renders that workload through the production walker/framebuffer
// and reports the field time in clk_ram cycles against the frame budget.
//============================================================================
`timescale 1ns/1ps

module tb_alien3_load;

// clk_ram = 96.634615 MHz; one 60 Hz frame is 1_610_577 cycles.
localparam integer FRAME_CYCLES = 1610577;
// Sprite ROM read latency in clk_ram cycles (SDRAM round trip + contention).
localparam integer ROM_LATENCY = 16;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

reg [15:0] sram [0:16383];
wire [15:0] slist_addr;
reg  [15:0] slist_q;
always @(posedge clk) slist_q <= sram[slist_addr[13:0]];

// Sprite ROM with a fixed pipeline latency.
wire         srom_req;
wire [23:4]  srom_addr;
reg          srom_ack = 0;
reg  [127:0] srom_data = {32{4'h5}};
reg  [7:0]   rom_wait = 0;
always @(posedge clk) begin
    srom_ack <= 1'b0;
    if (rst) rom_wait <= 0;
    else if (srom_req && !srom_ack) begin
        if (rom_wait == ROM_LATENCY[7:0]) begin
            srom_ack <= 1'b1;
            rom_wait <= 0;
        end
        else rom_wait <= rom_wait + 1'd1;
    end
    else rom_wait <= 0;
end

wire        fbw_start, fbw_valid, fbw_end, fbw_shadow, fbw_busy;
wire [2:0]  fbw_buf;
wire [8:0]  fbw_x;
wire [7:0]  fbw_y;
wire [15:0] fbw_pix;
wire        fbe_req, fbe_ack;
wire [2:0]  fbe_buf;
wire [7:0]  fbe_y;
wire        rendering;

reg present = 0, vblank = 0;
reg [2:0] ctl_addr = 0;
reg [7:0] ctl_wdata = 0;
reg       ctl_we = 0;

s32_sprite #(.POST_VBLANK_CYCLES(8)) sprite (
    .clk(clk), .rst(rst), .is_multi32(1'b0), .retain_previous(1'b1),
    .srom_bank_mask(2'b11),
    .present(present), .vblank(vblank), .rendering(rendering),
    .debug_first_rom_desc(), .debug_first_rom_valid(),
    .debug_last_desc(), .debug_last_draw_desc(),
    .debug_activity(), .debug_state(), .debug_counts(),
    .ctl_we(ctl_we), .ctl_addr(ctl_addr), .ctl_wdata(ctl_wdata),
    .ctl_rdata(), .ctl_raddr(3'd0),
    .slist_addr(slist_addr), .slist_data(slist_q),
    .srom_req(srom_req), .srom_addr(srom_addr),
    .srom_data(srom_data), .srom_ack(srom_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(fbw_buf),
    .fb_wr_x(fbw_x), .fb_wr_y(fbw_y), .fb_wr_valid(fbw_valid),
    .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_busy(fbw_busy),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y),
    .fb_er_ack(fbe_ack), .disp_buf(), .scan_buf(),
    .scan_buf_prev(), .scan_buf_prev2(), .scan_fields()
);

// Scanout runs concurrently: one dual-field line fetch per scanline, exactly
// as s32_core kicks it, so the measurement includes the read bandwidth the
// persistence feature adds.
reg        rd_req = 0;
reg  [7:0] rd_y = 0;
reg  [8:0] rd_x = 0;
wire        rd_ack;
wire [31:0] write_accepts, read_accepts, line_acks;
wire [31:0] max_wr_wait, max_rd_wait, max_er_wait;
wire        deadline_fail;

s32_fb_ddr_model #(.DEADLINE_CYCLES(2000000)) fb (
    .clk(clk), .rst(rst),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(rd_req), .rd_buf(3'd0), .rd_buf_alt(3'd1), .rd_buf_alt2(3'd2),
    .rd_fields(2'd2), .rd_y(rd_y), .rd_ack(rd_ack), .rd_x(rd_x), .rd_pix(),
    .write_accepts(write_accepts), .read_accepts(read_accepts),
    .line_acks(line_acks), .max_wr_wait(max_wr_wait),
    .max_rd_wait(max_rd_wait), .max_er_wait(max_er_wait),
    .deadline_fail(deadline_fail)
);

// One line fetch every 6144 cycles (one 15.7 kHz scanline at clk_ram).
integer scan_phase = 0;
always @(posedge clk) begin
    if (rst) begin
        scan_phase <= 0; rd_req <= 1'b0; rd_y <= 0;
    end
    else begin
        scan_phase <= (scan_phase == 6143) ? 0 : scan_phase + 1;
        if (scan_phase == 0) begin
            rd_req <= 1'b1;
            rd_y   <= rd_y + 1'd1;
        end
        else if (rd_ack) rd_req <= 1'b0;
        rd_x <= (rd_x == 9'd511) ? 9'd0 : rd_x + 1'd1;
    end
end

task write_ctl(input [2:0] a, input [7:0] d);
begin
    @(posedge clk); ctl_we <= 1'b1; ctl_addr <= a; ctl_wdata <= d;
    @(posedge clk); ctl_we <= 1'b0;
end
endtask

// 4bpp object.  Source width is 8*srcw pixels, so srcw = dstw/8 keeps 1:1.
task put_object(input integer entry, input [11:0] xpos, input [11:0] ypos,
                input integer w, input integer h, input integer srcw);
begin
    sram[entry * 8 + 0] = 16'h0000;
    sram[entry * 8 + 1] = {h[7:0], srcw[6:0], 1'b0};
    sram[entry * 8 + 2] = h[15:0] & 16'h03ff;
    sram[entry * 8 + 3] = w[15:0] & 16'h03ff;
    sram[entry * 8 + 4] = {4'h0, ypos};
    sram[entry * 8 + 5] = {4'h0, xpos};
    sram[entry * 8 + 6] = 16'h0000;
    sram[entry * 8 + 7] = 16'h0100;
end
endtask

integer i, gx, gy, e;
integer t_start, t_done, t_drain;
initial begin
    for (i = 0; i < 16384; i = i + 1) sram[i] = 16'hc000;

    // MAME-measured Alien 3 field: 8x8 grid of 40x28 background objects
    // (71,680 px) plus 39 mid-size scene/HUD objects (~29,000 px).
    e = 0;
    for (gy = 0; gy < 8; gy = gy + 1)
        for (gx = 0; gx < 8; gx = gx + 1) begin
            put_object(e, gx[11:0] * 40, gy[11:0] * 28, 40, 28, 5);
            e = e + 1;
        end
    for (i = 0; i < 39; i = i + 1) begin
        put_object(e, 12'd16 + i[11:0] * 6, 12'd60 + (i[11:0] % 5) * 24,
                   24, 32, 3);
        e = e + 1;
    end
    sram[e * 8 + 0] = 16'hc000;
    $display("  workload: %0d objects", e);

    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (6) @(posedge clk);
    write_ctl(3'd3, 8'h00);
    repeat (8) @(posedge clk);

    @(posedge clk); present <= 1'b1;
    repeat (2) @(posedge clk); present <= 1'b0;
    repeat (4) @(posedge clk);
    t_start = $time / 10;
    vblank <= 1'b1;
    repeat (2) @(posedge clk); vblank <= 1'b0;

    wait (rendering === 1'b1);
    wait (rendering === 1'b0);
    t_done = $time / 10;
    wait (fbw_busy === 1'b0);
    t_drain = $time / 10;

    $display("  erase+render+drain = %0d clk_ram cycles", t_drain - t_start);
    $display("  frame budget       = %0d clk_ram cycles", FRAME_CYCLES);
    $display("  field utilisation  = %0d %%",
             (t_drain - t_start) * 100 / FRAME_CYCLES);
    if (t_drain - t_start > FRAME_CYCLES)
        $display("ALIEN3 LOAD OVERRUN: a field does not fit in one frame");
    else
        $display("ALIEN3 LOAD OK");
    $finish;
end

initial begin
    #900000000;
    $display("ALIEN3 LOAD FAIL (timeout)");
    $finish;
end

endmodule

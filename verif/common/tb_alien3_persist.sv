//============================================================================
// Alien 3 field persistence: end-to-end sprite -> framebuffer -> scanout.
//
// Alien 3 emits only ONE player's HUD/sight objects per sprite field and
// alternates them between fields (verified against MAME's object list).  The
// dedicated build therefore retains preceding completed fields and folds them
// into scanout.  This bench drives that pattern through the real s32_sprite
// walker, the real s32_fb_if and a stalling DDR model:
//
//   * every field draws a common "scene" object at x=64
//   * even fields additionally draw the "P1" object at x=8
//   * odd  fields additionally draw the "P2" object at x=32
//
// After the third publication a merged scanline must contain the scene AND
// both player objects.  A single-field scanout shows only one of them.
//============================================================================
`timescale 1ns/1ps

module tb_alien3_persist;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

// ---------------------------------------------------------------------------
// Sprite list RAM (spriteram is 0x10000 words; the bench only uses entry 0..3)
// ---------------------------------------------------------------------------
reg [15:0] sram [0:16383];
wire [15:0] slist_addr;
reg  [15:0] slist_q;
always @(posedge clk) slist_q <= sram[slist_addr[13:0]];

// Sprite ROM: constant 4bpp pattern of pen 5 (neither pen 0 nor the 0xf end
// code), so every fetched row paints solid, non-transparent pixels.
wire         srom_req;
wire [23:4]  srom_addr;
reg          srom_ack = 0;
reg  [127:0] srom_data = {32{4'h5}};
always @(posedge clk) srom_ack <= srom_req;

// ---------------------------------------------------------------------------
// DUTs
// ---------------------------------------------------------------------------
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow, fbw_busy;
wire [2:0]  fbw_buf;
wire [8:0]  fbw_x;
wire [7:0]  fbw_y;
wire [15:0] fbw_pix;
wire        fbe_req, fbe_ack;
wire [2:0]  fbe_buf;
wire [7:0]  fbe_y;
wire [1:0]  disp_buf;
wire [2:0]  scan_buf, scan_buf_prev, scan_buf_prev2;
wire [1:0]  scan_fields;
wire        rendering;

reg present = 0;
reg vblank  = 0;
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
    .fb_er_ack(fbe_ack), .disp_buf(disp_buf), .scan_buf(scan_buf),
    .scan_buf_prev(scan_buf_prev), .scan_buf_prev2(scan_buf_prev2),
    .scan_fields(scan_fields)
);

reg        rd_req = 0;
reg  [7:0] rd_y   = 0;
reg  [8:0] rd_x   = 0;
wire        rd_ack;
wire [15:0] rd_pix;
wire [31:0] write_accepts, read_accepts, line_acks;
wire [31:0] max_wr_wait, max_rd_wait, max_er_wait;
wire        deadline_fail;

s32_fb_ddr_model #(.DEADLINE_CYCLES(200000)) fb (
    .clk(clk), .rst(rst),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(rd_req), .rd_buf(scan_buf), .rd_buf_alt(scan_buf_prev),
    .rd_buf_alt2(scan_buf_prev2), .rd_fields(scan_fields),
    .rd_y(rd_y), .rd_ack(rd_ack),
    .rd_x(rd_x), .rd_pix(rd_pix),
    .write_accepts(write_accepts), .read_accepts(read_accepts),
    .line_acks(line_acks), .max_wr_wait(max_wr_wait),
    .max_rd_wait(max_rd_wait), .max_er_wait(max_er_wait),
    .deadline_fail(deadline_fail)
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
integer errors = 0;

task write_ctl(input [2:0] a, input [7:0] d);
begin
    @(posedge clk); ctl_we <= 1'b1; ctl_addr <= a; ctl_wdata <= d;
    @(posedge clk); ctl_we <= 1'b0;
end
endtask

// One 8x8 4bpp object.  srcw=1 => 8 source pixels wide, srch=8 rows.
task put_object(input integer entry, input [11:0] xpos, input [11:0] ypos);
begin
    sram[entry * 8 + 0] = 16'h0000;      // draw, 4bpp, transp pen 0xf
    sram[entry * 8 + 1] = 16'h0802;      // srch=8, srcw=1
    sram[entry * 8 + 2] = 16'h0008;      // dsth=8
    sram[entry * 8 + 3] = 16'h0008;      // dstw=8
    sram[entry * 8 + 4] = {4'h0, ypos};
    sram[entry * 8 + 5] = {4'h0, xpos};
    sram[entry * 8 + 6] = 16'h0000;      // source address
    sram[entry * 8 + 7] = 16'h0100;      // colour bank
end
endtask

task put_end(input integer entry);
begin
    sram[entry * 8 + 0] = 16'hc000;
end
endtask

// Build the object list for a field: scene + the player whose turn it is.
// `variant` nudges the scene object so successive lists differ even when the
// same player is emitted twice, exactly as a moving scene does on hardware.
task build_list(input integer parity, input integer variant);
begin
    put_object(0, 12'd64 + variant[11:0], 12'd8);       // shared scene object
    put_object(1, parity ? 12'd32 : 12'd8, 12'd8);      // alternating player
    put_end(2);
end
endtask

task pulse_frame;
begin
    @(posedge clk); present <= 1'b1;
    repeat (2) @(posedge clk);
    present <= 1'b0;
    repeat (4) @(posedge clk);
    vblank <= 1'b1;
    repeat (2) @(posedge clk);
    vblank <= 1'b0;
end
endtask

integer field_variant = 0;
task run_field(input integer parity, input integer moving);
begin
    if (moving) field_variant = field_variant + 1;
    build_list(parity, field_variant);
    pulse_frame();
    wait (sprite.rs !== 0);
    wait (sprite.rs === 0);
    wait (fbw_busy === 1'b0);
    repeat (40) @(posedge clk);
end
endtask

// Fetch one display line through the production read port, then publish it by
// wrapping rd_x, exactly as the mixer's hcnt does.
task fetch_line(input [7:0] y);
begin
    rd_y <= y; rd_req <= 1'b1;
    @(posedge rd_ack);
    rd_req <= 1'b0;
    wait (!rd_ack);
    rd_x = 9'd511; @(posedge clk);
    rd_x = 9'd0;   @(posedge clk);
end
endtask

function automatic is_solid(input [15:0] p);
    is_solid = ((p & 16'h7fff) != 16'h7fff);
endfunction

task check_pixel(input [8:0] x, input expect_solid, input [255:0] name);
    reg [15:0] p;
begin
    rd_x = x; @(posedge clk); #1; p = rd_pix;
    if (is_solid(p) !== expect_solid) begin
        errors = errors + 1;
        $display("  FAIL %0s at x=%0d: pix=%04x (expected %0s)", name, x, p,
                 expect_solid ? "solid" : "transparent");
    end
end
endtask

integer i;
initial begin
    for (i = 0; i < 16384; i = i + 1) sram[i] = 16'hc000;

    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (6) @(posedge clk);

    // Automatic mode, render every field (ctl[3] = 0 => command 2'b11).
    write_ctl(3'd3, 8'h00);
    repeat (8) @(posedge clk);

    // Four fields: P1, P2, P1, P2.  After the second publication the retained
    // field is live, so fields 3 and 4 must both scan out as a merged pair.
    run_field(0, 0);
    run_field(1, 0);
    run_field(0, 0);
    run_field(1, 0);

    if (scan_fields == 2'd0) begin
        errors = errors + 1;
        $display("  FAIL field persistence never engaged");
    end
    $display("  scan_buf=%0d prev=%0d prev2=%0d fields=%0d",
             scan_buf, scan_buf_prev, scan_buf_prev2, scan_fields);

    // The newest field carries the P2 object at x=32; the retained field
    // carries P1 at x=8.  Both must survive the merge, and so must the scene.
    // Objects land at xpos-3 .. xpos+4 (the System 32 sprite origin offset).
    fetch_line(8'd8);
    check_pixel(9'd3,  1'b0, "gap before P1");
    check_pixel(9'd8,  1'b1, "P1 object (retained field)");
    check_pixel(9'd12, 1'b1, "P1 object (retained field)");
    check_pixel(9'd24, 1'b0, "gap between players");
    check_pixel(9'd32, 1'b1, "P2 object (newest field)");
    check_pixel(9'd36, 1'b1, "P2 object (newest field)");
    check_pixel(9'd50, 1'b0, "gap before scene");
    check_pixel(9'd64, 1'b1, "scene object");
    check_pixel(9'd68, 1'b1, "scene object");

    // One more field flips which player is newest; the merge must still show
    // both, proving the retention is not phase-dependent.
    run_field(0, 0);
    fetch_line(8'd8);
    check_pixel(9'd8,  1'b1, "P1 object after flip");
    check_pixel(9'd32, 1'b1, "P2 object after flip");
    check_pixel(9'd64, 1'b1, "scene object after flip");

    // ---- Repeated object list ----------------------------------------------
    // Alien 3 alternates the two players once per GAME LOGIC frame, not once
    // per sprite field.  Whenever the V60 misses a frame the identical object
    // list is walked twice, so two consecutive rendered fields carry the SAME
    // player.  Retaining the immediately preceding field then merges P1 with
    // P1 and the other player's HUD/sight vanishes -- the flicker that survives
    // plain two-field persistence.  Retention must therefore fall back to the
    // most recent field whose object list actually differed.
    // A field is published at the FOLLOWING start-of-vblank, so one extra pass
    // is needed for the duplicated pair to reach scanout.
    run_field(0, 0);
    run_field(0, 0);
    run_field(1, 0);
    run_field(1, 0);
    run_field(1, 0);
    $display("  repeat-phase scan_buf=%0d prev=%0d prev2=%0d fields=%0d",
             scan_buf, scan_buf_prev, scan_buf_prev2, scan_fields);
    fetch_line(8'd8);
    check_pixel(9'd8,  1'b1, "P1 object across a repeated list");
    check_pixel(9'd32, 1'b1, "P2 object across a repeated list");
    check_pixel(9'd64, 1'b1, "scene object across a repeated list");

    // ---- Held phase across a changing list -------------------------------
    // When the V60 runs behind, Alien 3 keeps rebuilding the object list every
    // frame (the scene still moves) but only advances the P1/P2 selector once
    // per completed logic frame, so each player is emitted TWICE in a row with
    // a different list each time.  Retaining a single preceding field then
    // merges a player with itself; the retained window must be deep enough to
    // still reach the other player.
    run_field(0, 1);
    run_field(0, 1);
    run_field(1, 1);
    run_field(1, 1);
    run_field(0, 1);
    $display("  hold-phase scan_buf=%0d prev=%0d prev2=%0d fields=%0d",
             scan_buf, scan_buf_prev, scan_buf_prev2, scan_fields);
    fetch_line(8'd8);
    check_pixel(9'd8,  1'b1, "P1 object across a held phase");
    check_pixel(9'd32, 1'b1, "P2 object across a held phase");

    if (errors == 0) $display("ALIEN3 PERSIST PASS");
    else             $display("ALIEN3 PERSIST FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #400000000;
    $display("ALIEN3 PERSIST FAIL (timeout)");
    $finish;
end

endmodule

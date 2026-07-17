//============================================================================
//  Directed test: s32_sprite pixel path (V-8 exact pen semantics)
//   1. 1:1 4bpp direct draw: nibble order (bits31:28 leftmost), positions
//   2. pen 0 never drawn (direct); pen F transparent only first/last of word
//   3. end code: word ending in F terminates the row (next word not drawn)
//   4. flipx: destination sweep reversed, source order preserved
//   5. 2x horizontal zoom: each source pixel doubled
//   6. indirect (inline table): transmask decides transparency, entry drawn
//   7. shadow sprite: run flagged fb_wr_shadow
//============================================================================
`timescale 1ns/1ps

module tb_sprite;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

// control port
reg       ctl_we = 0;
reg [2:0] ctl_addr = 0;
reg [7:0] ctl_wdata = 0;

// sprite RAM model (registered read, 1-clk lag like s32_core)
reg [15:0] sram [0:16383];
wire [15:0] slist_addr;
reg  [15:0] slist_q;
always @(posedge clk) slist_q <= sram[slist_addr[13:0]];

// sprite ROM model: 128-bit chunks indexed by chunk address
reg [127:0] rom128 [0:255];
wire        srom_req;
wire [23:4] srom_addr;
reg         srom_ack;
reg [127:0] srom_data;
always @(posedge clk) begin
    srom_ack  <= srom_req;
    srom_data <= rom128[srom_addr[11:4]];
end

// framebuffer capture
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow;
wire [8:0]  fbw_x;
wire [7:0]  fbw_y;
wire [15:0] fbw_pix;
wire        fbe_req;
reg         fbe_ack;
always @(posedge clk) fbe_ack <= fbe_req;

reg [15:0] fbcap [0:511];       // pixel values by x (single test row)
reg        fbsh  [0:511];       // captured with shadow flag
integer    fbcnt = 0;
reg        run_shadow = 0;
integer ci;
always @(posedge clk) begin
    if (fbw_start) run_shadow <= fbw_shadow;
    if (fbw_valid) begin
        fbcap[fbw_x] <= fbw_pix;
        fbsh[fbw_x]  <= run_shadow | fbw_shadow;
        fbcnt = fbcnt + 1;
    end
end

reg vblank = 0;

s32_sprite dut (
    .clk(clk), .rst(rst), .is_multi32(1'b0),
    .vblank(vblank), .rendering(),
    .ctl_we(ctl_we), .ctl_addr(ctl_addr), .ctl_wdata(ctl_wdata),
    .ctl_rdata(), .ctl_raddr(3'd0),
    .slist_addr(slist_addr), .slist_data(slist_q),
    .srom_req(srom_req), .srom_addr(srom_addr),
    .srom_data(srom_data), .srom_ack(srom_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(), .fb_wr_x(fbw_x), .fb_wr_y(fbw_y),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_busy(1'b0),
    .fb_er_req(fbe_req), .fb_er_buf(), .fb_er_y(), .fb_er_ack(fbe_ack),
    .disp_buf(), .mode_416(1'b0)
);

// write one list entry (8 words at entry*8)
task entry(input [13:0] e, input [15:0] w0, w1, w2, w3, w4, w5, w6, w7);
    sram[{e[10:0], 3'd0}]      = w0; sram[{e[10:0], 3'd0} + 1] = w1;
    sram[{e[10:0], 3'd0} + 2]  = w2; sram[{e[10:0], 3'd0} + 3] = w3;
    sram[{e[10:0], 3'd0} + 4]  = w4; sram[{e[10:0], 3'd0} + 5] = w5;
    sram[{e[10:0], 3'd0} + 6]  = w6; sram[{e[10:0], 3'd0} + 7] = w7;
endtask

task wctl(input [2:0] a, input [7:0] d);
    @(posedge clk); ctl_we <= 1; ctl_addr <= a; ctl_wdata <= d;
    @(posedge clk); ctl_we <= 0;
endtask

// run one frame: pulse vblank, wait for the walker to finish
task frame;
    integer k;
    for (k = 0; k < 512; k = k + 1) begin fbcap[k] = 16'hFFFF; fbsh[k] = 0; end
    fbcnt = 0;
    @(posedge clk); vblank <= 1;
    @(posedge clk); vblank <= 0;
    wait (dut.rendering === 1'b1);
    wait (dut.rendering === 1'b0);
    repeat (8) @(posedge clk);
endtask

integer errors = 0;
task check(input [8:0] x, input [15:0] want);
    if (fbcap[x] !== want) begin
        errors = errors + 1;
        $display("  FAIL x=%0d pix=%04x want=%04x", x, fbcap[x], want);
    end
endtask

// common fields: draw, 4bpp, srch=1, srcw=1 word, dsth=1, ax/ay=start(2'b10)
localparam [15:0] W0_PLAIN  = 16'h000A;              // ay=10 ax=10
localparam [15:0] W1_1x1    = 16'h0102;              // srch=1, srcw=1 (bits6:1)
localparam [15:0] COLOR     = 16'h0100;              // palette bits -> 0x8100 | pen

initial begin
    repeat (6) @(posedge clk);
    rst = 0;
    repeat (2) @(posedge clk);

    // sprite pixel data at word addr 0 (chunk 0): 0x12345678 -> pens 1..8
    // little-endian byte packing, BE word: bytes 12 34 56 78
    rom128[0] = 128'h0; rom128[0][31:0] = 32'h78563412;
    // word addr 1 (bytes 4-7): 0x1F0F0F3F -> pens 1,F,0,F,0,F,3,F (end code F)
    rom128[0][63:32] = 32'h3F0F0F1F;
    // word addr 2: 0x10203040 pens 1,0,2,0,3,0,4,0
    rom128[0][95:64] = 32'h40302010;

    // ---- 1: plain 1:1, xpos=100 ypos=10: pens 1..8 at x=100..107 ----
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0000, COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    check(100, 16'h8101); check(101, 16'h8102); check(102, 16'h8103);
    check(103, 16'h8104); check(104, 16'h8105); check(105, 16'h8106);
    check(106, 16'h8107); check(107, 16'h8108);
    check(99, 16'hFFFF);  check(108, 16'hFFFF);

    // ---- 2: pen 0 skipped everywhere, pen F drawn ONLY mid-word ----
    // word addr 2: pens 1,0,2,0,3,0,4,0 -> zeros never drawn
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0002, COLOR);
    frame;
    check(100, 16'h8101); check(101, 16'hFFFF); check(102, 16'h8102);
    check(103, 16'hFFFF); check(104, 16'h8103); check(105, 16'hFFFF);
    check(106, 16'h8104); check(107, 16'hFFFF);
    // word addr 1: pens 1,F,0,F,0,F,3,F: F at first(pos0)? pos0 pen=1 drawn;
    // F at positions 1,3,5 are MID-word -> drawn; last F transparent+endcode
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0001, COLOR);
    frame;
    check(100, 16'h8101); check(101, 16'h810F); check(102, 16'hFFFF);
    check(103, 16'h810F); check(104, 16'hFFFF); check(105, 16'h810F);
    check(106, 16'h8103); check(107, 16'hFFFF);

    // ---- 3: end code terminates the row: srcw=2 words, dstw=16; word0
    // ends in 8 (no code) -> continues; use words 1(themed F end)+2:
    // src = word1, word2: row should STOP after word1 (last pen F) ----
    entry(0, W0_PLAIN, 16'h0104, 16'h0001, 16'h0010, 16'd10, 16'd100, 16'h0001, COLOR);
    frame;
    check(106, 16'h8103);          // inside word 1
    check(108, 16'hFFFF);          // word 2 never drawn (row ended)
    check(110, 16'hFFFF);

    // ---- 4: flipx: pens 1..8 mirrored to x=107..100 ----
    entry(0, W0_PLAIN | 16'h0040, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0000, COLOR);
    frame;
    check(107, 16'h8101); check(106, 16'h8102); check(105, 16'h8103);
    check(104, 16'h8104); check(103, 16'h8105); check(102, 16'h8106);
    check(101, 16'h8107); check(100, 16'h8108);

    // ---- 5: 2x zoom: dstw=16 -> each pen doubled ----
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0010, 16'd10, 16'd100, 16'h0000, COLOR);
    frame;
    check(100, 16'h8101); check(101, 16'h8101);
    check(102, 16'h8102); check(103, 16'h8102);
    check(114, 16'h8108); check(115, 16'h8108);

    // ---- 6: indirect inline table: entry pen1 = 0x1234 (drawn),
    // pen2 = 0x7fff == transmask(ctl4=0,ctl5=0) -> transparent ----
    entry(0, W0_PLAIN | 16'h3000, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0002, 16'h0000);
    // inline table = entries 1..2 (16 words after the 8-entry words)
    sram[{11'd0,3'd0}+8+1]  = 16'h1234;   // pen 1
    sram[{11'd0,3'd0}+8+2]  = 16'h7fff;   // pen 2 -> transparent
    sram[{11'd0,3'd0}+8+3]  = 16'h0345;   // pen 3
    sram[{11'd0,3'd0}+8+4]  = 16'h0456;   // pen 4
    entry(3, 16'hC000, 0,0,0,0,0,0,0);    // list end AFTER skipped table
    frame;
    // src word 2: pens 1,0,2,0,3,0,4,0; pen0 entry = sram[..+8] (X? default 0)
    // set pen0 entry explicitly to transparent
    // (already checked below: pens 1,3,4 drawn; pen 2 transparent)
    check(100, 16'h1234); check(102, 16'hFFFF);
    check(104, 16'h0345); check(106, 16'h0456);

    // ---- 7: shadow sprite: fb_wr_shadow flagged for the run ----
    wctl(3'd5, 8'h01);                    // shadow enable (reg 5 bit 0)
    entry(0, W0_PLAIN | 16'h0800, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0000, COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    if (!fbsh[100] || !fbsh[107]) begin
        errors = errors + 1;
        $display("  FAIL shadow run not flagged (sh100=%0d sh107=%0d)", fbsh[100], fbsh[107]);
    end

    if (errors == 0) $display("SPRITE PASS");
    else             $display("SPRITE FAIL (%0d errors)", errors);
    $finish;
end

// pen0's indirect entry must not accidentally draw: init inline table area
integer ii;
initial begin
    for (ii = 0; ii < 16384; ii = ii + 1) sram[ii] = 16'h7fff;
end

initial begin
    #4000000;
    $display("SPRITE FAIL (timeout)");
    $finish;
end

endmodule

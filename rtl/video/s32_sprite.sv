//============================================================================
//  System 32 sprite engine — 315-5386A (DESIGN.md §6.3/§6.4, Appendix C.6/C.7)
//  Walks the sprite command list in sprite RAM, renders scaled sprites into
//  the off-chip framebuffer via s32_fb_if. Double-buffered; swap/erase per
//  control regs, latched at swap exactly like m_sprite_control_latched.
//
//  Sprite list entry (8 words) — DESIGN.md §6.3.
//  Framebuffer pixel = 0x8000 | color | pen ; shadow clears bit15.
//============================================================================

module s32_sprite (
    input             clk,          // clk_ram
    input             rst,
    input             is_multi32,

    // frame control
    input             vblank,       // start-of-vblank pulse
    output reg        rendering,

    // Observation-only descriptor captured for the first production sprite
    // ROM request after reset. No renderer state depends on these outputs.
    output reg [127:0] debug_first_rom_desc,
    output reg         debug_first_rom_valid,

    // sprite control registers (0x500000, byte regs 0..7)
    input             ctl_we,
    input       [2:0] ctl_addr,
    input       [7:0] ctl_wdata,
    output reg  [7:0] ctl_rdata,
    input       [2:0] ctl_raddr,

    // sprite RAM read port (word)
    output reg [15:0] slist_addr,
    input      [15:0] slist_data,

    // sprite ROM via SDRAM p2 port (128-bit bursts)
    output reg        srom_req,
    output reg [23:4] srom_addr,
    input     [127:0] srom_data,
    input             srom_ack,

    // framebuffer interface
    output reg        fb_wr_start,
    output reg  [1:0] fb_wr_buf,
    output reg  [8:0] fb_wr_x,
    output reg  [7:0] fb_wr_y,
    output reg        fb_wr_valid,
    output reg [15:0] fb_wr_pix,
    output reg        fb_wr_end,
    output reg        fb_wr_shadow,  // this run RMWs dest &= 0x7fff (V-10)
    input             fb_busy,       // previous run still flushing
    output reg        fb_er_req,
    output reg  [1:0] fb_er_buf,
    output reg  [7:0] fb_er_y,
    input             fb_er_ack,

    output reg  [1:0] disp_buf,     // which buffer pair the mixer reads
    input             mode_416
);

// control registers
reg [7:0] ctl [0:7];
reg [7:0] ctl_latched [0:7];
reg       frame_toggle;             // for 30Hz auto mode
reg       render_after_erase;       // combined command: erase, then swap/render
wire      erase_busy;

always @(*) begin
    case (ctl_raddr)
        3'd0: ctl_rdata = {6'h3f, erase_busy, disp_buf[0]};
        3'd1: ctl_rdata = {6'h3f, 2'd1};              // status: normal
        3'd2: ctl_rdata = {6'h3f, ctl_latched[2][1:0]};
        3'd3: ctl_rdata = {6'h3f, ctl_latched[3][1:0]};
        3'd4: ctl_rdata = {6'h3f, ctl_latched[4][1:0]};
        3'd5: ctl_rdata = {6'h3f, ctl_latched[5][1:0]};
        3'd6: ctl_rdata = {6'h3f, 1'b0, ctl_latched[6][0]};
        default: ctl_rdata = 8'hfc;
    endcase
end

// list walker / renderer FSM
typedef enum logic [4:0] {
    R_IDLE, R_SWAP, R_ERASE, R_ERASEW,
    R_FETCH, R_FETCHP, R_FETCHW, R_DECODE, R_SCALE,
    R_INDTAB, R_INDTABP, R_INDTABW,
    R_ROW, R_ROWDATA, R_ROWDATAW,
    R_RAMDATA, R_RAMDATAP, R_RAMDATAW,
    R_PIXEL, R_EMIT, R_ROWEND,
    R_NEXT, R_DONE
} rst_t;
rst_t rs;
assign erase_busy = (rs == R_ERASE || rs == R_ERASEW);

// latched sprite entry
reg [15:0] sw [0:7];
reg [2:0]  swi;
reg [12:0] list_idx;                 // entry index (16-byte units)
// The hardware reports an overdraw condition when list processing runs past
// its budget.  MAME's controller model bounds a frame to the 0x20000-byte
// sprite RAM divided by one 16-byte command (8192 commands).  Without the
// same bound, a missing END or a self-referential JUMP traps this FSM forever
// and leaves the last displayed framebuffer frozen while the V60 keeps going.
reg [13:0] list_count;
reg [15:0] clip_l, clip_t, clip_r, clip_b;   // in-clip rect
reg        clip_en, clipout_en;
reg [15:0] cout_l, cout_t, cout_r, cout_b;
reg [31:0] jump_xoff, jump_yoff;

// decoded fields
wire        d_ind    = sw[0][13];
wire        d_indloc = sw[0][12];
wire        d_shad   = sw[0][11] & ctl_latched[5][0]; // reg 0x0a bit0
wire        d_fromram= sw[0][10];
wire        d_bpp8   = sw[0][9];
wire        d_opaque = sw[0][8];
wire        d_flipy  = sw[0][7];
wire        d_flipx  = sw[0][6];
wire [1:0]  d_ay     = sw[0][3:2];
wire [1:0]  d_ax     = sw[0][1:0];
wire [7:0]  d_srch   = sw[1][15:8];
wire [5:0]  d_srcw   = d_bpp8 ? sw[1][5:0] : sw[1][6:1];
wire [9:0]  d_dsth   = sw[2][9:0];
wire [9:0]  d_dstw   = sw[3][9:0];
wire [1:0]  d_bank   = is_multi32 ? {sw[3][15], sw[3][13]} : {sw[3][14], sw[3][11]};
wire        d_mon    = is_multi32 & sw[3][11];
wire [11:0] d_ypos   = sw[4][11:0];
wire [11:0] d_xpos   = sw[5][11:0];
wire [19:0] d_addr   = {sw[2][15:12], sw[6]};
wire [15:0] d_color  = 16'h8000 | (sw[7] & (d_bpp8 ? 16'h7f00 : 16'h7ff0));

// scaling accumulators
reg [24:0] yacc, ystep;   // MAME controller model uses 16.16 zoom
reg [24:0] xacc, xstep;
reg [9:0]  dy, dx;        // dest iterators
reg [12:0] sx;
reg signed [13:0] x0, y0; // wide MAME int-domain origin; no 12-bit wrap
reg [15:0] indtab [0:15];
reg [3:0]  indi;
reg [127:0] pixrow;
reg [23:4]  rowbase;
reg [23:0] row_byte_base; // sprite base + source-row pitch, once per row
reg [15:0] ram_fetch_base;
reg [2:0]  ram_fetch_i;
reg [15:0] ram_even;

// simple per-row source fetch cache tag
reg [23:4] rowtag;
reg        rowtag_v;

// V-8 exact pen semantics state
reg [15:0] transmask_r;    // indirect transparency mask (ctl regs 4/5)
reg        do_clipout_row; // clip-out rect covers this row's y
reg [9:0]  last_word_r;    // last source 32-bit word visited (end codes)
reg [1:0]  last_wic_r;     // its position within the 128-bit chunk
reg        word_valid_r;

// Pixel address/position stage.  R_PIXEL verifies the source cache and
// registers these inexpensive coordinates; R_EMIT performs the wide dynamic
// pen select, transparency/clip tests, and framebuffer write one clock later.
// This removes the x-scale accumulator from the full decode/output path.
reg signed [13:0] pixel_scrx;
reg        [9:0]  pixel_sx_px;
reg        [2:0]  pixel_piw, pixel_piw_last;
reg        [9:0]  pixel_wordi;
reg        [23:0] pixel_byteaddr;

wire [8:0] hpix = mode_416 ? 9'd416 : 9'd320;
wire [9:0] d_dstw_center = (d_dstw - 10'd1) >> 1;
wire [9:0] d_dsth_center = (d_dsth - 10'd1) >> 1;

// A combinational 20-by-10 divide here makes Quartus expand two very large
// divider networks while elaborating the sprite engine.  Scaling setup is not
// on the pixel-rate path, so share one restoring divider across Y then X.
// The 25-bit numerators preserve MAME's unsigned 16.16 controller math.
wire [24:0] scale_ynum = {1'b0, d_srch, 16'b0};
wire [24:0] scale_xnum = d_bpp8 ? {1'b0, d_srcw, 18'b0}
                                     : {d_srcw, 19'b0};
wire        scale_start = (rs == R_DECODE) && (sw[0][15:14] == 2'b00) &&
                          (d_srcw != 0) && (d_srch != 0) &&
                          (d_dstw != 0) && (d_dsth != 0);
wire        scale_busy, scale_done;
wire [24:0] scale_yquot, scale_xquot;

s32_sprite_scale_div scale_div (
    .clk(clk), .rst(rst), .start(scale_start),
    .ynum(scale_ynum), .yden(d_dsth),
    .xnum(scale_xnum), .xden(d_dstw),
    .busy(scale_busy), .done(scale_done),
    .yquot(scale_yquot), .xquot(scale_xquot)
);

// MAME transparency_masks[ctl4 & 3][ctl5 & 3]
function automatic [15:0] transmask_of(input [1:0] row, input [1:0] col);
    logic [15:0] base;
    case (col)
        2'b00: base = 16'h7fff; 2'b01: base = 16'h3fff;
        2'b10: base = 16'h1fff; default: base = 16'h0fff;
    endcase
    case (row)
        2'b00:   transmask_of = base;
        2'b11:   transmask_of = base >> 2;
        default: transmask_of = base >> 1;
    endcase
endfunction

function automatic [11:0] sext12(input [11:0] v);
    sext12 = v;
endfunction

always @(posedge clk) begin
    if (rst) begin
        rs <= R_IDLE; rendering <= 0; disp_buf <= 0;
        debug_first_rom_desc <= 128'd0;
        debug_first_rom_valid <= 1'b0;
        list_count <= 0;
        srom_req <= 0; fb_er_req <= 0;
        fb_wr_valid <= 0; fb_wr_start <= 0; fb_wr_end <= 0;
        fb_wr_shadow <= 0;
        frame_toggle <= 0; render_after_erase <= 0;
        jump_xoff <= 0; jump_yoff <= 0;
        // control regs power up cleared (auto swap mode) — leaving them
        // uninitialized stalls the walker in R_IDLE until the game writes them
        for (int i = 0; i < 8; i++) begin
            ctl[i] <= 8'h00; ctl_latched[i] <= 8'h00;
        end
    end
    else begin
        fb_wr_start <= 0;
        fb_wr_valid <= 0;
        fb_wr_end   <= 0;

        // CPU control writes
        if (ctl_we) begin
            ctl[ctl_addr] <= ctl_wdata;
        end

        case (rs)
        R_IDLE: if (vblank) begin
            logic [1:0] command;
            // reg0 bit1 erases the currently displayed buffer; bit0 swaps
            // buffers and renders a new list. In automatic mode the
            // controller synthesizes command 3 immediately, then every other
            // frame when 30 Hz mode is selected.
            command = ctl[0][1:0];
            if (!ctl[3][1]) begin
                command = (!ctl[3][0] || !frame_toggle) ? 2'b11 : 2'b00;
                frame_toggle <= ~frame_toggle;
            end
            ctl[0] <= 0;
            if (command[1]) begin
                render_after_erase <= command[0];
                rendering <= 1'b0;
                fb_er_y <= 0;
                rs <= R_ERASE;
            end
            else if (command[0]) begin
                render_after_erase <= 1'b0;
                rs <= R_SWAP;
            end
        end

        R_SWAP: begin
            disp_buf <= disp_buf + 1'd1;     // swap front/back
            for (int i = 0; i < 8; i++) ctl_latched[i] <= ctl[i];
            ctl[0] <= 0;
            render_after_erase <= 1'b0;
            rendering <= 1'b1;
            list_idx <= 0;
            list_count <= 0;
            jump_xoff <= 0; jump_yoff <= 0;
            clip_en <= 0; clipout_en <= 0;
            clip_l <= 0; clip_t <= 0;
            clip_r <= {7'b0, 9'd511}; clip_b <= 16'd255;
            rs <= R_FETCH;
        end
        R_ERASE: begin
            fb_er_req <= 1'b1;
            fb_er_buf <= {1'b0, disp_buf[0]}; // erase currently visible screen A
            rs <= R_ERASEW;
        end
        R_ERASEW: if (fb_er_ack) begin
            fb_er_req <= 0;
            if (fb_er_y == 8'd223) begin
                rs <= render_after_erase ? R_SWAP : R_DONE;
            end
            else begin
                fb_er_y <= fb_er_y + 1'd1;
                rs <= R_ERASE;
            end
        end

        // fetch 8 words of the current entry
        // (slist_data is a registered BRAM read: q lags addr by one clk,
        //  so prime the pipeline one cycle before sampling)
        R_FETCH: begin
            swi <= 0;
            slist_addr <= {list_idx, 3'b000};
            rs <= R_FETCHP;
        end
        R_FETCHP: begin
            slist_addr <= {list_idx, 3'b000} + 16'd1;
            rs <= R_FETCHW;
        end
        R_FETCHW: begin
            sw[swi] <= slist_data;   // = mem[base+swi]
            if (swi == 3'd7) rs <= R_DECODE;
            else begin
                swi <= swi + 1'd1;
                slist_addr <= {list_idx, 3'b000} + swi + 16'd2;
            end
        end

        R_DECODE: begin
            if (list_count == 14'd8192) begin
                // Bounded-list overdraw: abandon this frame and return to
                // R_IDLE so the next vblank can start a fresh sprite pass.
                rendering <= 1'b0;
                rs <= R_DONE;
            end
            else begin
            list_count <= list_count + 1'd1;
            case (sw[0][15:14])
            2'b11: begin rendering <= 0; rs <= R_DONE; end       // end of list
            2'b10: begin                                          // jump
                if (sw[0][13]) begin
                    jump_yoff <= {20'b0, sw[1][11:0]};
                    jump_xoff <= {20'b0, sw[2][11:0]};
                end
                list_idx <= sw[0][12:0];
                rs <= R_FETCH;
            end
            2'b01: begin                                          // set clip
                // MAME: bit12 of word0 gates clip-in (words 0-3: y0,y1,x0,x1
                // sext12); bit13 gates clip-out (words 4-7)
                if (sw[0][12]) begin
                    clip_en <= 1'b1;
                    clip_t <= {{4{sw[0][11]}}, sw[0][11:0]};
                    clip_b <= {{4{sw[1][11]}}, sw[1][11:0]};
                    clip_l <= {{4{sw[2][11]}}, sw[2][11:0]};
                    clip_r <= {{4{sw[3][11]}}, sw[3][11:0]};
                end
                // MAME changes clip-out only when bit 13 is set.  A later
                // clip-in-only command leaves the previous exclusion active.
                if (sw[0][13]) begin
                    clipout_en <= 1'b1;
                    cout_t <= {{4{sw[4][11]}}, sw[4][11:0]};
                    cout_b <= {{4{sw[5][11]}}, sw[5][11:0]};
                    cout_l <= {{4{sw[6][11]}}, sw[6][11:0]};
                    cout_r <= {{4{sw[7][11]}}, sw[7][11:0]};
                end
                list_idx <= list_idx + 1'd1;
                rs <= R_FETCH;
            end
            default: begin                                        // draw sprite
                if (d_srcw == 0 || d_srch == 0 || d_dstw == 0 || d_dsth == 0) begin
                    // Inline indirect tables occupy the following two list
                    // entries even when the draw itself has zero dimensions.
                    list_idx <= list_idx + 1'd1
                              + (d_ind && d_indloc ? 13'd2 : 13'd0);
                    rs <= R_FETCH;
                end
                else begin
                    // Hardware has two center encodings (00 and 11).  Center
                    // uses (size-1)/2, which matters for even-width sprites.
                    // 10=start, 01=end.
                    logic signed [13:0] xx, yy;
                    // MAME uses int arithmetic after sign-extending both
                    // 12-bit values.  Explicitly widen before addition so
                    // large negative offsets cannot wrap back onscreen.
                    xx = {{2{d_xpos[11]}}, d_xpos}
                       + (sw[0][4] ? {{2{jump_xoff[11]}}, jump_xoff[11:0]} : 14'sd0);
                    yy = {{2{d_ypos[11]}}, d_ypos}
                       + (sw[0][5] ? {{2{jump_yoff[11]}}, jump_yoff[11:0]} : 14'sd0);
                    case (d_ax)
                        2'b00, 2'b11:
                            xx = xx - $signed({4'b0000, d_dstw_center});
                        2'b01:
                            xx = xx - $signed({4'b0000, d_dstw}) + 14'sd1;
                        default: ;
                    endcase
                    case (d_ay)
                        2'b00, 2'b11:
                            yy = yy - $signed({4'b0000, d_dsth_center});
                        2'b01:
                            yy = yy - $signed({4'b0000, d_dsth}) + 14'sd1;
                        default: ;
                    endcase
                    x0 <= xx; y0 <= yy;
                    transmask_r <= transmask_of(ctl_latched[4][1:0],
                                                ctl_latched[5][1:0])
                                   & (d_bpp8 ? 16'hfff0 : 16'hffff);
                    yacc <= 0;
                    dy <= 0;
                    indi <= 0;
                    rs <= R_SCALE;
                end
            end
            endcase
            end
        end

        // The shared divider produces both unsigned 16.16 steps exactly 50
        // clocks after scale_start.  One following clock transfers the pair
        // atomically before any row or indirect-table work can consume them.
        R_SCALE: if (scale_done) begin
            ystep <= scale_yquot;
            xstep <= scale_xquot;
            rs <= d_ind ? R_INDTAB : R_ROW;
        end

        // indirect palette table load (inline or spriteram)
        R_INDTAB: begin
            slist_addr <= d_indloc ? ({list_idx, 3'b000} + 4'd8 + indi)
                                   : ({sw[7][12:0], 3'b000} + indi);
            rs <= R_INDTABP;
        end
        R_INDTABP: rs <= R_INDTABW;   // BRAM q lag: dead cycle before sampling
        R_INDTABW: begin
            // MAME: entry & (bpp8 ? 0xfff0 : 0xffff), bit15 forced when the
            // shadow-enable bit (ctl reg5 bit0) is set
            indtab[indi] <= (slist_data & (d_bpp8 ? 16'hfff0 : 16'hffff))
                          | (ctl_latched[5][0] ? 16'h8000 : 16'h0000);
            if (indi == 4'hf) rs <= R_ROW;
            else begin indi <= indi + 1'd1; rs <= R_INDTAB; end
        end

        // per destination row. Flip reverses the DESTINATION sweep while the
        // source reads forward (hardware/MAME model) — end codes and word
        // transparency track source order regardless of flip.
        R_ROW: begin
            logic signed [13:0] scry;
            logic [12:0] sy_now;
            scry = d_flipy ? (y0 + $signed({4'b0000, d_dsth})
                              - 14'sd1 - $signed({4'b0000, dy}))
                           : (y0 + $signed({4'b0000, dy}));
            sy_now = {4'b0000, yacc[24:16]};
            // The row multiply is invariant across every destination pixel.
            // Register it here so R_PIXEL only performs a small offset add.
            row_byte_base <= ({4'b0, d_addr} << 2)
                           + (sy_now * {d_srcw, 2'b00});
            if (dy == d_dsth) begin
                list_idx <= list_idx + 1'd1 + (d_ind && d_indloc ? 13'd2 : 13'd0);
                rs <= R_FETCH;
            end
            else if (scry < 0 || scry > 14'sd223 ||
                     (clip_en && (scry < $signed(clip_t) ||
                                  scry > $signed(clip_b)))) begin
                dy <= dy + 1'd1;               // row not visible: skip
                yacc <= yacc + ystep;
                rs <= R_ROW;
            end
            else if (!fb_busy) begin   // wait out the previous run's flush
                xacc <= 0;
                dx <= 0;
                rowtag_v <= 0;
                word_valid_r <= 0;
                do_clipout_row <= clipout_en && scry >= $signed(cout_t)
                                             && scry <= $signed(cout_b);
                fb_wr_start <= 1'b1;
                fb_wr_buf <= {d_mon, ~disp_buf[0]};
                // MAME applies latched controller flip while scanning the
                // displayed sprite framebuffer.  Mirroring writes into the
                // back buffer is equivalent and keeps the framebuffer read
                // interface sequential.
                fb_wr_y <= ctl_latched[2][1] ? (8'd223 - scry[7:0])
                                              : scry[7:0];
                fb_wr_shadow <= d_shad;
                rs <= R_PIXEL;
            end
        end

        // fetch 128-bit chunk of source row when needed
        R_ROWDATA: begin
            if (!debug_first_rom_valid) begin
                debug_first_rom_desc <= {sw[7], sw[6], sw[5], sw[4],
                                         sw[3], sw[2], sw[1], sw[0]};
                debug_first_rom_valid <= 1'b1;
            end
            srom_req <= 1'b1;
            srom_addr <= rowbase;
            rs <= R_ROWDATAW;
        end
        R_ROWDATAW: if (srom_ack) begin
            srom_req <= 0;
            pixrow <= srom_data;
            rowtag <= rowbase;
            rowtag_v <= 1;
            rs <= R_PIXEL;
        end

        // Pixel-from-sprite-RAM mode shares the list RAM read port while the
        // draw command is active.  Four pairs of CPU-visible halfwords form a
        // 16-byte cache line.  Repack each pair to the same byte layout as a
        // sprite-ROM burst (matching the 315-5386/MAME controller model).
        R_RAMDATA: begin
            ram_fetch_i <= 0;
            slist_addr <= ram_fetch_base;
            rs <= R_RAMDATAP;
        end
        R_RAMDATAP: begin
            slist_addr <= ram_fetch_base + 16'd1;
            rs <= R_RAMDATAW;
        end
        R_RAMDATAW: begin
            if (!ram_fetch_i[0]) begin
                ram_even <= slist_data;
            end
            else begin
                pixrow[{ram_fetch_i[2:1], 5'b00000} +: 32] <=
                    {ram_even[7:0], ram_even[15:8],
                     slist_data[7:0], slist_data[15:8]};
            end

            if (ram_fetch_i == 3'd7) begin
                rowtag <= rowbase;
                rowtag_v <= 1;
                rs <= R_PIXEL;
            end
            else begin
                ram_fetch_i <= ram_fetch_i + 1'd1;
                slist_addr <= ram_fetch_base + {13'b0, ram_fetch_i} + 16'd2;
            end
        end

        R_PIXEL: begin
            logic signed [13:0] scrx;
            logic [9:0]  sx_px;        // source pixel index within the row
            logic [2:0]  piw, piw_last;// position within the 32-bit word
            logic [9:0]  wordi;        // source 32-bit word index
            logic [23:0] byteaddr;
            logic [23:4] need;

            scrx = d_flipx ? (x0 + $signed({4'b0000, d_dstw})
                              - 14'sd1 - $signed({4'b0000, dx}))
                           : (x0 + $signed({4'b0000, dx}));
            sx_px = {1'b0, xacc[24:16]};
            piw      = d_bpp8 ? {1'b0, sx_px[1:0]} : sx_px[2:0];
            piw_last = d_bpp8 ? 3'd3 : 3'd7;
            wordi    = d_bpp8 ? {2'b0, sx_px[9:2]} : {3'b0, sx_px[9:3]};
            // byte address: row pitch was registered once in R_ROW.
            byteaddr = row_byte_base
                     + (d_bpp8 ? {14'b0, sx_px} : {15'b0, sx_px[9:1]});
            // Sprite RAM is 0x20000 bytes and wraps independently of the ROM
            // bank.  Both sources use the same 16-byte pixrow cache layout.
            need = d_fromram ? {7'b0, byteaddr[16:4]}
                             : {d_bank, byteaddr[21:4]};

            if (dx == d_dstw) begin
                fb_wr_end <= 1'b1;
                dy <= dy + 1'd1;
                yacc <= yacc + ystep;
                rs <= R_ROW;
            end
            // word boundary crossed: end-code check on the PREVIOUS word's
            // final pixel (using the old pixrow — covers zoom-skipped pixels)
            else if (word_valid_r && wordi != last_word_r) begin
                if (!d_opaque &&
                    (d_bpp8 ? (pixrow[{last_wic_r, 5'b11000} +: 8] == 8'hff)
                            : (pixrow[{last_wic_r, 5'b11000} +: 4] == 4'hf))) begin
                    fb_wr_end <= 1'b1;
                    dy <= dy + 1'd1;
                    yacc <= yacc + ystep;
                    rs <= R_ROW;
                end
                else last_word_r <= wordi;   // crossing consumed
            end
            else if (!rowtag_v || need != rowtag) begin
                rowbase <= need;
                if (d_fromram) begin
                    ram_fetch_base <= {byteaddr[16:4], 3'b000};
                    rs <= R_RAMDATA;
                end
                else begin
                    rs <= R_ROWDATA;
                end
            end
            else begin
                pixel_scrx    <= scrx;
                pixel_sx_px   <= sx_px;
                pixel_piw     <= piw;
                pixel_piw_last<= piw_last;
                pixel_wordi   <= wordi;
                pixel_byteaddr<= byteaddr;
                rs <= R_EMIT;
            end
        end

        R_EMIT: begin
            logic [3:0]  pen4;
            logic [7:0]  pen8, pix, trans_now;
            logic [15:0] outpix, indpix;
            logic        gate_clip, gate_draw;

            // Pen extract: bits 31:28 of the BE word = leftmost pixel;
            // even source px = high nibble of its byte.
            pen8 = pixrow[{pixel_byteaddr[3:0], 3'b000} +: 8];
            pen4 = pixel_sx_px[0] ? pen8[3:0] : pen8[7:4];
            pix  = d_bpp8 ? pen8 : {4'b0, pen4};
            // MAME: first/last pixel of each 32-bit word uses transp
            // (0x0f/0xff, or 0 when opaque); middle pixels use 0.
            trans_now = (pixel_piw == 3'd0 || pixel_piw == pixel_piw_last)
                      ? (d_opaque ? 8'h00 : (d_bpp8 ? 8'hff : 8'h0f))
                      : 8'h00;
            gate_clip = (pixel_scrx >= 0) &&
                (pixel_scrx < $signed({4'b0, hpix})) &&
                (!clip_en || (pixel_scrx >= $signed(clip_l) &&
                              pixel_scrx <= $signed(clip_r))) &&
                (!do_clipout_row || !(pixel_scrx >= $signed(cout_l) &&
                                      pixel_scrx <= $signed(cout_r)));
            indpix = d_bpp8 ? (indtab[pen8[7:4]] | {8'b0, pen8[3:0]})
                            : indtab[pen4];
            if (d_ind) begin
                // Indirect: table entry decides transparency via transmask.
                gate_draw = (pix != trans_now) &&
                            ((indpix & transmask_r) != transmask_r);
                outpix = indpix;
            end
            else begin
                // Direct: pen 0 is never drawn (even opaque).
                gate_draw = (pix != trans_now) && (pix != 8'h00);
                outpix = d_color | {8'b0, pix};
            end
            fb_wr_valid <= gate_clip && gate_draw;
            fb_wr_pix   <= outpix;   // shadow runs RMW in fb_if
            fb_wr_x     <= ctl_latched[2][0]
                         ? (hpix - 9'd1 - pixel_scrx[8:0])
                         : pixel_scrx[8:0];
            last_word_r  <= pixel_wordi;
            last_wic_r   <= pixel_byteaddr[3:2];
            word_valid_r <= 1'b1;
            // End code seen directly at the word's final source pixel.
            if (pixel_piw == pixel_piw_last && !d_opaque &&
                (d_bpp8 ? (pen8 == 8'hff) : (pen4 == 4'hf))) begin
                fb_wr_end <= 1'b1;
                dy <= dy + 1'd1;
                yacc <= yacc + ystep;
                rs <= R_ROW;
            end
            else begin
                dx <= dx + 1'd1;
                xacc <= xacc + xstep;
                rs <= R_PIXEL;
            end
        end

        R_DONE: rs <= R_IDLE;
        default: rs <= R_IDLE;
        endcase
    end
end

endmodule

//============================================================================
// Shared unsigned sprite-scale divider.
//
// Computes ynum/yden followed by xnum/xden with one 25-bit restoring-divider
// datapath.  Each quotient takes 25 clocks and truncates toward zero, matching
// the unsigned SystemVerilog '/' previously used by s32_sprite.  Callers must
// supply non-zero divisors (zero-sized sprites are rejected before start).
//============================================================================
module s32_sprite_scale_div (
    input             clk,
    input             rst,
    input             start,
    input      [24:0] ynum,
    input       [9:0] yden,
    input      [24:0] xnum,
    input       [9:0] xden,
    output reg        busy,
    output reg        done,
    output reg [24:0] yquot,
    output reg [24:0] xquot
);

reg [24:0] shift_r;
reg [10:0] rem_r;
reg  [9:0] den_r;
reg [24:0] xnum_r;
reg  [9:0] xden_r;
reg  [4:0] bit_count;
reg        axis_x;

wire [10:0] trial_raw = {rem_r[9:0], shift_r[24]};
wire        trial_ge  = trial_raw >= {1'b0, den_r};
wire [10:0] trial_next = trial_ge ? trial_raw - {1'b0, den_r}
                                         : trial_raw;
wire [24:0] shift_next = {shift_r[23:0], trial_ge};

always @(posedge clk) begin
    if (rst) begin
        shift_r <= 0;
        rem_r <= 0;
        den_r <= 0;
        xnum_r <= 0;
        xden_r <= 0;
        bit_count <= 0;
        axis_x <= 0;
        busy <= 0;
        done <= 0;
        yquot <= 0;
        xquot <= 0;
    end
    else begin
        done <= 1'b0;
        if (start && !busy) begin
            shift_r <= ynum;
            rem_r <= 0;
            den_r <= yden;
            xnum_r <= xnum;
            xden_r <= xden;
            bit_count <= 0;
            axis_x <= 1'b0;
            busy <= 1'b1;
        end
        else if (busy) begin
            shift_r <= shift_next;
            rem_r <= trial_next;
            if (bit_count == 5'd24) begin
                if (!axis_x) begin
                    yquot <= shift_next;
                    shift_r <= xnum_r;
                    rem_r <= 0;
                    den_r <= xden_r;
                    bit_count <= 0;
                    axis_x <= 1'b1;
                end
                else begin
                    xquot <= shift_next;
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
            else bit_count <= bit_count + 1'd1;
        end
    end
end

endmodule

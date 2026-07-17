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

always @(*) begin
    case (ctl_raddr)
        3'd0: ctl_rdata = {6'h3f, 1'b0, disp_buf[0]};
        3'd1: ctl_rdata = {6'h3f, 2'd1};              // status: normal
        3'd2: ctl_rdata = {6'h3f, ctl_latched[2][1:0]};
        3'd3: ctl_rdata = {6'h3f, ctl_latched[3][1:0]};
        3'd6: ctl_rdata = {6'h3f, 1'b0, ctl_latched[6][0]};
        default: ctl_rdata = 8'hfc;
    endcase
end

// list walker / renderer FSM
typedef enum logic [4:0] {
    R_IDLE, R_SWAP, R_ERASE, R_ERASEW,
    R_FETCH, R_FETCHP, R_FETCHW, R_DECODE, R_SCALE,
    R_INDTAB, R_INDTABP, R_INDTABW,
    R_ROW, R_ROWDATA, R_ROWDATAW, R_PIXEL, R_ROWEND,
    R_NEXT, R_DONE
} rst_t;
rst_t rs;

// latched sprite entry
reg [15:0] sw [0:7];
reg [2:0]  swi;
reg [12:0] list_idx;                 // entry index (16-byte units)
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
reg [19:0] yacc, ystep;   // src rows per dst row: srch*8 / dsth (10.10)
reg [19:0] xacc, xstep;
reg [9:0]  dy, dx;        // dest iterators
reg [12:0] sy;            // source row (in pixels)
reg [12:0] sx;
reg signed [11:0] x0, y0; // screen origin after alignment
reg [15:0] indtab [0:15];
reg [3:0]  indi;
reg [127:0] pixrow;
reg [23:4]  rowbase;

// simple per-row source fetch cache tag
reg [23:4] rowtag;
reg        rowtag_v;

// V-8 exact pen semantics state
reg [15:0] transmask_r;    // indirect transparency mask (ctl regs 4/5)
reg        do_clipout_row; // clip-out rect covers this row's y
reg [9:0]  last_word_r;    // last source 32-bit word visited (end codes)
reg [1:0]  last_wic_r;     // its position within the 128-bit chunk
reg        word_valid_r;

wire [8:0] hpix = mode_416 ? 9'd416 : 9'd320;

// A combinational 20-by-10 divide here makes Quartus expand two very large
// divider networks while elaborating the sprite engine.  Scaling setup is not
// on the pixel-rate path, so share one restoring divider across Y then X.
// The explicit 20-bit numerators preserve the original unsigned 10.10 math.
wire [19:0] scale_ynum = {2'b0, d_srch, 10'b0};
wire [19:0] scale_xnum = d_bpp8 ? {2'b0, d_srcw, 12'b0}
                                     : {1'b0, d_srcw, 13'b0};
wire        scale_start = (rs == R_DECODE) && (sw[0][15:14] == 2'b00) &&
                          (d_srcw != 0) && (d_srch != 0) &&
                          (d_dstw != 0) && (d_dsth != 0);
wire        scale_busy, scale_done;
wire [19:0] scale_yquot, scale_xquot;

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
        srom_req <= 0; fb_er_req <= 0;
        fb_wr_valid <= 0; fb_wr_start <= 0; fb_wr_end <= 0;
        fb_wr_shadow <= 0;
        frame_toggle <= 0;
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
            // automatic mode: swap every frame (or every other), manual: on demand
            logic do_swap;
            do_swap = 0;
            if (!ctl[3][1]) begin            // auto
                frame_toggle <= ~frame_toggle;
                do_swap = ctl[3][0] ? frame_toggle : 1'b1;
            end
            else do_swap = ctl[0][1];        // manual: pending swap bit
            if (do_swap) rs <= R_SWAP;
        end

        R_SWAP: begin
            disp_buf <= disp_buf + 1'd1;     // swap front/back
            for (int i = 0; i < 8; i++) ctl_latched[i] <= ctl[i];
            ctl[0] <= 0;
            fb_er_y <= 0;
            rs <= R_ERASE;
        end
        R_ERASE: begin
            fb_er_req <= 1'b1;
            fb_er_buf <= {1'b0, ~disp_buf[0]};   // erase back buffer (screen A)
            rs <= R_ERASEW;
        end
        R_ERASEW: if (fb_er_ack) begin
            fb_er_req <= 0;
            if (fb_er_y == 8'd223) begin
                rendering <= 1'b1;
                list_idx <= 0;
                clip_en <= 0; clipout_en <= 0;
                clip_l <= 0; clip_t <= 0;
                clip_r <= {7'b0, 9'd511}; clip_b <= 16'd255;
                rs <= R_FETCH;
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
                clipout_en <= sw[0][13];
                if (sw[0][13]) begin
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
                    list_idx <= list_idx + 1'd1;
                    rs <= R_FETCH;
                end
                else begin
                    // alignment: 00=center 10=start 01=end
                    logic signed [11:0] xx, yy;
                    xx = $signed(d_xpos) + (sw[0][4] ? $signed(jump_xoff[11:0]) : 12'sd0);
                    yy = $signed(d_ypos) + (sw[0][5] ? $signed(jump_yoff[11:0]) : 12'sd0);
                    case (d_ax)
                        2'b00: xx = xx - $signed({2'b0, d_dstw[9:1]});
                        2'b01: xx = xx - $signed({1'b0, d_dstw[9:0]}) + 1;
                        default: ;
                    endcase
                    case (d_ay)
                        2'b00: yy = yy - $signed({2'b0, d_dsth[9:1]});
                        2'b01: yy = yy - $signed({1'b0, d_dsth[9:0]}) + 1;
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

        // The shared divider produces both unsigned 10.10 steps exactly 40
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
            logic signed [12:0] scry;
            scry = d_flipy ? ($signed({y0[11], y0}) + $signed({3'b0, d_dsth})
                              - 13'sd1 - $signed({3'b0, dy}))
                           : ($signed({y0[11], y0}) + $signed({3'b0, dy}));
            sy = {3'b0, yacc[19:10]};
            if (dy == d_dsth) begin
                list_idx <= list_idx + 1'd1 + (d_ind && d_indloc ? 13'd2 : 13'd0);
                rs <= R_FETCH;
            end
            else if (scry < 0 || scry > 13'sd223 ||
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
                fb_wr_y <= scry[7:0];
                fb_wr_shadow <= d_shad;
                rs <= R_PIXEL;
            end
        end

        // fetch 128-bit chunk of source row when needed
        R_ROWDATA: begin
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

        R_PIXEL: begin
            logic signed [12:0] scrx;
            logic [9:0]  sx_px;        // source pixel index within the row
            logic [2:0]  piw, piw_last;// position within the 32-bit word
            logic [9:0]  wordi;        // source 32-bit word index
            logic [23:0] byteaddr;
            logic [23:4] need;
            logic [3:0]  pen4;
            logic [7:0]  pen8, pix, trans_now;
            logic [15:0] outpix, indpix;
            logic        gate_clip, gate_draw;

            scrx = d_flipx ? ($signed({x0[11], x0}) + $signed({3'b0, d_dstw})
                              - 13'sd1 - $signed({3'b0, dx}))
                           : ($signed({x0[11], x0}) + $signed({3'b0, dx}));
            sx_px = xacc[19:10];
            piw      = d_bpp8 ? {1'b0, sx_px[1:0]} : sx_px[2:0];
            piw_last = d_bpp8 ? 3'd3 : 3'd7;
            wordi    = d_bpp8 ? {2'b0, sx_px[9:2]} : {3'b0, sx_px[9:3]};
            // byte address: addr is a 32-bit-word base; row pitch srcw words
            byteaddr = ({4'b0, d_addr} << 2)
                     + (sy * {d_srcw, 2'b00})
                     + (d_bpp8 ? {14'b0, sx_px} : {15'b0, sx_px[9:1]});
            need = {d_bank, byteaddr[21:4]};

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
                rs <= R_ROWDATA;
            end
            else begin
                // pen extract: bits 31:28 of the BE word = leftmost pixel;
                // even source px = high nibble of its byte
                pen8 = pixrow[{byteaddr[3:0], 3'b000} +: 8];
                pen4 = sx_px[0] ? pen8[3:0] : pen8[7:4];
                pix  = d_bpp8 ? pen8 : {4'b0, pen4};
                // MAME: first/last pixel of each 32-bit word uses transp
                // (0x0f/0xff, or 0 when opaque); middle pixels use 0
                trans_now = (piw == 3'd0 || piw == piw_last)
                          ? (d_opaque ? 8'h00 : (d_bpp8 ? 8'hff : 8'h0f))
                          : 8'h00;
                gate_clip = (scrx >= 0) && (scrx < $signed({4'b0, hpix})) &&
                    (!clip_en || (scrx >= $signed(clip_l) &&
                                  scrx <= $signed(clip_r))) &&
                    (!do_clipout_row || !(scrx >= $signed(cout_l) &&
                                          scrx <= $signed(cout_r)));
                indpix = d_bpp8 ? (indtab[pen8[7:4]] | {8'b0, pen8[3:0]})
                                : indtab[pen4];
                if (d_ind) begin
                    // indirect: table entry decides transparency via transmask
                    gate_draw = (pix != trans_now) &&
                                ((indpix & transmask_r) != transmask_r);
                    outpix = indpix;
                end
                else begin
                    // direct: pen 0 is never drawn (even opaque)
                    gate_draw = (pix != trans_now) && (pix != 8'h00);
                    outpix = d_color | {8'b0, pix};
                end
                if (gate_clip && gate_draw) begin
                    fb_wr_valid <= 1'b1;
                    fb_wr_pix   <= outpix;   // shadow runs RMW in fb_if
                    fb_wr_x     <= scrx[8:0];
                end
                else fb_wr_valid <= 1'b0;
                last_word_r  <= wordi;
                last_wic_r   <= byteaddr[3:2];
                word_valid_r <= 1'b1;
                // end code seen directly at the word's final source pixel
                if (piw == piw_last && !d_opaque &&
                    (d_bpp8 ? (pen8 == 8'hff) : (pen4 == 4'hf))) begin
                    fb_wr_end <= 1'b1;
                    dy <= dy + 1'd1;
                    yacc <= yacc + ystep;
                    rs <= R_ROW;
                end
                else begin
                    dx <= dx + 1'd1;
                    xacc <= xacc + xstep;
                end
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
// Computes ynum/yden followed by xnum/xden with one 20-bit restoring-divider
// datapath.  Each quotient takes 20 clocks and truncates toward zero, matching
// the unsigned SystemVerilog '/' previously used by s32_sprite.  Callers must
// supply non-zero divisors (zero-sized sprites are rejected before start).
//============================================================================
module s32_sprite_scale_div (
    input             clk,
    input             rst,
    input             start,
    input      [19:0] ynum,
    input       [9:0] yden,
    input      [19:0] xnum,
    input       [9:0] xden,
    output reg        busy,
    output reg        done,
    output reg [19:0] yquot,
    output reg [19:0] xquot
);

reg [19:0] shift_r;
reg [10:0] rem_r;
reg  [9:0] den_r;
reg [19:0] xnum_r;
reg  [9:0] xden_r;
reg  [4:0] bit_count;
reg        axis_x;

wire [10:0] trial_raw = {rem_r[9:0], shift_r[19]};
wire        trial_ge  = trial_raw >= {1'b0, den_r};
wire [10:0] trial_next = trial_ge ? trial_raw - {1'b0, den_r}
                                         : trial_raw;
wire [19:0] shift_next = {shift_r[18:0], trial_ge};

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
            if (bit_count == 5'd19) begin
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

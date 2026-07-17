//============================================================================
//  System 32 mixer — 315-5387 (DESIGN.md §6.6, Appendix C.8)
//  Per-pixel priority resolution across TEXT/NBG0-3/BITMAP/SPRITE/BACKGROUND
//  with sprite grouping, palette lookup, blending, color offsets and shadow.
//  One instance per screen (Multi 32 = two).
//
//  Line-buffer inputs are written by s32_tilemap; the sprite line comes from
//  the framebuffer line fetcher. This module implements MAME mix_all_layers'
//  effective-priority scheme evaluated directly per pixel:
//    - first  = topmost non-transparent layer (the winner)
//    - second = the scan continued below the winner (blend partner)
//    - blend  = (first*(7-f) + second*(f+1)) >> 3 per 5-bit channel, gated
//               by the winner's blendmask (reg 0x30+2*lay bits 13:6) and,
//               for a sprite partner, sprblendmask over the sprite group
//    - shadow = sprite shadow sources halve final RGB after blending
//  Two palette lookups per pixel are time-multiplexed on the single mixer
//  palette port (a pixel period is ~15 clk_ram; each lookup needs ~5).
//============================================================================

module s32_mixer (
    input             clk,          // clk_ram
    input             rst,

    // mixer register file (0x610000/0x690000): 64 words
    input             reg_we,
    input       [5:0] reg_addr,
    input      [15:0] reg_wdata,
    output     [15:0] reg_rdata,
    input       [5:0] reg_raddr,
    output     [15:0] reg_r4e,        // 0x4E: palette write-both control (B6)

    // display timing
    input       [8:0] disp_x,
    input       [8:0] disp_y,
    input             disp_active,
    input             display_en,    // 315-5296 CNT1
    input       [5:0] layer_off,     // per-layer disable (TEXT,NBG0-3,BITMAP)

    // registered pixels from the shared tile/bitmap line buffer
    input      [13:0] px_text,
    input      [13:0] px_nbg0,
    input      [13:0] px_nbg1,
    input      [13:0] px_nbg2,
    input      [13:0] px_nbg3,
    input      [13:0] px_bmp,

    // sprite line pixel (from framebuffer line buffer, already fetched)
    input      [15:0] spr_pix,

    // palette read port (time-multiplexed: first then second lookup)
    output     [13:0] pal_addr,
    input      [15:0] pal_data,

    // final pixel out
    output reg [23:0] rgb
);

// ---------------------------------------------------------------------------
// register file
// ---------------------------------------------------------------------------
reg [15:0] mreg [0:63];
integer __mri;
// MAME video_start memsets mixer_control to 0xFF: unwritten registers read
// 0xFFFF, giving priority 0xF. holo only programs sprite group 0 and relies
// on group 1 (the r4c=0 default group) reading as all-ones — a zero init
// left every sprite at priority 0 and the screen black (real-ROM boot).
initial for(__mri=0;__mri<64;__mri=__mri+1) mreg[__mri]=16'hFFFF;
assign reg_rdata = mreg[reg_raddr];
assign reg_r4e   = mreg[6'h27];   // 0x4E/2
always @(posedge clk) if (reg_we) mreg[reg_addr] <= reg_wdata;

// ---------------------------------------------------------------------------
// sprite group extraction (reg 0x4C low nibble -> shift/mask/or)
// ---------------------------------------------------------------------------
wire [15:0] r4c = mreg[6'h26];  // 0x4C/2
wire [15:0] r4e = mreg[6'h27];
wire [15:0] r3e = mreg[6'h1f];  // 0x3E/2: color-offset select
reg  [3:0] sprgroup_shift;
reg  [3:0] sprgroup_mask;
reg  [3:0] sprgroup_or;
always @(*) begin
    case (r4c[3:0])
        4'h0: begin sprgroup_shift=14; sprgroup_mask=4'h0; sprgroup_or=4'h1; end
        4'h1: begin sprgroup_shift=14; sprgroup_mask=4'h1; sprgroup_or=4'h2; end
        4'h2: begin sprgroup_shift=13; sprgroup_mask=4'h3; sprgroup_or=4'h4; end
        4'h3: begin sprgroup_shift=12; sprgroup_mask=4'h7; sprgroup_or=4'h8; end
        4'h4: begin sprgroup_shift=14; sprgroup_mask=4'h1; sprgroup_or=4'h0; end
        4'h5: begin sprgroup_shift=13; sprgroup_mask=4'h3; sprgroup_or=4'h0; end
        4'h6: begin sprgroup_shift=12; sprgroup_mask=4'h7; sprgroup_or=4'h0; end
        4'h7: begin sprgroup_shift=11; sprgroup_mask=4'hf; sprgroup_or=4'h0; end
        4'h8: begin sprgroup_shift=14; sprgroup_mask=4'h1; sprgroup_or=4'h0; end
        4'h9: begin sprgroup_shift=13; sprgroup_mask=4'h3; sprgroup_or=4'h0; end
        4'ha: begin sprgroup_shift=12; sprgroup_mask=4'h7; sprgroup_or=4'h0; end
        4'hb: begin sprgroup_shift=11; sprgroup_mask=4'hf; sprgroup_or=4'h0; end
        4'hc: begin sprgroup_shift=13; sprgroup_mask=4'h1; sprgroup_or=4'h0; end
        4'hd: begin sprgroup_shift=12; sprgroup_mask=4'h3; sprgroup_or=4'h0; end
        4'he: begin sprgroup_shift=11; sprgroup_mask=4'h7; sprgroup_or=4'h0; end
        4'hf: begin sprgroup_shift=10; sprgroup_mask=4'hf; sprgroup_or=4'h0; end
    endcase
end

// sprite pixel semantics (MAME mix loop, exactly):
//   transparent when (pix & 0x7fff) == 0x7fff (covers 0xFFFF erase + 0x7FFF)
//   shadow source a: bit15 CLEAR when reg 0x4C bit2 set (RMW shadow sprites)
//   shadow source b: masked pen == sprshadow (0x7ffe & sprpixmask) — the
//     shadow pen: itself transparent, shadows whatever wins beneath
wire [3:0]  spr_group = sprgroup_or | (spr_pix >> sprgroup_shift) & {12'b0,sprgroup_mask};
wire [15:0] sprpixmask = ((16'h1 << sprgroup_shift) - 1) & 16'h3fff;
wire        spr_transp = (spr_pix & 16'h7fff) == 16'h7fff;
wire [15:0] sprshadowpen = 16'h7ffe & sprpixmask;
wire        spr_shadow_pen = !spr_transp &&
                             ((spr_pix & sprpixmask & 16'h7ffe) == sprshadowpen);
wire        spr_shadow_rmw = r4c[2] && !spr_pix[15];
wire        spr_shadow_src = spr_shadow_pen | spr_shadow_rmw;
wire        spr_opaque = !spr_transp && !spr_shadow_pen;   // can win the scan

// ---------------------------------------------------------------------------
// effective priority per layer:  {prio[3:0], rank[2:0]}
//   rank: sprites=7, text=6, nbg0=5 ... bitmap=1, background=0
//   layer regs: 0x20+2*lay (TEXT..BITMAP), 0x2C background, 0x00+2*grp sprites
// ---------------------------------------------------------------------------
reg [15:0] sprreg;
reg [6:0] ep_spr, ep_text, ep_nbg0, ep_nbg1, ep_nbg2, ep_nbg3, ep_bmp;
reg [6:0] ep_spr_nom;   // sprite order slot regardless of pixel content
wire [6:0] ep_bg = {4'd1, 3'd0};   // background: priority 1, rank 0
reg [15:0] lr_t, lr_0, lr_1, lr_2, lr_3, lr_b;
always @(*) begin
    sprreg = mreg[{2'b00, spr_group}];
    lr_t = mreg[6'h10]; lr_0 = mreg[6'h11]; lr_1 = mreg[6'h12];
    lr_2 = mreg[6'h13]; lr_3 = mreg[6'h14]; lr_b = mreg[6'h15];
    ep_spr_nom = (sprreg[3:0] != 0) ? {sprreg[3:0], 3'd7} : 7'd0;
    ep_spr  = spr_opaque ? ep_spr_nom : 7'd0;
    // bit13 = drawn/opaque, set by the renderers only for nonzero pens
    // (8bpp bitmap tests the FULL pen byte, so the mixer must not re-test
    //  pen[3:0] here)
    // disabled layers never mix (MAME enablemask) — a disabled layer's
    // line buffer keeps stale pixels, so it must be gated here
    ep_text = (!layer_off[0] && px_text[13] && lr_t[3:0] != 0) ? {lr_t[3:0], 3'd6} : 7'd0;
    ep_nbg0 = (!layer_off[1] && px_nbg0[13] && lr_0[3:0] != 0) ? {lr_0[3:0], 3'd5} : 7'd0;
    ep_nbg1 = (!layer_off[2] && px_nbg1[13] && lr_1[3:0] != 0) ? {lr_1[3:0], 3'd4} : 7'd0;
    ep_nbg2 = (!layer_off[3] && px_nbg2[13] && lr_2[3:0] != 0) ? {lr_2[3:0], 3'd3} : 7'd0;
    ep_nbg3 = (!layer_off[4] && px_nbg3[13] && lr_3[3:0] != 0) ? {lr_3[3:0], 3'd2} : 7'd0;
    ep_bmp  = (!layer_off[5] && px_bmp[13]  && lr_b[3:0] != 0) ? {lr_b[3:0], 3'd1} : 7'd0;
end

// winner select (8-way max)
reg [6:0] best;
reg [3:0] bestsel;   // 0=text 1..4 nbg 5 bmp 6 spr 7 bg (== MAME laynum)
always @(*) begin
    best = ep_bg; bestsel = 4'd7;
    if (ep_bmp  > best) begin best = ep_bmp;  bestsel = 4'd5; end
    if (ep_nbg3 > best) begin best = ep_nbg3; bestsel = 4'd4; end
    if (ep_nbg2 > best) begin best = ep_nbg2; bestsel = 4'd3; end
    if (ep_nbg1 > best) begin best = ep_nbg1; bestsel = 4'd2; end
    if (ep_nbg0 > best) begin best = ep_nbg0; bestsel = 4'd1; end
    if (ep_text > best) begin best = ep_text; bestsel = 4'd0; end
    if (ep_spr  > best) begin best = ep_spr;  bestsel = 4'd6; end
end

// blend partner: the same scan continued below the winner
reg [6:0] best2;
reg [3:0] best2sel;
always @(*) begin
    best2 = 7'd0; best2sel = 4'd7;   // background is the floor of every scan
    if (bestsel != 4'd7)               begin best2 = ep_bg;   best2sel = 4'd7; end
    if (bestsel != 4'd5 && ep_bmp  > best2) begin best2 = ep_bmp;  best2sel = 4'd5; end
    if (bestsel != 4'd4 && ep_nbg3 > best2) begin best2 = ep_nbg3; best2sel = 4'd4; end
    if (bestsel != 4'd3 && ep_nbg2 > best2) begin best2 = ep_nbg2; best2sel = 4'd3; end
    if (bestsel != 4'd2 && ep_nbg1 > best2) begin best2 = ep_nbg1; best2sel = 4'd2; end
    if (bestsel != 4'd1 && ep_nbg0 > best2) begin best2 = ep_nbg0; best2sel = 4'd1; end
    if (bestsel != 4'd0 && ep_text > best2) begin best2 = ep_text; best2sel = 4'd0; end
    if (bestsel != 4'd6 && ep_spr  > best2) begin best2 = ep_spr;  best2sel = 4'd6; end
end

// ---------------------------------------------------------------------------
// backdrop pixel (MAME update_background): per line,
//   bit15 ? (reg5E & 0x1e00) + ((reg5E + y) & 0x1ff) : reg5E & 0x1e00
// ---------------------------------------------------------------------------
wire [15:0] r5e = mreg[6'h2f];
wire [13:0] bg_pen = {1'b0, r5e[12:9], 9'b0}
                   + (r5e[15] ? {5'b0, (r5e[8:0] + disp_y) & 9'h1ff} : 14'd0);

// ---------------------------------------------------------------------------
// per-layer palette info: palbase nibble, mixshift, 14-bit pen
//   index = palbase + ((pen >> shift) & 0x3ff0) + (pen & 0xf)   (wraps 14 bit)
//   sprite: palbase from group reg unless (0x4C & 3) == 3 (then from 0x4C);
//           mixshift always from the group reg
// NOTE: the layer mux must be an explicit always@(*) reading the signals
// directly — hiding them inside a function called from a continuous assign
// leaves them out of the sensitivity list (iverilog) and the index goes stale.
// ---------------------------------------------------------------------------
wire [15:0] lr_bg = mreg[6'h16];
wire [19:0] li_text = {lr_t[7:4], lr_t[9:8], 1'b0, px_text[12:0]};
wire [19:0] li_nbg0 = {lr_0[7:4], lr_0[9:8], 1'b0, px_nbg0[12:0]};
wire [19:0] li_nbg1 = {lr_1[7:4], lr_1[9:8], 1'b0, px_nbg1[12:0]};
wire [19:0] li_nbg2 = {lr_2[7:4], lr_2[9:8], 1'b0, px_nbg2[12:0]};
wire [19:0] li_nbg3 = {lr_3[7:4], lr_3[9:8], 1'b0, px_nbg3[12:0]};
wire [19:0] li_bmp  = {lr_b[7:4], lr_b[9:8], 1'b0, px_bmp[12:0]};
wire [19:0] li_spr  = {(r4c[1:0] == 2'b11) ? r4c[7:4] : sprreg[7:4],
                       sprreg[9:8], spr_pix[13:0] & sprpixmask[13:0]};
wire [19:0] li_bg   = {lr_bg[7:4], lr_bg[9:8], bg_pen};

reg [19:0] li_first, li_second;
always @(*) begin
    case (bestsel)
        4'd0: li_first = li_text;  4'd1: li_first = li_nbg0;
        4'd2: li_first = li_nbg1;  4'd3: li_first = li_nbg2;
        4'd4: li_first = li_nbg3;  4'd5: li_first = li_bmp;
        4'd6: li_first = li_spr;   default: li_first = li_bg;
    endcase
    case (best2sel)
        4'd0: li_second = li_text; 4'd1: li_second = li_nbg0;
        4'd2: li_second = li_nbg1; 4'd3: li_second = li_nbg2;
        4'd4: li_second = li_nbg3; 4'd5: li_second = li_bmp;
        4'd6: li_second = li_spr;  default: li_second = li_bg;
    endcase
end

function automatic [13:0] mk_palidx(input [19:0] li);
    mk_palidx = {li[19:16], 10'b0}
              + ((li[13:0] >> li[15:14]) & 14'h3ff0)
              + {10'b0, li[3:0]};
endfunction

wire [13:0] idx_first  = mk_palidx(li_first);
wire [13:0] idx_second = mk_palidx(li_second);

// ---------------------------------------------------------------------------
// blend controls (reg 0x4E: bit11 enable, bits 10:8 factor;
//   winner's reg 0x30+2*lay: bits 13:6 blendmask, bits 5:0 sprite-group code)
// ---------------------------------------------------------------------------
wire        blendenable = r4e[11];
wire [2:0]  blendfactor = r4e[10:8];
wire [15:0] wblendreg   = mreg[6'h18 + {2'b0, bestsel}];   // valid for lay 0..5
wire        winner_blends = (bestsel <= 4'd5);
wire [7:0]  blendmask   = (blendenable && winner_blends) ? wblendreg[13:6] : 8'h00;

// compute_sprite_blend: mm=(enc>>4)&3, v=enc&0xf
reg [15:0] sprblendmask;
always @(*) begin
    case (wblendreg[5:4])
        2'b00: sprblendmask = 16'h1 << wblendreg[3:0];
        2'b01: sprblendmask = (16'h1 << wblendreg[3:0]) | ((16'h1 << wblendreg[3:0]) - 16'h1);
        2'b10: sprblendmask = ~((16'h1 << wblendreg[3:0]) - 16'h1);
        2'b11: sprblendmask = 16'hffff;
    endcase
end

wire do_blend = blendmask[best2sel[2:0]] &&
                (best2sel != 4'd6 || sprblendmask[spr_group]);

// shadow applies when the scan passes the sprite layer's order slot:
//   scan 1 (always): sprite at/above the winner
//   scan 2 (only when the winner has blends): sprite below winner, at/above
//   the partner — MAME's second loop re-evaluates shadow identically
wire shadow_now = spr_shadow_src && (ep_spr_nom != 0) &&
                  ( ep_spr_nom >= best ||
                    (blendmask != 8'h00 && bestsel != 4'd6 && ep_spr_nom >= best2) );

// ---------------------------------------------------------------------------
// color offsets: rgboffs bank0 = regs 0x40-0x44, bank1 = 0x46-0x4A, bank2 = 0
//   mode = {r3e[15], r3e[laybit]}  (laybit = laynum, bg uses bit 8)
//   layerflag: text..bitmap = reg(0x30+2*lay) bit14; sprites = 0x4C bit15;
//              background = 0x3E bit14
//   mode 0/3 -> bank !layerflag; mode 1 -> bank 2; mode 2 -> !flag ? 2 : 0
// ---------------------------------------------------------------------------
wire [5:0] layer_color_flags = {mreg[6'h1d][14], mreg[6'h1c][14],
                                mreg[6'h1b][14], mreg[6'h1a][14],
                                mreg[6'h19][14], mreg[6'h18][14]};
wire [17:0] coloroffs_bank0 = {mreg[6'h22][5:0], mreg[6'h21][5:0],
                               mreg[6'h20][5:0]};
wire [17:0] coloroffs_bank1 = {mreg[6'h25][5:0], mreg[6'h24][5:0],
                               mreg[6'h23][5:0]};

// All dependencies are explicit function arguments.  Quartus 17 can omit
// global signals referenced only from inside an automatic function (it
// previously reported r3e as assigned-but-never-read), silently removing the
// color-offset mode logic from hardware.
function automatic [1:0] coloroffs_of(
    input [3:0]  sel,
    input [15:0] ctl3e,
    input        sprite_flag,
    input [5:0]  layer_flags
);
    logic laybit, lflag;
    case (sel)
        4'd0: begin laybit = ctl3e[0]; lflag = layer_flags[0]; end
        4'd1: begin laybit = ctl3e[1]; lflag = layer_flags[1]; end
        4'd2: begin laybit = ctl3e[2]; lflag = layer_flags[2]; end
        4'd3: begin laybit = ctl3e[3]; lflag = layer_flags[3]; end
        4'd4: begin laybit = ctl3e[4]; lflag = layer_flags[4]; end
        4'd5: begin laybit = ctl3e[5]; lflag = layer_flags[5]; end
        4'd6: begin laybit = ctl3e[6]; lflag = sprite_flag;   end
        default: begin laybit = ctl3e[8]; lflag = ctl3e[14]; end
    endcase
    case ({ctl3e[15], laybit})
        2'b00, 2'b11: coloroffs_of = {1'b0, ~lflag};
        2'b01:        coloroffs_of = 2'd2;
        default:      coloroffs_of = lflag ? 2'd0 : 2'd2;
    endcase
endfunction

function automatic signed [5:0] off_chan(
    input [1:0]  bank,
    input [1:0]  ch,
    input [17:0] bank0,
    input [17:0] bank1
);
    case (bank)
        2'd0: case (ch)
            2'd0:    off_chan = $signed(bank0[5:0]);
            2'd1:    off_chan = $signed(bank0[11:6]);
            default: off_chan = $signed(bank0[17:12]);
        endcase
        2'd1: case (ch)
            2'd0:    off_chan = $signed(bank1[5:0]);
            2'd1:    off_chan = $signed(bank1[11:6]);
            default: off_chan = $signed(bank1[17:12]);
        endcase
        default: off_chan = 6'sd0;
    endcase
endfunction

// ---------------------------------------------------------------------------
// pixel pipeline: two palette lookups per pixel, then MAME's 5-bit-domain
// arithmetic. Palette port is registered on clk_sys (2 clk_ram) — allow 5
// clk_ram per lookup. Pixel period is >= ~11.6 clk_ram (416 mode).
//   T0 (disp_x changes): synchronous line-RAM read is issued
//   T1: latch winner context from the RAM outputs, present first index
//   T6: capture first pixel, present second index
//   T11: capture second pixel, blend/shadow/clamp, register rgb
// ---------------------------------------------------------------------------
reg [8:0]  dx_d;
reg [3:0]  ph;
reg        launch_pending;
reg [13:0] pal_addr_r;
reg [15:0] first_pal;
reg [13:0] idx2_hold;
reg        blend_hold, shadow_hold, act_hold;
reg [1:0]  co1_hold, co2_hold;
assign pal_addr = pal_addr_r;

function automatic [4:0] clamp5(input signed [11:0] v);
    if (v > 12'sd31)     clamp5 = 5'd31;
    else if (v < 12'sd0) clamp5 = 5'd0;
    else                 clamp5 = v[4:0];
endfunction

always @(posedge clk) begin
    logic signed [7:0]  r1, g1, b1, r2, g2, b2;
    logic signed [11:0] rr, gg, bb;

    dx_d <= disp_x;
    if (rst) begin
        ph <= 4'hF;
        launch_pending <= 1'b0;
        rgb <= 24'h000000;
    end
    else if (disp_x != dx_d) begin
        // The line memories sample disp_x on this edge.  Their registered
        // outputs become visible after the edge, so launch winner selection
        // on the following clock rather than pairing old pixels with new x.
        launch_pending <= 1'b1;
        ph <= 4'hF;
    end
    else if (launch_pending) begin
        pal_addr_r  <= idx_first;
        idx2_hold   <= idx_second;
        blend_hold  <= do_blend;
        shadow_hold <= shadow_now;
        co1_hold    <= coloroffs_of(bestsel,  r3e, r4c[15], layer_color_flags);
        co2_hold    <= coloroffs_of(best2sel, r3e, r4c[15], layer_color_flags);
        act_hold    <= disp_active & display_en;
        launch_pending <= 1'b0;
        ph <= 4'd0;
    end
    else if (ph != 4'hF) begin
        ph <= ph + 1'd1;
        if (ph == 4'd4) begin
            first_pal  <= pal_data;
            pal_addr_r <= idx2_hold;
        end
        else if (ph == 4'd9) begin
            // both pixels in hand: offsets in the 5-bit domain, then blend,
            // then shadow halving, then clamp — exactly MAME's order
            r1 = $signed({3'b0, first_pal[4:0]})
               + off_chan(co1_hold, 2'd0, coloroffs_bank0, coloroffs_bank1);
            g1 = $signed({3'b0, first_pal[9:5]})
               + off_chan(co1_hold, 2'd1, coloroffs_bank0, coloroffs_bank1);
            b1 = $signed({3'b0, first_pal[14:10]})
               + off_chan(co1_hold, 2'd2, coloroffs_bank0, coloroffs_bank1);
            r2 = $signed({3'b0, pal_data[4:0]})
               + off_chan(co2_hold, 2'd0, coloroffs_bank0, coloroffs_bank1);
            g2 = $signed({3'b0, pal_data[9:5]})
               + off_chan(co2_hold, 2'd1, coloroffs_bank0, coloroffs_bank1);
            b2 = $signed({3'b0, pal_data[14:10]})
               + off_chan(co2_hold, 2'd2, coloroffs_bank0, coloroffs_bank1);
            if (blend_hold) begin
                rr = (r1 * $signed({2'b0, 3'd7 - blendfactor})
                    + r2 * ($signed({2'b0, blendfactor}) + 5'sd1)) >>> 3;
                gg = (g1 * $signed({2'b0, 3'd7 - blendfactor})
                    + g2 * ($signed({2'b0, blendfactor}) + 5'sd1)) >>> 3;
                bb = (b1 * $signed({2'b0, 3'd7 - blendfactor})
                    + b2 * ($signed({2'b0, blendfactor}) + 5'sd1)) >>> 3;
            end
            else begin
                rr = r1; gg = g1; bb = b1;
            end
            if (shadow_hold) begin
                rr = rr >>> 1; gg = gg >>> 1; bb = bb >>> 1;
            end
            rgb <= !act_hold ? 24'h000000
                 : {clamp5(rr), 3'b000, clamp5(gg), 3'b000, clamp5(bb), 3'b000};
            ph <= 4'hF;
        end
    end
end

endmodule

//============================================================================
//  System 32 tilemap engine (DESIGN.md §6.2, Appendix C)
//  Renders one scanline of each enabled layer into per-layer line buffers:
//    NBG0/1: X/Y zoom via 8.8 step accumulators ($1FF50-56, 0x200=1.0)
//    NBG2/3: rowscroll/rowselect via VRAM tables ($1FF04)
//    TEXT:   8x8 chars from VRAM (page/bank $1FF5C)
//    BITMAP: linear VRAM bitmap 4/8bpp ($1FF88-8C)
//  Tile pixel data: 16x16 4bpp from SDRAM tile region via p1 burst port
//  (one 64-bit burst = one tile row).
//  Output pixel format into line buffers: {palette[8:0], pen[3:0]} + opaque
//  flag; the mixer applies palbase/shift.
//
//  Time budget: renders during previous line's active+blank at clk_ram/2;
//  worst case 4 layers x 416 px + text + bitmap ≈ 2700 fetch-limited cycles,
//  available ≈ 3000 (DESIGN.md §10.2).
//============================================================================

module s32_tilemap (
    input             clk,          // clk_ram
    input             rst,

    // frame timing
    input       [8:0] line,         // line to render (next display line)
    input             line_start,   // pulse: begin rendering `line`
    output reg        line_done,
    input             mode_416,
    input       [1:0] ext_tilebank, // 315-5296 port H bit0 (bit1 unused)

    // video registers (from s32_vram)
    input      [15:0] r1ff00, r1ff02, r1ff04, r1ff06, r1ff5c, r1ff5e,
    input      [15:0] r1ff88, r1ff8a, r1ff8c, r1ff8e,
    input      [15:0] scrollx [0:3],
    input      [15:0] scrolly [0:3],
    input      [15:0] offsx   [0:3],
    input      [15:0] offsy   [0:3],
    input      [15:0] pages   [0:7],
    input      [15:0] zoomx   [0:1],
    input      [15:0] zoomy   [0:1],
    input      [15:0] clips   [0:19],

    // VRAM fetch port
    output reg [15:0] vram_addr,
    input      [15:0] vram_rdata,

    // SDRAM tile data port (p1)
    output reg        tile_req,
    output reg [21:3] tile_addr,    // 8-byte aligned within tile region
    input      [63:0] tile_data,
    input             tile_ack,

    // line buffer write (to mixer): layer 0=TEXT 1..4=NBG0-3 5=BITMAP
    output reg        lb_we,
    output reg  [2:0] lb_layer,
    output reg  [8:0] lb_x,
    output reg [13:0] lb_pix,       // {pal[8:0], pen[3:0]} | [13]=opaque-valid
    output      [5:0] layer_off_o   // to the mixers (MAME enablemask, inverted)
);

// layer enable logic: $1FF02 low bits + $1FF8E second disable set
// (+ $1FF00 bits 12/13 disable NBG2/NBG3 — MAME update_tilemaps)
wire [5:0] layer_off = { r1ff02[5] | r1ff8e[5],                // BITMAP
                         r1ff02[3] | r1ff8e[4] | r1ff00[13],   // NBG3
                         r1ff02[2] | r1ff8e[3] | r1ff00[12],   // NBG2
                         r1ff02[1] | r1ff8e[2],                // NBG1
                         r1ff02[0] | r1ff8e[1],                // NBG0
                         r1ff02[4] | r1ff8e[0] };              // TEXT
assign layer_off_o = layer_off;

wire [1:0] tilebank = {ext_tilebank[0], r1ff00[10]};

// rendering FSM: iterate layers, per layer iterate x
typedef enum logic [4:0] {
    T_IDLE, T_LSTART, T_ROWTAB1, T_ROWTAB2,
    T_NAME, T_NAMEW, T_NAMER, T_PIX, T_PIXW, T_EMIT,
    T_TXT_NAME, T_TXT_NAMEW, T_TXT_NAMER,
    T_TXT_PIX, T_TXT_PIXW, T_TXT_PIXR, T_TXT_EMIT,
    T_BMP, T_BMPW, T_BMPR, T_DONE
} tst_t;
tst_t tst;

reg [2:0]  lay;          // 0..3 = NBG0..3, 4 = TEXT, 5 = BITMAP
reg [9:0]  x;            // dest x
reg [9:0]  srcx;         // source x (integer part)
reg [8:0]  srcy;
reg [19:0] xacc, xstep;  // 10.10 accumulator for zoom
reg [15:0] name;
reg [63:0] row;
reg [15:0] rowscroll_add;
reg [8:0]  rowselect_y;
reg        use_rowsel;

wire [8:0] hpix = mode_416 ? 9'd416 : 9'd320;
wire [10:0] zoom_losum = {1'b0, xacc[9:0]} + {1'b0, xstep[9:0]};
wire [9:0]  nsx_zoom = scrollx[lay][9:0] + xacc[19:10] + xstep[19:10] + {9'b0, zoom_losum[10]};


// page select for current layer/srcx/srcy: 2x2 pages of 512x256
function automatic [6:0] page_of(input [2:0] l, input [9:0] sx, input [8:0] sy);
    logic [15:0] w;
    w = pages[{l[1:0], sy[8]}];       // word: {upper/lower}
    page_of = sx[9] ? w[14:8] : w[6:0];
endfunction

// tile name address within VRAM: page*0x200 + row*32 + col
function automatic [15:0] name_addr(input [6:0] pg, input [9:0] sx, input [8:0] sy);
    name_addr = {pg, 9'b0} + {7'b0, sy[7:4], sx[8:4]};
endfunction

// layer clip windows (MAME compute_clipping_extents, per-pixel form):
//   rect i = clips[4i..4i+3] = {min_x[8:0], min_y[7:0], max_x[8:0], max_y[7:0]}
//   (max inclusive); pixel drawn iff !enable | (inside-union ^ clipout)
function automatic clip_vis(input [8:0] xx, input [8:0] yy,
                            input en, input outp, input [4:0] msk);
    logic [4:0] hit;
    integer ci;
    for (ci = 0; ci < 5; ci = ci + 1)
        hit[ci] = msk[ci] &&
            xx >= clips[4*ci][8:0]   && yy >= {1'b0, clips[4*ci+1][7:0]} &&
            xx <= clips[4*ci+2][8:0] && yy <= {1'b0, clips[4*ci+3][7:0]};
    clip_vis = !en || ((|hit) ^ outp);
endfunction

// text layer name address: page from $1FF5C bits 7:4 (<<11 words)
wire [15:0] text_page_base = {(r1ff5c >> 4) & 16'h001f, 11'b0};
// text char gfx base: bank bits 2:0 of $1FF5C, 16 words/char
wire [15:0] text_bank_base = {r1ff5c[2:0], 13'b0};

always @(posedge clk) begin
    if (rst) begin
        tst <= T_IDLE; line_done <= 0; lb_we <= 0; tile_req <= 0;
    end
    else begin
        lb_we <= 1'b0;

        case (tst)
        T_IDLE: if (line_start) begin
            lay <= 0;
            x   <= 0;
            line_done <= 0;
            tst <= T_LSTART;
        end

        // per-layer setup
        T_LSTART: begin
            if (lay < 4) begin
                if (layer_off[lay+1]) begin
                    lay <= lay + 1'd1;
                    // Always re-enter layer setup.  Jumping directly from a
                    // disabled NBG3 to T_TXT_NAME bypassed the TEXT disable
                    // bit and rendered stale text pixels anyway.
                    tst <= T_LSTART;
                    if (lay == 3) begin x <= 0; end
                end
                else begin
                    // compute source y for this layer
                    logic [8:0] sy;
                    sy = scrolly[lay][8:0] + line;
                    if (lay < 2) begin
                        // V-2 (MAME update_tilemap_zoom): step = 0x200/zoom
                        // (zoom floored at 0x80); src = scroll - center +
                        // (screen+center)*step. 10.10 fixed point.
                        logic signed [31:0] d;
                        logic [10:0] zy, zx;
                        logic [19:0] stepy;
                        zy = (zoomy[lay][10:0] < 11'h080) ? 11'h080 : zoomy[lay][10:0];
                        zx = (zoomx[lay][10:0] < 11'h080) ? 11'h080 : zoomx[lay][10:0];
                        stepy = (20'h200 << 10) / {9'b0, zy};
                        d = ($signed({23'b0, line}) + $signed({{23{offsy[lay][8]}}, offsy[lay][8:0]}))
                            * $signed({12'b0, stepy});
                        sy = scrolly[lay][8:0] - offsy[lay][8:0] + d[18:10];
                        xacc  <= ($signed({{22{offsx[lay][9]}}, offsx[lay][9:0]}) * $signed({12'b0, (20'h200 << 10) / {9'b0, zx}}));
                        xstep <= (20'h200 << 10) / {9'b0, zx};
                    end
                    else begin
                        xacc  <= 0;
                        xstep <= 20'h00200 << 10; // unused for NBG2/3
                    end
                    srcy <= sy;
                    x <= 0;
                    use_rowsel <= 0;
                    rowscroll_add <= 0;
                    // rowscroll/rowselect fetch for NBG2/3
                    if (lay >= 2 && (r1ff04[lay-2] | r1ff04[lay])) begin
                        // rowscroll entry: table_base + 0x100*(lay-2) + line
                        vram_addr <= {r1ff04[15:10], 10'b0} +
                                     (lay == 3 ? 16'h0100 : 16'h0000) + {7'b0, line};
                        tst <= T_ROWTAB1;
                    end
                    else tst <= T_NAME;
                end
            end
            else if (lay == 4) begin
                x <= 0;
                tst <= layer_off[0] ? T_LSTART : T_TXT_NAME;
                if (layer_off[0]) lay <= 5;
            end
            else begin
                // bitmap
                x <= 0;
                tst <= layer_off[5] ? T_DONE : T_BMP;
            end
        end

        // rowscroll value
        T_ROWTAB1: begin
            // wait 1 clk for vram read
            tst <= T_ROWTAB2;
        end
        T_ROWTAB2: begin
            if (r1ff04[lay-2]) rowscroll_add <= vram_rdata & 16'h3ff;
            if (r1ff04[lay]) begin
                // rowselect table at +0x200
                // (second fetch folded: approximate single-fetch, rowselect
                //  fetched next state via same path)
                use_rowsel <= 1'b1;
                rowselect_y <= vram_rdata[8:0]; // NOTE: refined during co-sim
            end
            tst <= T_NAME;
        end

        // fetch tile name for current x
        T_NAME: begin
            logic [9:0] sx;
            if (lay < 2) sx = scrollx[lay][9:0] + xacc[19:10];
            else         sx = scrollx[lay][9:0] + rowscroll_add[9:0] + x;
            srcx <= sx;
            vram_addr <= name_addr(page_of(lay, sx, use_rowsel ? (scrolly[lay][8:0]+rowselect_y) : srcy), sx,
                                   use_rowsel ? (scrolly[lay][8:0]+rowselect_y) : srcy);
            tst <= T_NAMEW;
        end
        T_NAMEW: begin
            // The VRAM video port is synchronous: the address is sampled on
            // this edge and its registered data is visible after the edge.
            // Consume it in the following state, not as the old address is
            // still visible here.
            tst <= T_NAMER;
        end
        T_NAMER: begin
            name <= vram_rdata;
            tst <= T_PIX;
        end
        // fetch tile pixel row from SDRAM: tile code 13 bits + bank
        T_PIX: begin
            logic [14:0] code;
            logic [3:0]  trow;
            logic [8:0] eff_y;
            code = {tilebank, name[12:0]};
            eff_y = use_rowsel ? (scrolly[lay][8:0]+rowselect_y) : srcy;
            trow = eff_y[3:0] ^ {4{name[15]}};
            tile_addr <= {code, trow};   // 15+4 = 19 bits of 8-byte rows
            tile_req  <= 1'b1;
            tst <= T_PIXW;
        end
        T_PIXW: if (tile_ack) begin
            tile_req <= 0;
            row <= tile_data;
            tst <= T_EMIT;
        end
        // emit up to 16 pixels (or until tile boundary/zoom step)
        T_EMIT: begin
            logic [3:0] col;
            logic [3:0] pen;
            col = srcx[3:0] ^ {4{name[14]}};
            // 4bpp packed msb-first per 16px row (bgcharlayout nibble order)
            // bgcharlayout x-offsets {0,4,16,20,8,12,24,28,...}: column ->
            // nibble index swaps the middle bits; even nibble = high half of
            // its byte (MSB-first packing), odd = low half.
            begin
                logic [3:0] nib;
                nib = {col[3], col[1], col[2], ~col[0]};
                pen = row[{nib[3:1], 3'b000} + (nib[0] ? 3'd0 : 3'd4) +: 4];
            end
            lb_we    <= 1'b1;
            lb_layer <= lay + 1;   // NBG0 = layer1
            lb_x     <= x[8:0];
            // clip window: $1FF02 bit (11+bg) enable / (6+bg) clip-out;
            // $1FF06 nibble bg selects rects 0-3
            lb_pix   <= {(|pen) && clip_vis(x[8:0], line,
                            r1ff02[4'd11 + {1'b0, lay}],
                            r1ff02[4'd6  + {1'b0, lay}],
                            {1'b0, r1ff06[{lay[1:0], 2'b00} +: 4]}),
                         name[12:4], pen};
            // advance
            if (x == hpix-1) begin
                lay <= lay + 1'd1;
                tst <= T_LSTART;
            end
            else begin
                x <= x + 1'd1;
                if (lay < 2) begin
                    xacc <= xacc + xstep;
                    // refetch name/pixels when tile col crosses
                    if (nsx_zoom[9:4] != srcx[9:4]) tst <= T_NAME;
                    else srcx <= nsx_zoom;
                end
                else begin
                    if (srcx[3:0] == 4'hf) tst <= T_NAME;
                    else srcx <= srcx + 1'd1;
                end
            end
        end

        // ---- text layer: 8x8 4bpp chars from VRAM ----
        T_TXT_NAME: begin
            vram_addr <= text_page_base + {5'b0, line[7:3], x[8:3]};
            tst <= T_TXT_NAMEW;
        end
        T_TXT_NAMEW: begin
            tst <= T_TXT_NAMER;
        end
        T_TXT_NAMER: begin
            name <= vram_rdata;
            tst <= T_TXT_PIX;
        end
        T_TXT_PIX: begin
            // char gfx: 8x8x4 = 16 words; word = 4 pixels (packed msb)
            vram_addr <= text_bank_base + {name[8:0], 4'b0} + {line[2:0], x[2]} ;
            tst <= T_TXT_PIXW;
        end
        T_TXT_PIXW: begin
            tst <= T_TXT_PIXR;
        end
        T_TXT_PIXR: begin
            row[15:0] <= vram_rdata;
            tst <= T_TXT_EMIT;
        end
        T_TXT_EMIT: begin
            logic [1:0] col;
            logic [3:0] pen;
            col = x[1:0];
            case (col)
                2'd0: pen = row[7:4];
                2'd1: pen = row[3:0];
                2'd2: pen = row[15:12];
                default: pen = row[11:8];
            endcase
            lb_we    <= 1'b1;
            lb_layer <= 3'd0;
            lb_x     <= x[8:0];
            lb_pix   <= {|pen, 2'b00, name[15:9], pen};
            if (x == hpix-1) begin
                lay <= 5;
                tst <= T_LSTART;
            end
            else begin
                x <= x + 1'd1;
                if (x[1:0] == 2'b11) tst <= (x[2:0]==3'b111) ? T_TXT_NAME : T_TXT_PIX;
            end
        end

        // ---- bitmap layer (MAME update_bitmap) ----
        //   4bpp: 512x512, row = 128 words, y wraps 9 bits
        //   8bpp: 512x256, row = 256 words, y wraps 8 bits
        //   color = (reg 0x1FF8C << 4) masked above the pen bits
        T_BMP: begin
            logic [8:0] bx, by;
            bx = x[8:0] + r1ff88[8:0];
            by = line + r1ff8a[8:0];
            if (r1ff00[11]) // 8bpp
                vram_addr <= {by[7:0], bx[8:1]};
            else
                vram_addr <= {by[8:0], bx[8:2]};
            tst <= T_BMPW;
        end
        T_BMPW: begin
            tst <= T_BMPR;
        end
        T_BMPR: begin
            logic [8:0] bx;
            logic [7:0] pen8;
            bx = x[8:0] + r1ff88[8:0];
            if (r1ff00[11]) pen8 = bx[0] ? vram_rdata[15:8] : vram_rdata[7:0];
            else            pen8 = {4'b0, vram_rdata[{bx[1:0],2'b00} +: 4]};
            lb_we    <= 1'b1;
            lb_layer <= 3'd5;
            lb_x     <= x[8:0];
            // bitmap clip: $1FF02 bit15 enable / bit10 clip-out, rect 4 only
            if (r1ff00[11])
                lb_pix <= {(|pen8) && clip_vis(x[8:0], line,
                              r1ff02[15], r1ff02[10], 5'b10000),
                           r1ff8c[8:4], pen8};                   // 8bpp
            else
                lb_pix <= {(|pen8[3:0]) && clip_vis(x[8:0], line,
                              r1ff02[15], r1ff02[10], 5'b10000),
                           r1ff8c[8:0], pen8[3:0]};              // 4bpp
            if (x == hpix-1) tst <= T_DONE;
            else begin x <= x + 1'd1; tst <= T_BMP; end
        end

        T_DONE: begin
            line_done <= 1'b1;
            tst <= T_IDLE;
        end
        default: tst <= T_IDLE;
        endcase
    end
end

endmodule

//============================================================================
//  Sega System 32 / Multi 32 — board top (DESIGN.md §3.1)
//  Wires: V60 + bus decode (Appendix A), video pipeline, sound subsystem,
//  I/O chips, interrupt controller, protection modules, SDRAM/DDR3.
//============================================================================

import s32_pkg::*;

module s32_core #(
`ifdef S32_SYSTEM32_ONLY
    // The SegaS32 Quartus revision sets this macro so Cyclone V only pays for
    // hardware present on a single-screen System 32 board.  A future Multi 32
    // revision leaves the macro unset (or explicitly overrides the parameter).
    parameter SYSTEM32_ONLY = 1'b1
`else
    parameter SYSTEM32_ONLY = 1'b0
`endif
) (
    input             clk_sys,      // 48.324 MHz
    input             clk_ram,      // 96.648 MHz
    input             rst,
    // Keep CRT timing alive while game logic is held in ROM-load reset.
    input             video_rst,

    input  board_desc_t board,

    // clock enables (from fractional CE generators in emu top)
    input             ce_cpu,       // 16.108 / 20 MHz
    input             ce_z80,       // 8.054 / 8.0
    input             ce_fm,
    input             ce_pcm,       // 12.5 / 10.0

    // SDRAM ports (to sdram.sv in emu top)
    output            sdr_p0_req,
    output     [24:1] sdr_p0_addr,
    input      [15:0] sdr_p0_dout,
    input             sdr_p0_ack,
    output            sdr_p1_req,
    output     [24:3] sdr_p1_addr,
    input      [63:0] sdr_p1_dout,
    input             sdr_p1_ack,
    output            sdr_p2_req,
    output     [24:4] sdr_p2_addr,
    input     [127:0] sdr_p2_dout,
    input             sdr_p2_ack,
    output            sdr_p3_req,
    output     [24:1] sdr_p3_addr,
    input      [15:0] sdr_p3_dout,
    input             sdr_p3_ack,
    output            sdr_p4_req,
    output     [24:1] sdr_p4_addr,
    input      [15:0] sdr_p4_dout,
    input             sdr_p4_ack,

    // DDR3 framebuffer service (s32_fb_if lives in emu top)
    output            fb_wr_start,
    output      [1:0] fb_wr_buf,
    output      [8:0] fb_wr_x,
    output      [7:0] fb_wr_y,
    output            fb_wr_valid,
    output     [15:0] fb_wr_pix,
    output            fb_wr_end,
    output            fb_wr_shadow,   // run RMWs dest &= 0x7fff (V-10)
    input             fb_wr_busy,     // fb_if still flushing previous run
    output            fb_er_req,
    output      [1:0] fb_er_buf,
    output      [7:0] fb_er_y,
    input             fb_er_ack,
    output            fb_rd_req,
    output      [1:0] fb_rd_buf,
    output      [7:0] fb_rd_y,
    input             fb_rd_ack,
    output      [8:0] fb_rd_x,
    input      [15:0] fb_rd_pix,

    // V25 program load
    input             v25_prg_wr,
    input      [15:0] v25_prg_waddr,
    input       [7:0] v25_prg_wdata,

    // EEPROM NVRAM load/save
    input             eep_ld_wr,
    input       [5:0] eep_ld_addr,
    input      [15:0] eep_ld_data,
    output     [15:0] eep_rd_data,
    input       [5:0] eep_rd_addr,
    input             eep_upload,
    output            eep_modified,

    // inputs (already mapped per game class by emu top)
    input       [7:0] in_p1a, in_p2a, in_portc, in_svc12, in_svc34,
    input       [7:0] in_p1b, in_p2b, in_portc_b, in_svc12_b, in_svc34_b,
    input       [7:0] adc_ch [0:7],
    input             trk_dv [0:2],
    input signed [8:0] trk_dx [0:2],
    input signed [8:0] trk_dy [0:2],
    input       [7:0] trk_btn [0:2],
    input       [7:0] ppi_pa, ppi_pb, ppi_pc,

    // video out (screen A; screen B via second mixer on M32)
    output     [23:0] rgb_a,
    output     [23:0] rgb_b,
    output            ce_pix,
    output            hs, vs, hb, vb,

    output signed [15:0] audio_l,
    output signed [15:0] audio_r,

    output      [7:0] out_lamps,    // misc outputs (coin counters etc)

    // Hardware bring-up visibility. These signals are selected by the
    // top-level Debug Video option and do not alter the emulated board.
    output     [31:0] debug_pc,
    output            debug_halted,
    output     [23:0] debug_status,
    output     [15:0] debug_first_rom,
    output      [8:0] debug_hcnt,
    output    [127:0] debug_sprite_desc,
    output            debug_sprite_desc_valid
);

// A System32-only bitstream must not enter a Multi 32 runtime configuration if
// it is accidentally paired with a Multi 32 MRA.  The universal source build
// retains the descriptor-selected path when SYSTEM32_ONLY is false.
wire is_multi32 = SYSTEM32_ONLY ? 1'b0 : board.multi32;
`ifdef S32_GA2_ONLY
localparam GA2_ONLY = 1'b1;
`else
localparam GA2_ONLY = 1'b0;
`endif

// ---------------------------------------------------------------------------
// CPU + bus adapter
// ---------------------------------------------------------------------------
wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;
wire        wr_stb;

wire        irq_n;
wire [7:0]  irq_vector;
wire [31:0] v60_debug_pc;
wire        v60_debug_halted;

s32_v60 #(.START_PC(32'h00FFFFF0)) v60 (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(),
    .nmi_n(1'b1),
    .dbg_pc(v60_debug_pc), .dbg_halted(v60_debug_halted)
);

assign debug_pc     = v60_debug_pc;
assign debug_halted = v60_debug_halted;

s32_v60_bus vbus (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

// ---------------------------------------------------------------------------
// address decode (Appendix A) — 24-bit space
// ---------------------------------------------------------------------------
wire [23:0] A = {m_addr, 1'b0};
wire sel_rom    = (A < 24'h200000);
wire sel_wram   = (A[23:20] == 4'h2);
wire sel_vram   = (A[23:20] == 4'h3);
wire sel_sprram = (A[23:20] == 4'h4);
wire sel_sprctl = (A[23:20] == 4'h5);
wire sel_shared = (A[23:20] == 4'h7);
wire sel_comm   = (A[23:16] == 8'h80);
wire sel_dual   = (A[23:16] == 8'h81);
wire sel_prot_a = (A[23:20] == 4'hA);
wire sel_v25    = sel_prot_a && (A[19:12] == 8'h00); // 0xA00000-A00FFF
// MAME's I/O mirrors ignore A19:A7 (System 32) or A18:A7 (Multi 32).
// A6:A5 remain decoded: 00 selects the 5296 and A6 selects expansion I/O.
wire io0_area   = (A[23:20] == 4'hC) && (!is_multi32 || !A[19]);
wire sel_io0    = io0_area && (A[6:5] == 2'b00);
wire sel_ioex   = io0_area && A[6];
wire sel_io1    = is_multi32 && (A[23:20] == 4'hC) && A[19] &&
                  (A[6:5] == 2'b00);
wire sel_intc   = (A[23:20] == 4'hD) && !A[19];
wire sel_rand   = (A[23:20] == 4'hD) &&  A[19];
wire sel_romhi  = (A[23:20] == 4'hF);

// Palette/mixer windows are mirrored through bits 19:17 (System 32) or
// 18:17 (Multi 32); A16 alone distinguishes palette RAM from mixer regs.
wire pal_area   = (A[23:20] == 4'h6);
wire is_pal0    = pal_area && !A[16] && (!is_multi32 || !A[19]);
wire is_mix0    = pal_area &&  A[16] && (!is_multi32 || !A[19]);
wire is_pal1    = is_multi32 && pal_area && A[19] && !A[16];
wire is_mix1    = is_multi32 && pal_area && A[19] &&  A[16];

// ---------------------------------------------------------------------------
// work RAM — dual port (CPU + protection)
//
// System 32 has 64 KiB (32K x 16); Multi 32 has 128 KiB (64K x 16).  Keeping
// the depth elaboration-time constant lets Quartus remove 64 M10Ks from the
// SegaS32 revision instead of retaining the runtime-selectable maximum.
// ---------------------------------------------------------------------------
localparam integer WRAM_ADDR_WIDTH = SYSTEM32_ONLY ? 15 : 16;
localparam integer WRAM_WORDS      = SYSTEM32_ONLY ? 32768 : 65536;
wire [15:0] wram_q;
wire [WRAM_ADDR_WIDTH-1:0] wram_a = SYSTEM32_ONLY ? A[15:1] :
                                    (is_multi32 ? A[16:1] : {1'b0, A[15:1]});

// protection second port
wire        pr_req, pr_we;
wire [15:0] pr_addr;
wire [15:0] pr_wdata;
wire [1:0]  pr_be;
wire [15:0] pr_q;
reg         pr_ack;
wire [WRAM_ADDR_WIDTH-1:0] pr_wram_a = pr_addr[WRAM_ADDR_WIDTH-1:0];

s32_big_dpram #(
    .ADDR_WIDTH(WRAM_ADDR_WIDTH), .NUM_WORDS(WRAM_WORDS)
) work_ram (
    .clock_a(clk_sys), .address_a(wram_a),
    .data_a(m_wdata), .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_wram), .q_a(wram_q),
    .clock_b(clk_sys), .address_b(pr_wram_a),
    .data_b(pr_wdata), .byteena_b(pr_be),
    .wren_b(pr_req && pr_we), .q_b(pr_q)
);

always @(posedge clk_sys)
    pr_ack <= pr_req;

// ---------------------------------------------------------------------------
// video subsystem
// ---------------------------------------------------------------------------
wire [15:0] vram_cpu_q, vram_vid_q;
wire        io0_cnt1, io0_cnt2;
wire [15:0] vid_vaddr;
wire [15:0] r1ff00, r1ff02, r1ff04, r1ff06, r1ff5c, r1ff5e;
wire [15:0] r1ff88, r1ff8a, r1ff8c, r1ff8e;
wire [15:0] w_scrollx [0:3];
wire [15:0] w_scrolly [0:3];
wire [15:0] w_offsx [0:3];
wire [15:0] w_offsy [0:3];
wire [15:0] w_pages [0:7];
wire [15:0] w_zoomx [0:1];
wire [15:0] w_zoomy [0:1];
wire [15:0] w_clips [0:19];

s32_vram vram (
    .clk(clk_sys), .vid_clk(clk_ram),
    .cpu_we(m_req && m_we && sel_vram),
    .cpu_addr(A[16:1]),
    .cpu_wdata(m_wdata), .cpu_be(m_be), .cpu_rdata(vram_cpu_q),
    .vid_addr(vid_vaddr), .vid_rdata(vram_vid_q),
    .reg_1ff00(r1ff00), .reg_1ff02(r1ff02), .reg_1ff04(r1ff04),
    .reg_1ff06(r1ff06),
    .reg_scrollx(w_scrollx), .reg_scrolly(w_scrolly),
    .reg_offsx(w_offsx), .reg_offsy(w_offsy),
    .reg_pages(w_pages), .reg_zoomx(w_zoomx), .reg_zoomy(w_zoomy),
    .reg_1ff5c(r1ff5c), .reg_1ff5e(r1ff5e), .reg_clips(w_clips),
    .reg_1ff88(r1ff88), .reg_1ff8a(r1ff8a), .reg_1ff8c(r1ff8c),
    .reg_1ff8e(r1ff8e)
);

// sprite RAM: CPU port + engine port
wire [15:0] sprram_q, sprlist_q;
wire [15:0] slist_addr;
s32_big_dpram #(
    .ADDR_WIDTH(16), .NUM_WORDS(65536), .MIXED_RDW_MODE("DONT_CARE")
) sprite_ram (
    .clock_a(clk_sys), .address_a(A[16:1]),
    .data_a(m_wdata), .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_sprram), .q_a(sprram_q),
    .clock_b(clk_ram), .address_b(slist_addr),
    .data_b(16'h0000), .byteena_b(2'b00),
    .wren_b(1'b0), .q_b(sprlist_q)
);

// CRT timing
wire mode_416;
wire vbl_start, vbl_end;
wire [8:0] hcnt, vcnt;
assign debug_hcnt = hcnt;
s32_video crt (
    .clk(clk_sys), .rst(video_rst), .mode_416(mode_416),
    .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt),
    .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
    .vblank_start(vbl_start), .vblank_end(vbl_end)
);

// tilemap engine (clk_ram domain; registers quasi-static)
wire        tm_lb_we;
wire [2:0]  tm_lb_layer;
wire [8:0]  tm_lb_x;
wire [13:0] tm_lb_pix;
reg  line_start_r;
reg  [8:0] render_line;
reg  lb_bank = 0;
always @(posedge clk_ram) begin
    line_start_r <= 0;
    // kick renderer at each hblank start for next line (sync crossing
    // simplified). Position must follow the video mode: in 320-wide mode
    // htotal is 409, so a fixed 416 tick never fires and no line ever
    // renders (found by real-ROM boot: holo runs 320 mode and displayed
    // pure black).
    if (ce_pix && hcnt == (mode_416 ? 9'd417 : 9'd321)) begin
        render_line <= (vcnt == 9'd261) ? 9'd0 : vcnt + 1'd1;
        line_start_r <= 1'b1;
        lb_bank <= ~lb_bank;
    end
end

wire [7:0] io0_ph;
wire [5:0] tm_layer_off;
wire [21:3] tile_rom_addr;
s32_tilemap tilemap (
    .clk(clk_ram), .rst(rst),
    .line(render_line), .line_start(line_start_r), .line_done(),
    .mode_416(mode_416), .ext_tilebank(io0_ph[1:0]), .layer_off_o(tm_layer_off),
    .r1ff00(r1ff00), .r1ff02(r1ff02), .r1ff04(r1ff04), .r1ff06(r1ff06),
    .r1ff5c(r1ff5c), .r1ff5e(r1ff5e),
    .r1ff88(r1ff88), .r1ff8a(r1ff8a), .r1ff8c(r1ff8c), .r1ff8e(r1ff8e),
    .scrollx(w_scrollx), .scrolly(w_scrolly),
    .offsx(w_offsx), .offsy(w_offsy),
    .pages(w_pages), .zoomx(w_zoomx), .zoomy(w_zoomy), .clips(w_clips),
    .vram_addr(vid_vaddr), .vram_rdata(vram_vid_q),
    .tile_req(sdr_p1_req), .tile_addr(tile_rom_addr),
    .tile_data(sdr_p1_dout), .tile_ack(sdr_p1_ack),
    .lb_we(tm_lb_we), .lb_layer(tm_lb_layer), .lb_x(tm_lb_x), .lb_pix(tm_lb_pix)
);
// The 4 MB tile region begins at the non-power-of-two-aligned 0x600000.
// Concatenating only the high address bits placed reads at 0x400000 and would
// fetch sound ROM on hardware; add the renderer's region-local row address.
assign sdr_p1_addr = SDR_TILES_BASE[24:3] + {3'b000, tile_rom_addr};

// sprite engine
wire [7:0] sprctl_q;
wire [1:0] disp_buf;
s32_sprite sprite (
    .clk(clk_ram), .rst(rst), .is_multi32(is_multi32),
    // MAME schedules sprite erase/swap/render just after VBLANK ends, not at
    // its leading edge.  GA2 builds its next command list during VBLANK, so
    // launching at vbl_start can consume the list before the IRQ-side update.
    .vblank(vbl_end), .rendering(),
    .debug_first_rom_desc(debug_sprite_desc),
    .debug_first_rom_valid(debug_sprite_desc_valid),
    .ctl_we(wr_stb && m_we && sel_sprctl && m_be[0]),
    .ctl_addr(A[3:1]), .ctl_wdata(m_wdata[7:0]),
    .ctl_rdata(sprctl_q), .ctl_raddr(A[3:1]),
    .slist_addr(slist_addr), .slist_data(sprlist_q),
    .srom_req(sdr_p2_req), .srom_addr(sdr_p2_addr[23:4]),
    .srom_data(sdr_p2_dout), .srom_ack(sdr_p2_ack),
    .fb_wr_start(fb_wr_start), .fb_wr_buf(fb_wr_buf), .fb_wr_x(fb_wr_x),
    .fb_wr_y(fb_wr_y), .fb_wr_valid(fb_wr_valid), .fb_wr_pix(fb_wr_pix),
    .fb_wr_end(fb_wr_end),
    .fb_wr_shadow(fb_wr_shadow), .fb_busy(fb_wr_busy),
    .fb_er_req(fb_er_req), .fb_er_buf(fb_er_buf), .fb_er_y(fb_er_y),
    .fb_er_ack(fb_er_ack),
    .disp_buf(disp_buf), .mode_416(mode_416)
);
assign sdr_p2_addr[24] = 1'b1;   // sprites region base 0x1000000

// B5: 416/320 width follows sprite control reg 6 bit0 (CPU-written)
reg mode_416_r = 1'b1;
always @(posedge clk_sys)
    if (m_req && m_we && sel_sprctl && m_be[0] && A[3:1] == 3'd6)
        mode_416_r <= m_wdata[0];
assign mode_416 = mode_416_r;

// Sprite line prefetch for mixer. Hold the request and its address until the
// DDR service acknowledges it; a one-cycle pulse was lost whenever an erase
// or sprite write occupied the framebuffer engine.
reg       fb_rd_req_r;
reg [1:0] fb_rd_buf_r;
reg [7:0] fb_rd_y_r;
wire fb_rd_kick = ce_pix && hcnt == (mode_416 ? 9'd420 : 9'd324);
always @(posedge clk_ram) begin
    if (rst) begin
        fb_rd_req_r <= 1'b0;
        fb_rd_buf_r <= 2'd0;
        fb_rd_y_r   <= 8'd0;
    end
    else if (fb_rd_req_r) begin
        if (fb_rd_ack) fb_rd_req_r <= 1'b0;
    end
    else if (!fb_rd_ack && fb_rd_kick) begin
        fb_rd_req_r <= 1'b1;
        fb_rd_buf_r <= {1'b0, disp_buf[0]};
        // CRT lines are 0..261. Truncating line 261 before adding produced
        // line 6 instead of the next frame's line 0.
        fb_rd_y_r <= (vcnt == 9'd261) ? 8'd0 : vcnt[7:0] + 8'd1;
    end
end
assign fb_rd_req = fb_rd_req_r;
assign fb_rd_buf = fb_rd_buf_r;
assign fb_rd_y   = fb_rd_y_r;
assign fb_rd_x   = hcnt;

// mixers + palettes
// Screen B sprite line: per-monitor framebuffer fetch is a tracked deeper
// item; v1 shares screen A's fetched line so B's tilemaps/palette/mixer are
// nonetheless fully independent (the valuable part of B7).
wire [15:0] fb_rd_pix_b = fb_rd_pix;
wire [15:0] pal0_cpu_q, pal1_cpu_q;
wire [13:0] mix0_pal_addr, mix1_pal_addr;
wire [15:0] mix0_pal_q, mix1_pal_q;
wire [15:0] mix0_q, mix1_q;
wire [15:0] mix0_r4e, mix1_r4e;
wire [13:0] mix_px_text, mix_px_nbg0, mix_px_nbg1;
wire [13:0] mix_px_nbg2, mix_px_nbg3, mix_px_bmp;

// Both current screen mixers consume the same tilemap-renderer stream.  Share
// the twelve physical parity/layer RAM banks and fan out their registered
// pixels; the mixers retain independent registers, palettes and RGB pipelines.
s32_linebuf shared_lbuf (
    .clk(clk_ram),
    .lb_we(tm_lb_we), .lb_layer(tm_lb_layer), .lb_wx(tm_lb_x),
    .lb_wpix(tm_lb_pix), .lb_bank(render_line[0]),
    .rd_x(hcnt), .rd_bank(vcnt[0]),
    .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
    .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
    .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp)
);

s32_palette pal0 (
    .clk(clk_sys),
    .cpu_we(m_req && m_we && is_pal0),
    .cpu_addr(A[15:1]), .cpu_wdata(m_wdata), .cpu_be(m_be),
    .cpu_rdata(pal0_cpu_q), .mixer_r4e(mix0_r4e),
    .mix_addr(mix0_pal_addr), .mix_data(mix0_pal_q)
);

s32_mixer mix0 (
    .clk(clk_ram), .rst(rst),
    .reg_we(wr_stb && m_we && is_mix0),
    .reg_addr(A[6:1]), .reg_wdata(m_wdata), .reg_be(m_be),
    .reg_rdata(mix0_q), .reg_raddr(A[6:1]), .reg_r4e(mix0_r4e),
    .disp_x(hcnt), .disp_y(vcnt), .disp_active(~hb & ~vb),
    .display_en(io0_cnt1), .layer_off(tm_layer_off),
    .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
    .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
    .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp),
    .spr_pix(fb_rd_pix),
    .pal_addr(mix0_pal_addr), .pal_data(mix0_pal_q),
    .rgb(rgb_a)
);

generate
    if (SYSTEM32_ONLY) begin : g_system32_only_video
        // 0x680000/0x690000 are Multi 32-only windows, so System 32 reads
        // continue through the normal open-bus default in the CPU read mux.
        // Mirror A onto the unused output to keep the top-level screen selector
        // harmless for single-screen MRAs.
        assign pal1_cpu_q     = 16'hffff;
        assign mix1_q         = 16'hffff;
        assign mix1_r4e       = 16'h0000;
        assign mix1_pal_addr  = 14'h0000;
        assign mix1_pal_q     = 16'h0000;
        assign rgb_b          = rgb_a;
    end
    else begin : g_multi32_video
        // B7: Multi 32 second screen — palette bank 1 (0x680000) + mixer 1
        // (0x690000).  This branch remains available to a future Multi 32 QSF.
        s32_palette pal1 (
            .clk(clk_sys),
            .cpu_we(m_req && m_we && is_pal1),
            .cpu_addr(A[15:1]), .cpu_wdata(m_wdata), .cpu_be(m_be),
            .cpu_rdata(pal1_cpu_q), .mixer_r4e(mix1_r4e),
            .mix_addr(mix1_pal_addr), .mix_data(mix1_pal_q)
        );
        s32_mixer mix1 (
            .clk(clk_ram), .rst(rst),
            .reg_we(wr_stb && m_we && is_mix1),
            .reg_addr(A[6:1]), .reg_wdata(m_wdata), .reg_be(m_be),
            .reg_rdata(mix1_q), .reg_raddr(A[6:1]), .reg_r4e(mix1_r4e),
            .disp_x(hcnt), .disp_y(vcnt), .disp_active(~hb & ~vb),
            .display_en(io0_cnt1), .layer_off(tm_layer_off),
            .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
            .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
            .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp),
            .spr_pix(fb_rd_pix_b),
            .pal_addr(mix1_pal_addr), .pal_data(mix1_pal_q),
            .rgb(rgb_b)
        );
    end
endgenerate

// ---------------------------------------------------------------------------
// sound subsystem
// ---------------------------------------------------------------------------
wire        snd_doorbell, snd_to_v60;
wire [7:0]  sh_rdata;
wire [23:0] zrom_ba;
wire [21:0] mpcm_ba;

s32_soundsys #(.SYSTEM32_ONLY(SYSTEM32_ONLY)) sound (
    .clk(clk_sys), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm),
    .rst(rst),
    .z80_reset(~io0_cnt2),
    .is_multi32(is_multi32),
    .sh_cs(m_req && sel_shared && m_be[0]),
    .sh_we(m_we && sel_shared && m_be[0]),
    .sh_addr(A[13:1]), .sh_wdata(m_wdata[7:0]), .sh_rdata(sh_rdata),
    .v60_doorbell(snd_doorbell),
    .irq_to_v60(snd_to_v60),
    .zrom_req(sdr_p3_req), .zrom_addr(zrom_ba),
    .zrom_data(sdr_p3_dout), .zrom_ack(sdr_p3_ack),
    .mpcm_req(sdr_p4_req), .mpcm_addr(mpcm_ba),
    .mpcm_data(sdr_p4_dout[7:0]), .mpcm_ack(sdr_p4_ack),
    .audio_l(audio_l), .audio_r(audio_r)
);
// B1: SDRAM address hookup for sound ports — add region bases so fetches
// land in the soundcpu / multipcm regions instead of address 0.
assign sdr_p3_addr = SDR_SOUNDCPU_BASE[24:1] + {1'b0, zrom_ba[23:1]};
assign sdr_p4_addr = SDR_MULTIPCM_BASE[24:1] + {3'b000, mpcm_ba[21:1]};

// ---------------------------------------------------------------------------
// I/O chips + EEPROM
// ---------------------------------------------------------------------------
wire [7:0] io0_q, io1_q;
wire [7:0] io0_pd, io0_pg, io1_ph;
wire       eep_do;

s32_io5296 io0 (
    .clk(clk_sys), .rst(rst),
    .cs(m_req && sel_io0 && m_be[0]), .we(m_we),
    .addr(A[5:1]), .wdata(m_wdata[7:0]), .rdata(io0_q),
    .in_pa(in_p1a), .in_pb(in_p2a),
    .in_pc(in_portc),                          // B2: portc no longer carries EEPROM
    .in_pe(in_svc12),
    .in_pf({eep_do, in_svc34[6:0]}),           // B2/B3: EEPROM do_read on SERVICE34 bit7
    .out_pd(io0_pd), .out_pg(io0_pg), .out_ph(io0_ph),
    .cnt0(), .cnt1(io0_cnt1), .cnt2(io0_cnt2)
);
assign out_lamps = io0_pd;

s32_io5296 io1 (
    .clk(clk_sys), .rst(rst),
    .cs(m_req && sel_io1 && m_be[0]), .we(m_we),
    .addr(A[5:1]), .wdata(m_wdata[7:0]), .rdata(io1_q),
    .in_pa(in_p1b), .in_pb(in_p2b), .in_pc(in_portc_b),
    .in_pe(in_svc12_b), .in_pf(in_svc34_b),
    .out_pd(), .out_pg(), .out_ph(io1_ph),
    .cnt0(), .cnt1(), .cnt2()
);

// EEPROM wiring: S32 = io0 port D bits {7=DI,5=CS,6=CLK}; M32 = io1 port H
wire [7:0] eep_src = is_multi32 ? io1_ph : io0_pd;
s32_eeprom93c46 eeprom (
    .clk(clk_sys), .rst(rst),
    .di(eep_src[7]), .cs(eep_src[5]), .sk(eep_src[6]), .dout(eep_do),
    .ld_wr(eep_ld_wr), .ld_addr(eep_ld_addr), .ld_data(eep_ld_data),
    .rd_data(eep_rd_data), .rd_addr(eep_rd_addr),
    .upload(eep_upload), .modified(eep_modified)
);

// extended IO: ADC / trackballs / PPI
wire adc_bit;
wire [7:0] trk_q [0:2];
wire sel_adc   = sel_ioex && (A[5:3] == 3'b010) && board.has_adc;
wire sel_track = sel_ioex && (A[5:3] <= 3'b010) && board.has_track;
wire sel_ppi   = sel_ioex && (A[5:3] == 3'b100) && board.has_ppi;
genvar t;                         // declare outside the generate-for (Quartus 17.0)
generate
    if (GA2_ONLY) begin : g_ga2_no_analog
        // GA2's 0x22 descriptor has neither ADC nor trackball hardware.
        // Removing these runtime-dead peripherals also removes their input
        // selection muxes from the dedicated release.
        assign adc_bit = 1'b1;
        for (t = 0; t < 3; t = t + 1) begin : tracks
            assign trk_q[t] = 8'hff;
        end
    end
    else begin : g_extended_analog
        reg [2:0] analog_bank;
        s32_msm6253 adc (
            .clk(clk_sys),
            .cs(m_req && sel_adc && m_be[0]), // 0xC00050-57
            .we(m_we), .addr(A[2:1]),
            .dout_bit(adc_bit),
            .an0(adc_ch[{analog_bank[0], 2'd0}]), .an1(adc_ch[{analog_bank[0], 2'd1}]),
            .an2(adc_ch[{analog_bank[0], 2'd2}]), .an3(adc_ch[{analog_bank[0], 2'd3}])
        );
        always @(posedge clk_sys)
            if (m_req && m_we && sel_ioex && m_be[0] && is_multi32 &&
                A[5:0] == 6'h20)
                analog_bank <= m_wdata[2:0];   // 0xC00060 analog_bank_w

        for (t = 0; t < 3; t = t + 1) begin : tracks
            s32_upd4701 upd (
                .clk(clk_sys), .rst(rst),
                .delta_valid(trk_dv[t]), .dx(trk_dx[t]), .dy(trk_dy[t]),
                .cs(m_req && sel_ioex && m_be[0] &&
                    board.has_track && A[5:3] == t[2:0]), // B4: 0x40/48/50
                .we(m_we), .addr(A[2:1]),
                .rdata(trk_q[t]), .buttons(trk_btn[t])
            );
        end
    end
endgenerate

wire [7:0] ppi_q;
s32_i8255 ppi (
    .clk(clk_sys),
    .cs(m_req && sel_ppi && m_be[0]),
    .we(m_we), .addr(A[2:1]), .wdata(m_wdata[7:0]), .rdata(ppi_q),
    .pa(ppi_pa), .pb(ppi_pb), .pc_in(ppi_pc), .pc_out()
);

// ---------------------------------------------------------------------------
// interrupt controller
// ---------------------------------------------------------------------------
wire [7:0] intc_q;
s32_intc intc (
    .clk(clk_sys), .rst(rst), .is_multi32(is_multi32),
    .cs(wr_stb && sel_intc), .we(m_we),
    .addr(A[3:1]), .be(m_be), .wdata(m_wdata), .rdata(intc_q),
    .vblank_start(vbl_start), .vblank_end(vbl_end),
    .sound_irq(snd_to_v60),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_taken(1'b0),
    .z80_doorbell(snd_doorbell)
);

// ---------------------------------------------------------------------------
// protection
// ---------------------------------------------------------------------------
wire        br_trap;
wire [15:0] br_trap_q;
wire [15:0] dsp_q, dual_q;
wire [7:0]  v25_q;

generate
    if (GA2_ONLY) begin : g_ga2_no_other_protection
        // GA2 uses the V25 mailbox below.  Generic HLE, Burning Rival and
        // Air Rescue DSP protection are unreachable in the dedicated MRA.
        assign pr_req = 1'b0;
        assign pr_we = 1'b0;
        assign pr_addr = 16'h0000;
        assign pr_wdata = 16'h0000;
        assign pr_be = 2'b00;
        assign br_trap = 1'b0;
        assign br_trap_q = 16'hffff;
        assign dsp_q = 16'hffff;
    end
    else begin : g_other_protection
        s32_prot_hle prot (
            .clk(clk_sys), .rst(rst), .prot_sel(board.prot_sel),
            .cpu_wr(m_req && m_we && (sel_wram || sel_prot_a)),
            .cpu_addr(A), .cpu_wdata(m_wdata),
            .vblank(vbl_start),
            .wram_req(pr_req), .wram_we(pr_we), .wram_addr(pr_addr),
            .wram_wdata(pr_wdata), .wram_be(pr_be),
            .wram_rdata(pr_q), .wram_ack(pr_ack),
            .rom_req(), .rom_addr(), .rom_data(sdr_p0_dout), .rom_ack(1'b0)
        );

        s32_prot_brival brival (
            .clk(clk_sys), .rst(rst), .enable(board.prot_sel == PROT_BRIVAL),
            .cpu_wr(m_req && m_we && sel_prot_a),
            .cpu_addr(A), .cpu_wdata(m_wdata),
            .cpu_rd(m_req && !m_we && sel_wram),
            .trap_active(br_trap), .trap_data(br_trap_q),
            .pram_we(), .pram_addr(), .pram_wdata(),
            .rom_req(), .rom_addr(), .rom_data(sdr_p0_dout), .rom_ack(1'b0)
        );

        s32_arescue_dsp dsp (
            .clk(clk_sys), .rst(rst), .enable(board.has_dsp_hle),
            .cs(m_req && sel_prot_a && A[15:4] == 0), .we(m_we),
            .addr(A[2:1]), .wdata(m_wdata), .rdata(dsp_q)
        );
    end
endgenerate

generate
    if (GA2_ONLY) begin : g_no_dualpcb
        // GA2 is a single-board System 32 title.  Keeping this runtime-dead
        // 4KB array cost 32,784 registers in Quartus 17 because its original
        // read/write shape did not infer block RAM.
        assign dual_q = 16'h0000;
    end
    else begin : g_dualpcb
        s32_dualpcb dual (
            .clk(clk_sys), .enable(board.dual_pcb),
            .cs_ram(m_req && sel_dual && !A[15]),
            .cs_id(m_req && sel_dual && A[15]),
            .we(m_we), .addr(A[11:1]), .wdata(m_wdata), .rdata(dual_q)
        );
    end
endgenerate

`ifdef S32_REAL_V25
s32_v25_cpu v25 (
`else
s32_v25 v25 (
`endif
    .clk(clk_sys), .rst(rst), .enable(board.has_v25),
    .table_sel(board.v25_table),
    .prg_wr(v25_prg_wr), .prg_waddr(v25_prg_waddr), .prg_wdata(v25_prg_wdata),
    .cs(m_req && sel_v25 && board.has_v25 && m_be[0]), .we(m_we),
    .addr(A[11:1]), .wdata(m_wdata[7:0]), .rdata(v25_q)
);

// ---------------------------------------------------------------------------
// V60 ROM fetch via SDRAM p0, through a small I/D cache (perf):
//   32 lines x 8 bytes direct-mapped. Hit = 1 clk_sys; miss = 4 sequential
//   p0 word reads to fill the line. Reset (incl. ROM download) invalidates.
// ---------------------------------------------------------------------------
reg        rom_req_r;
reg [23:1] rom_addr_r;
assign sdr_p0_req  = rom_req_r;
assign sdr_p0_addr = {2'b00, rom_addr_r[21:1]};   // maincpu base = 0

reg  [63:0] icache_data [0:31];
reg  [12:0] icache_tag  [0:31];      // addr[20:8]
reg  [31:0] icache_valid;

// MAME: map(0xf00000, 0xffffff).rom().region("maincpu", 0) — the top window
// mirrors the FIRST megabyte (the V60 reset stub at 0xFFFFF0 lives at
// maincpu offset 0xFFFF0). A[20:0] would fetch reset code from the wrong
// megabyte — found by real-ROM inspection (ga2: JMP $00100506 sits at
// 0x0FFFF0, data at 0x1FFFF0).
wire [20:0] rom_byte_a = sel_romhi ? {1'b0, A[19:0]} : A[20:0];
wire [4:0]  ic_line    = rom_byte_a[7:3];
wire [12:0] ic_tag     = rom_byte_a[20:8];
wire        ic_hit     = icache_valid[ic_line] && (icache_tag[ic_line] == ic_tag);
wire [63:0] ic_ldata   = icache_data[ic_line];
wire [15:0] ic_word    = ic_ldata[{rom_byte_a[2:1], 4'b0000} +: 16];

reg  [1:0]  fill_word;
reg         rom_filling;
reg         rom_ready;               // pulses when requested word available
reg  [15:0] rom_word_r;

always @(posedge clk_sys) begin
    if (rst) begin
        rom_req_r <= 0; rom_filling <= 0; rom_ready <= 0;
        icache_valid <= 32'h0;
    end
    else begin
        rom_req_r <= 0;
        rom_ready <= 0;
        if (m_req && !m_we && (sel_rom || sel_romhi) && !rom_filling && !rom_ready) begin
            if (ic_hit) begin
                rom_word_r <= ic_word;
                rom_ready  <= 1'b1;
            end
            else begin
                rom_filling <= 1'b1;
                fill_word   <= 0;
                rom_req_r   <= 1'b1;
                rom_addr_r  <= {3'b000, rom_byte_a[20:3], 2'b00};
            end
        end
        else if (rom_filling && sdr_p0_ack) begin
            icache_data[ic_line][{fill_word, 4'b0000} +: 16] <= sdr_p0_dout;
            if (fill_word == 2'd3) begin
                rom_filling <= 0;
                icache_tag[ic_line]   <= ic_tag;
                icache_valid[ic_line] <= 1'b1;
                // serve the requested word directly
                rom_word_r <= (rom_byte_a[2:1] == 2'd3) ? sdr_p0_dout
                             : icache_data[ic_line][{rom_byte_a[2:1], 4'b0000} +: 16];
                rom_ready  <= 1'b1;
            end
            else begin
                fill_word  <= fill_word + 1'd1;
                rom_req_r  <= 1'b1;
                rom_addr_r <= {3'b000, rom_byte_a[20:3], 2'b00} + {20'b0, fill_word + 2'd1};
            end
        end
    end
end

// ---------------------------------------------------------------------------
// CPU read mux + ack
// ---------------------------------------------------------------------------
reg [15:0] rmux;
reg        ack_r;
assign m_rdata = rmux;
assign m_ack   = ack_r;

// 16-bit LFSR noise for 0xD80000
reg [15:0] lfsr = 16'hACE1;
always @(posedge clk_sys) if (ce_cpu) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

reg ack_d;
reg rd_wait;   // BRAM/register reads: one dead cycle so the registered q
               // (wram_q, v25 rdata, io rdata, ...) reflects THIS address.
               // Without it rmux latches the previous access's data — the q
               // registers update on the same edge the ack mux samples them.
assign wr_stb = ack_r & ~ack_d;   // one-shot per transaction (for side-effect regs)
always @(posedge clk_sys) begin
    ack_d <= ack_r;
    if (!m_req) begin ack_r <= 0; rd_wait <= 0; end
    else if (!ack_r) begin
        if (sel_rom || sel_romhi) begin
            if (m_we) ack_r <= 1'b1;   // writes to ROM: ack + discard
            else if (rom_ready) begin rmux <= rom_word_r; ack_r <= 1'b1; end
        end
        else if (!m_we && !rd_wait) rd_wait <= 1'b1;
        else begin
            rd_wait <= 1'b0;
            ack_r <= 1'b1;   // BRAM/regs
            casez (1'b1)
                br_trap:     rmux <= br_trap_q;
                sel_wram:    rmux <= wram_q;
                sel_vram:    rmux <= vram_cpu_q;
                sel_sprram:  rmux <= sprram_q;
                sel_sprctl:  rmux <= {8'hff, sprctl_q};
                is_pal0:     rmux <= pal0_cpu_q;
                is_mix0:     rmux <= mix0_q;
                is_pal1:     rmux <= pal1_cpu_q;   // B7: Multi 32 screen B
                is_mix1:     rmux <= mix1_q;
                sel_shared:  rmux <= {8'hff, sh_rdata};
                sel_comm:    rmux <= 16'hffff;      // s32comm absent: link not connected
                sel_dual:    rmux <= board.dual_pcb ? dual_q : 16'hffff;
                sel_v25:     if (GA2_ONLY)
                                 rmux <= {8'hff, v25_q};
                             else
                                 rmux <= board.has_v25 ? {8'hff, v25_q} :
                                         board.has_dsp_hle ? dsp_q : 16'hffff;
                sel_prot_a:  rmux <= board.has_dsp_hle ? dsp_q : 16'hffff;
                sel_io0:     rmux <= {8'hff, io0_q};
                sel_io1:     rmux <= {8'hff, io1_q};
                sel_ioex:    if (GA2_ONLY)
                                 rmux <= sel_ppi ? {8'hff, ppi_q} : 16'hffff;
                             else
                                 rmux <= sel_adc   ? {8'hff, 7'h7f, adc_bit} :
                                         sel_track ? {8'hff, trk_q[A[4]?2:(A[3]?1:0)]} :
                                         sel_ppi   ? {8'hff, ppi_q} : 16'hffff;
                sel_intc:    rmux <= {8'hff, intc_q};
                sel_rand:    rmux <= lfsr;
                default:     rmux <= 16'hffff;
            endcase
        end
    end
end

// Sticky boot-progress telemetry for first-hardware bring-up. A screenshot of
// the diagnostic modes preserves enough state to locate a boot stall without
// requiring SignalTap or changing CPU/memory timing.
reg [23:0] debug_status_r;
reg [15:0] debug_first_rom_r;
reg        debug_first_rom_seen;
reg [15:0] debug_bus_wait;
reg [23:0] debug_prev_pc_r;
reg [23:0] debug_pc_seen_r;
reg [23:0] debug_pc_hist0_r;
reg [23:0] debug_pc_hist1_r;
reg [23:0] debug_pc_hist2_r;
reg [23:0] debug_pc_hist3_r;
reg [23:0] debug_pc_hist4_r;
reg  [7:0] debug_last_irq_vector_r;
reg [23:0] debug_halt_trace_rgb;

// If the CPU halts unexpectedly, expose eight compact post-mortem clues as
// 8-pixel bands. The top-level displays one 64-pixel strip over the otherwise
// unchanged game image, while debug mode 2 repeats the trace across the screen:
//   current PC, previous PC, five older PCs, last/current IRQ vectors.
always @(*) begin
    case (hcnt[5:3])
        3'd0: debug_halt_trace_rgb = v60_debug_pc[23:0];
        3'd1: debug_halt_trace_rgb = debug_prev_pc_r;
        3'd2: debug_halt_trace_rgb = debug_pc_hist0_r;
        3'd3: debug_halt_trace_rgb = debug_pc_hist1_r;
        3'd4: debug_halt_trace_rgb = debug_pc_hist2_r;
        3'd5: debug_halt_trace_rgb = debug_pc_hist3_r;
        3'd6: debug_halt_trace_rgb = debug_pc_hist4_r;
        default: debug_halt_trace_rgb = {8'h00, debug_last_irq_vector_r, irq_vector};
    endcase
end

assign debug_status = v60_debug_halted ? debug_halt_trace_rgb : debug_status_r;
assign debug_first_rom = v60_debug_halted ?
                         {debug_last_irq_vector_r, irq_vector} :
                         debug_first_rom_r;

always @(posedge clk_sys) begin
    if (rst) begin
        debug_status_r       <= 24'h000000;
        debug_first_rom_r    <= 16'h0000;
        debug_first_rom_seen <= 1'b0;
        debug_bus_wait       <= 16'h0000;
        debug_prev_pc_r      <= 24'hfffff0;
        debug_pc_seen_r      <= 24'hfffff0;
        debug_pc_hist0_r     <= 24'hfffff0;
        debug_pc_hist1_r     <= 24'hfffff0;
        debug_pc_hist2_r     <= 24'hfffff0;
        debug_pc_hist3_r     <= 24'hfffff0;
        debug_pc_hist4_r     <= 24'hfffff0;
        debug_last_irq_vector_r <= 8'hff;
    end
    else begin
        if (v60_debug_pc[23:0] != debug_pc_seen_r) begin
            debug_pc_hist4_r <= debug_pc_hist3_r;
            debug_pc_hist3_r <= debug_pc_hist2_r;
            debug_pc_hist2_r <= debug_pc_hist1_r;
            debug_pc_hist1_r <= debug_pc_hist0_r;
            debug_pc_hist0_r <= debug_prev_pc_r;
            debug_prev_pc_r  <= debug_pc_seen_r;
            debug_pc_seen_r  <= v60_debug_pc[23:0];
        end
        // Sampling while the controller asserts IRQ avoids routing the CPU's
        // otherwise-unused irq_ack hierarchy output, which Quartus 17 crashes
        // while elaborating. The value still identifies the selected source.
        if (!irq_n)
            debug_last_irq_vector_r <= irq_vector;

        debug_status_r[0] <= 1'b1;
        if (c_req)       debug_status_r[1]  <= 1'b1;
        if (c_ack)       debug_status_r[2]  <= 1'b1;
        if (m_req)       debug_status_r[3]  <= 1'b1;
        if (m_ack)       debug_status_r[4]  <= 1'b1;
        if (sdr_p0_req)  debug_status_r[5]  <= 1'b1;
        if (sdr_p0_ack)  debug_status_r[6]  <= 1'b1;
        if (v60_debug_pc != 32'h00fffff0)
            debug_status_r[7] <= 1'b1;
        if (v60_debug_pc < 32'h00200000)
            debug_status_r[8] <= 1'b1;
        if (m_req && m_we && sel_wram) debug_status_r[9]  <= 1'b1;
        if (m_req && m_we && sel_vram) debug_status_r[10] <= 1'b1;
        if (m_req && m_we && is_pal0)  debug_status_r[11] <= 1'b1;
        if (m_req && m_we && sel_io0)  debug_status_r[12] <= 1'b1;
        if (m_req && m_we && sel_intc) debug_status_r[13] <= 1'b1;
        if (io0_cnt1)                  debug_status_r[14] <= 1'b1;
        if (v60_debug_halted)          debug_status_r[15] <= 1'b1;
        if (sdr_p1_req)                debug_status_r[16] <= 1'b1;
        if (sdr_p1_ack)                debug_status_r[17] <= 1'b1;
        if (sdr_p2_req)                debug_status_r[18] <= 1'b1;
        if (sdr_p2_ack)                debug_status_r[19] <= 1'b1;
        if (vbl_start)                 debug_status_r[20] <= 1'b1;
        if (!irq_n)                    debug_status_r[21] <= 1'b1;
        if (v60_debug_pc[31:24] != 8'h00)
            debug_status_r[22] <= 1'b1;

        if (m_req && !m_ack) begin
            if (!(&debug_bus_wait)) debug_bus_wait <= debug_bus_wait + 1'd1;
            if (&debug_bus_wait)  debug_status_r[23] <= 1'b1;
        end
        else debug_bus_wait <= 16'h0000;

        if (sdr_p0_ack && !debug_first_rom_seen) begin
            debug_first_rom_seen <= 1'b1;
            debug_first_rom_r    <= sdr_p0_dout;
        end
    end
end

endmodule

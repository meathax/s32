//============================================================================
//  Arcade: Sega System 32 / Multi 32 for MiSTer  (emu top)
//  DESIGN.md §9 — framework integration.
//============================================================================

module emu
(
    input         CLK_50M,
    input         RESET,
    inout  [45:0] HPS_BUS,

    output        CLK_VIDEO,
    output        CE_PIXEL,
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output  [1:0] VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,

    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,

    output  [1:0] BUTTONS,

    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    // DDR3
    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    // SDRAM
    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE,

    input         CLK_AUDIO,   // 24.576 MHz
    inout   [3:0] ADC_BUS,

    // SD-SPI
    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,

    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,

    input         OSD_STATUS
);

// unused framework peripherals
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

import s32_pkg::*;

// Declare the descriptor before it is referenced by the clock-enable logic.
// Quartus 17 otherwise parses board_desc.multi32 as a hierarchical name.
board_desc_t board_desc;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;
// Lit until the index-0 ROM stream has fully drained to SDRAM.
assign LED_USER = ~rom_loaded;
assign LED_POWER = 0;
assign LED_DISK = 0;
assign BUTTONS = 0;

//////////////////////////////////   CONF   ///////////////////////////////////
// BUILD_DATE is normally provided by sys/build_id.tcl -> build_id.v. Guard it
// so the core still compiles cleanly if that define is absent.
`ifndef BUILD_DATE
`define BUILD_DATE "SegaS32"
`endif

localparam CONF_STR = {
    "S32;;",
    "-;",
    "O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "O[6],Screen (Multi32),A,B;",
    "O[7],Service Mode,Off,On;",
    "O[11:8],Debug Video,Game,CPU PC,Progress,First ROM Word,Tile ROM Probe,Sprite ROM Probe,Inputs,Sprite FB/DDR,Palette Rd,FB Overrun,Camera Var,V25;",
    "-;",
    "R[0],Reset;",
    "J1,B1,B2,B3,B4,B5,B6,Start,Coin,Test,Service;",
    "V,v",`BUILD_DATE
};

////////////////////////////   CLOCKS/PLL   ///////////////////////////////////
wire clk_sys, clk_ram, clk_v25, pll_locked;
wire rom_loaded;
wire sdram_ready;
reg  sdram_ready_meta, sdram_ready_sys;
pll pll (
    .refclk_clk(CLK_50M),
    .reset_reset(1'b0),
    .outclk0_clk(clk_ram),    // 96.648 MHz
    .outclk1_clk(clk_sys),    // 48.324 MHz
    .outclk2_clk(SDRAM_CLK),  // 96.648 MHz, 180 deg: centred SDRAM interface
    .outclk3_clk(clk_v25),    // 24.162 MHz (clk_sys/2): s80x86 compute domain
    .locked_export(pll_locked)
);
assign DDRAM_CLK = clk_ram;
assign CLK_VIDEO = clk_sys;

// Keep every game subsystem reset until a complete index-0 ROM transfer has
// drained into SDRAM. The loader itself is reset only by PLL startup so soft
// reset and NVRAM transfers do not forget that ROM is already resident.
wire video_reset = RESET | status[0] | buttons[1] | ~pll_locked;
wire reset = video_reset | ioctl_download | ~rom_loaded | ~sdram_ready_sys;

// Synchronise the controller-ready level from clk_ram before it gates the
// loader and the game logic in clk_sys.
always @(posedge clk_sys) begin
    if (!pll_locked) begin
        sdram_ready_meta <= 1'b0;
        sdram_ready_sys  <= 1'b0;
    end
    else begin
        sdram_ready_meta <= sdram_ready;
        sdram_ready_sys  <= sdram_ready_meta;
    end
end

// fractional clock enables (DESIGN.md §3.3)
reg ce_cpu, ce_z80, ce_fm, ce_pcm;
reg [15:0] acc_cpu, acc_z80, acc_fm, acc_pcm;
wire is_multi32 = board_desc.multi32;
always @(posedge clk_sys) begin
    logic [16:0] s;
    if (reset) begin
        ce_cpu <= 1'b0; ce_z80 <= 1'b0; ce_pcm <= 1'b0;
        acc_cpu <= 16'd0; acc_z80 <= 16'd0; acc_pcm <= 16'd0;
    end
    else begin
        // cpu: 16.108/48.324 = 1/3 (V60) ; 20/48.324 (V70)
        s = acc_cpu + (is_multi32 ? 16'd27122 : 16'd21845);  // /65536 fractions
        ce_cpu <= s[16];
        acc_cpu <= s[15:0];
        // z80: 8.054/48.324 = 1/6 ; 8.0/48.324
        s = acc_z80 + (is_multi32 ? 16'd10849 : 16'd10923);
        ce_z80 <= s[16];
        acc_z80 <= s[15:0];
        // pcm: 12.5/48.324 ; 10/48.324
        s = acc_pcm + (is_multi32 ? 16'd13561 : 16'd16952);
        ce_pcm <= s[16];
        acc_pcm <= s[15:0];
    end
end

// JT12's resettable operator/envelope rings advance only on its enabled
// clock.  Keep the FM chip clock running throughout board/ROM-load reset;
// tying it to the halted Z80 CE leaves those rings unreset and can poison the
// stereo mixer with unknown/random startup state.  PLL unlock is the only
// condition that stops and rephases this NCO.
always @(posedge clk_sys) begin
    logic [16:0] s;
    if (!pll_locked) begin
        ce_fm <= 1'b0;
        acc_fm <= 16'd0;
    end
    else begin
        s = acc_fm + (is_multi32 ? 16'd10849 : 16'd10923);
        ce_fm <= s[16];
        acc_fm <= s[15:0];
    end
end

///////////////////////////////   HPS IO   ////////////////////////////////////
wire  [1:0] buttons;
wire [63:0] status;
wire        ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout, ioctl_din;
wire        eep_upload, eep_modified;
wire  [5:0] eep_rd_addr;
wire [15:0] eep_rd_data;

wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3, joystick_4, joystick_5;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire  [7:0] paddle_0, paddle_1;
wire [24:0] ps2_mouse;

hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),

    .buttons(buttons),
    .status(status),

    .ioctl_download(ioctl_download),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(eep_modified),
    .ioctl_upload_index(8'd3),
    .ioctl_wr(ioctl_wr),
    .ioctl_rd(ioctl_rd),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_din(ioctl_din),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait),

    .joystick_0(joystick_0),
    .joystick_1(joystick_1),
    .joystick_2(joystick_2),
    .joystick_3(joystick_3),
    .joystick_4(joystick_4),
    .joystick_5(joystick_5),
    .joystick_l_analog_0(joystick_l_analog_0),
    .joystick_l_analog_1(joystick_l_analog_1),
    .paddle_0(paddle_0),
    .paddle_1(paddle_1),
    .ps2_mouse(ps2_mouse)
);

// MiSTer MRA NVRAM is a byte stream at index 3. Convert the EEPROM's
// 64x16 little-endian shadow into that stream for save uploads.
s32_eeprom_nvram_if eep_nvram_if (
    .ioctl_upload(ioctl_upload), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .eep_rd_data(eep_rd_data),
    .eep_upload(eep_upload), .eep_rd_addr(eep_rd_addr),
    .ioctl_din(ioctl_din)
);

////////////////////////////   ROM LOADING   //////////////////////////////////
wire        sw_req, sw_ack;
wire [24:1] sw_addr;
wire [15:0] sw_din;
wire  [1:0] sw_be;
wire        v25_wr;
wire [15:0] v25_waddr;
wire  [7:0] v25_wdata;
wire        eep_wr;
wire  [5:0] eep_waddr;
wire [15:0] eep_wdata;

s32_rom_loader loader (
    .clk(clk_sys), .rst(~pll_locked),
    .mem_ready(sdram_ready_sys),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .board_desc(board_desc),
    .sdr_wr_req(sw_req), .sdr_wr_addr(sw_addr), .sdr_wr_din(sw_din),
    .sdr_wr_be(sw_be), .sdr_wr_ack(sw_ack),
    .v25_wr(v25_wr), .v25_waddr(v25_waddr), .v25_wdata(v25_wdata),
    .eep_wr(eep_wr), .eep_waddr(eep_waddr), .eep_wdata(eep_wdata),
    .eep_loaded(), .rom_loaded(rom_loaded)
);

/////////////////////////////////   SDRAM   ///////////////////////////////////
wire        p0_req, p0_ack, p1_req, p1_ack, p2_req, p2_ack, p3_req, p3_ack, p4_req, p4_ack, p5_req, p5_ack;
wire        core_p1_req, core_p2_req;
wire [24:1] p0_addr, p3_addr, p4_addr;
wire [24:3] p1_addr, p5_addr;
wire [24:4] p2_addr;
wire [24:3] core_p1_addr;
wire [24:4] core_p2_addr;
wire [15:0] p0_dout, p3_dout, p4_dout;
wire [63:0] p1_dout, p5_dout;
wire[127:0] p2_dout;

// Read fixed, non-uniform GA2 graphics blocks through the real burst ports.
// Each returned 16-bit lane is displayed as a 64-pixel colour band by the
// debug video mux below.  This distinguishes SDRAM burst corruption from the
// tile/sprite unpackers without changing the normal game path.
wire debug_tile_probe   = status[11:8] == 4'd4;
wire debug_sprite_probe = status[11:8] == 4'd5;
localparam [24:3] DEBUG_TILE_ADDR = SDR_TILES_BASE[24:3] + 22'd92;
localparam [24:4] DEBUG_SPR_ADDR  = SDR_SPRITES_BASE[24:4];
reg         debug_p1_req;
reg         debug_p1_valid, debug_p2_valid;
reg  [63:0] debug_p1_data;
reg [127:0] debug_p2_data;
reg  [24:4] debug_p2_addr;

assign p1_req  = debug_tile_probe   ? debug_p1_req  : core_p1_req;
assign p1_addr = debug_tile_probe   ? DEBUG_TILE_ADDR : core_p1_addr;
// The live sprite probe observes the production port without stealing or
// delaying requests. This keeps mode 5 cycle-identical to normal rendering.
assign p2_req  = core_p2_req;
assign p2_addr = core_p2_addr;

always @(posedge clk_ram) begin
    if (reset || !debug_tile_probe) begin
        debug_p1_req   <= 1'b0;
        debug_p1_valid <= 1'b0;
        debug_p1_data  <= 64'd0;
    end
    else if (!debug_p1_valid) begin
        debug_p1_req <= 1'b1;
        if (p1_ack) begin
            debug_p1_req   <= 1'b0;
            debug_p1_valid <= 1'b1;
            debug_p1_data  <= p1_dout;
        end
    end

    if (reset || !debug_sprite_probe) begin
        debug_p2_valid <= 1'b0;
        debug_p2_data  <= 128'd0;
        debug_p2_addr  <= 21'd0;
    end
    else if (!debug_p2_valid && core_p2_req && p2_ack) begin
        debug_p2_valid <= 1'b1;
        debug_p2_data  <= p2_dout;
        debug_p2_addr  <= core_p2_addr;
    end
end

sdram sdram (
    .clk(clk_ram), .init(~pll_locked), .ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(sw_req), .wr_addr(sw_addr), .wr_din(sw_din), .wr_be(sw_be), .wr_ack(sw_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

////////////////////////////   FRAMEBUFFER   //////////////////////////////////
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow, fbw_busy;
wire        fbe_req, fbe_ack, fbr_req, fbr_ack;
wire  [1:0] fbw_buf, fbe_buf, fbr_buf;
wire  [8:0] fbw_x, fbr_x;
wire  [7:0] fbw_y, fbe_y, fbr_y;
wire [15:0] fbw_pix, fbr_pix;

s32_fb_if fb (
    .clk(clk_ram), .rst(reset),
    .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(fbr_req), .rd_buf(fbr_buf), .rd_y(fbr_y), .rd_ack(fbr_ack),
    .rd_x(fbr_x), .rd_pix(fbr_pix)
);

// Live DDR/framebuffer telemetry for the raw sprite diagnostic. These
// modulo-256 counters are observation-only: no request, acknowledge, or game
// data path depends on them. Splitting erase traffic from renderer flushes is
// essential because a sticky DDR-write flag can otherwise be satisfied by the
// initial clear even when no sprite payload ever reaches memory.
reg [7:0] fbw_count, fbend_count;
reg [7:0] ddrwe_count, erase_count, ddrdata_count, fbrack_count;
reg       fbrack_prev;
always @(posedge clk_ram) begin
    if (reset) begin
        fbw_count     <= 8'd0;
        fbend_count   <= 8'd0;
        ddrwe_count   <= 8'd0;
        erase_count   <= 8'd0;
        ddrdata_count <= 8'd0;
        fbrack_count  <= 8'd0;
        fbrack_prev   <= 1'b0;
    end
    else begin
        if (fbw_valid) fbw_count <= fbw_count + 1'd1;
        if (fbw_end)   fbend_count <= fbend_count + 1'd1;
        if (DDRAM_WE && !DDRAM_BUSY) begin
            if (fbe_req) erase_count <= erase_count + 1'd1;
            else         ddrwe_count <= ddrwe_count + 1'd1;
        end
        if (DDRAM_DOUT_READY)
            ddrdata_count <= ddrdata_count + 1'd1;
        fbrack_prev <= fbr_ack;
        if (fbr_ack && !fbrack_prev)
            fbrack_count <= fbrack_count + 1'd1;
    end
end

//////////////////////////////   INPUTS   /////////////////////////////////////
// MiSTer logical joystick bits are directions [3:0], six arcade buttons
// [9:4], Start [10], Coin [11].  GA2's 315-5296 player ports follow MAME:
// {left,right,up,down,unused,button3,button2,button1}, active low.
function automatic [7:0] p_dig(input [31:0] j);
    p_dig = ~{j[1], j[0], j[3], j[2], 1'b0, j[6], j[5], j[4]};
endfunction

wire [7:0] adc_ch [0:7];
assign adc_ch[0] = joystick_l_analog_0[7:0]   ^ 8'h80;
assign adc_ch[1] = joystick_l_analog_0[15:8]  ^ 8'h80;
assign adc_ch[2] = joystick_l_analog_1[7:0]   ^ 8'h80;
assign adc_ch[3] = joystick_l_analog_1[15:8]  ^ 8'h80;
assign adc_ch[4] = {paddle_0};
assign adc_ch[5] = {paddle_1};
assign adc_ch[6] = 8'h80;
assign adc_ch[7] = 8'h80;

// trackballs from mouse
reg        m_dv [0:2];
reg signed [8:0] m_dx [0:2], m_dy [0:2];
reg mouse_toggle;
always @(posedge clk_sys) begin
    m_dv[0] <= 0; m_dv[1] <= 0; m_dv[2] <= 0;
    if (ps2_mouse[24] != mouse_toggle) begin
        mouse_toggle <= ps2_mouse[24];
        m_dv[0] <= 1'b1;
        m_dx[0] <= {ps2_mouse[4], ps2_mouse[15:8]};
        m_dy[0] <= {ps2_mouse[5], ps2_mouse[23:16]};
    end
end
wire [7:0] trk_btn [0:2];
assign trk_btn[0] = {4'b0, ~joystick_0[4], 3'b0};
assign trk_btn[1] = {4'b0, ~joystick_1[4], 3'b0};
assign trk_btn[2] = {4'b0, ~joystick_2[4], 3'b0};
// Digital trackball fallback: the trackball games (sonic, 3 players) were
// mouse-only, and players 2/3 had no source at all.  A held D-pad now injects
// rate-limited trackball deltas so a gamepad can play.  Player 1 still prefers
// the real mouse when it moves.  TRK_STEP/rate are hardware-tunable, and the Y
// sign may want inverting on hardware.  NOTE: this only reaches the game on a
// UNIVERSAL build -- the S32_HOLO_ONLY profile trims the trackball read decode
// (s32_core sel_ioex under GAME_ONLY).
reg [15:0] trk_div = 16'd0;
always @(posedge clk_sys) trk_div <= trk_div + 1'b1;
wire trk_tick = (trk_div == 16'd0);       // ~12 injections/frame @48 MHz
localparam signed [8:0] TRK_STEP = 9'sd4;

wire p0_dpad = joystick_0[0] | joystick_0[1] | joystick_0[2] | joystick_0[3];
wire p1_dpad = joystick_1[0] | joystick_1[1] | joystick_1[2] | joystick_1[3];
wire p2_dpad = joystick_2[0] | joystick_2[1] | joystick_2[2] | joystick_2[3];

wire trk_dv_a [0:2];
assign trk_dv_a[0] = m_dv[0] | (trk_tick & p0_dpad);
assign trk_dv_a[1] = trk_tick & p1_dpad;
assign trk_dv_a[2] = trk_tick & p2_dpad;
wire signed [8:0] trk_dx_a [0:2];
wire signed [8:0] trk_dy_a [0:2];
// j[0]=right(+x) j[1]=left(-x) j[2]=down(+y) j[3]=up(-y)
assign trk_dx_a[0] = m_dv[0] ? m_dx[0] : joystick_0[0] ? TRK_STEP : joystick_0[1] ? -TRK_STEP : 9'sd0;
assign trk_dy_a[0] = m_dv[0] ? m_dy[0] : joystick_0[2] ? TRK_STEP : joystick_0[3] ? -TRK_STEP : 9'sd0;
assign trk_dx_a[1] = joystick_1[0] ? TRK_STEP : joystick_1[1] ? -TRK_STEP : 9'sd0;
assign trk_dy_a[1] = joystick_1[2] ? TRK_STEP : joystick_1[3] ? -TRK_STEP : 9'sd0;
assign trk_dx_a[2] = joystick_2[0] ? TRK_STEP : joystick_2[1] ? -TRK_STEP : 9'sd0;
assign trk_dy_a[2] = joystick_2[2] ? TRK_STEP : joystick_2[3] ? -TRK_STEP : 9'sd0;

// MAME system32_generic: port C is unused; port E/SERVICE12 is
// {unknown[7:6], start2, start1, coin2, coin1, test, service}, active low.
// Test = the OSD "Service Mode" toggle OR the mappable Test button (j12);
// Service (coin-service credit) = the mappable Service button (j13).
wire [7:0] portc = 8'hff;
wire test_btn = status[7] | joystick_0[12] | joystick_1[12];
wire svc_btn  = joystick_0[13] | joystick_1[13];
wire [7:0] svc12 = ~{2'b00, joystick_1[10], joystick_0[10],
                     joystick_1[11], joystick_0[11], test_btn, svc_btn};
// Port F/SERVICE34: bits 3:0 = DIP SW1:1-4 (Off), bit4 = PCB Push SW1
// (Service), bit5 = PCB Push SW2 (Test), bit6 unknown; bit7 is replaced by the
// EEPROM DO line inside s32_core.  Some games poll the PCB push switches
// rather than the cabinet Test line, so drive them from the same buttons —
// physically equivalent to pressing the matching switch on the board.
wire [7:0] svc34 = ~{2'b00, test_btn, svc_btn, 4'b0000};
// GA2's 4-player i8255 port C is MAME EXTRA3 (ppi.in_pc_callback -> "EXTRA3").
// Base sets: bit0=Start3, bit1=Start4, bits[7:2] unused. The US sets (ga2u,
// spidmanu, arabfgtu) instead read COIN1 on bit3 (0x08) and COIN2 on bit2
// (0x04) here (PORT_MODIFY EXTRA3). IO-11/12: additively drive those two bits
// from the same P1/P2 coin buttons that feed SERVICE12 coin1/coin2, so US sets
// register their primary coins. Safe for every non-US set because they mark
// EXTRA3 bits 2/3 IPT_UNUSED. NOTE (unverified on hardware): on a US set the
// coin button now also pulses SERVICE12 (read there as COIN3/COIN4), so if that
// game credits COIN3/4 as well as COIN1/2 a single press could double-count;
// eliminating that needs a board-descriptor US flag, deferred by choice.
wire [7:0] ga2_ppi_pc = ~{4'b0, joystick_0[11], joystick_1[11],
                          joystick_3[10], joystick_2[10]};

//////////////////////////////   CORE   ///////////////////////////////////////
wire [23:0] rgb_a, rgb_b;
wire ce_pix_core, core_hs, core_vs, core_hb, core_vb;
wire signed [15:0] aud_l, aud_r;
wire [31:0] core_debug_pc;
wire        core_debug_halted;
wire [23:0] core_debug_status;
wire [15:0] core_debug_first_rom;
wire  [8:0] core_debug_hcnt;
wire  [8:0] core_debug_vcnt;
wire [127:0] core_debug_sprite_desc;
wire         core_debug_sprite_desc_valid;
wire [127:0] core_debug_sprite_last_desc;
wire [127:0] core_debug_sprite_last_draw_desc;
wire  [23:0] core_debug_sprite_activity;
wire  [31:0] core_debug_sprite_state;
wire  [63:0] core_debug_sprite_counts;
wire         core_debug_sprite_rendering;
wire  [47:0] core_debug_sprram_cpu;
wire  [47:0] core_debug_pal_rd;      // clk_sys palette shadow {0x410,0x200,0x000}
wire  [23:0] core_debug_fb_underrun; // PF-6: sprite line-fetch overrun telemetry
wire  [15:0] core_debug_cam;         // spidman world-camera {page, display_lo}
wire  [23:0] core_debug_v25;         // V25 bring-up flags/mailbox snoop
wire  [89:0] core_debug_v25_img;     // MCU image hash sweep + first fetched line

s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram),
`ifdef S32_REAL_V25
    .clk_v25(clk_v25),
`endif
    .rst(reset), .video_rst(video_reset),
    .board(board_desc),
    .ce_cpu(ce_cpu), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm),
    .sdr_p0_req(p0_req), .sdr_p0_addr(p0_addr), .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(core_p1_req), .sdr_p1_addr(core_p1_addr), .sdr_p1_dout(p1_dout),
    .sdr_p1_ack(debug_tile_probe ? 1'b0 : p1_ack),
    .sdr_p2_req(core_p2_req), .sdr_p2_addr(core_p2_addr), .sdr_p2_dout(p2_dout),
    .sdr_p2_ack(p2_ack),
    .sdr_p3_req(p3_req), .sdr_p3_addr(p3_addr), .sdr_p3_dout(p3_dout), .sdr_p3_ack(p3_ack),
    .sdr_p4_req(p4_req), .sdr_p4_addr(p4_addr), .sdr_p4_dout(p4_dout), .sdr_p4_ack(p4_ack),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr), .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(fbw_buf), .fb_wr_x(fbw_x), .fb_wr_y(fbw_y),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_wr_busy(fbw_busy),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y), .fb_er_ack(fbe_ack),
    .fb_rd_req(fbr_req), .fb_rd_buf(fbr_buf), .fb_rd_y(fbr_y), .fb_rd_ack(fbr_ack),
    .fb_rd_x(fbr_x), .fb_rd_pix(fbr_pix),
    .v25_prg_wr(v25_wr), .v25_prg_waddr(v25_waddr), .v25_prg_wdata(v25_wdata),
    .eep_ld_wr(eep_wr), .eep_ld_addr(eep_waddr), .eep_ld_data(eep_wdata),
    .eep_rd_data(eep_rd_data), .eep_rd_addr(eep_rd_addr),
    .eep_upload(eep_upload), .eep_modified(eep_modified),
    .in_p1a(p_dig(joystick_0)), .in_p2a(p_dig(joystick_1)),
    .in_portc(portc), .in_svc12(svc12), .in_svc34(svc34),
    .in_p1b(p_dig(joystick_2)), .in_p2b(p_dig(joystick_3)),
    .in_portc_b(8'hff), .in_svc12_b(8'hff), .in_svc34_b(8'hff),
    .adc_ch(adc_ch),
    .trk_dv(trk_dv_a), .trk_dx(trk_dx_a), .trk_dy(trk_dy_a), .trk_btn(trk_btn),
    .ppi_pa(p_dig(joystick_2)), .ppi_pb(p_dig(joystick_3)), .ppi_pc(ga2_ppi_pc),
    .rgb_a(rgb_a), .rgb_b(rgb_b),
    .ce_pix(ce_pix_core),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .audio_l(aud_l), .audio_r(aud_r),
    .out_lamps(),
    .debug_pc(core_debug_pc), .debug_halted(core_debug_halted),
    .debug_status(core_debug_status), .debug_first_rom(core_debug_first_rom),
    .debug_hcnt(core_debug_hcnt), .debug_vcnt(core_debug_vcnt),
    .debug_sprite_desc(core_debug_sprite_desc),
    .debug_sprite_desc_valid(core_debug_sprite_desc_valid),
    .debug_sprite_last_desc(core_debug_sprite_last_desc),
    .debug_sprite_last_draw_desc(core_debug_sprite_last_draw_desc),
    .debug_sprite_activity(core_debug_sprite_activity),
    .debug_sprite_state(core_debug_sprite_state),
    .debug_sprite_counts(core_debug_sprite_counts),
    .debug_sprite_rendering(core_debug_sprite_rendering),
    .debug_sprram_cpu(core_debug_sprram_cpu),
    .debug_pal_rd(core_debug_pal_rd),
    .debug_fb_underrun(core_debug_fb_underrun),
    .debug_cam(core_debug_cam),
    .debug_v25(core_debug_v25),
    .debug_v25_img(core_debug_v25_img)
);

assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

//////////////////////////////   VIDEO   //////////////////////////////////////
wire [23:0] game_rgb = status[6] ? rgb_b : rgb_a;
wire [15:0] debug_p1_word = debug_p1_data[{core_debug_hcnt[7:6], 4'b0000} +: 16];
// Mode 5 is a four-band sprite post-mortem. Every cell is 16 pixels wide so
// one screenshot gives stable, exact RGB values even if p2 never requests.
//   y=  0..55 : summary, CPU sprite-RAM writes, activity/state/counts
//   y= 56..111: last decoded descriptor (D0..D7 tags, words 0..7)
//   y=112..167: last draw descriptor    (E0..E7 tags, words 0..7)
//   y=168..223: first ROM descriptor (F0..F7), data (A0..A7), addr/flags
// Summary cells x=0,16,...,160 are: signature; CPU write count/status/address
// high; CPU address-low/data; activity; state-low; "ST"/state-high;
// swap/decode/END counts; JUMP/zero/draw counts; fromRAM/ROM-request/flags;
// first p2 physical address; and p2-valid/descriptor-valid/rendering as
// full-intensity R/G/B. CPU status byte = {seen, last_BE[1:0], 5'b0}.
// Descriptor cell RGB = {tag, word[15:8], word[7:0]}, word 0 first.
wire [4:0] debug_p2_cell = core_debug_hcnt[8:4];
wire [2:0] debug_p2_word_sel = core_debug_hcnt[6:4];
wire [15:0] debug_p2_last_word =
    core_debug_sprite_last_desc[{debug_p2_word_sel, 4'b0000} +: 16];
wire [15:0] debug_p2_draw_word =
    core_debug_sprite_last_draw_desc[{debug_p2_word_sel, 4'b0000} +: 16];
wire [15:0] debug_p2_first_word =
    core_debug_sprite_desc[{debug_p2_word_sel, 4'b0000} +: 16];
wire [15:0] debug_p2_rom_word =
    debug_p2_data[{debug_p2_word_sel, 4'b0000} +: 16];
wire [7:0] debug_p2_flags = {5'b00000, core_debug_sprite_rendering,
                            core_debug_sprite_desc_valid, debug_p2_valid};
reg [23:0] debug_p2_rgb;
always @(*) begin
    debug_p2_rgb = 24'h000000;
    if (core_debug_vcnt < 9'd56) begin
        case (debug_p2_cell)
            5'd0: debug_p2_rgb = 24'h533205; // "S2", diagnostic revision 5
            5'd1: debug_p2_rgb = core_debug_sprram_cpu[47:24];
            5'd2: debug_p2_rgb = core_debug_sprram_cpu[23:0];
            5'd3: debug_p2_rgb = core_debug_sprite_activity;
            5'd4: debug_p2_rgb = core_debug_sprite_state[23:0];
            5'd5: debug_p2_rgb = {16'h5354, core_debug_sprite_state[31:24]};
            5'd6: debug_p2_rgb = {core_debug_sprite_counts[7:0],
                                  core_debug_sprite_counts[15:8],
                                  core_debug_sprite_counts[23:16]};
            5'd7: debug_p2_rgb = {core_debug_sprite_counts[31:24],
                                  core_debug_sprite_counts[39:32],
                                  core_debug_sprite_counts[47:40]};
            5'd8: debug_p2_rgb = {core_debug_sprite_counts[55:48],
                                  core_debug_sprite_counts[63:56],
                                  debug_p2_flags};
            5'd9: debug_p2_rgb = {3'b000, debug_p2_addr};
            5'd10: debug_p2_rgb = {debug_p2_valid ? 8'hff : 8'h00,
                                   core_debug_sprite_desc_valid ? 8'hff : 8'h00,
                                   core_debug_sprite_rendering ? 8'hff : 8'h00};
            default: debug_p2_rgb = 24'h000000;
        endcase
    end
    else if (core_debug_vcnt < 9'd112) begin
        if (debug_p2_cell < 5'd8)
            debug_p2_rgb = {8'hd0 + {5'b00000, debug_p2_word_sel},
                            debug_p2_last_word};
        else if (debug_p2_cell == 5'd8) debug_p2_rgb = core_debug_sprite_activity;
        else if (debug_p2_cell == 5'd9) debug_p2_rgb = core_debug_sprite_state[23:0];
    end
    else if (core_debug_vcnt < 9'd168) begin
        if (debug_p2_cell < 5'd8)
            debug_p2_rgb = {8'he0 + {5'b00000, debug_p2_word_sel},
                            debug_p2_draw_word};
        else if (debug_p2_cell == 5'd8) debug_p2_rgb = core_debug_sprite_activity;
        else if (debug_p2_cell == 5'd9) debug_p2_rgb = core_debug_sprite_state[23:0];
    end
    else begin
        if (debug_p2_cell < 5'd8)
            debug_p2_rgb = {8'hf0 + {5'b00000, debug_p2_word_sel},
                            debug_p2_first_word};
        else if (debug_p2_cell < 5'd16)
            debug_p2_rgb = {8'ha0 + {5'b00000, debug_p2_word_sel},
                            debug_p2_rom_word};
        else if (debug_p2_cell == 5'd16) debug_p2_rgb = {3'b000, debug_p2_addr};
        else if (debug_p2_cell == 5'd17) debug_p2_rgb = {16'h0000, debug_p2_flags};
        else if (debug_p2_cell == 5'd18) debug_p2_rgb = core_debug_sprite_activity;
        else if (debug_p2_cell == 5'd19) debug_p2_rgb = core_debug_sprite_state[23:0];
    end
end
reg input_coin_seen, input_start_seen;
always @(posedge clk_sys) begin
    if (reset) begin
        input_coin_seen  <= 1'b0;
        input_start_seen <= 1'b0;
    end
    else begin
        if (!svc12[2]) input_coin_seen  <= 1'b1;
        if (!svc12[4]) input_start_seen <= 1'b1;
    end
end

// Three 32-pixel bands expose live state:
 //   R/G/B band 0 = renderer pixels / run ends / {write buf, read buf}
 //   R/G/B band 1 = non-erase writes / erase writes / line acknowledgements
 //   R/G/B band 2 = returned DDR beats / current erase line / read line
 // The remainder is the raw 16-bit sprite framebuffer pixel.
wire [23:0] debug_fb_rgb = core_debug_hcnt < 9'd32 ?
                              {fbw_count, fbend_count,
                               4'b0000, fbw_buf, fbr_buf} :
                           core_debug_hcnt < 9'd64 ?
                              {ddrwe_count, erase_count, fbrack_count} :
                           core_debug_hcnt < 9'd96 ?
                              {ddrdata_count, fbe_y, fbr_y} :
                              {8'h00, fbr_pix};

// Palette-readback diagnostic (audit R20 palette suspects).  Three horizontal
// bands show the clk_sys native content of palette entries 0x000 (top),
// 0x200 (middle — the Holosseum backdrop) and 0x410 (bottom — sprite base),
// converted xBBBBBGGGGGRRRRR -> RGB888.  Comparing the middle band (clk_sys
// shadow of 0x200) against the normal game backdrop (clk_ram read of 0x200)
// splits the fault: middle-band black + game background blue => a below-RTL
// read/storage divergence; both blue => a write-side value fault.
wire [15:0] dbg_pal_sel = (core_debug_vcnt < 9'd74)  ? core_debug_pal_rd[15:0]  :
                          (core_debug_vcnt < 9'd149) ? core_debug_pal_rd[31:16] :
                                                       core_debug_pal_rd[47:32];
wire [4:0] dbg_pr = dbg_pal_sel[4:0], dbg_pg = dbg_pal_sel[9:5], dbg_pb = dbg_pal_sel[14:10];
wire [23:0] debug_pal_rgb = {dbg_pr, dbg_pr[4:2], dbg_pg, dbg_pg[4:2], dbg_pb, dbg_pb[4:2]};

// Camera-var view: GREEN = display low byte 0x208032 (should ramp smoothly as
// you walk right); MAGENTA = page byte 0x208033 scaled (should step up only at
// page boundaries).  If magenta jumps up almost immediately while green is
// still low, the core's page is running ahead of the display -> the carry
// divergence behind the early Venom/Scorpion triggers.
wire [7:0] cam_page = core_debug_cam[15:8];
wire [7:0] cam_lo   = core_debug_cam[7:0];
wire [7:0] cam_mag  = {cam_page[2:0], 5'h00};
wire [23:0] debug_cam_rgb = {cam_mag, cam_lo, cam_mag};

// V25 view, three horizontal bands (core_debug_v25 =
// {ce[3:0], wake, mb_nonzero, unmapped, io, rd_cnt[7:0], mb_last[7:0]}):
//   top:    RED flickers ~10Hz while the V25 is being clocked;
//           GREEN solid = firmware touched internal I/O (it executes);
//           BLUE solid  = unmapped access seen (executing garbage).
//   middle: gray level = the byte the V60 last read from 0xA00100
//           (0x00 black = V25 silent; 'w' 0x77 = wake string present).
//   bottom: RED changes while the V60 polls the mailbox;
//           GREEN solid = wake byte confirmed  ->  V25 fully healthy;
//           BLUE solid  = some nonzero mailbox byte was read.
wire [7:0] v25_mb_last  = core_debug_v25[7:0];
wire [7:0] v25_rd_cnt   = core_debug_v25[15:8];
wire       v25_io       = core_debug_v25[16];
wire       v25_unm      = core_debug_v25[17];
wire       v25_mb_nz    = core_debug_v25[18];
wire       v25_wake     = core_debug_v25[19];
wire [3:0] v25_ce_blink = core_debug_v25[23:20];
wire [63:0] v25_first_line = core_debug_v25_img[63:0];
wire [23:0] v25_img_hash   = core_debug_v25_img[87:64];
wire        v25_first_vld  = core_debug_v25_img[88];
wire        v25_sweep_done = core_debug_v25_img[89];
// Bands top→bottom: status flags / image hash as a solid colour / the first
// fetched 8-byte line as 8 grey stripes (32px each, repeating) / last V60
// mailbox-0x100 byte / V60 poll activity.
wire  [2:0] v25_seg = core_debug_hcnt[7:5];
wire  [7:0] v25_seg_byte = v25_first_line[{v25_seg, 3'b000} +: 8];
wire [23:0] debug_v25_rgb =
    (core_debug_vcnt < 9'd40)  ? {{v25_ce_blink, 4'h0},
                                  v25_io  ? 8'hff : 8'h00,
                                  v25_unm ? 8'hff : 8'h00} :
    (core_debug_vcnt < 9'd80)  ? (v25_sweep_done
                                    ? {v25_img_hash[23:16], v25_img_hash[15:8],
                                       v25_img_hash[7:0]}
                                    : 24'h400040) :
    (core_debug_vcnt < 9'd140) ? (v25_first_vld
                                    ? {v25_seg_byte, v25_seg_byte, v25_seg_byte}
                                    : 24'h400000) :
    (core_debug_vcnt < 9'd180) ? {v25_mb_last, v25_mb_last, v25_mb_last} :
                                 {v25_rd_cnt,
                                  v25_wake  ? 8'hff : 8'h00,
                                  v25_mb_nz ? 8'hff : 8'h00};

wire [23:0] debug_rgb = status[11:8] == 4'd1 ? core_debug_pc[23:0] :
                        status[11:8] == 4'd2 ? core_debug_status :
                        status[11:8] == 4'd3 ? {8'h00, core_debug_first_rom} :
                        status[11:8] == 4'd4 ? (debug_p1_valid ? {8'h00, debug_p1_word} : 24'hC00000) :
                        status[11:8] == 4'd5 ? debug_p2_rgb :
                        status[11:8] == 4'd6 ? {input_coin_seen ? 8'hff : 8'h00,
                                               input_start_seen ? 8'hff : 8'h00,
                                               ~svc12} :
                        status[11:8] == 4'd7 ? debug_fb_rgb :
                        status[11:8] == 4'd8 ? debug_pal_rgb :
                        status[11:8] == 4'd9 ? core_debug_fb_underrun :
                        status[11:8] == 4'd10 ? debug_cam_rgb :
                        status[11:8] == 4'd11 ? debug_v25_rgb :
                                                   game_rgb;
// Valid sync continues throughout startup. The solid colour identifies the
// exact gate holding game logic: blue=download, red=ROM completion,
// yellow=external/OSD reset. Normal game RGB takes over after boot.
wire [23:0] rgb_out = ioctl_download ? 24'h0000C0 :
                        ~rom_loaded   ? 24'hC00000 :
                        video_reset   ? 24'hC0C000 : debug_rgb;

assign CE_PIXEL = ce_pix_core;
assign VGA_R  = rgb_out[23:16];
assign VGA_G  = rgb_out[15:8];
assign VGA_B  = rgb_out[7:0];
assign VGA_HS = core_hs;
assign VGA_VS = core_vs;
assign VGA_DE = ~(core_hb | core_vb);
// Scandoubler Fx is a 3-bit field (None/CRT 25/50/75).  VGA_SL takes the two low
// bits directly so None=0 and CRT 25/50/75 map to 1/2/3 (audit R20 PF-1 — the old
// status[5:4] slice made CRT 75% unreachable; audit F2 — dropped the
// non-functional "HQ2x" option, this core has no hq2x scaler instance).
wire [2:0] scandoubler_fx = status[5:3];
wire [2:0] scanline_level = scandoubler_fx;   // None=0, CRT 25/50/75 = 1/2/3
assign VGA_SL = scanline_level[1:0];

// Original = the 4:3 arcade monitor (MAME's default for both 320- and 416-wide
// System 32 modes); the old 13:7 square-pixel ratio stretched holo's 320 mode.
// Full Screen fills; [ARC1]/[ARC2] emit the framework custom-aspect encoding
// (ARY=0, ARX = menu index) instead of acting as 16:9 (audit R20 PF-2).
wire [1:0] aspect = status[2:1];
assign VIDEO_ARX = (aspect == 0) ? 13'd4 : {11'd0, (aspect - 1'd1)};
assign VIDEO_ARY = (aspect == 0) ? 13'd3 : 13'd0;

endmodule

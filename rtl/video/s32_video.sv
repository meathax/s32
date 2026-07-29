//============================================================================
//  System 32 video top: CRT timing (design note §6.8) + pipeline orchestration.
//  416x224 in 512x262 @ 60.04 Hz (dot CE = clk_sys/6 = 8.052885 MHz), or
//  320x224 in 410x262 @ 59.97 Hz (dot CE = clk_sys*2/15 = 6.442308 MHz).
//  Mode from $1FF00 bit 15.  ga2 runs in 320 mode.
//
//  TODO(provenance, audit SY-V1/V3/X5): htotal 512/410, VTOTAL 261 and the
//  hsync/vsync positions below have no cited source.  MAME is not one -- it
//  models no dot clock and no horizontal blanking at all (set_size(52*8,262)
//  + 60 Hz, no set_raw).  MacDonald's probed figures are 512.33 px/line for
//  416 mode (consistent with 512 here) and 397.58 for 320 mode (not 410), but
//  he labels the per-line numbers "preliminary ideas".  The sync structure
//  (front porch / sync width / back porch) is undocumented anywhere.  The one
//  accuracy-critical number is the vblank IRQ raster line, which is inherited
//  from MAME's visarea rather than measured; it sets the whole CPU frame
//  budget.  Settling any of this needs a PCB capture.
//============================================================================

module s32_video (
    input             clk,          // clk_sys (48.3 MHz)
    input             rst,
    input             mode_416,

    output reg        ce_pix,
    output reg        mode_active,
    output reg  [8:0] hcnt,
    output reg  [8:0] vcnt,
    output reg        hblank,
    output reg        vblank,
    output reg        hsync,
    output reg        vsync,
    output            vblank_start, // pulse: line 224 start (IRQ source 0)
    output            vblank_end    // pulse: line 0 start   (IRQ source 1)
);

// Dot-clock CE.  EXACT integer ratios -- do NOT convert this to a fractional
// NCO.  416 mode is 40/240 = 1/6 (one pixel every 6 clk_sys); 320 mode is
// 32/240 = 2/15 (two pixels every 15 clk_sys).  Both divide clk_sys with no
// remainder, so a 410-pixel 320-mode line is exactly 3075 clk_sys and every
// line on screen is bit-identical in length.  The hsync edge therefore never
// moves relative to clk_sys, and the line frequency is dead stable.
//
// *** REGRESSION HISTORY -- READ BEFORE "IMPROVING" THIS (audit SY-V5). ***
// A 2026-07-28 revision replaced these dividers with 16-bit NCOs (10924 / 8738)
// to chase the documented PCLK rates: the board's 416-mode dot clock is
// OSC1/4 = 8.053975 MHz where /6 of clk_sys gives 8.052885 MHz, a 0.0135%
// average-frequency error.  That change SHIPPED AND WAS REPORTED BY A USER as
// the picture shaking side to side on a consumer CRT, and was reverted here.
//
// Why it fails: an NCO's accumulator does not repeat within a line (period
// 32768 for 8738/65536), so consecutive lines differ in length by up to one
// clk_sys = 20.7 ns.  A consumer TV's horizontal AFC has a narrow capture
// range and expects a rock-stable line period; ~20 ns of random line-to-line
// jitter is plainly visible as horizontal instability.  A PVM/BVM tolerates
// it, a consumer set does not.  The 0.0135% average error the NCO "fixed" is
// imperceptible, so the trade was strictly negative.
//
// RULE: any future change here must keep the pixel period an exact integer (or
// exact repeating pattern) number of clk_sys cycles.  Average frequency
// accuracy is worth far less than line-to-line stability on a CRT.
//
// ga2 uses the 320-mode path: every write to $31FF00 across 25,085 attract
// frames has bit 15 clear (verif/mame/ga2_regtrace.lua), and MAME's runtime
// visarea for ga2 probes as 320x224 -- the "416x224" in MAME front-ends is the
// driver's static set_size(52*8,262), not the runtime visarea.
//
// TODO(provenance, audit SY-V1/X5): 320-mode here is 6.442308 MHz with htotal
// 410, giving 6.442308/(410*262) = 59.97 Hz.  MacDonald probed the real 320
// PCLK as OSC2/8 = 6.25 MHz with ~397.58 px/line.  Our two errors CANCEL to
// very nearly the right frame rate; correcting the clock alone would give
// 58.2 Hz and run ga2 ~3% slow.  Both numbers must move together, and his
// per-line figure is back-derived from an assumed 60 Hz (circular), so htotal
// still has no independent source.  Needs a PCB hsync/vsync capture, and any
// replacement must still satisfy the exact-integer RULE above.
reg [7:0] ce_acc;
wire [7:0] ce_add = mode_active ? 8'd40 : 8'd32; // 40/240=1/6 ; 32/240=2/15
always @(posedge clk) begin
    if (rst) begin ce_acc <= 0; ce_pix <= 0; end
    else begin
        logic [8:0] s;
        s = ce_acc + ce_add;
        ce_pix <= (s >= 9'd240);
        // s is at most 279, so the wrapped result is 0..39.  Work on the
        // explicit low byte to avoid an implicit 9-to-8-bit truncation.
        ce_acc <= (s >= 9'd240) ? (s[7:0] - 8'd240) : s[7:0];
    end
end

wire [8:0] htotal = mode_active ? 9'd511 : 9'd409;
wire [8:0] hdisp  = mode_active ? 9'd415 : 9'd319;
localparam [8:0] VTOTAL = 9'd261;
localparam [8:0] VDISP  = 9'd223;

reg vb_start_r, vb_end_r;
assign vblank_start = vb_start_r;
assign vblank_end   = vb_end_r;

always @(posedge clk) begin
    if (rst) begin
        mode_active <= mode_416;
        hcnt <= 0; vcnt <= 0;
        hblank <= 0; vblank <= 0; hsync <= 0; vsync <= 0;
        vb_start_r <= 0; vb_end_r <= 0;
    end
    else begin
        vb_start_r <= 0;
        vb_end_r   <= 0;
        if (ce_pix) begin
            if (hcnt == htotal) begin
                hcnt <= 0;
                hblank <= 0;
                if (vcnt == VTOTAL) begin
                    vcnt <= 0;
                    vblank <= 0;
                    vb_end_r <= 1'b1;
                    // Width affects dot cadence and horizontal totals.  Apply
                    // it only between complete frames so a live register
                    // write cannot truncate or stretch the current line.
                    mode_active <= mode_416;
                end
                else begin
                    vcnt <= vcnt + 1'd1;
                    if (vcnt == VDISP) begin
                        vblank <= 1'b1;
                        vb_start_r <= 1'b1;
                    end
                end
            end
            else begin
                hcnt <= hcnt + 1'd1;
                if (hcnt == hdisp) hblank <= 1'b1;
            end
            // syncs in blanking region
            hsync <= (hcnt >= hdisp + 9'd24) && (hcnt < hdisp + 9'd56);
            vsync <= (vcnt >= VDISP  + 9'd10) && (vcnt < VDISP + 9'd13);
        end
    end
end

endmodule

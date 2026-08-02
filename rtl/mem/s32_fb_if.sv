//============================================================================
//  Sega System 32 — sprite framebuffer interface (DESIGN.md §4.4)
//  Backing store: MiSTer DDR3 (DDRAM 64-bit burst interface).
//  Layout: 4 buffers (A/B x screen0/1), stride 512 pixels x 16 bit,
//  256 lines. Base = FB_BASE + buf*512*256*2.
//  Services (per DESIGN.md):
//    - erase_line(y):     fill line with 0xFFFF
//    - write_run(...):    pixel run writes from the sprite renderer;
//                         wr_shadow runs RMW dest &= 0x7fff instead
//                         (MAME shadow sprites clear framebuffer bit 15)
//    - read_line(y):      whole-line fetch into mixer line buffer
//  A run's untouched pixels are never written: a per-pixel valid mask
//  drives the DDR byte enables (partial head/tail words stay intact).
//  wr_busy holds the renderer off while the previous run drains.
//============================================================================

module s32_fb_if #(
    parameter [31:0] FB_BASE = 32'h3000_0000
)(
    input             clk,      // clk_ram
    input             rst,

    // DDRAM (MiSTer)
    input             DDRAM_BUSY,
    output      [7:0] DDRAM_BURSTCNT,
    output     [28:0] DDRAM_ADDR,
    input      [63:0] DDRAM_DOUT,
    input             DDRAM_DOUT_READY,
    output            DDRAM_RD,
    output     [63:0] DDRAM_DIN,
    output      [7:0] DDRAM_BE,
    output            DDRAM_WE,

    // renderer write port: run of pixels, 1/clk while wvalid.
    // wr_x is PER PIXEL (absolute x) — pixels may arrive in any order and
    // with gaps (flipped sprites sweep right-to-left; clip-out punches holes)
    input             wr_start,        // begin run (latches y/buf/shadow)
    input       [1:0] wr_buf,          // buffer select
    input       [8:0] wr_x,            // x of THIS pixel (valid with wr_valid)
    input       [7:0] wr_y,
    input             wr_valid,        // one pixel this cycle
    input      [15:0] wr_pix,
    input             wr_end,
    input             wr_shadow,       // run is a shadow RMW (dest &= 0x7fff)
    output            wr_busy,         // previous run still flushing

    // erase port
    input             er_req,
    input       [1:0] er_buf,
    input       [7:0] er_y,
    output reg        er_ack,

    // line read port -> mixer
    input             rd_req,
    input       [1:0] rd_buf,
    input       [1:0] rd_buf_alt,       // preceding completed field
    input             rd_dual,          // combine current + preceding field
    input       [7:0] rd_y,
    output reg        rd_ack,          // line available in buffer
    input       [8:0] rd_x,            // synchronous read of fetched line
    output     [15:0] rd_pix
);

// line assembly buffer for writes: pixels land at their absolute x, a mask
// tracks which were written; flush covers [run_x0 .. run_xe] with byte
// enables from the mask (order/gap agnostic)
// Store four pixels per entry, matching one 64-bit DDR word.  The explicit
// RAM below has a 16-bit-lane write port for arbitrary-order sprite pixels and
// a synchronous 64-bit flush read port.  Keeping this out of flops removes the
// 8,192-register run buffer and its large read mux from the integrated map.
reg [511:0] run_msk;               // which pixels this run actually wrote
// Two fetched/composed lines. Scanout reads one M10K bank while DDR fills the
// other, allowing the next line to be requested near the start of the current
// line instead of racing the renderer during the short horizontal blank.
reg [8:0]   run_x0, run_xe;        // min / max written x
reg [7:0]   run_y;
reg [1:0]   run_bufsel;
reg         run_active;
reg         run_shadow;
reg         run_any;               // at least one pixel written

// Match the registered tile line-buffer latency.  The mixer deliberately
// waits one clk_ram edge after disp_x changes before snapshotting all layer
// pixels, so registering this read both aligns sprites with the tile layers
// and prevents a deep clk_sys -> clk_ram path through the priority logic.
reg  [1:0] rd_lane;
reg        display_bank;
reg        fill_bank;
reg        line_ready;
wire       rd_line_publish = (rd_x == 9'd0) && line_ready;
wire       scan_bank = rd_line_publish ? fill_bank : display_bank;

// Resolve optional alternating player fields while the preceding field is
// fetched from DDR, before acknowledging the completed line to scanout.
// System 32 regards both 0xffff and 0x7fff as transparent; the latter is what
// remains when a shadow RMW crosses an erased pixel.  For 0x7fff, retain the
// preceding field's pixel while applying the newest field's shadow flag.  This
// makes both player HUD/sight fields solid without dropping shadow semantics.
// Keeping the composed result in the inactive line RAM removes both a second
// scanout RAM and the transparency compare from the 96.6 MHz pixel-read path.
function automatic [63:0] compose_line_word(
    input [63:0] newest,
    input [63:0] prior
);
    reg [63:0] result;
    begin
        result = newest;
        if (&newest[14:0]) begin
            result[14:0] = prior[14:0];
            result[15] = prior[15] & newest[15];
        end
        if (&newest[30:16]) begin
            result[30:16] = prior[30:16];
            result[31] = prior[31] & newest[31];
        end
        if (&newest[46:32]) begin
            result[46:32] = prior[46:32];
            result[47] = prior[47] & newest[47];
        end
        if (&newest[62:48]) begin
            result[62:48] = prior[62:48];
            result[63] = prior[63] & newest[63];
        end
        compose_line_word = result;
    end
endfunction

reg rd_dual_latched;

// DDR engine
typedef enum logic [3:0] { D_IDLE, D_WR_PF, D_WR, D_ER, D_RD, D_RD_W,
                           D_RD_ALT, D_RD_ALT_W, D_RD_ALT_FLUSH,
                           D_SH_R, D_SH_RW, D_SH_W } dstate_t;
dstate_t dst = D_IDLE;

reg [28:0] daddr;
reg [7:0]  dburst;
reg        dwe, drd;
reg [63:0] ddin;
reg [7:0]  dbe;
reg [6:0]  beat, beats;
reg [6:0]  rbeat;
reg [1:0]  rd_buf_alt_latched;
reg [63:0] compose_prior;
reg  [6:0] compose_addr;
reg        compose_valid;

// Each bank is a true 128x64 simple-dual-port RAM. During a second field
// field fetch, the inactive bank's read port feeds a one-beat RMW pipeline;
// the active bank remains dedicated to scanout. Keeping the bank select
// outside the memory array prevents Quartus from flattening the two lines into
// 16,384 registers and more than 12,000 ALUTs.
wire       compose_state = (dst == D_RD_ALT_W) ||
                           (dst == D_RD_ALT_FLUSH);
wire [6:0] line_raddr0 = (compose_state && !fill_bank) ? rbeat
                                                       : rd_x[8:2];
wire [6:0] line_raddr1 = (compose_state &&  fill_bank) ? rbeat
                                                       : rd_x[8:2];
wire [63:0] line_q0, line_q1;
wire [63:0] fill_line_q = fill_bank ? line_q1 : line_q0;
wire        line_direct_we = (dst == D_RD_W) && DDRAM_DOUT_READY;
wire        line_compose_we = compose_state && compose_valid;
wire        line_we = line_direct_we || line_compose_we;
wire [6:0]  line_waddr = line_compose_we ? compose_addr : rbeat;
wire [63:0] line_wdata = line_compose_we
                       ? compose_line_word(fill_line_q, compose_prior)
                       : DDRAM_DOUT;
wire        line_we0 = line_we && !fill_bank;
wire        line_we1 = line_we &&  fill_bank;

s32_fb_line_ram line_ram0 (
    .clk(clk), .wr_en(line_we0), .wr_addr(line_waddr),
    .wr_data(line_wdata), .rd_addr(line_raddr0), .rd_q(line_q0)
);
s32_fb_line_ram line_ram1 (
    .clk(clk), .wr_en(line_we1), .wr_addr(line_waddr),
    .wr_data(line_wdata), .rd_addr(line_raddr1), .rd_q(line_q1)
);

wire [63:0] rd_word = scan_bank ? line_q1 : line_q0;
assign rd_pix = (rd_lane == 2'd0) ? rd_word[15:0]  :
                (rd_lane == 2'd1) ? rd_word[31:16] :
                (rd_lane == 2'd2) ? rd_word[47:32] : rd_word[63:48];

always @(posedge clk) begin
    if (rst) begin
        rd_lane <= 2'd0;
    end
    else begin
        rd_lane <= rd_x[1:0];
    end
end

function automatic [28:0] pix_addr(input [1:0] buf_i, input [7:0] y,
                                   input [6:0] x_word);
    // 64-bit word address for DDRAM: byte addr / 8
    pix_addr = FB_BASE[31:3] + {{12{1'b0}}, buf_i, 15'b0}
                                + {{14{1'b0}}, y, 7'b0}
                                + {22'b0, x_word};
endfunction

// Synchronous run-buffer read pipeline.  D_WR_PF consumes the base word
// fetched while D_IDLE accepted the flush.  Thereafter the RAM looks one word
// ahead while DDR is stalled, or two words ahead on an accepted write; at the
// accepting edge q still contains the immediately following word.  Thus the
// registered RAM sustains one DDR word per accepted clock without allowing a
// stalled request's data to change.
wire [6:0] run_word_base = run_x0[8:2];
wire [6:0] run_cur_word  = run_word_base + beat;
wire [6:0] run_next_word = run_cur_word + 7'd1;
wire [6:0] run_ram_raddr = (dst == D_IDLE)  ? run_word_base :
                            (dst == D_WR_PF) ? run_next_word :
                            (dst == D_WR)    ? run_cur_word
                                                + (DDRAM_BUSY ? 7'd1 : 7'd2) :
                                               run_cur_word;

wire [3:0] run_base_mask = run_msk[{run_word_base, 2'b00} +: 4];
wire [3:0] run_cur_mask  = run_msk[{run_cur_word,  2'b00} +: 4];
wire [3:0] run_next_mask = run_msk[{run_next_word, 2'b00} +: 4];
wire [7:0] run_base_be = {{2{run_base_mask[3]}}, {2{run_base_mask[2]}},
                           {2{run_base_mask[1]}}, {2{run_base_mask[0]}}};
wire [7:0] run_next_be = {{2{run_next_mask[3]}}, {2{run_next_mask[2]}},
                           {2{run_next_mask[1]}}, {2{run_next_mask[0]}}};
// Shadow writes only the high byte of each valid lane (bit 15 lives there).
wire [7:0] run_cur_shadow_be = {run_cur_mask[3], 1'b0,
                                 run_cur_mask[2], 1'b0,
                                 run_cur_mask[1], 1'b0,
                                 run_cur_mask[0], 1'b0};

wire [63:0] run_ram_q;
s32_fb_run_ram run_ram (
    .clk(clk),
    .wr_en(wr_valid && run_active),
    .wr_addr(wr_x[8:2]),
    .wr_lane(wr_x[1:0]),
    .wr_data(wr_pix),
    .rd_addr(run_ram_raddr),
    .rd_q(run_ram_q)
);

assign DDRAM_ADDR     = daddr;
assign DDRAM_BURSTCNT = dburst;
assign DDRAM_WE       = dwe;
assign DDRAM_RD       = drd;
assign DDRAM_DIN      = ddin;
assign DDRAM_BE       = dbe;

reg flush_req;

// Scanout has a fixed deadline; a completed sprite run may remain queued until
// a pending display-line fetch has been launched.  Keep acceptance explicit so
// deferring the flush cannot discard it.
wire erase_pending = er_req && !er_ack;
// Do not reuse the just-filled bank until the raster boundary has published
// it. This also makes a rare late line recover cleanly instead of allowing the
// following request to overwrite a completed-but-not-yet-visible line.
wire read_pending  = rd_req && !rd_ack && !line_ready;
wire flush_accept  = (dst == D_IDLE) && !erase_pending &&
                     !read_pending && flush_req;

// capture pixel runs (indexed by the pixel's own x)
always @(posedge clk) begin
    if (wr_start) begin
        run_x0     <= 9'd511;
        run_xe     <= 9'd0;
        run_y      <= wr_y;
        run_bufsel <= wr_buf;
        run_shadow <= wr_shadow;
        run_active <= 1'b1;
        run_any    <= 1'b0;
        run_msk    <= 512'b0;
    end
    if (wr_valid && run_active) begin
        run_msk[wr_x] <= 1'b1;
        run_any <= 1'b1;
        if (wr_x < run_x0) run_x0 <= wr_x;
        if (wr_x > run_xe) run_xe <= wr_x;
    end
    if (flush_accept) run_active <= 1'b0;
    if (rst) run_active <= 1'b0;
end

always @(posedge clk) begin
    if (rst) flush_req <= 0;
    else if (wr_end && run_active) flush_req <= 1'b1;
    else if (flush_accept) flush_req <= 1'b0;
end

// hold the renderer off from wr_end (combinational — closes the one-cycle
// window before flush_req registers) until the flush completes
assign wr_busy = wr_end | flush_req |
                 (dst == D_WR_PF) | (dst == D_WR) |
                 (dst == D_SH_R) | (dst == D_SH_RW) | (dst == D_SH_W);

always @(posedge clk) begin
    if (rst) begin
        dst <= D_IDLE; dwe <= 0; drd <= 0; er_ack <= 0; rd_ack <= 0;
        rd_dual_latched <= 1'b0;
        rd_buf_alt_latched <= 2'd0;
        display_bank <= 1'b0;
        fill_bank <= 1'b1;
        line_ready <= 1'b0;
        compose_prior <= 64'd0;
        compose_addr <= 7'd0;
        compose_valid <= 1'b0;
    end
    else begin
        // A one-cycle valid pulse makes the alternate-field RMW pipeline safe
        // even when DDR inserts gaps between DOUT_READY beats.
        compose_valid <= 1'b0;
        // Publish a completely fetched line only at the raster boundary. The
        // bank that is still being displayed is never modified underneath the
        // mixer, even if DDR completes very early in the preceding scanline.
        if (rd_line_publish) begin
            display_bank <= fill_bank;
            line_ready <= 1'b0;
        end
        case (dst)
        D_IDLE: begin
            dwe <= 0; drd <= 0;
            if (erase_pending) begin
                daddr  <= pix_addr(er_buf, er_y, 7'd0);
                // MiSTer recommends pipelined single writes. With burstcnt=1
                // each accepted beat may advance DDRAM_ADDR legally.
                dburst <= 8'd1;
                ddin   <= 64'hFFFF_FFFF_FFFF_FFFF;
                dbe    <= 8'hFF;
                beat   <= 0; beats <= 7'd127;
                dwe    <= 1'b1;
                dst    <= D_ER;
            end
            else if (read_pending) begin
                daddr  <= pix_addr(rd_buf, rd_y, 7'd0);
                dburst <= 8'd128;
                rbeat  <= 0;
                fill_bank <= ~display_bank;
                rd_dual_latched <= rd_dual;
                rd_buf_alt_latched <= rd_buf_alt;
                drd    <= 1'b1;
                dbe    <= 8'hFF;  // audit R20 PF-4: reads drive all byte lanes
                dst    <= D_RD;
            end
            else if (flush_req) begin
                beat  <= 0;
                beats <= (run_xe[8:2] - run_x0[8:2]);
                daddr <= pix_addr(run_bufsel, run_y, run_x0[8:2]);
                if (!run_any) begin
                    // fully-transparent row: nothing to flush
                end
                else if (run_shadow) begin
                    // RMW span: read word, clear bit15 of valid lanes, write
                    dburst <= 8'd1;
                    drd    <= 1'b1;
                    dbe    <= 8'hFF;  // audit R20 PF-4: reads drive all byte lanes
                    dst    <= D_SH_R;
                end
                else begin
                    dburst <= 8'd1;
                    dst    <= D_WR_PF;
                end
            end

        end
        // One synchronous-RAM prefetch cycle.  q is the base word requested
        // while the preceding D_IDLE edge accepted this flush.
        D_WR_PF: begin
            ddin <= run_ram_q;
            dbe  <= run_base_be;
            dwe  <= 1'b1;
            dst  <= D_WR;
        end
        D_ER: if (!DDRAM_BUSY) begin
            dwe <= 1'b1;
            if (beat == beats) begin dwe <= 0; er_ack <= 1'b1; dst <= D_IDLE; end
            else begin beat <= beat + 1'd1; daddr <= daddr + 1'd1; end
        end
        D_WR: if (!DDRAM_BUSY) begin
            if (beat == beats) begin dwe <= 0; dst <= D_IDLE; end
            else begin
                beat  <= beat + 1'd1;
                daddr <= daddr + 1'd1;
                ddin  <= run_ram_q;
                dbe   <= run_next_be;
                dwe   <= 1'b1;
            end
        end
        // shadow RMW loop: one 64-bit word per iteration
        D_SH_R: if (!DDRAM_BUSY) begin
            drd <= 1'b0;
            dst <= D_SH_RW;
        end
        D_SH_RW: if (DDRAM_DOUT_READY) begin
            ddin <= DDRAM_DOUT & 64'h7FFF_7FFF_7FFF_7FFF;
            dbe  <= run_cur_shadow_be;
            dwe  <= 1'b1;
            dst  <= D_SH_W;
        end
        D_SH_W: if (!DDRAM_BUSY) begin
            dwe <= 1'b0;
            if (beat == beats) dst <= D_IDLE;
            else begin
                beat   <= beat + 1'd1;
                daddr  <= daddr + 1'd1;
                dburst <= 8'd1;
                drd    <= 1'b1;
                dbe    <= 8'hFF;  // audit R20 PF-4: reads drive all byte lanes
                dst    <= D_SH_R;
            end
        end
        D_RD: if (!DDRAM_BUSY) begin
            drd <= 1'b0;
            dst <= D_RD_W;
        end
        D_RD_W: begin
            if (DDRAM_DOUT_READY) begin
                rbeat <= rbeat + 1'd1;
                if (rbeat == 7'd127) begin
                    if (rd_dual_latched) begin
                        daddr  <= pix_addr(rd_buf_alt_latched, rd_y, 7'd0);
                        dburst <= 8'd128;
                        rbeat  <= 0;
                        drd    <= 1'b1;
                        dst    <= D_RD_ALT;
                    end
                    else begin
                        line_ready <= 1'b1;
                        rd_ack <= 1'b1;
                        dst <= D_IDLE;
                    end
                end
            end
        end
        D_RD_ALT: if (!DDRAM_BUSY) begin
            drd <= 1'b0;
            dst <= D_RD_ALT_W;
        end
        D_RD_ALT_W: begin
            if (DDRAM_DOUT_READY) begin
                compose_prior <= DDRAM_DOUT;
                compose_addr <= rbeat;
                compose_valid <= 1'b1;
                rbeat <= rbeat + 1'd1;
                if (rbeat == 7'd127) begin
                    // The final current/prior pair is written on the following
                    // edge after the synchronous RAM read has arrived.
                    dst <= D_RD_ALT_FLUSH;
                end
            end
        end
        D_RD_ALT_FLUSH: begin
            line_ready <= 1'b1;
            rd_ack <= 1'b1;
            dst <= D_IDLE;
        end
        default: dst <= D_IDLE;
        endcase
        // Four-phase request/acknowledge: a held request is accepted once,
        // and the acknowledge drops as soon as its producer drops request.
        if (!rd_req) rd_ack <= 1'b0;
        if (!er_req) er_ack <= 1'b0;
    end
end

endmodule

// ---------------------------------------------------------------------------
// 128 x 64 fetched-line RAM. Port A writes complete DDR words while port B is
// used either by scanout or by the inactive-bank composition pipeline.
// ---------------------------------------------------------------------------
module s32_fb_line_ram (
    input              clk,
    input              wr_en,
    input       [6:0]  wr_addr,
    input      [63:0]  wr_data,
    input       [6:0]  rd_addr,
    output     [63:0]  rd_q
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clk),
    .address_a(wr_addr),
    .data_a(wr_data),
    .wren_a(wr_en),

    .clock1(clk),
    .address_b(rd_addr),
    .q_b(rd_q),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a(1'b1),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = 128,
    ram.widthad_a = 7,
    ram.width_a = 64,
    ram.numwords_b = 128,
    ram.widthad_b = 7,
    ram.width_b = 64,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "DUAL_PORT",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "TRUE",
    ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    ram.width_byteena_a = 1;
`else
reg [63:0] mem [0:127];
reg [63:0] rd_q_r;
assign rd_q = rd_q_r;

integer __line_init;
initial begin
    rd_q_r = 64'd0;
    for (__line_init = 0; __line_init < 128; __line_init = __line_init + 1)
        mem[__line_init] = 64'd0;
end

always @(posedge clk) begin
    rd_q_r <= mem[rd_addr];
    if (wr_en)
        mem[wr_addr] <= wr_data;
end
`endif

endmodule

// ---------------------------------------------------------------------------
// 128 x 64 captured-run RAM.  Port A writes one 16-bit pixel lane per clock;
// port B returns a complete DDR word one clock after rd_addr is presented.
// Quartus' integrated-synthesis macro selects the Cyclone V primitive, while
// normal simulators use the cycle-equivalent behavioural array.
// ---------------------------------------------------------------------------
module s32_fb_run_ram (
    input              clk,
    input              wr_en,
    input       [6:0]  wr_addr,
    input       [1:0]  wr_lane,
    input      [15:0]  wr_data,
    input       [6:0]  rd_addr,
    output     [63:0]  rd_q
);

wire [63:0] wr_word = {4{wr_data}};
wire  [7:0] wr_be = (wr_lane == 2'd0) ? 8'b0000_0011 :
                     (wr_lane == 2'd1) ? 8'b0000_1100 :
                     (wr_lane == 2'd2) ? 8'b0011_0000 : 8'b1100_0000;

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clk),
    .address_a(wr_addr),
    .data_a(wr_word),
    .byteena_a(wr_be),
    .wren_a(wr_en),

    .clock1(clk),
    .address_b(rd_addr),
    .q_b(rd_q),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = 128,
    ram.widthad_a = 7,
    ram.width_a = 64,
    ram.numwords_b = 128,
    ram.widthad_b = 7,
    ram.width_b = 64,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "DUAL_PORT",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    ram.width_byteena_a = 8;
`else
reg [63:0] mem [0:127];
reg [63:0] rd_q_r;
assign rd_q = rd_q_r;

integer __run_init;
initial begin
    for (__run_init = 0; __run_init < 128; __run_init = __run_init + 1)
        mem[__run_init] = 64'd0;
end

always @(posedge clk) begin
    rd_q_r <= mem[rd_addr];
    if (wr_en) begin
        case (wr_lane)
            2'd0: mem[wr_addr][15:0]  <= wr_data;
            2'd1: mem[wr_addr][31:16] <= wr_data;
            2'd2: mem[wr_addr][47:32] <= wr_data;
            2'd3: mem[wr_addr][63:48] <= wr_data;
        endcase
    end
end
`endif

endmodule

//============================================================================
//  Ricoh RF5C68 (ASSP 5C105 / Sega 315-5476A) — 8-voice PCM (DESIGN.md §7.4)
//  64KB wave RAM, Fs = clk/384 (12.5MHz -> 32.552 kHz).
//  Register map (per MAME rf5c68.cpp):
//    0 ENV, 1 PAN {R[7:4],L[3:0]}, 2 FDL, 3 FDH, 4 LSL, 5 LSH, 6 ST,
//    7 control {en[7], sel[6]: 1=cbank(ch) 0=wbank, val[3:0]},
//    8 channel-OFF mask (active low enables)
//  Samples: 8-bit sign-magnitude-ish (0xFF = loop marker -> jump to LS).
//============================================================================

module s32_rf5c68 (
    input             clk,          // clk_sys
    input             ce,           // 12.5 MHz clock enable
    input             rst,

    // Z80-side access: regs at 0x0000-0x000F (mirrored to 0x0FFF),
    // wave RAM window at 0x1000-0x1FFF (4KB page = wbank)
    input             cs,           // 0xC000-0xDFFF region select
    input             we,
    input      [12:0] addr,
    input       [7:0] wdata,
    output reg  [7:0] rdata,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

// Per-channel registers.
reg [7:0]  env  [0:7];
reg [7:0]  pan  [0:7];
reg [15:0] fd   [0:7];
reg [15:0] ls   [0:7];
reg [7:0]  st   [0:7];
reg [26:0] caddr[0:7];     // 16.11 address accumulator
reg [7:0]  chan_off_m;     // channel off mask
reg        enable;
reg [2:0]  cbank;
reg [3:0]  wbank;

// Wave RAM is deliberately described as one read/write port plus one read-only
// port.  Both reads are registered so Quartus can map this 64Kx8 array to true
// dual-port M10K memory rather than implementing it in ALMs.
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] wram [0:65535];
wire [15:0] zram_addr = {wbank, addr[11:0]};
wire        zram_we   = cs && we && addr[12];
reg  [7:0]  zram_q;
reg         zram_sel_q;
reg [15:0]  voice_ram_addr;
reg  [7:0]  voice_ram_q;

always @(posedge clk) begin
    if (zram_we) wram[zram_addr] <= wdata;
    zram_q     <= wram[zram_addr];
    zram_sel_q <= addr[12];
    voice_ram_q <= wram[voice_ram_addr];
end

always @* rdata = zram_sel_q ? zram_q : 8'hff;

// Fs divider: one channel is launched per 48 CE ticks (8 ch x 48 = 384).
reg [5:0]  div48;
reg [2:0]  ch;
reg signed [15:0] acc_l, acc_r;

// A synchronous RAM read takes one clock after its address is registered.  The
// explicit wait/use states also provide the extra loop-target fetch required
// when the first byte is the 0xff marker.
localparam [2:0] VS_IDLE       = 3'd0;
localparam [2:0] VS_FETCH_WAIT = 3'd1;
localparam [2:0] VS_FETCH_USE  = 3'd2;
localparam [2:0] VS_LOOP_WAIT  = 3'd3;
localparam [2:0] VS_LOOP_USE   = 3'd4;
reg [2:0] voice_state;
reg [2:0] voice_ch;
reg       voice_last;
reg [7:0] voice_env;
reg [7:0] voice_pan;
reg [15:0] voice_fd;
reg [15:0] voice_ls;

// Keep the multiply widths explicit.  sample[7]=1 is positive; sample[7]=0
// is negative, matching MAME's RF5C68 sign/magnitude convention.
wire [14:0] voice_mag_env = voice_ram_q[6:0] * voice_env;
wire [18:0] voice_prod_l  = voice_mag_env * voice_pan[3:0];
wire [18:0] voice_prod_r  = voice_mag_env * voice_pan[7:4];
wire [13:0] voice_mag_l   = voice_prod_l[18:5];
wire [13:0] voice_mag_r   = voice_prod_r[18:5];
wire signed [15:0] voice_delta_l = voice_ram_q[7]
                                       ? $signed({2'b00, voice_mag_l})
                                       : -$signed({2'b00, voice_mag_l});
wire signed [15:0] voice_delta_r = voice_ram_q[7]
                                       ? $signed({2'b00, voice_mag_r})
                                       : -$signed({2'b00, voice_mag_r});

integer i;
always @(posedge clk) begin
    if (rst) begin
        enable      <= 1'b0;
        cbank       <= 3'd0;
        wbank       <= 4'd0;
        chan_off_m  <= 8'hff;
        div48       <= 6'd0;
        ch          <= 3'd0;
        acc_l       <= 16'sd0;
        acc_r       <= 16'sd0;
        out_l       <= 16'sd0;
        out_r       <= 16'sd0;
        voice_state <= VS_IDLE;
        voice_ram_addr <= 16'd0;
        voice_ch    <= 3'd0;
        voice_last  <= 1'b0;
        voice_env   <= 8'd0;
        voice_pan   <= 8'd0;
        voice_fd    <= 16'd0;
        voice_ls    <= 16'd0;
        for (i = 0; i < 8; i = i + 1) begin
            env[i]   <= 8'd0;
            pan[i]   <= 8'd0;
            fd[i]    <= 16'd0;
            ls[i]    <= 16'd0;
            st[i]    <= 8'd0;
            caddr[i] <= 27'd0;
        end
    end
    else begin
        // The voice pipeline completes long before the following 48-CE slot.
        // caddr is owned by this process so CPU reloads and playback advances
        // cannot become multiple drivers in synthesis.
        case (voice_state)
            VS_FETCH_WAIT: voice_state <= VS_FETCH_USE;

            VS_FETCH_USE: begin
                if (voice_ram_q == 8'hff) begin
                    caddr[voice_ch] <= {voice_ls, 11'b0};
                    voice_ram_addr <= voice_ls;
                    voice_state    <= VS_LOOP_WAIT;
                end
                else begin
                    caddr[voice_ch] <= caddr[voice_ch] + {11'b0, voice_fd};
                    if (voice_last) begin
                        out_l <= acc_l + voice_delta_l;
                        out_r <= acc_r + voice_delta_r;
                        acc_l <= 16'sd0;
                        acc_r <= 16'sd0;
                    end
                    else begin
                        acc_l <= acc_l + voice_delta_l;
                        acc_r <= acc_r + voice_delta_r;
                    end
                    voice_state <= VS_IDLE;
                end
            end

            VS_LOOP_WAIT: voice_state <= VS_LOOP_USE;

            VS_LOOP_USE: begin
                // A marker at the loop target is an empty/dead voice: retain
                // the loop address and contribute silence, as MAME does.
                if (voice_ram_q != 8'hff) begin
                    caddr[voice_ch] <= {voice_ls, 11'b0} + {11'b0, voice_fd};
                    if (voice_last) begin
                        out_l <= acc_l + voice_delta_l;
                        out_r <= acc_r + voice_delta_r;
                        acc_l <= 16'sd0;
                        acc_r <= 16'sd0;
                    end
                    else begin
                        acc_l <= acc_l + voice_delta_l;
                        acc_r <= acc_r + voice_delta_r;
                    end
                end
                else if (voice_last) begin
                    out_l <= acc_l;
                    out_r <= acc_r;
                    acc_l <= 16'sd0;
                    acc_r <= 16'sd0;
                end
                voice_state <= VS_IDLE;
            end

            default: ;
        endcase

        if (ce) begin
            div48 <= (div48 == 6'd47) ? 6'd0 : div48 + 1'd1;
            if ((div48 == 6'd0) && (voice_state == VS_IDLE)) begin
                voice_ch   <= ch;
                voice_last <= (ch == 3'd7);
                voice_env  <= env[ch];
                voice_pan  <= pan[ch];
                voice_fd   <= fd[ch];
                voice_ls   <= ls[ch];
                ch         <= ch + 1'd1;
                if (enable && !chan_off_m[ch]) begin
                    voice_ram_addr <= caddr[ch][26:11];
                    voice_state    <= VS_FETCH_WAIT;
                end
                else if (ch == 3'd7) begin
                    out_l <= acc_l;
                    out_r <= acc_r;
                    acc_l <= 16'sd0;
                    acc_r <= 16'sd0;
                end
            end
        end

        // Z80 register writes.  These are intentionally later in the process
        // so an explicit CPU start/off write wins over a simultaneous voice
        // address advance.
        if (cs && we && !addr[12]) begin
            case (addr[3:0])
                4'h0: env[cbank] <= wdata;
                4'h1: pan[cbank] <= wdata;
                4'h2: fd[cbank][7:0]  <= wdata;
                4'h3: fd[cbank][15:8] <= wdata;
                4'h4: ls[cbank][7:0]  <= wdata;
                4'h5: ls[cbank][15:8] <= wdata;
                4'h6: begin
                    st[cbank] <= wdata;
                    if (chan_off_m[cbank]) caddr[cbank] <= {wdata, 19'b0};
                end
                4'h7: begin
                    enable <= wdata[7];
                    if (wdata[6]) cbank <= wdata[2:0];
                    else          wbank <= wdata[3:0];
                end
                4'h8: begin
                    chan_off_m <= wdata;
                    for (i = 0; i < 8; i = i + 1) begin
                        if (wdata[i]) caddr[i] <= {st[i], 19'b0};
                    end
                end
                default: ;
            endcase
        end
    end
end

endmodule

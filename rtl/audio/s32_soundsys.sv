//============================================================================
//  System 32 / Multi 32 sound subsystem glue (DESIGN.md §7, Appendix B)
//  Z80 (T80s) + memory/IO decode + banking + interrupt controller +
//  2x jt12 (YM3438) or 1x jt12 + MultiPCM, RF5C68, shared RAM.
//============================================================================

import s32_pkg::*;

module s32_soundsys #(
    parameter SYSTEM32_ONLY = 1'b0
) (
    input             clk,          // clk_sys
    input             ce_z80,       // 8.054 / 8.0 MHz
    input             ce_fm,        // YM3438 clock enable (chip-internal /6)
    input             ce_pcm,       // 12.5 MHz (RF5C68) / 10 MHz (MultiPCM)
    input             rst,          // board/system reset
    input             z80_reset,    // I/O-chip CNT2: sound-CPU reset only
    input             is_multi32,

    // V60 side of shared RAM (byte-wide, low lanes of 0x700000 window)
    input             sh_cs,
    input             sh_we,
    input      [12:0] sh_addr,
    input       [7:0] sh_wdata,
    output      [7:0] sh_rdata,

    // main CPU doorbell (int_control offsets 12-15 write)
    input             v60_doorbell,
    // sound -> main IRQ (Z80 port 0xc0.. bit2 set)
    output reg        irq_to_v60,

    // Z80 sound ROM via SDRAM (p3 port)
    output            zrom_req,
    output     [23:0] zrom_addr,    // byte address within soundcpu region
    input      [15:0] zrom_data,
    input             zrom_ack,

    // MultiPCM sample ROM via SDRAM
    output            mpcm_req,
    output     [21:0] mpcm_addr,
    input       [7:0] mpcm_data,
    input             mpcm_ack,

    output signed [15:0] audio_l,
    output signed [15:0] audio_r
);

// ---------------------------------------------------------------------------
// Z80 core (T80s, VHDL). Fast all-Verilog core tests use a behavioral
// stub, while S32_REAL_Z80_SIM enables the same mixed-language CPU used by
// hardware for dedicated sound-ROM boot and bus-integration regressions.
// ---------------------------------------------------------------------------
wire [15:0] z_addr;
wire [7:0]  z_dout;
wire [229:0] z_reg_debug;
wire [1:0]   z_iset_debug;
reg  [7:0]  z_din;
wire        z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_m1_n;
reg         z_int_n;
wire        z_wait_n;

`ifdef SIMULATION
`ifndef S32_REAL_Z80_SIM
`define S32_Z80_STUB
`endif
`endif
`ifndef S32_Z80_STUB
T80s z80 (
    .RESET_n (~(rst | z80_reset)),
    .CLK     (clk),
    .CEN     (ce_z80),
    .WAIT_n  (z_wait_n),
    .INT_n   (z_int_n),
    .NMI_n   (1'b1),
    .BUSRQ_n (1'b1),
    .M1_n    (z_m1_n),
    .MREQ_n  (z_mreq_n),
    .IORQ_n  (z_iorq_n),
    .RD_n    (z_rd_n),
    .WR_n    (z_wr_n),
    .RFSH_n  (),
    .HALT_n  (),
    .BUSAK_n (),
    .OUT0    (1'b0),
    .A       (z_addr),
    .DI      (z_din),
    .DO      (z_dout),
    .REG     (z_reg_debug),
    .DIRSet  (1'b0),
    .DIR     (230'd0),
    .ISet_out(z_iset_debug)
);
`else
assign z_addr = 16'h0000; assign z_dout = 8'h00;
assign z_mreq_n = 1'b1; assign z_iorq_n = 1'b1;
assign z_rd_n = 1'b1; assign z_wr_n = 1'b1; assign z_m1_n = 1'b1;
`endif
`ifdef S32_Z80_STUB
`undef S32_Z80_STUB
`endif

wire z_mem_rd = ~z_mreq_n & ~z_rd_n;
wire z_mem_wr = ~z_mreq_n & ~z_wr_n;
wire z_io_rd  = ~z_iorq_n & ~z_rd_n & z_m1_n;
wire z_io_wr  = ~z_iorq_n & ~z_wr_n;
wire z_intack = ~z_iorq_n & ~z_m1_n;

// ---------------------------------------------------------------------------
// memory decode:
//  0000-9FFF ROM (fixed)  A000-BFFF ROM bank  C000-DFFF PCM chip
//  E000-FFFF shared RAM (8KB)
// ---------------------------------------------------------------------------
reg [8:0] sound_bank;
wire [23:0] rom_byte_addr = (z_addr < 16'ha000) ? {8'b0, z_addr}
                          : {2'b0, sound_bank, z_addr[12:0]};

// ROM fetch through SDRAM word port with byte select + 1-deep cache
reg        rreq;
reg [23:1] raddr;               // outstanding SDRAM request address
reg [23:1] rtag;                // address associated with rdata_w
reg [15:0] rdata_w;
reg        rvalid;
assign zrom_req  = rreq;
assign zrom_addr = {raddr, 1'b0};
wire rom_sel = (z_addr < 16'hc000);
wire rom_hit = rvalid && (rtag == rom_byte_addr[23:1]);
assign z_wait_n = ~(rom_sel && (z_mem_rd) && !rom_hit);

always @(posedge clk) begin
    if (rst) begin rreq <= 0; rvalid <= 0; rtag <= 0; end
    else begin
        if (rom_sel && z_mem_rd && !rom_hit && !rreq) begin
            rreq  <= 1'b1;
            raddr <= rom_byte_addr[23:1];
        end
        if (zrom_ack) begin
            rreq <= 0;
            rdata_w <= zrom_data;
            rtag <= raddr;
            rvalid <= 1'b1;
        end
    end
end

// Shared RAM 8KB true dual port.  Both buses use clk_sys, and both registered
// read outputs update every clock exactly as the original array did.  The
// explicit wrapper prevents Quartus 17 from expanding this memory into logic.
wire [7:0] shz_rd_r;
s32_byte_dpram #(.ADDR_WIDTH(13), .NUM_WORDS(8192)) shared_ram (
    .clock(clk),
    .address_a(sh_addr), .data_a(sh_wdata), .rden_a(1'b1),
    .wren_a(sh_cs && sh_we), .q_a(sh_rdata),
    .address_b(z_addr[12:0]), .data_b(z_dout), .rden_b(1'b1),
    .wren_b(z_mem_wr && z_addr[15:13] == 3'b111), .q_b(shz_rd_r)
);

// ---------------------------------------------------------------------------
// PCM chips
// ---------------------------------------------------------------------------
wire        pcm_cs = (z_addr[15:13] == 3'b110);   // C000-DFFF
wire [7:0]  rf_rdata;
wire signed [15:0] rf_l, rf_r;

s32_rf5c68 rf5c68 (
    .clk(clk), .ce(ce_pcm & ~is_multi32), .rst(rst),
    .cs(pcm_cs & ~is_multi32 & (z_mem_rd | z_mem_wr)),
    .we(z_mem_wr),
    .addr(z_addr[12:0]), .wdata(z_dout), .rdata(rf_rdata),
    .out_l(rf_l), .out_r(rf_r)
);

reg [2:0] mpcm_bank_lo, mpcm_bank_hi;
wire signed [15:0] mp_l, mp_r;
generate
    if (SYSTEM32_ONLY) begin : g_no_multipcm
        assign mpcm_req  = 1'b0;
        assign mpcm_addr = 22'd0;
        assign mp_l = 16'sd0;
        assign mp_r = 16'sd0;
    end
    else begin : g_multipcm
        s32_multipcm multipcm (
            .clk(clk), .ce(ce_pcm & is_multi32), .rst(rst),
            .cs(pcm_cs & is_multi32 & (z_mem_rd | z_mem_wr)),
            .we(z_mem_wr),
            .addr(z_addr[1:0]), .wdata(z_dout), .rdata(),
            .rom_req(mpcm_req), .rom_addr(mpcm_addr),
            .rom_data(mpcm_data), .rom_ack(mpcm_ack),
            .bank_lo(mpcm_bank_lo), .bank_hi(mpcm_bank_hi),
            .out_l(mp_l), .out_r(mp_r)
        );
    end
endgenerate

// ---------------------------------------------------------------------------
// FM: 2x jt12 in YM2612/3438 mode (jt12 top: jt12; using jt03-style wrapper)
// ---------------------------------------------------------------------------
wire [7:0] fm1_dout, fm2_dout;
wire       fm1_irq_n, fm2_irq_n;
wire signed [15:0] fm1_l, fm1_r, fm2_l, fm2_r;

wire fm1_cs = z_io_rd | z_io_wr ? (z_addr[7:4] == 4'h8) : 1'b0;
wire fm2_cs = (z_io_rd | z_io_wr) && (z_addr[7:4] == 4'h9) && !is_multi32;

jt12 fm1 (
    .rst(rst), .clk(clk), .cen(ce_fm),
    .din(z_dout), .addr(z_addr[1:0]),
    .cs_n(~fm1_cs), .wr_n(z_wr_n | z_iorq_n),
    .dout(fm1_dout), .irq_n(fm1_irq_n),
    .en_hifi_pcm(1'b1),
    .snd_left(fm1_l), .snd_right(fm1_r), .snd_sample()
);

jt12 fm2 (
    .rst(rst), .clk(clk), .cen(ce_fm),
    .din(z_dout), .addr(z_addr[1:0]),
    .cs_n(~fm2_cs), .wr_n(z_wr_n | z_iorq_n),
    .dout(fm2_dout), .irq_n(fm2_irq_n),
    .en_hifi_pcm(1'b1),
    .snd_left(fm2_l), .snd_right(fm2_r), .snd_sample()
);

// ---------------------------------------------------------------------------
// sound interrupt controller (Appendix B.2): 3 vector slots
// ---------------------------------------------------------------------------
reg [7:0] snd_irq_ctl [0:2];
reg [2:0] snd_irq_input;
reg [2:0] snd_irq_next;
reg [7:0] snd_irq_mask;   // slot 3 = mask reg (MAME: m_sound_irq_control[3])
reg [7:0] sound_dummy_value;

wire ym_irq = ~fm1_irq_n;   // only YM #1 wired (MAME)
reg  ym_irq_d;

// vector on intack: lowest pending slot * 2
reg [7:0] int_vector;
always @(*) begin
    int_vector = 8'h00;
    z_int_n = 1'b1;
    for (int i = 2; i >= 0; i--)
        if (snd_irq_input[i] & ~snd_irq_mask[i]) begin
            int_vector = {5'b0, i[1:0], 1'b0};
            z_int_n = 1'b0;
        end
end

// Merge an acknowledge with source changes before committing the pending
// bits.  An event arriving on the acknowledge cycle must remain pending; the
// previous sequence of nonblocking assignments allowed the ACK to overwrite
// a simultaneous YM/V60 event.
always @(*) begin
    snd_irq_next = snd_irq_input;
    if (z_io_wr && z_addr[7:4] == 4'hc && z_addr[0])
        snd_irq_next = snd_irq_next & z_dout[2:0];
    if (ym_irq & ~ym_irq_d)
        for (int i = 0; i < 3; i++)
            if (snd_irq_ctl[i] == SOUND_IRQ_YM3438[7:0])
                snd_irq_next[i] = 1'b1;
    if (~ym_irq & ym_irq_d)
        for (int i = 0; i < 3; i++)
            if (snd_irq_ctl[i] == SOUND_IRQ_YM3438[7:0])
                snd_irq_next[i] = 1'b0;
    if (v60_doorbell)
        for (int i = 0; i < 3; i++)
            if (snd_irq_ctl[i] == SOUND_IRQ_V60[7:0])
                snd_irq_next[i] = 1'b1;
end

always @(posedge clk) begin
    if (rst) begin
        snd_irq_input <= 0;
        snd_irq_ctl[0] <= 8'h00;
        snd_irq_ctl[1] <= 8'h00;
        snd_irq_ctl[2] <= 8'h00;
        snd_irq_mask  <= 8'h00;
        sound_dummy_value <= 8'h00;
        sound_bank    <= 0;
        mpcm_bank_lo  <= 3'd0;
        mpcm_bank_hi  <= 3'd0;
        irq_to_v60    <= 0;
        ym_irq_d      <= 0;
    end
    else begin
        irq_to_v60 <= 1'b0;
        ym_irq_d   <= ym_irq;
        snd_irq_input <= snd_irq_next;

        // Z80 IO writes
        if (z_io_wr) begin
            casez (z_addr[7:0])
                8'ha?: sound_bank[5:0] <= z_dout[5:0];
                8'hb?: begin
                    if (is_multi32) begin
                        mpcm_bank_hi <= z_dout[5:3];
                        mpcm_bank_lo <= z_dout[2:0];
                    end
                    else sound_bank[8:6] <= {z_dout[1:0], z_dout[2]};
                end
                8'hc?: begin
                    if (z_addr[2]) irq_to_v60 <= 1'b1;                // doorbell
                end
                8'hd?: begin
                    // MAME maps D0-D3 mirrored only at D4-D7.  D8-DF are
                    // genuinely unmapped and must not alias these registers.
                    if (!z_addr[3]) begin
                        if (z_addr[1:0] == 2'd3) snd_irq_mask <= z_dout;
                        else                    snd_irq_ctl[z_addr[1:0]] <= z_dout;
                    end
                end
                8'hf1: sound_dummy_value <= z_dout;
                default: ;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// Z80 read mux
// ---------------------------------------------------------------------------
always @(*) begin
    if (z_intack)      z_din = int_vector;
    else if (z_io_rd) begin
        casez (z_addr[7:0])
            8'h8?: z_din = fm1_dout;
            8'h9?: z_din = is_multi32 ? 8'hff : fm2_dout;
            8'hf1: z_din = sound_dummy_value;
            default: z_din = 8'hff;
        endcase
    end
    else if (z_mem_rd) begin
        if (z_addr[15:13] == 3'b111)      z_din = shz_rd_r;
        else if (pcm_cs)                  z_din = is_multi32 ? 8'h00 : rf_rdata;
        else                              z_din = rom_byte_addr[0] ? rdata_w[15:8] : rdata_w[7:0];
    end
    else z_din = 8'hff;
end

// ---------------------------------------------------------------------------
// Output mixer. Widen before arithmetic and saturate after route scaling so
// full-scale legal samples cannot wrap around and reverse polarity.
// ---------------------------------------------------------------------------
s32_audio_mix output_mixer (
    .is_multi32(is_multi32),
    .fm1_l(fm1_l), .fm1_r(fm1_r),
    .fm2_l(fm2_l), .fm2_r(fm2_r),
    .rf_l(rf_l),   .rf_r(rf_r),
    .mp_l(mp_l),   .mp_r(mp_r),
    .audio_l(audio_l), .audio_r(audio_r)
);

endmodule

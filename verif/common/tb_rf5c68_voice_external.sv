`timescale 1ns/1ps
`default_nettype none

//============================================================================
// RF5C68 EXTERNAL WAVE RAM — VOICE PATH (closed loop against the real SDRAM)
//
// tb_rf5c68_external only ever exercised the Z80 side: it never toggled `ce`,
// never set the enable bit and never cleared the channel-off mask, so the
// voice fetch path (wave_rd_voice / voice_data_ready / the 0xff loop refetch /
// CPU-vs-voice arbitration) never executed.  This bench closes that gap and
// does it honestly:
//
//   * the backing store is the REAL rtl/mem/sdram.sv driving a protocol-level
//     SDR chip model that stores RAW words and honours DQML/DQMH,
//   * runtime wave writes go through the REAL rtl/mem/s32_sdram_write_mux2.sv
//     and share it with a loader client,
//   * the address/byte-lane/inversion arithmetic is copied verbatim from
//     rtl/s32_core.sv:861-870 with SDR_MULTIPCM_BASE from rtl/s32_pkg.sv,
//   * background p0/p1 traffic gives the wave read port a variable grant
//     latency instead of a fixed two-cycle model latency.
//
// Clocks: clk_sys 48.5 MHz (#10.3), clk_ram 97.1 MHz (#5.15) as in
// tb_core_boot.  ce_pcm is modelled as clk_sys/4 (12.1 MHz vs the production
// fractional 12.5 MHz from rtl/audio/s32_audio_ce.sv) — the RF5C68 only cares
// that CE ticks, and /4 keeps one 48-CE voice slot at 192 clk_sys (production:
// ~186), i.e. the same order of magnitude of fetch headroom.
//============================================================================

module tb_rf5c68_voice_external;

localparam [24:0] SDR_MULTIPCM_BASE = 25'h0A0_0000;
localparam [23:0] BASE_WORD = SDR_MULTIPCM_BASE[24:1];

reg clk_sys = 1'b0;
reg clk_ram = 1'b0;
always #10.3 clk_sys = ~clk_sys;
always #5.15 clk_ram = ~clk_ram;

reg rst = 1'b1;
reg init = 1'b1;
wire ready;

// ce_pcm: clk_sys / 4
reg [1:0] ce_div = 2'd0;
reg       ce_pcm = 1'b0;
always @(posedge clk_sys) begin
    ce_div <= ce_div + 2'd1;
    ce_pcm <= (ce_div == 2'd3);
end

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
reg         cs = 1'b0;
reg         we = 1'b0;
reg  [12:0] addr = 13'd0;
reg  [7:0]  wdata = 8'd0;
wire [7:0]  rdata;
wire        cpu_wait;

wire        wave_rd_req;
wire [15:0] wave_rd_addr;
wire        wave_wr_req;
wire [15:0] wave_wr_addr;
wire [7:0]  wave_wr_data;
wire signed [15:0] out_l, out_r;

wire [15:0] sdr_p4_dout;
wire        sdr_p4_ack;
wire        sdr_wave_wr_ack;

s32_rf5c68 #(.EXTERNAL_WAVE_RAM(1'b1)) dut (
    .clk(clk_sys), .ce(ce_pcm), .rst(rst),
    .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .wave_rd_req(wave_rd_req), .wave_rd_addr(wave_rd_addr),
    .wave_rd_data(sdr_p4_dout), .wave_rd_ack(sdr_p4_ack),
    .wave_wr_req(wave_wr_req), .wave_wr_addr(wave_wr_addr),
    .wave_wr_data(wave_wr_data), .wave_wr_ack(sdr_wave_wr_ack),
    .cpu_wait(cpu_wait),
    .out_l(out_l), .out_r(out_r)
);

// ---------------------------------------------------------------------------
// Production address arithmetic (rtl/s32_core.sv:861-870), verbatim.
// ---------------------------------------------------------------------------
wire        sdr_p4_req  = wave_rd_req;
wire [24:1] sdr_p4_addr = SDR_MULTIPCM_BASE[24:1] + {9'b000000000, wave_rd_addr[15:1]};
wire        sdr_wave_wr_req  = wave_wr_req;
wire [24:1] sdr_wave_wr_addr = SDR_MULTIPCM_BASE[24:1] +
                               {9'b000000000, wave_wr_addr[15:1]};
wire [15:0] sdr_wave_wr_data = wave_wr_addr[0] ? {~wave_wr_data, 8'h00}
                                               : {8'h00, ~wave_wr_data};
wire [1:0]  sdr_wave_wr_be   = wave_wr_addr[0] ? 2'b10 : 2'b01;

// ---------------------------------------------------------------------------
// Real write serializer: c0 = loader, c1 = RF5C68 runtime wave port
// ---------------------------------------------------------------------------
reg         ld_req = 1'b0;
reg  [24:1] ld_addr = '0;
reg  [15:0] ld_data = '0;
reg  [1:0]  ld_be = 2'b11;
wire        ld_ack;

wire        sdr_wr_req;
wire [24:1] sdr_wr_addr;
wire [15:0] sdr_wr_data;
wire [1:0]  sdr_wr_be;
wire        sdr_wr_ack;

s32_sdram_write_mux2 wrmux (
    .clk(clk_sys), .rst(rst),
    .c0_req(ld_req), .c0_addr(ld_addr), .c0_data(ld_data), .c0_be(ld_be),
    .c0_ack(ld_ack),
    .c1_req(sdr_wave_wr_req), .c1_addr(sdr_wave_wr_addr),
    .c1_data(sdr_wave_wr_data), .c1_be(sdr_wave_wr_be),
    .c1_ack(sdr_wave_wr_ack),
    .d_req(sdr_wr_req), .d_addr(sdr_wr_addr), .d_data(sdr_wr_data),
    .d_be(sdr_wr_be), .d_ack(sdr_wr_ack)
);

// ---------------------------------------------------------------------------
// Real SDRAM controller + protocol-level chip model
// ---------------------------------------------------------------------------
tri  [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

// Background contention so the wave read port sees a variable grant latency.
reg         p0_req = 1'b0;
reg  [24:1] p0_addr = '0;
reg         p1_req = 1'b0;
reg  [24:3] p1_addr = '0;
wire [63:0] p0_dout, p1_dout, p5_dout;
wire [127:0] p2_dout;
wire [15:0] p3_dout;
wire p0_ack, p1_ack, p2_ack, p3_ack, p5_ack;

sdram sdr (
    .clk(clk_ram), .init(init), .ready(ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE),
    .wr_req(sdr_wr_req), .wr_addr(sdr_wr_addr), .wr_din(sdr_wr_data),
    .wr_be(sdr_wr_be), .wr_ack(sdr_wr_ack),
    .p0_req(p0_req), .p0_burst(1'b0), .p0_addr(p0_addr),
    .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(1'b0), .p2_addr('0), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(1'b0), .p3_addr('0), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(sdr_p4_req), .p4_addr(sdr_p4_addr),
    .p4_dout(sdr_p4_dout), .p4_ack(sdr_p4_ack),
    .p5_req(1'b0), .p5_addr('0), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

s32_sdr_chip_model #(.BASE_WORD(BASE_WORD), .WORDS(32768)) chip (
    .clk(clk_ram), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE)
);

// Background traffic generator (only inside the modelled window).
reg contention_en = 1'b0;
reg [15:0] lfsr = 16'hACE1;
always @(posedge clk_ram) begin
    lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    p0_req <= 1'b0;
    p1_req <= 1'b0;
    if (contention_en) begin
        if (lfsr[3:0] == 4'h5) begin
            p0_req  <= 1'b1;
            p0_addr <= BASE_WORD + {14'd0, lfsr[9:0]};
        end
        else if (lfsr[3:0] == 4'hA) begin
            p1_req  <= 1'b1;
            p1_addr <= (BASE_WORD >> 2) + {14'd0, lfsr[11:4]};
        end
    end
end

// ---------------------------------------------------------------------------
// Z80-side bus tasks (mirror rtl/audio/s32_soundsys.sv: cs is qualified by
// z_mem_rd|z_mem_wr and the Z80 is stalled by WAIT_n while cpu_wait is high).
// ---------------------------------------------------------------------------
integer errors = 0;

task automatic write_reg(input [3:0] ra, input [7:0] data);
begin
    @(negedge clk_sys); cs = 1'b1; we = 1'b1; addr = {9'd0, ra}; wdata = data;
    @(posedge clk_sys); #1;
    @(negedge clk_sys); cs = 1'b0; we = 1'b0;
    @(posedge clk_sys); #1;
end
endtask

task automatic write_wave(input [11:0] wa, input [7:0] data);
integer guard;
begin
    @(negedge clk_sys); cs = 1'b1; we = 1'b1; addr = {1'b1, wa}; wdata = data;
    // cpu_wait is a wire: let it settle before sampling, then hold the bus
    // cycle exactly as the Z80's WAIT_n input does.
    guard = 0;
    while (!cpu_wait && guard < 10) begin @(posedge clk_sys); #1; guard = guard + 1; end
    while (cpu_wait && guard < 4000) begin @(posedge clk_sys); #1; guard = guard + 1; end
    if (guard >= 4000) begin
        $display("FAIL: external wave write to %03x timed out", wa);
        errors = errors + 1;
    end
    @(negedge clk_sys); cs = 1'b0; we = 1'b0;
    @(posedge clk_sys); #1;
end
endtask

task automatic read_wave(input [11:0] wa, output [7:0] got);
integer guard;
begin
    @(negedge clk_sys); cs = 1'b1; we = 1'b0; addr = {1'b1, wa};
    guard = 0;
    while (!cpu_wait && guard < 10) begin @(posedge clk_sys); #1; guard = guard + 1; end
    while (cpu_wait && guard < 4000) begin @(posedge clk_sys); #1; guard = guard + 1; end
    if (guard >= 4000) begin
        $display("FAIL: external wave read from %03x timed out", wa);
        errors = errors + 1;
    end
    got = rdata;
    @(negedge clk_sys); cs = 1'b0;
    @(posedge clk_sys); #1;
end
endtask

// ld_ack is combinational off the clk_ram-domain SDRAM ack, so it can fall on
// the very clk_sys edge a delayed sample would inspect.  Latch it.
reg ld_ack_seen = 1'b0;
reg ld_ack_clr = 1'b0;
always @(posedge clk_sys) begin
    if (ld_ack_clr) ld_ack_seen <= 1'b0;
    else if (ld_ack) ld_ack_seen <= 1'b1;
end

task automatic loader_write(input [24:1] a, input [15:0] d, input [1:0] be);
integer guard;
begin
    @(negedge clk_sys); ld_ack_clr = 1'b1;
    @(posedge clk_sys); #1;
    @(negedge clk_sys); ld_ack_clr = 1'b0;
    ld_addr = a; ld_data = d; ld_be = be; ld_req = 1'b1;
    guard = 0;
    while (!ld_ack_seen && guard < 4000) begin @(posedge clk_sys); #1; guard = guard + 1; end
    if (guard >= 4000) begin
        $display("FAIL: loader write timed out"); errors = errors + 1;
    end
    @(negedge clk_sys); ld_req = 1'b0;
    @(posedge clk_sys); #1;
end
endtask

// ---------------------------------------------------------------------------
// Golden shadow of what the CPU actually wrote (independent of the DUT).
// ---------------------------------------------------------------------------
reg [7:0] golden [0:65535];
integer g;

// ---------------------------------------------------------------------------
// Voice-fetch observer.  Every byte the voice engine consumes must be the byte
// the CPU wrote at the address the engine asked for.
// ---------------------------------------------------------------------------
localparam [2:0] VS_FETCH_USE = 3'd2;
localparam [2:0] VS_LOOP_USE  = 3'd4;
integer fetches = 0;
integer loop_fetches = 0;
integer mismatches = 0;
reg checking = 1'b0;
reg [7:0] exp_b;

always @(posedge clk_sys) begin
    if (checking && !rst) begin
        if (dut.voice_state == VS_FETCH_USE || dut.voice_state == VS_LOOP_USE) begin
            exp_b = golden[dut.voice_ram_addr];
            fetches = fetches + 1;
            if (dut.voice_state == VS_LOOP_USE) loop_fetches = loop_fetches + 1;
            if (dut.voice_ram_q !== exp_b) begin
                if (mismatches < 12)
                    $display("VOICE FETCH MISMATCH @%0t addr=%04x got=%02x expected=%02x",
                             $time, dut.voice_ram_addr, dut.voice_ram_q, exp_b);
                mismatches = mismatches + 1;
            end
        end
    end
end

// Every wave write the RF5C68 requests must become exactly one SDRAM WRITE
// command at the chip.  A silently dropped write is the fail-silent mechanism
// that turns the aperture back into 0xff (permanent silence).
integer wr_requests = 0;
reg wr_req_d = 1'b0;
always @(posedge clk_sys) begin
    wr_req_d <= sdr_wave_wr_req;
    if (sdr_wave_wr_req && !wr_req_d) wr_requests = wr_requests + 1;
end

// out_l activity tracking
integer nonzero_out = 0;
always @(posedge clk_sys) if (checking && (out_l !== 16'sd0)) nonzero_out = nonzero_out + 1;

`ifdef RFDBG2
reg wvq = 1'b0;
always @(posedge clk_sys) begin
    wvq <= sdr_wave_wr_req;
    if (sdr_wave_wr_req && !wvq)
        $display("%0t WVREQ addr=%04x data=%02x -> sdr %h be=%b d=%h",
                 $time, wave_wr_addr, wave_wr_data, sdr_wave_wr_addr,
                 sdr_wave_wr_be, sdr_wave_wr_data);
    if (sdr_wave_wr_req && sdr_wave_wr_ack)
        $display("%0t WVACK addr=%04x", $time, wave_wr_addr);
end
always @(posedge clk_ram)
    if ({SDRAM_nCS,SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE} == 4'b0100)
        $display("%0t CHIPWR ba=%0d row=%h col=%h dq=%h dqm=%b%b",
                 $time, SDRAM_BA, chip.act_row[SDRAM_BA], SDRAM_A[9:0],
                 SDRAM_DQ, SDRAM_DQMH, SDRAM_DQML);
`endif

`ifdef RFDBG
always @(posedge clk_sys)
    if (!rst)
        $display("%0t sys ldreq=%b ldack=%b wvreq=%b wvack=%b act=%b own=%b cool=%b dreq=%b dack=%b addr=%h be=%b data=%h cs=%b we=%b a=%h cw=%b done=%b",
                 $time, ld_req, ld_ack, sdr_wave_wr_req, sdr_wave_wr_ack,
                 wrmux.active, wrmux.owner, wrmux.cooldown, sdr_wr_req, sdr_wr_ack,
                 sdr_wr_addr, sdr_wr_be, sdr_wr_data, cs, we, addr, cpu_wait, dut.cpu_wave_done);
`endif

// ---------------------------------------------------------------------------
integer i;
reg [7:0] rb;
initial begin
    for (g = 0; g < 65536; g = g + 1) golden[g] = 8'hff;  // cleared aperture

    repeat (8) @(posedge clk_ram);
    init = 1'b0;
    while (!ready) @(posedge clk_ram);
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys); rst = 1'b0;
    repeat (4) @(posedge clk_sys);

    // Prove the loader client still owns the shared write port (and that the
    // chip model's inverted-clear convention holds): write one word raw.
    loader_write(BASE_WORD + 24'h000100, 16'h0000, 2'b11);

    // ---- program the chip the way real sound code does ----
    write_reg(4'h7, 8'h40);            // sel=1 -> cbank = 0, enable off
    write_reg(4'h0, 8'hff);            // ENV
    write_reg(4'h1, 8'hff);            // PAN both channels full
    write_reg(4'h2, 8'h00);            // FD low
    write_reg(4'h3, 8'h08);            // FD high -> 0x0800 = 1.0 byte/sample
    write_reg(4'h4, 8'h00);            // LS low
    write_reg(4'h5, 8'h20);            // LS high -> loop start 0x2000
    write_reg(4'h6, 8'h20);            // ST -> caddr = 0x2000

    // ---- fill wave RAM through the Z80-visible window (wbank 2) ----
    write_reg(4'h7, 8'h02);            // sel=0 -> wbank = 2 (0x2000-0x2fff)
    for (i = 0; i < 16; i = i + 1) begin
        write_wave(i[11:0], 8'hc0 + i[7:0]);
        golden[16'h2000 + i] = 8'hc0 + i[7:0];
    end
    write_wave(12'h010, 8'hff);        // end marker -> loop back to LS
    golden[16'h2010] = 8'hff;

    // Read back through the CPU port: this is the same aperture the voice
    // engine will read.
    for (i = 0; i < 16; i = i + 1) begin
        read_wave(i[11:0], rb);
        if (rb !== golden[16'h2000 + i]) begin
            $display("FAIL: CPU readback %04x got %02x expected %02x",
                     16'h2000 + i, rb, golden[16'h2000 + i]);
            errors = errors + 1;
        end
    end

    // ---- channel 1: a DEAD voice whose start AND loop target are both the
    // 0xff end marker (never-written aperture).  It must contribute silence
    // and must not stall the shared fetch engine for channel 0. ----
    write_reg(4'h7, 8'h41);            // cbank = 1
    write_reg(4'h0, 8'hff);            // ENV
    write_reg(4'h1, 8'hff);            // PAN
    write_reg(4'h2, 8'h00);
    write_reg(4'h3, 8'h08);            // FD = 1.0
    write_reg(4'h4, 8'h00);
    write_reg(4'h5, 8'h30);            // LS = 0x3000 (all 0xff)
    write_reg(4'h6, 8'h30);            // ST = 0x3000

    // ---- start both voices ----
    write_reg(4'h8, 8'hfc);            // channels 0 and 1 ON
    write_reg(4'h7, 8'h80);            // enable = 1

    checking = 1'b1;
    contention_en = 1'b1;

    // 48 CE per voice slot, 8 slots per sample, ce_pcm = clk_sys/4 ->
    // 1536 clk_sys per sample.  Run ~20 samples with no CPU traffic.
    repeat (20 * 1536) @(posedge clk_sys);

    // ---- CPU/voice contention: keep hammering the shared aperture from the
    // Z80 side while the voice engine fetches.  Both clients must be correct.
    // Keep bit7 set: reg 7 assigns `enable` from bit 7 on EVERY write (MAME
    // rf5c68.cpp does the same), so a bank select must re-assert it.
    write_reg(4'h7, 8'h82);            // wbank 2 again for the CPU window
    for (i = 0; i < 48; i = i + 1) begin
        write_wave(12'h800 + i[11:0], 8'h10 + i[7:0]);
        golden[16'h2800 + i] = 8'h10 + i[7:0];
        read_wave(12'h800 + i[11:0], rb);
        if (rb !== golden[16'h2800 + i]) begin
            $display("FAIL: contended CPU readback %04x got %02x expected %02x",
                     16'h2800 + i, rb, golden[16'h2800 + i]);
            errors = errors + 1;
        end
        // Re-read a byte the playing voice is also fetching: the CPU lane and
        // the voice lane must not corrupt each other.
        read_wave(12'h003, rb);
        if (rb !== golden[16'h2003]) begin
            $display("FAIL: contended CPU readback 2003 got %02x expected %02x",
                     rb, golden[16'h2003]);
            errors = errors + 1;
        end
    end

    repeat (20 * 1536) @(posedge clk_sys);

    contention_en = 1'b0;
    checking = 1'b0;

    $display("RF5C68 VOICE: fetches=%0d loop_fetches=%0d mismatches=%0d nonzero_out_cycles=%0d out_l=%0d out_r=%0d",
             fetches, loop_fetches, mismatches, nonzero_out, out_l, out_r);
    $display("RF5C68 VOICE: state=%0d rd_req=%b rd_voice=%b ready=%b cpu_done=%b enable=%b off_m=%02x ch=%0d caddr0=%h caddr1=%h",
             dut.voice_state, dut.wave_rd_req, dut.wave_rd_voice,
             dut.voice_data_ready, dut.cpu_wave_done, dut.enable, dut.chan_off_m,
             dut.ch, dut.caddr[0], dut.caddr[1]);
    $display("RF5C68 VOICE: chip reads=%0d writes=%0d oob=%0d proto=%0d",
             chip.reads_seen, chip.writes_seen, chip.oob_errors, chip.proto_errors);

    if (fetches < 20) begin
        $display("FAIL: voice engine performed only %0d fetches in 40 sample periods", fetches);
        errors = errors + 1;
    end
    if (loop_fetches < 1) begin
        $display("FAIL: 0xff end-marker loop refetch never executed");
        errors = errors + 1;
    end
    if (mismatches != 0) begin
        $display("FAIL: %0d voice fetches returned data the CPU never wrote", mismatches);
        errors = errors + 1;
    end
    if (nonzero_out == 0) begin
        $display("FAIL: out_l stayed at zero for the entire run (silent channel)");
        errors = errors + 1;
    end
    // 1 loader word + every RF5C68 byte write must appear at the chip.
    if (chip.writes_seen != wr_requests + 1) begin
        $display("FAIL: %0d RF5C68 wave writes requested + 1 loader word, but the chip saw %0d WRITE commands",
                 wr_requests, chip.writes_seen);
        errors = errors + 1;
    end
    if (chip.oob_errors != 0 || chip.proto_errors != 0) begin
        $display("FAIL: SDRAM chip model reported protocol/range errors");
        errors = errors + 1;
    end

    if (errors == 0) $display("RF5C68 VOICE EXTERNAL PASS");
    else $display("RF5C68 VOICE EXTERNAL FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #40000000;
    $display("RF5C68 VOICE EXTERNAL FAIL (timeout)");
    $finish;
end

endmodule
`default_nettype wire

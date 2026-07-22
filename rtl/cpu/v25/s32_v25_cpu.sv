// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega System 32 V25 protection subsystem using the vendored s80x86 core.
//
// The NEC V25 used by Golden Axe: The Revenge of Death Adder and Arabian
// Fight executes an encrypted 80186-class instruction stream.  Only opcode
// bytes are translated; ModR/M, displacement and immediate bytes remain raw.
// The small hook in the vendored Core applies opcode_xlat_out only while its
// decoder is consuming an opcode/prefix byte.
//
// Core remains in the clk_sys domain and advances only on a synchronous
// fractional clock enable.  The reduced ratio 2500/12081 converts the nominal
// 48.324 MHz clk_sys to exactly 10.000 MHz average V25 cadence.  Pulses are one
// clk_sys period wide and separated by four or five periods; no fabric clock
// is generated.  The as-built PLL frequency (48.317307 MHz) gives 9.998615 MHz,
// a -0.01385% error from the original 10 MHz V25.

`default_nettype none

module s32_v25_cpu (
    input  wire        clk,          // clk_sys (48.324 MHz): V60-side mailbox + p5 bridge
    input  wire        clk_v25,      // ~24.162 MHz (clk_sys/2): the s80x86 compute domain
    input  wire        rst,
    input  wire        enable,
    input  wire        pause,        // OSD pause (clk_sys-domain level)
    input  wire        table_sel,    // 0 = ga2, 1 = arabfgt

    // Program load port.  prg_waddr is already address-descrambled by the
    // System 32 ROM loader; bytes stored here remain opcode-encrypted.
    input  wire        prg_wr,
    input  wire [15:0] prg_waddr,
    input  wire  [7:0] prg_wdata,

    // Descrambled 64 KiB program image in external SDRAM. Each request fetches
    // one aligned 8-byte cache line; acknowledgement/data may return at any
    // time and are retained until the next virtual V25 clock enable.
    output wire        rom_req,
    output wire [15:3] rom_addr,
    input  wire [63:0] rom_data,
    input  wire        rom_ack,

    // V60/right side of the MB8421 (0xA00000-0xA00fff, low byte lane).
    input  wire        cs,
    input  wire        we,
    input  wire [11:1] addr,
    input  wire  [7:0] wdata,
    output wire  [7:0] rdata,

    // Bring-up diagnostics.  Named instantiations may leave these open.
    output wire        debug_cpu_clk,
    output reg         debug_io_seen,
    output reg  [15:0] debug_last_io_addr,
    output reg         debug_unmapped_seen,
    output reg  [19:0] debug_last_unmapped_addr,
    // The first program line the CPU actually fetched (clk domain): compares
    // byte-for-byte on the OSD against the known-good image's reset line.
    output reg         debug_first_fetch_valid,
    output reg  [63:0] debug_first_fetch_data,
    output reg  [15:3] debug_first_fetch_addr
);

// The s80x86 now runs on clk_v25 = clk_sys/2 (~24.162 MHz), which halves its
// fabric timing requirement so the large core meets timing with real margin.
// The fractional enable keeps the EXACT same 10 MHz average V25 cadence: on the
// half-rate clock the increment is doubled (5000/12081 * 24.162 = 9.9986 MHz),
// identical to the original 2500/12081 * 48.324.  Enable pulses are one clk_v25
// period wide, separated by two or three periods -- cycle-accuracy is unchanged.
localparam [13:0] V25_CE_MODULUS = 14'd12081;
localparam [13:0] V25_CE_INCREMENT = 14'd5000;

// clk_v25-domain reset: asserts asynchronously with rst, deasserts only on a
// clk_v25 edge.  rst is a clk_sys-domain level and clk_v25 is a phase-locked
// output of the same PLL, so an unsynchronised release edge can land inside a
// clk_v25 flop's recovery window on every boot -- and the SDC's asynchronous
// clock group removes that timing from analysis.  Every clk_v25 flop below
// (including the s80x86) must reset from rst_v25, never from raw rst.
reg [2:0] rst_v25_sync;
always @(posedge clk_v25 or posedge rst)
    if (rst) rst_v25_sync <= 3'b111;
    else     rst_v25_sync <= {rst_v25_sync[1:0], 1'b0};
wire rst_v25 = rst_v25_sync[2];

// enable/table_sel are quasi-static clk_sys-domain config bits (latched from
// the MRA descriptor during download, while reset is held).  Two-flop them so
// the clk_v25 domain never samples a mid-transition level.
reg enable_s1, enable_v25, table_sel_s1, table_sel_v25;
reg pause_s1, pause_v25;
always @(posedge clk_v25 or posedge rst_v25)
    if (rst_v25) begin
        enable_s1 <= 1'b0; enable_v25 <= 1'b0;
        table_sel_s1 <= 1'b0; table_sel_v25 <= 1'b0;
        pause_s1 <= 1'b0; pause_v25 <= 1'b0;
    end else begin
        enable_s1 <= enable;       enable_v25 <= enable_s1;
        table_sel_s1 <= table_sel; table_sel_v25 <= table_sel_s1;
        pause_s1 <= pause;         pause_v25 <= pause_s1;
    end

reg [13:0] v25_ce_accum;
reg        v25_ce;
wire       core_reset = rst_v25 | ~enable_v25;
// Upstream has a few synchronously initialized pipeline/state registers.
// Advancing them while reset is active preserves the original reset contract;
// normal architectural execution remains qualified by v25_ce.
wire       core_ce = v25_ce | core_reset;

always @(posedge clk_v25 or posedge rst_v25) begin
    if (rst_v25) begin
        v25_ce_accum <= 14'd0;
        v25_ce       <= 1'b0;
    end else if (!enable_v25) begin
        v25_ce_accum <= 14'd0;
        v25_ce       <= 1'b0;
    end else if (pause_v25) begin
        // OSD pause freezes the virtual 10 MHz cadence with the V60/Z80/PCM
        // CEs; the accumulator phase is preserved so cadence resumes cleanly.
        // Without this the MCU kept running against a paused V60 and could
        // rewrite a half-consumed mailbox response (ga2/arabfgt).
        v25_ce       <= 1'b0;
    end else if (v25_ce_accum >= V25_CE_MODULUS - V25_CE_INCREMENT) begin
        v25_ce_accum <= v25_ce_accum + V25_CE_INCREMENT - V25_CE_MODULUS;
        v25_ce       <= 1'b1;
    end else begin
        v25_ce_accum <= v25_ce_accum + V25_CE_INCREMENT;
        v25_ce       <= 1'b0;
    end
end

assign debug_cpu_clk = v25_ce;

// -------------------------------------------------------------------------
// CPU buses
// -------------------------------------------------------------------------
wire [19:1] instr_addr;
wire [15:0] instr_rdata;
wire        instr_access;
reg         instr_ack;

wire [19:1] data_addr;
wire [15:0] data_wdata;
wire [15:0] data_rdata;
wire        data_access;
reg         data_ack;
wire        data_we;
wire  [1:0] data_bytesel;
wire        data_io;

wire  [7:0] opcode_xlat_in;
wire  [7:0] opcode_xlat_out;

Core cpu (
    .clk(clk_v25),
    .ce(core_ce),
    .reset(core_reset),
    .nmi(1'b0),
    .intr(1'b0),
    .irq(8'h00),
    .inta(),

    .instr_m_addr(instr_addr),
    .instr_m_data_in(instr_rdata),
    .instr_m_access(instr_access),
    .instr_m_ack(instr_ack),

    .data_m_addr(data_addr),
    .data_m_data_in(data_rdata),
    .data_m_data_out(data_wdata),
    .data_m_access(data_access),
    .data_m_ack(data_ack),
    .data_m_wr_en(data_we),
    .data_m_bytesel(data_bytesel),
    .d_io(data_io),
    .lock(),

    .opcode_xlat_in(opcode_xlat_in),
    .opcode_xlat_out(opcode_xlat_out),
    .opcode_xlat_en(enable_v25),

    .debug_stopped(),
    .debug_seize(1'b0),
    .debug_addr(8'h00),
    .debug_run(1'b0),
    .debug_val(),
    .debug_wr_val(16'h0000),
    .debug_wr_en(1'b0)
);

// -------------------------------------------------------------------------
// NEC opcode translation tables from MAME's segas32_m.cpp.
// Unknown encrypted values deliberately translate to 00h, matching MAME.
// Translation occurs at the decoder boundary rather than on the instruction
// bus, which is essential: operands fetched over that bus are not encrypted.
// -------------------------------------------------------------------------
function automatic [7:0] ga2_opcode(input [7:0] enc);
begin
    case (enc)
        8'h02: ga2_opcode = 8'hea; 8'h05: ga2_opcode = 8'h8b;
        8'h1f: ga2_opcode = 8'hfa; 8'h2a: ga2_opcode = 8'h3b;
        8'h2c: ga2_opcode = 8'h49; 8'h35: ga2_opcode = 8'he8;
        8'h38: ga2_opcode = 8'h75; 8'h3d: ga2_opcode = 8'h3a;
        8'h44: ga2_opcode = 8'h8d; 8'h4c: ga2_opcode = 8'hbf;
        8'h4e: ga2_opcode = 8'h88; 8'h53: ga2_opcode = 8'h81;
        8'h70: ga2_opcode = 8'h02; 8'h7f: ga2_opcode = 8'hbc;
        8'h83: ga2_opcode = 8'h8a; 8'h8a: ga2_opcode = 8'h83;
        8'h9d: ga2_opcode = 8'hb8; 8'h9e: ga2_opcode = 8'h26;
        8'had: ga2_opcode = 8'hb5; 8'haf: ga2_opcode = 8'heb;
        8'hbb: ga2_opcode = 8'hb2; 8'hc3: ga2_opcode = 8'hc3;
        8'hd8: ga2_opcode = 8'hb9; 8'hd9: ga2_opcode = 8'hbb;
        8'hdb: ga2_opcode = 8'h43; 8'hf2: ga2_opcode = 8'h8e;
        8'hfb: ga2_opcode = 8'hbe; 8'hfd: ga2_opcode = 8'h80;
        default: ga2_opcode = 8'h00;
    endcase
end
endfunction

function automatic [7:0] arf_opcode(input [7:0] enc);
begin
    case (enc)
        8'h02: arf_opcode = 8'h43; 8'h06: arf_opcode = 8'h83;
        8'h0a: arf_opcode = 8'hea; 8'h0d: arf_opcode = 8'hbc;
        8'h0e: arf_opcode = 8'h73; 8'h20: arf_opcode = 8'h3a;
        8'h23: arf_opcode = 8'hbe; 8'h2e: arf_opcode = 8'h80;
        8'h31: arf_opcode = 8'hb5; 8'h37: arf_opcode = 8'h26;
        8'h4b: arf_opcode = 8'he8; 8'h4c: arf_opcode = 8'h8d;
        8'h4e: arf_opcode = 8'h8b; 8'h53: arf_opcode = 8'hfa;
        8'h55: arf_opcode = 8'h8a; 8'h77: arf_opcode = 8'hba;
        8'h78: arf_opcode = 8'h88; 8'h97: arf_opcode = 8'hbb;
        8'had: arf_opcode = 8'h75; 8'haf: arf_opcode = 8'hbf;
        8'hb8: arf_opcode = 8'h03; 8'hb9: arf_opcode = 8'h3b;
        8'hba: arf_opcode = 8'h8e; 8'hbb: arf_opcode = 8'h74;
        8'hbe: arf_opcode = 8'h81; 8'hc3: arf_opcode = 8'hc3;
        8'hd7: arf_opcode = 8'hb9; 8'hd8: arf_opcode = 8'hb2;
        8'hdd: arf_opcode = 8'h49; 8'he8: arf_opcode = 8'heb;
        8'hfe: arf_opcode = 8'h02; 8'hff: arf_opcode = 8'hb8;
        default: arf_opcode = 8'h00;
    endcase
end
endfunction

assign opcode_xlat_out = table_sel_v25 ? arf_opcode(opcode_xlat_in)
                                       : ga2_opcode(opcode_xlat_in);

// Program ROM lives in external SDRAM and is mirrored at 00000h and f0000h.
// Keeping the 64 KiB image out of M10Ks recovers 64 blocks required to fit the
// real V25 alongside the System 32 video and audio hardware.
reg        rom_ready;
reg [15:0] rom_q;
reg        cache_req;
reg [15:1] cache_addr;
wire       cache_ack;
wire [15:0] cache_data;

// prg_wr (a clk_sys loader pulse) synchronised into the clk_v25 cache domain.
// It only matters during ROM download, when rst is held, so a missed/stretched
// pulse is harmless -- the cache is reset then anyway.
reg prg_wr_s1, prg_wr_s2;
always @(posedge clk_v25 or posedge rst_v25)
    if (rst_v25) begin prg_wr_s1 <= 1'b0; prg_wr_s2 <= 1'b0; end
    else         begin prg_wr_s1 <= prg_wr; prg_wr_s2 <= prg_wr_s1; end
wire prg_wr_v25 = prg_wr_s2;

// Cache runs in clk_v25; its SDRAM p5 fetch crosses to the clk_sys/clk_ram SDRAM
// controller through the CDC toggle handshake below.
wire        cache_rom_req;
wire [15:3] cache_rom_addr;
wire [63:0] cache_rom_data;
wire        cache_rom_ack;

s32_v25_rom_cache program_cache (
    .clk(clk_v25), .rst(rst_v25), .invalidate(prg_wr_v25),
    .cpu_req(cache_req), .cpu_addr(cache_addr),
    .cpu_data(cache_data), .cpu_ack(cache_ack),
    .rom_req(cache_rom_req), .rom_addr(cache_rom_addr),
    .rom_data(cache_rom_data), .rom_ack(cache_rom_ack)
);

// ---- p5 clock-domain bridge: clk_v25 cache <-> clk_sys/clk_ram SDRAM --------
// A two-flop toggle handshake carries one aligned 8-byte line fetch across the
// crossing.  cache_rom_req (a one-clk_v25 pulse) flips req_tgl; the clk_sys side
// syncs it, issues the SDRAM p5 request, captures the burst on rom_ack, then
// flips ack_tgl; the clk_v25 side syncs that and pulses cache_rom_ack with the
// latched data.  Address and data buses are held stable across each half of the
// handshake, so only the toggles are synchronised.
reg        req_tgl_v25;
reg [15:3] req_addr_v25;
always @(posedge clk_v25 or posedge rst_v25)
    if (rst_v25) begin req_tgl_v25 <= 1'b0; req_addr_v25 <= 13'd0; end
    else if (cache_rom_req) begin
        req_tgl_v25  <= ~req_tgl_v25;
        req_addr_v25 <= cache_rom_addr;
    end

reg        req_s1, req_s2, req_s3;
reg [15:3] br_addr_r;
reg [63:0] br_data_r;
reg        br_busy;
reg        ack_tgl_clk;
reg        sdr_req_r;
always @(posedge clk or posedge rst)
    if (rst) begin
        req_s1<=1'b0; req_s2<=1'b0; req_s3<=1'b0; br_busy<=1'b0;
        ack_tgl_clk<=1'b0; sdr_req_r<=1'b0; br_addr_r<=13'd0; br_data_r<=64'd0;
        debug_first_fetch_valid <= 1'b0;
        debug_first_fetch_data  <= 64'd0;
        debug_first_fetch_addr  <= 13'd0;
    end else begin
        req_s1 <= req_tgl_v25; req_s2 <= req_s1; req_s3 <= req_s2;
        sdr_req_r <= 1'b0;
        if (!br_busy && (req_s2 ^ req_s3)) begin
            br_busy   <= 1'b1;
            br_addr_r <= req_addr_v25;   // stable while the cache holds the miss
            sdr_req_r <= 1'b1;
        end
        if (br_busy && rom_ack) begin
            br_busy     <= 1'b0;
            br_data_r   <= rom_data;
            ack_tgl_clk <= ~ack_tgl_clk;
            if (!debug_first_fetch_valid) begin
                debug_first_fetch_valid <= 1'b1;
                debug_first_fetch_data  <= rom_data;
                debug_first_fetch_addr  <= br_addr_r;
            end
        end
    end
assign rom_req  = sdr_req_r;
assign rom_addr = br_addr_r;

reg ack_s1, ack_s2, ack_s3;
always @(posedge clk_v25 or posedge rst_v25)
    if (rst_v25) begin ack_s1<=1'b0; ack_s2<=1'b0; ack_s3<=1'b0; end
    else begin ack_s1 <= ack_tgl_clk; ack_s2 <= ack_s1; ack_s3 <= ack_s2; end
assign cache_rom_ack  = ack_s2 ^ ack_s3;
assign cache_rom_data = br_data_r;      // stable when cache_rom_ack pulses

// -------------------------------------------------------------------------
// MB8421 mailbox.  The physical part has 2 KiB, mirrored throughout the
// V25's 10000h-1ffffh window.  Port A is the byte-wide V60 side; port B is
// the 16-bit CPU side with independent byte enables.
// -------------------------------------------------------------------------
wire  [7:0] dpram_v60_q;
reg   [9:0] dpram_cpu_addr;
reg  [15:0] dpram_cpu_wdata;
reg   [1:0] dpram_cpu_byteena;
reg         dpram_cpu_rden;
reg         dpram_cpu_wren;
wire [15:0] dpram_cpu_q;

s32_v25_mailbox_dpram mb_ram (
    .v60_clock(clk),                 // clk_sys: V60 side (System 32 bus)
    .v60_addr(addr),
    .v60_wdata(wdata),
    // Always live to the V60 (MAME parity: the MB8421 is a plain dual-port
    // RAM).  Gating these on `enable` dropped every V60 mailbox write during
    // the post-reset image sweep (~2-4 ms), a blackout MAME does not have.
    // `cs` already carries board.has_v25 at the instantiation site.
    .v60_rden(cs),
    .v60_wren(cs && we),
    .v60_q(dpram_v60_q),

    .cpu_clock(clk_v25),             // clk_v25: s80x86 side
    .cpu_addr(dpram_cpu_addr),
    .cpu_wdata(dpram_cpu_wdata),
    .cpu_byteena(dpram_cpu_byteena),
    .cpu_rden(dpram_cpu_rden),
    .cpu_wren(dpram_cpu_wren),
    .cpu_q(dpram_cpu_q)
);

assign rdata = dpram_v60_q;

// -------------------------------------------------------------------------
// Single-target CPU bus arbiter. External ROM responses are retained across
// fractional CE gaps; the synchronous mailbox keeps its settling cycle.
// Data transactions take priority so prefetch cannot starve load/store.
// -------------------------------------------------------------------------
localparam [3:0]
    BUS_IDLE       = 4'd0,
    BUS_I_ROM_WAIT = 4'd1,
    BUS_D_ROM_WAIT = 4'd3,
    BUS_D_DP_WAIT  = 4'd5,
    BUS_D_DP_ACK   = 4'd6;

reg [3:0] bus_state;
reg [15:0] instr_rdata_r;
reg [15:0] data_rdata_r;

assign instr_rdata = instr_rdata_r;
assign data_rdata  = data_rdata_r;

wire instr_is_rom = (instr_addr[19:16] == 4'h0) ||
                    (instr_addr[19:16] == 4'hf);
wire data_is_rom   = (data_addr[19:16] == 4'h0) ||
                    (data_addr[19:16] == 4'hf);
wire data_is_dpram = (data_addr[19:16] == 4'h1);

always @(posedge clk_v25 or posedge rst_v25) begin
    if (rst_v25) begin
        bus_state                <= BUS_IDLE;
        instr_ack               <= 1'b0;
        data_ack                <= 1'b0;
        instr_rdata_r           <= 16'hffff;
        data_rdata_r            <= 16'hffff;
        cache_addr              <= 15'd0;
        cache_req               <= 1'b0;
        rom_ready               <= 1'b0;
        rom_q                   <= 16'hffff;
        dpram_cpu_addr          <= 10'd0;
        dpram_cpu_wdata         <= 16'd0;
        dpram_cpu_byteena       <= 2'b00;
        dpram_cpu_rden          <= 1'b0;
        dpram_cpu_wren          <= 1'b0;
        debug_io_seen           <= 1'b0;
        debug_last_io_addr      <= 16'd0;
        debug_unmapped_seen     <= 1'b0;
        debug_last_unmapped_addr <= 20'd0;
    end else begin
        // Requests and BRAM enables are one clk_v25 pulse. CPU acknowledgements
        // change only on V25 CE edges and remain visible throughout CE gaps.
        cache_req       <= 1'b0;
        dpram_cpu_rden  <= 1'b0;
        dpram_cpu_wren  <= 1'b0;

        if (cache_ack) begin
            rom_q     <= cache_data;
            rom_ready <= 1'b1;
        end

        if (!enable_v25 || prg_wr_v25) begin
            bus_state  <= BUS_IDLE;
            instr_ack <= 1'b0;
            data_ack  <= 1'b0;
            rom_ready <= 1'b0;
        end else if (v25_ce) begin
            instr_ack <= 1'b0;
            data_ack  <= 1'b0;
            case (bus_state)
                BUS_IDLE: begin
                    if (data_access) begin
                        if (data_io) begin
                            // V25 internal peripherals/I/O are not yet
                            // modelled.  Ack safely and retain the exact port
                            // for the firmware test to report.
                            data_rdata_r       <= 16'hffff;
                            data_ack           <= 1'b1;
                            debug_io_seen      <= 1'b1;
                            debug_last_io_addr <= {
                                data_addr[15:1], data_bytesel == 2'b10
                            };
                        end else if (data_is_dpram) begin
                            dpram_cpu_addr    <= data_addr[10:1];
                            dpram_cpu_wdata   <= data_wdata;
                            dpram_cpu_byteena <= data_bytesel;
                            dpram_cpu_rden    <= ~data_we;
                            dpram_cpu_wren    <= data_we;
                            bus_state         <= BUS_D_DP_WAIT;
                        end else if (data_is_rom) begin
                            // The V25 internal data area (IDB=0xFF at reset)
                            // overlays 0xFFE00-0xFFFFF inside this window and
                            // is not backed by the model: writes are dropped,
                            // reads return program bytes.  Surface both so a
                            // hardware failure of this class is visible —
                            // SFR page (0xFFFxx: on-chip peripheral regs; the
                            // ga2 boot writes byte 0xFFFEB = PRC) goes to the
                            // informational io band like port I/O; IRAM page
                            // (0xFFExx: register banks/data) would be real
                            // data loss and goes to the unmapped fault band.
                            if (data_addr[19:8] == 12'hfff) begin
                                debug_io_seen      <= 1'b1;
                                debug_last_io_addr <= {
                                    data_addr[15:1], data_bytesel == 2'b10
                                };
                            end else if (data_addr[19:8] == 12'hffe) begin
                                debug_unmapped_seen      <= 1'b1;
                                debug_last_unmapped_addr <= {data_addr, 1'b0};
                            end
                            if (data_we) begin
                                // ROM/internal-area writes: acknowledged, dropped.
                                data_ack <= 1'b1;
                            end else begin
                                cache_addr <= data_addr[15:1];
                                cache_req  <= 1'b1;
                                rom_ready <= 1'b0;
                                bus_state <= BUS_D_ROM_WAIT;
                            end
                        end else begin
                            data_rdata_r             <= 16'hffff;
                            data_ack                 <= 1'b1;
                            debug_unmapped_seen      <= 1'b1;
                            debug_last_unmapped_addr <= {data_addr, 1'b0};
                        end
                    end else if (instr_access) begin
                        if (instr_is_rom) begin
                            cache_addr <= instr_addr[15:1];
                            cache_req  <= 1'b1;
                            rom_ready <= 1'b0;
                            bus_state <= BUS_I_ROM_WAIT;
                        end else begin
                            instr_rdata_r            <= 16'hffff;
                            instr_ack                <= 1'b1;
                            debug_unmapped_seen      <= 1'b1;
                            debug_last_unmapped_addr <= {instr_addr, 1'b0};
                        end
                    end
                end

                BUS_I_ROM_WAIT: begin
                    if (rom_ready || cache_ack) begin
                        instr_rdata_r <= cache_ack ? cache_data : rom_q;
                        instr_ack     <= 1'b1;
                        rom_ready     <= 1'b0;
                        bus_state     <= BUS_IDLE;
                    end
                end
                BUS_D_ROM_WAIT: begin
                    if (rom_ready || cache_ack) begin
                        data_rdata_r <= cache_ack ? cache_data : rom_q;
                        data_ack     <= 1'b1;
                        rom_ready    <= 1'b0;
                        bus_state    <= BUS_IDLE;
                    end
                end

                BUS_D_DP_WAIT: bus_state <= BUS_D_DP_ACK;
                BUS_D_DP_ACK: begin
                    data_rdata_r <= dpram_cpu_q;
                    data_ack     <= 1'b1;
                    bus_state    <= BUS_IDLE;
                end

                default: bus_state <= BUS_IDLE;
            endcase
        end
    end
end

endmodule

// (audit hygiene) A mixed-width s32_v25_program_rom block-memory module used to
// live here but was never instantiated: the real V25 core streams its program
// from external SDRAM over rom_req/rom_addr/rom_data, and the mailbox HLE owns no
// program store.  It was removed so it can no longer be mistaken for a live ROM.

// Mixed-width true-dual-port mailbox memory.
module s32_v25_mailbox_dpram (
    input  wire        v60_clock,
    input  wire [10:0] v60_addr,
    input  wire  [7:0] v60_wdata,
    input  wire        v60_rden,
    input  wire        v60_wren,
    output wire  [7:0] v60_q,
    input  wire        cpu_clock,
    input  wire  [9:0] cpu_addr,
    input  wire [15:0] cpu_wdata,
    input  wire  [1:0] cpu_byteena,
    input  wire        cpu_rden,
    input  wire        cpu_wren,
    output wire [15:0] cpu_q
);
`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(v60_clock), .address_a(v60_addr), .data_a(v60_wdata),
    .wren_a(v60_wren), .rden_a(v60_rden), .q_a(v60_q),
    .clock1(cpu_clock), .address_b(cpu_addr), .data_b(cpu_wdata),
    .wren_b(cpu_wren), .rden_b(cpu_rden), .q_b(cpu_q),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
    .addressstall_b(1'b0), .byteena_a(1'b1),
    .byteena_b(cpu_byteena), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus()
);
defparam
    ram.operation_mode = "BIDIR_DUAL_PORT",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.numwords_a = 2048,
    ram.widthad_a = 11,
    ram.width_a = 8,
    ram.width_byteena_a = 1,
    ram.numwords_b = 1024,
    ram.widthad_b = 10,
    ram.width_b = 16,
    ram.width_byteena_b = 2,
    ram.address_reg_b = "CLOCK1",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    ram.read_during_write_mode_mixed_ports = "DONT_CARE";
`else
reg [7:0] mem [0:2047];
reg [7:0] v60_q_r;
reg [15:0] cpu_q_r;
assign v60_q = v60_q_r;
assign cpu_q = cpu_q_r;

integer init_i;
initial
    for (init_i = 0; init_i < 2048; init_i = init_i + 1)
        mem[init_i] = 8'h00;

always @(posedge v60_clock) begin
    if (v60_rden) v60_q_r <= mem[v60_addr];
    if (v60_wren) mem[v60_addr] <= v60_wdata;
end
always @(posedge cpu_clock) begin
    if (cpu_rden)
        cpu_q_r <= {mem[{cpu_addr, 1'b1}], mem[{cpu_addr, 1'b0}]};
    if (cpu_wren && cpu_byteena[0]) mem[{cpu_addr, 1'b0}] <= cpu_wdata[7:0];
    if (cpu_wren && cpu_byteena[1]) mem[{cpu_addr, 1'b1}] <= cpu_wdata[15:8];
end
`endif
endmodule

`default_nettype wire


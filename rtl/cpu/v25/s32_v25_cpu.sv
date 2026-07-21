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
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
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
    output reg  [19:0] debug_last_unmapped_addr
);

localparam [13:0] V25_CE_MODULUS = 14'd12081;
localparam [13:0] V25_CE_INCREMENT = 14'd2500;

reg [13:0] v25_ce_accum;
reg        v25_ce;
wire       core_reset = rst | ~enable;
// Upstream has a few synchronously initialized pipeline/state registers.
// Advancing them while reset is active preserves the original reset contract;
// normal architectural execution remains qualified by v25_ce.
wire       core_ce = v25_ce | core_reset;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        v25_ce_accum <= 14'd0;
        v25_ce       <= 1'b0;
    end else if (!enable) begin
        v25_ce_accum <= 14'd0;
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
    .clk(clk),
    .ce(core_ce),
    .reset(rst | ~enable),
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
    .opcode_xlat_en(enable),

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

assign opcode_xlat_out = table_sel ? arf_opcode(opcode_xlat_in)
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

s32_v25_rom_cache program_cache (
    .clk(clk), .rst(rst), .invalidate(prg_wr),
    .cpu_req(cache_req), .cpu_addr(cache_addr),
    .cpu_data(cache_data), .cpu_ack(cache_ack),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .rom_data(rom_data), .rom_ack(rom_ack)
);

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
    .v60_clock(clk),
    .v60_addr(addr),
    .v60_wdata(wdata),
    .v60_rden(enable && cs),
    .v60_wren(enable && cs && we),
    .v60_q(dpram_v60_q),

    .cpu_clock(clk),
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

always @(posedge clk or posedge rst) begin
    if (rst) begin
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
        // Requests and BRAM enables are one clk_sys pulse. CPU acknowledgements
        // change only on V25 CE edges and remain visible throughout CE gaps.
        cache_req       <= 1'b0;
        dpram_cpu_rden  <= 1'b0;
        dpram_cpu_wren  <= 1'b0;

        if (cache_ack) begin
            rom_q     <= cache_data;
            rom_ready <= 1'b1;
        end

        if (!enable || prg_wr) begin
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
                            if (data_we) begin
                                // ROM writes are ignored but acknowledged.
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
    ram.read_during_write_mode_mixed_ports = "OLD_DATA";
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


//============================================================================
//  System 32 protection & per-game custom hardware (DESIGN.md §8)
//  All modules sit on the V60 bus as snoopers/responders enabled by the
//  board descriptor's prot_sel / flags.
//============================================================================

import s32_pkg::*;

// ---------------------------------------------------------------------------
//  s32_prot_hle: the write-triggered work-RAM protections
//  (sonic §8.2, darkedge/f1lap vblank §8.4, dbzvrvs, jleague §8.5)
//  Watches CPU writes; issues its own work-RAM writes via a dedicated port
//  (arbitration handled by the bus controller: prot port wins, CPU stalls).
// ---------------------------------------------------------------------------
module s32_prot_hle (
    input             clk,
    input             rst,
    input       [6:0] prot_sel,

    // CPU bus snoop (writes to work RAM window 0x200000+)
    input             cpu_wr,
    input      [23:0] cpu_addr,
    input      [15:0] cpu_wdata,

    // vblank strobe (darkedge/f1lap FD1149 behaviour)
    input             vblank,

    // work RAM second port
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,    // word address within 128KB window
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input      [15:0] wram_rdata,
    input             wram_ack,

    // program ROM read port (through SDRAM arbiter, shared with CPU port)
    output reg        rom_req,
    output reg [23:0] rom_addr,
    input      [15:0] rom_data,
    input             rom_ack
);

typedef enum logic [3:0] {
    P_IDLE,
    // sonic: on write to 0x20E5C4 -> read level table, update 0xF06E/F0BC
    SON_RD0, SON_RD1, SON_WR0, SON_WR1, SON_WR2,
    // darkedge/f1lap vblank writes
    DKE_W0, DKE_R0, DKE_W1, DKE_W2,
    F1L_W0, F1L_R0, F1L_W1,
    // dbzvrvs: copy 0x200044 -> 0x2080C8
    DBZ_R0, DBZ_W0
} pst_t;
pst_t ps;

reg [15:0] cleared;      // sonic cleared-levels value
reg [15:0] level;
reg [7:0]  tmp;

always @(posedge clk) begin
    if (rst) begin
        ps <= P_IDLE;
        wram_req <= 0; rom_req <= 0;
    end
    else begin
        case (ps)
        P_IDLE: begin
            wram_req <= 0; rom_req <= 0;
            case (prot_sel)
            PROT_SONIC:
                if (cpu_wr && cpu_addr == 24'h20E5C4) begin
                    cleared <= cpu_wdata;
                    if (cpu_wdata == 0) begin
                        level <= 16'h0007;
                        ps <= SON_WR0;
                    end
                    else begin
                        // level = ROM[0x263A + cleared*2 - 2] | ROM[.. -1]<<8
                        rom_req  <= 1'b1;
                        rom_addr <= 24'h00263A + {cpu_wdata[14:0], 1'b0} - 24'd2;
                        ps <= SON_RD0;
                    end
                end
            PROT_DBZVRVS:
                // audit R20 IO-8: dbzvrvs prot window is 0xA00000-0xA7FFFF (MAME install range)
                if (cpu_wr && cpu_addr[23:19] == 5'b10100) begin
                    wram_req <= 1'b1; wram_we <= 0;
                    wram_addr <= 16'h0044 >> 1;   // read 0x200044
                    ps <= DBZ_R0;
                end
            PROT_JLEAGUE:
                if (cpu_wr && cpu_addr[23:1] == (24'h20F700 >> 1)) begin
                    // write_byte(0x20F708, ROM[0x7BBC0 + data*2])
                    rom_req  <= 1'b1;
                    rom_addr <= 24'h07BBC0 + {cpu_wdata[14:0], 1'b0};
                    ps <= SON_RD1;   // reuse: single-byte fetch + write
                end
                else if (cpu_wr && cpu_addr[23:1] == (24'h20F704 >> 1)) begin
                    wram_req <= 1'b1; wram_we <= 1'b1;
                    wram_addr <= 16'h0016 >> 1;   // 0x200016
                    wram_wdata <= {8'h00, cpu_wdata[7:0]};
                    wram_be <= 2'b01;
                    ps <= SON_WR2;
                end
            PROT_DARKEDGE:
                if (vblank) begin
                    wram_req <= 1'b1; wram_we <= 1'b1;
                    wram_addr <= 16'hF072 >> 1;
                    wram_wdata <= 16'h0000; wram_be <= 2'b11;
                    ps <= DKE_W0;
                end
            PROT_F1LAP:
                if (vblank) begin
                    wram_req <= 1'b1; wram_we <= 1'b1;
                    wram_addr <= 16'hF7C6 >> 1;
                    wram_wdata <= 16'h0000; wram_be <= 2'b01;
                    ps <= F1L_W0;
                end
            default: ;
            endcase
        end

        // ---- sonic ----
        SON_RD0: if (rom_ack) begin
            rom_req <= 0;
            level <= rom_data;             // little-endian word = {hi,lo} layout per MAME byte reads
            ps <= SON_WR0;
        end
        SON_WR0: begin
            wram_req <= 1'b1; wram_we <= 1'b1;
            wram_addr <= 16'hF06E >> 1;
            wram_wdata <= level; wram_be <= 2'b11;
            ps <= SON_WR1;
        end
        SON_WR1: if (wram_ack) begin
            wram_req <= 1'b1; wram_we <= 1'b1;
            wram_addr <= 16'hF0BC >> 1;
            wram_wdata <= 16'h0000; wram_be <= 2'b11;
            ps <= SON_WR2;
        end
        SON_WR2: if (wram_ack) begin
            // second status word for sonic; harmless elsewhere
            if (prot_sel == PROT_SONIC) begin
                wram_req <= 1'b1; wram_we <= 1'b1;
                wram_addr <= (16'hF0BC + 16'h2) >> 1;
                wram_wdata <= 16'h0000; wram_be <= 2'b11;
            end
            else wram_req <= 0;
            ps <= P_IDLE;
        end
        SON_RD1: if (rom_ack) begin       // jleague byte fetch
            rom_req <= 0;
            wram_req <= 1'b1; wram_we <= 1'b1;
            wram_addr <= 16'hF708 >> 1;
            wram_wdata <= {8'h00, rom_data[7:0]};
            wram_be <= 2'b01;
            ps <= SON_WR2;
        end

        // ---- darkedge vblank sequence ----
        DKE_W0: if (wram_ack) begin
            wram_req <= 1'b1; wram_we <= 1'b1;
            wram_addr <= 16'hF082 >> 1;
            wram_wdata <= 16'h0000; wram_be <= 2'b11;
            ps <= DKE_R0;
        end
        DKE_R0: if (wram_ack) begin
            wram_req <= 1'b1; wram_we <= 1'b0;
            wram_addr <= 16'hA12C >> 1;
            ps <= DKE_W1;
        end
        DKE_W1: if (wram_ack) begin
            tmp <= wram_rdata[7:0];
            if (wram_rdata[7:0] != 0) begin
                wram_req <= 1'b1; wram_we <= 1'b1;
                wram_addr <= 16'hA12C >> 1;
                wram_wdata <= {8'h00, wram_rdata[7:0] - 8'h01};
                wram_be <= 2'b01;
                ps <= DKE_W2;
            end
            else begin wram_req <= 0; ps <= P_IDLE; end
        end
        DKE_W2: if (wram_ack) begin
            if (tmp == 8'h01) begin
                wram_req <= 1'b1; wram_we <= 1'b1;
                wram_addr <= 16'hA12E >> 1;
                wram_wdata <= {8'h00, 8'h01};
                wram_be <= 2'b01;
            end
            else wram_req <= 0;
            ps <= P_IDLE;
        end

        // ---- f1lap vblank ----
        F1L_W0: if (wram_ack) begin
            wram_req <= 1'b1; wram_we <= 1'b0;
            wram_addr <= 16'hEE81 >> 1;
            ps <= F1L_R0;
        end
        F1L_R0: if (wram_ack) begin
            if (wram_rdata[15:8] == 8'hFF) begin
                wram_req <= 1'b1; wram_we <= 1'b1;
                wram_addr <= 16'hEE81 >> 1;
                wram_wdata <= 16'h0000; wram_be <= 2'b10;  // odd byte
                ps <= F1L_W1;
            end
            else begin wram_req <= 0; ps <= P_IDLE; end
        end
        F1L_W1: if (wram_ack) begin wram_req <= 0; ps <= P_IDLE; end

        // ---- dbzvrvs copy ----
        DBZ_R0: if (wram_ack) begin
            wram_req <= 1'b1; wram_we <= 1'b1;
            wram_addr <= 16'h80C8 >> 1;
            wram_wdata <= wram_rdata; wram_be <= 2'b11;
            ps <= DBZ_W0;
        end
        DBZ_W0: if (wram_ack) begin wram_req <= 0; ps <= P_IDLE; end

        default: ps <= P_IDLE;
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
//  s32_prot_brival: protection RAM string responder (§8.3)
//  Reads 0x20BA00-07 trapped; writes 0xA00800-80A trigger 16-byte ROM copies.
// ---------------------------------------------------------------------------
module s32_prot_brival (
    input             clk,
    input             rst,
    input             enable,

    input             cpu_wr,
    input      [23:0] cpu_addr,
    input      [15:0] cpu_wdata,

    // read trap: asserted when CPU reads 0x20BA00-07 word-wide
    input             cpu_rd,
    input       [1:0] cpu_be,           // audit R20 IO-9: MAME traps word reads only
    output reg        trap_active,
    output reg [15:0] trap_data,

    // protection RAM (256 bytes) CPU-visible via workram overlay
    output reg        pram_we,
    output reg  [7:0] pram_addr,
    output reg  [7:0] pram_wdata,

    // ROM port
    output reg        rom_req,
    output reg [23:0] rom_addr,
    input      [15:0] rom_data,
    input             rom_ack
);

// slot -> ROM source address (MAME prot_address table)
function automatic [23:0] slot_rom(input [2:0] s);
    case (s)
        3'd0: slot_rom = 24'h109517;
        3'd5: slot_rom = 24'h109617;
        default: slot_rom = 24'h109597;
    endcase
endfunction

reg [2:0] slot;
reg [3:0] cnt;
typedef enum logic [1:0] { B_IDLE, B_RD, B_WR } bst_t;
bst_t bs;

always @(posedge clk) begin
    if (rst) begin bs <= B_IDLE; rom_req <= 0; pram_we <= 0; end
    else begin
        pram_we <= 0;
        // MAME's brival read handler is installed word-wide (mem_mask 0xffff);
        // byte reads fall through to work RAM, so only trap full-word accesses
        // (audit R20 IO-9).
        trap_active <= enable && cpu_rd && (cpu_be == 2'b11) &&
                       (cpu_addr[23:4] == (24'h20BA00 >> 4)) &&
                       (cpu_addr[3:1] == 3'd0 || cpu_addr[3:1] == 3'd2 || cpu_addr[3:1] == 3'd3);
        trap_data <= 16'h0000;

        case (bs)
        B_IDLE: if (enable && cpu_wr && cpu_addr[23:12] == 12'hA00 &&
                    cpu_addr[11:4] == 8'h80 && cpu_addr[3:1] <= 3'd5) begin
            slot <= cpu_addr[3:1];
            cnt <= 0;
            rom_req <= 1'b1;
            rom_addr <= slot_rom(cpu_addr[3:1]);
            bs <= B_RD;
        end
        B_RD: if (rom_ack) begin
            rom_req <= 0;
            pram_we <= 1'b1;
            pram_addr <= {slot, 4'b0} + {3'b0, cnt};
            pram_wdata <= rom_data[7:0];
            // bytes fetched one at a time (low byte of word reads)
            if (cnt == 4'd15) bs <= B_IDLE;
            else begin
                cnt <= cnt + 1'd1;
                rom_req <= 1'b1;
                rom_addr <= slot_rom(slot) + {19'b0, cnt} + 24'd1;
                bs <= B_RD;
            end
        end
        default: bs <= B_IDLE;
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
//  s32_arescue_dsp: HLE of the uPD77P25 command interface (§8.6)
//  Registers at 0xA00000-0xA00007 (words 0-3); read of word 2 (offset 4)
//  triggers command evaluation per MAME arescue_dsp_r.
// ---------------------------------------------------------------------------
module s32_arescue_dsp (
    input             clk,
    input             rst,
    input             enable,

    input             cs,           // 0xA00000-0xA00007
    input             we,
    input       [1:0] addr,         // word offset
    input      [15:0] wdata,
    output reg [15:0] rdata
);

reg [15:0] io [0:3];

always @(posedge clk) begin
    if (rst) begin
        io[0] <= 0; io[1] <= 0; io[2] <= 0; io[3] <= 0;
    end
    else if (enable && cs) begin
        if (we) io[addr] <= wdata;
        else begin
            if (addr == 2'd2) begin
                case (io[0])
                    16'h0003: begin io[0] <= 16'h8000; io[1] <= 16'h0001; end
                    16'h0006: io[0] <= {io[1][13:0], 2'b00};   // 4 * operand
                    default: ;
                endcase
            end
            rdata <= io[addr];
        end
    end
end

endmodule

// ---------------------------------------------------------------------------
//  s32_dualpcb: single-board mode bridge responder (§8.6)
//  4KB comms RAM at 0x810000 + identity word at 0x818000.
// ---------------------------------------------------------------------------
module s32_dualpcb (
    input             clk,
    input             enable,

    input             cs_ram,       // 0x810000-0x810FFF
    input             cs_id,        // 0x818000-0x818003
    input             we,
    input      [11:1] addr,
    input      [15:0] wdata,
    output reg [15:0] rdata
);

reg [15:0] comm [0:2047];

// audit R20 IO-10(b): dual-PCB comms RAM powers up 0xFF (f1en install path memsets it)
integer __comm_init;
initial begin
    for (__comm_init = 0; __comm_init < 2048; __comm_init = __comm_init + 1)
        comm[__comm_init] = 16'hFFFF;
end

always @(posedge clk) begin
    if (cs_ram) begin
        if (we) comm[addr] <= wdata;
        rdata <= comm[addr];
    end
    else if (cs_id) begin
        // main-board identity (dual_pcb_mainsub): partner-present code.
        rdata <= 16'h0000;
    end
end

endmodule

// ---------------------------------------------------------------------------
//  s32_v25: protection MCU subsystem (§8.1) — ga2 / arabfgt
//  v1 strategy per DESIGN.md: HLE responder implementing the documented
//  wakeup/command protocol through the MB8421 dual-port RAM at 0xA00000,
//  carrying the real opcode-decrypt tables for the future full-core swap.
//  The 64KB descrambled program is loaded to BRAM by the ROM loader; a
//  full V30-family core drops in behind this interface (M-next).
// ---------------------------------------------------------------------------
module s32_v25 (
    input             clk,
    input             rst,
    input             enable,
    input             table_sel,    // 0 = ga2, 1 = arabfgt

    // program BRAM load port (from loader, descrambled)
    input             prg_wr,
    input      [15:0] prg_waddr,
    input       [7:0] prg_wdata,

    // V60-side DPRAM access (0xA00000-0xA00FFF, low byte lanes)
    input             cs,
    input             we,
    input      [11:1] addr,
    input       [7:0] wdata,
    output      [7:0] rdata
);

// The mailbox HLE does not model V25 program memory: prg_wr/prg_waddr/prg_wdata
// are accepted for interface symmetry with the real s32_v25_cpu core (which uses
// them to invalidate its decode cache) but carry no storage here.  A prior
// write-only 64 KiB array was never read anywhere in the RTL and has been
// removed so it can no longer be misread as a live program store (audit hygiene).

// MB8421 mailbox RAM.  The HLE currently owns only the V60-side port, but an
// explicit true-dual-port block preserves the physical interface for a future
// MCU core without paying 16K flip-flops in the GA2 build.
wire [7:0] dpram_q;
s32_byte_dpram #(.ADDR_WIDTH(11), .NUM_WORDS(2048), .POWER_UP_UNINITIALIZED("FALSE")) dpram_mem ( // audit R20 PF-8: deterministic zero power-up
    .clock(clk),
    .address_a(addr), .data_a(wdata), .rden_a(enable && cs),
    .wren_a(enable && cs && we), .q_a(dpram_q),
    .address_b(11'd0), .data_b(8'd0), .rden_b(1'b0),
    .wren_b(1'b0), .q_b()
);

// HLE: wakeup string + echo protocol (MAME simulation fallback)
//   ga2:  "wake up! GOLDEN AXE The Revenge of Death-Adder! "
//   arf:  "wake up! ARF!                                   "
// The V25 firmware fills DPRAM offset 0 with the string, then serves
// command/response tables. v1 provides the string + the ga2 sprite
// expansion results table (prot[16] from MAME).
function automatic [7:0] wake_ga2(input [5:0] i);
    case (i)
        6'd0:  wake_ga2 = "w"; 6'd1:  wake_ga2 = "a"; 6'd2:  wake_ga2 = "k";
        6'd3:  wake_ga2 = "e"; 6'd4:  wake_ga2 = " "; 6'd5:  wake_ga2 = "u";
        6'd6:  wake_ga2 = "p"; 6'd7:  wake_ga2 = "!"; 6'd8:  wake_ga2 = " ";
        6'd9:  wake_ga2 = "G"; 6'd10: wake_ga2 = "O"; 6'd11: wake_ga2 = "L";
        6'd12: wake_ga2 = "D"; 6'd13: wake_ga2 = "E"; 6'd14: wake_ga2 = "N";
        6'd15: wake_ga2 = " "; 6'd16: wake_ga2 = "A"; 6'd17: wake_ga2 = "X";
        6'd18: wake_ga2 = "E"; 6'd19: wake_ga2 = " "; 6'd20: wake_ga2 = "T";
        6'd21: wake_ga2 = "h"; 6'd22: wake_ga2 = "e"; 6'd23: wake_ga2 = " ";
        6'd24: wake_ga2 = "R"; 6'd25: wake_ga2 = "e"; 6'd26: wake_ga2 = "v";
        6'd27: wake_ga2 = "e"; 6'd28: wake_ga2 = "n"; 6'd29: wake_ga2 = "g";
        6'd30: wake_ga2 = "e"; 6'd31: wake_ga2 = " "; 6'd32: wake_ga2 = "o";
        6'd33: wake_ga2 = "f"; 6'd34: wake_ga2 = " "; 6'd35: wake_ga2 = "D";
        6'd36: wake_ga2 = "e"; 6'd37: wake_ga2 = "a"; 6'd38: wake_ga2 = "t";
        6'd39: wake_ga2 = "h"; 6'd40: wake_ga2 = "-"; 6'd41: wake_ga2 = "A";
        6'd42: wake_ga2 = "d"; 6'd43: wake_ga2 = "d"; 6'd44: wake_ga2 = "e";
        6'd45: wake_ga2 = "r"; 6'd46: wake_ga2 = "!"; 6'd47: wake_ga2 = " ";
        default: wake_ga2 = " ";
    endcase
endfunction
function automatic [7:0] wake_arf(input [5:0] i);
    case (i)
        6'd0: wake_arf = "w"; 6'd1: wake_arf = "a"; 6'd2: wake_arf = "k";
        6'd3: wake_arf = "e"; 6'd4: wake_arf = " "; 6'd5: wake_arf = "u";
        6'd6: wake_arf = "p"; 6'd7: wake_arf = "!"; 6'd8: wake_arf = " ";
        6'd9: wake_arf = "A"; 6'd10: wake_arf = "R"; 6'd11: wake_arf = "F";
        6'd12: wake_arf = "!";
        default: wake_arf = " ";
    endcase
endfunction

// ga2 sprite-expansion result table (MAME prot[16])
function automatic [7:0] ga2_prot(input [3:0] i);
    case (i)
        4'd0:  ga2_prot = 8'h0a; 4'd2:  ga2_prot = 8'hc5;
        4'd4:  ga2_prot = 8'h11; 4'd6:  ga2_prot = 8'h11;
        4'd8:  ga2_prot = 8'h18; 4'd10: ga2_prot = 8'h18;
        4'd12: ga2_prot = 8'h1f; 4'd14: ga2_prot = 8'hc6;
        default: ga2_prot = 8'h00;
    endcase
endfunction

// Capture the address on the same edge as the RAM read.  The wrapper q and
// this selector then become visible together, preserving the original single
// synchronous-read cycle without adding a second output register.
reg [11:1] rd_addr;
reg        rd_table_sel;
always @(posedge clk) begin
    if (enable && cs) begin
        rd_addr      <= addr;
        rd_table_sel <= table_sel;
    end
end

// Window layout proven from the ga2 V60 boot code (loop at 0x1009ce):
// the game polls byte 0xA00100 for 'w' then string-compares 0x30 bytes
// against its ROM copy at 0x1009FF, so the wakeup string is byte window
// 0x100-0x15F (word index 0x80-0xAF); the sprite-expansion results table is
// byte window 0x000-0x01F.  rd_addr retains the input's [11:1] naming, so
// rd_addr[6:1] is the six-bit character offset.
assign rdata = (rd_addr >= 11'h80 && rd_addr < 11'hB0)
             ? (rd_table_sel ? wake_arf(rd_addr[6:1])
                             : wake_ga2(rd_addr[6:1]))
             : (!rd_table_sel && rd_addr < 11'h10)
             ? ga2_prot(rd_addr[4:1])
             : dpram_q;

endmodule

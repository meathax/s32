
//============================================================================
//  System 32 protection hardware retained by the production profile.
//============================================================================

import s32_pkg::*;

module s32_prot_darkedge #(
    parameter ENABLE = 1'b1
) (
    input             clk,
    input             rst,
    input             enable,
    input             vblank,
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input      [15:0] wram_rdata,
    input             wram_ack
);

typedef enum logic [2:0] { DKE_IDLE, DKE_W0, DKE_R0, DKE_W1, DKE_W2 } dke_state_t;
dke_state_t state;
reg [7:0] tmp;

always @(posedge clk) begin
    if (rst || !ENABLE || !enable) begin
        state      <= DKE_IDLE;
        wram_req   <= 1'b0;
        wram_we    <= 1'b0;
        wram_addr  <= 16'h0000;
        wram_wdata <= 16'h0000;
        wram_be    <= 2'b00;
        tmp        <= 8'h00;
    end
    else begin
        case (state)
        DKE_IDLE: begin
            wram_req <= 1'b0;
            if (vblank) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hF072 >> 1;
                wram_wdata <= 16'h0000;
                wram_be    <= 2'b11;
                state      <= DKE_W0;
            end
        end
        DKE_W0: if (wram_ack) begin
            wram_req   <= 1'b1;
            wram_we    <= 1'b1;
            wram_addr  <= 16'hF082 >> 1;
            wram_wdata <= 16'h0000;
            wram_be    <= 2'b11;
            state      <= DKE_R0;
        end
        DKE_R0: if (wram_ack) begin
            wram_req  <= 1'b1;
            wram_we   <= 1'b0;
            wram_addr <= 16'hA12C >> 1;
            state     <= DKE_W1;
        end
        DKE_W1: if (wram_ack) begin
            tmp <= wram_rdata[7:0];
            if (wram_rdata[7:0] != 0) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hA12C >> 1;
                wram_wdata <= {8'h00, wram_rdata[7:0] - 8'h01};
                wram_be    <= 2'b01;
                state      <= DKE_W2;
            end
            else begin
                wram_req <= 1'b0;
                state    <= DKE_IDLE;
            end
        end
        DKE_W2: if (wram_ack) begin
            if (tmp == 8'h01) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hA12E >> 1;
                wram_wdata <= 16'h0001;
                wram_be    <= 2'b01;
            end
            else begin
                wram_req <= 1'b0;
            end
            state <= DKE_IDLE;
        end
        default: begin
            wram_req <= 1'b0;
            state    <= DKE_IDLE;
        end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
// Burning Rival ROM-string protection copy (MAME init_brival).
// ---------------------------------------------------------------------------
module s32_prot_brival (
    input             clk,
    input             rst,
    input             enable,

    input             cpu_wr,
    input      [23:0] cpu_addr,
    input      [15:0] cpu_wdata,

    // Read trap: the MAME handler is installed for word reads at 0x20BA00-07.
    input             cpu_rd,
    input       [1:0] cpu_be,
    output reg        trap_active,
    output reg [15:0] trap_data,

    // Protection RAM bytes are overlaid onto the work-RAM second port.
    output reg        pram_we,
    output reg  [7:0] pram_addr,
    output reg  [7:0] pram_wdata,

    // Main-ROM read client.
    output reg        rom_req,
    output reg [23:0] rom_addr,
    input      [15:0] rom_data,
    input             rom_ack
);

function automatic [23:0] slot_rom(input [2:0] s);
    case (s)
        3'd0: slot_rom = 24'h109517;
        3'd5: slot_rom = 24'h109617;
        default: slot_rom = 24'h109597;
    endcase
endfunction

reg [2:0] slot;
reg [3:0] cnt;
typedef enum logic [2:0] { B_IDLE, B_RD, B_GAP, B_WR } brival_state_t;
brival_state_t state;

always @(posedge clk) begin
    if (rst) begin
        state       <= B_IDLE;
        rom_req     <= 1'b0;
        pram_we     <= 1'b0;
        trap_active <= 1'b0;
        trap_data   <= 16'h0000;
    end
    else begin
        pram_we <= 1'b0;
        // Byte reads fall through to work RAM; only full-word accesses are
        // handled by the protection device.
        trap_active <= enable && cpu_rd && (cpu_be == 2'b11) &&
                       (cpu_addr[23:4] == 20'h20BA0) &&
                       (cpu_addr[3:1] == 3'd0 ||
                        cpu_addr[3:1] == 3'd2 ||
                        cpu_addr[3:1] == 3'd3);
        trap_data <= 16'h0000;

        case (state)
        B_IDLE: begin
            rom_req <= 1'b0;
            if (enable && cpu_wr && cpu_addr[23:12] == 12'hA00 &&
                cpu_addr[11:4] == 8'h80 && cpu_addr[3:1] <= 3'd5) begin
                slot     <= cpu_addr[3:1];
                cnt      <= 4'd0;
                rom_req  <= 1'b1;
                rom_addr <= slot_rom(cpu_addr[3:1]);
                state    <= B_RD;
            end
        end
        B_RD: if (rom_ack) begin
            rom_req    <= 1'b0;
            pram_we    <= 1'b1;
            pram_addr  <= {slot, 4'b0} + {3'b0, cnt};
            // The cache returns a word containing the requested byte.  The
            // odd source address selects its upper lane.
            pram_wdata <= rom_addr[0] ? rom_data[15:8] : rom_data[7:0];
            if (cnt == 4'd15) begin
                state <= B_IDLE;
            end
            else begin
                cnt   <= cnt + 1'b1;
                state <= B_GAP;
            end
        end
        B_GAP: begin
            // The ROM client is edge-triggered.  Keep one complete low cycle
            // between consecutive byte requests.
            rom_req  <= 1'b1;
            rom_addr <= slot_rom(slot) + {19'b0, cnt};
            state    <= B_RD;
        end
        default: begin
            state   <= B_IDLE;
            rom_req <= 1'b0;
        end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
// The J.League 1994 protection write handler.
//
// MAME's init_jleague installs a write16 handler at 0x20f700-0x20f705:
// offset 0 indexes the main-ROM table at 0x07bbc0 and publishes its low byte
// at work RAM 0x20f708; offset 2 (0x20f704) publishes the selected team byte at
// 0x200016.  svf/svfo/svs do not install this handler and therefore never
// enable this responder.
// ---------------------------------------------------------------------------
module s32_prot_jleague #(
    parameter ENABLE = 1'b1
) (
    input             clk,
    input             rst,
    input             enable,
    input             cpu_write,
    input      [23:0] cpu_addr,
    input      [15:0] cpu_wdata,
    output reg        rom_req,
    output reg  [20:0] rom_addr,
    input      [15:0] rom_data,
    input             rom_ack,
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input             wram_ack
);

typedef enum logic [1:0] { JL_IDLE, JL_ROM, JL_WR } jl_state_t;
jl_state_t state;

always @(posedge clk) begin
    if (rst || !ENABLE || !enable) begin
        state      <= JL_IDLE;
        rom_req    <= 1'b0;
        rom_addr   <= 21'h000000;
        wram_req   <= 1'b0;
        wram_we    <= 1'b0;
        wram_addr  <= 16'h0000;
        wram_wdata <= 16'h0000;
        wram_be    <= 2'b00;
    end
    else begin
        case (state)
        JL_IDLE: begin
            rom_req  <= 1'b0;
            wram_req <= 1'b0;
            if (cpu_write && cpu_addr == 24'h20f700) begin
                // 0x07bbc0 + data * 2, the same word-aligned main-ROM read
                // used by segas32_state::jleague_protection_w.
                rom_addr <= 21'h07bbc0 + {4'd0, cpu_wdata, 1'b0};
                rom_req  <= 1'b1;
                state    <= JL_ROM;
            end
            else if (cpu_write && cpu_addr == 24'h20f704) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'h0016 >> 1;
                wram_wdata <= {8'h00, cpu_wdata[7:0]};
                wram_be    <= 2'b01;
                state      <= JL_WR;
            end
        end
        JL_ROM: begin
            if (rom_ack) begin
                rom_req    <= 1'b0;
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hf708 >> 1;
                wram_wdata <= {8'h00, rom_data[7:0]};
                wram_be    <= 2'b01;
                state      <= JL_WR;
            end
        end
        JL_WR: begin
            if (wram_ack) begin
                wram_req <= 1'b0;
                state    <= JL_IDLE;
            end
        end
        default: begin
            state    <= JL_IDLE;
            rom_req  <= 1'b0;
            wram_req <= 1'b0;
        end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
// SegaSonic final level-load protection HLE.
//
// The final set writes the cleared-level index at 0x20e5c4. MAME's handler
// selects the corresponding stage ID from the ROM table and publishes it at
// work RAM 0x20f06e, then clears the two status words at 0x20f0bc/0x20f0be.
// The table values are the final-game order documented by the debug analysis.
// Keep this responder profile-gated: the prototype does not install it.
// ---------------------------------------------------------------------------
module s32_prot_sonic #(
    parameter ENABLE = 1'b1
) (
    input             clk,
    input             rst,
    input             enable,
    input             cpu_write,
    input      [23:0] cpu_addr,
    input       [7:0] cpu_wdata,
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input             wram_ack
);

typedef enum logic [1:0] { SONIC_IDLE, SONIC_LEVEL, SONIC_STATUS0, SONIC_STATUS1 } sonic_state_t;
sonic_state_t state;

function automatic [15:0] sonic_level(input [15:0] cleared);
    case (cleared)
        16'd0:  sonic_level = 16'h0007;
        16'd1:  sonic_level = 16'h0007;
        16'd2:  sonic_level = 16'h0006;
        16'd3:  sonic_level = 16'h0005;
        16'd4:  sonic_level = 16'h0008;
        16'd5:  sonic_level = 16'h0009;
        16'd6:  sonic_level = 16'h000a;
        16'd7:  sonic_level = 16'h0003;
        16'd8:  sonic_level = 16'h0004;
        16'd9:  sonic_level = 16'h0010;
        16'd10: sonic_level = 16'h000c;
        16'd11: sonic_level = 16'h000d;
        16'd12: sonic_level = 16'h000e;
        16'd13: sonic_level = 16'h000f;
        16'd14: sonic_level = 16'h000b;
        16'd15: sonic_level = 16'h0011;
        16'd16: sonic_level = 16'h000a;
        16'd17: sonic_level = 16'h000a;
        default: sonic_level = 16'h000a;
    endcase
endfunction

always @(posedge clk) begin
    if (rst || !ENABLE || !enable) begin
        state      <= SONIC_IDLE;
        wram_req   <= 1'b0;
        wram_we    <= 1'b0;
        wram_addr  <= 16'h0000;
        wram_wdata <= 16'h0000;
        wram_be    <= 2'b00;
    end
    else begin
        wram_req <= 1'b0;
        wram_we  <= 1'b0;
        case (state)
            SONIC_IDLE: begin
                if (cpu_write && cpu_addr == 24'h20e5c4) begin
                    wram_req   <= 1'b1;
                    wram_we    <= 1'b1;
                    wram_addr  <= 16'hf06e >> 1;
                    wram_wdata <= sonic_level({8'h00, cpu_wdata});
                    wram_be    <= 2'b11;
                    state      <= SONIC_LEVEL;
                end
            end
            SONIC_LEVEL: begin
                if (wram_ack) begin
                    wram_req   <= 1'b1;
                    wram_we    <= 1'b1;
                    wram_addr  <= 16'hf0bc >> 1;
                    wram_wdata <= 16'h0000;
                    wram_be    <= 2'b11;
                    state      <= SONIC_STATUS0;
                end
            end
            SONIC_STATUS0: begin
                if (wram_ack) begin
                    wram_req   <= 1'b1;
                    wram_we    <= 1'b1;
                    wram_addr  <= 16'hf0be >> 1;
                    wram_wdata <= 16'h0000;
                    wram_be    <= 2'b11;
                    state      <= SONIC_STATUS1;
                end
            end
            SONIC_STATUS1: begin
                if (wram_ack)
                    state <= SONIC_IDLE;
            end
            default: state <= SONIC_IDLE;
        endcase
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
s32_byte_spram #(.ADDR_WIDTH(11), .NUM_WORDS(2048), .POWER_UP_UNINITIALIZED("FALSE")) dpram_mem ( // audit R20 PF-8: deterministic zero power-up
    .clock(clk),
    .address_a(addr), .data_a(wdata), .rden_a(enable && cs),
    .wren_a(enable && cs && we), .q_a(dpram_q)
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

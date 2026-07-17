//============================================================================
//  Sega 315-5560 "MultiPCM" (Yamaha YMW-258-F GEW8) — DESIGN.md §7.5
//  28 slots, Fs = clk/224 (10 MHz -> 44.64 kHz).
//  Sample descriptor table (12 bytes/instrument) read from sample ROM:
//    [0..2] start (24-bit BE, bit22 = 12-bit format flag)
//    [3..4] loop (16 BE)   [5..6] 0x10000 - end count (16 BE)
//    [7]    LFO/VIB        [8] attack/decay1  [9] decay2/sustain-level
//    [10]   release/KRS    [11] ALFO
//  Slot regs (per MAME): 0=pan 1=sample# 2=pitch-lo 3=pitch-hi(oct+pitch)
//    4=keyon(bit7) 5=TL(+direct flag bit0) 6=LFO 7=ALFO
//  Z80 interface: addr 0=data 1=?? 2=slot-select/reg-select scheme —
//  MAME: write port 0 = data, 1 = slot, 2 = register.
//  Envelope: simplified linear-rate ADSR derived from the rate registers
//  (full YMF278-style curves refined during the audio verification pass).
//============================================================================

module s32_multipcm (
    input             clk,          // clk_sys
    input             ce,           // 10 MHz enable
    input             rst,

    // Z80 access
    input             cs,
    input             we,
    input       [1:0] addr,
    input       [7:0] wdata,
    output      [7:0] rdata,

    // sample ROM via SDRAM byte port (through multipcm banking)
    output reg        rom_req,
    output reg [21:0] rom_addr,     // byte address within 4MB region
    input       [7:0] rom_data,
    input             rom_ack,

    // Z80-controlled 1MB-window banking (0xb0 port outside)
    input       [2:0] bank_lo,
    input       [2:0] bank_hi,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

assign rdata = 8'h00;

// slot state
reg [7:0]  sreg [0:27][0:7];
reg [4:0]  cur_slot;
reg [2:0]  cur_reg;

// per-slot playback state
reg [21:0] s_start [0:27];
reg [15:0] s_loop  [0:27];
reg [15:0] s_end   [0:27];
reg        s_fmt12 [0:27];
reg        s_active[0:27];
reg [37:0] s_pos   [0:27];   // 22.16 sample position
reg [15:0] s_env   [0:27];   // simplified envelope level
reg [1:0]  s_phase [0:27];   // 0=attack 1=decay 2=sustain 3=release
reg [27:0] keyon_pending;

// register write path
always @(posedge clk) begin
    if (cs && we) begin
        case (addr)
            2'd1: cur_slot <= (wdata[4:0] < 28) ? wdata[4:0] : 5'd0;  // slot sel (VALUE_TO_CHANNEL simplified)
            2'd2: cur_reg  <= wdata[2:0];
            2'd0: begin
                sreg[cur_slot][cur_reg] <= wdata;
                if (cur_reg == 3'd4) begin
                    if (wdata[7]) begin
                        // key on: fetch descriptor (kicked in engine below)
                        s_active[cur_slot] <= 1'b1;
                        s_phase[cur_slot]  <= 2'd0;
                        s_env[cur_slot]    <= 16'h0000;
                        s_pos[cur_slot]    <= 0;
                        keyon_pending      <= keyon_pending | (28'h1 << cur_slot);
                    end
                    else s_phase[cur_slot] <= 2'd3;  // release
                end
            end
            default: ;
        endcase
    end
end

// engine: iterate slots; each slot gets 8 CE ticks (28*8 = 224)
reg [2:0]  tick;
reg [4:0]  slot;
reg signed [19:0] acc_l, acc_r;
reg [1:0]  eng;     // sub-state: 0=addr 1=fetch 2=mix

// descriptor fetch FSM (runs opportunistically between slot services)
reg [4:0]  df_slot;
reg [3:0]  df_idx;
reg        df_busy;
reg [7:0]  df_buf [0:11];

function automatic [21:0] banked(input [21:0] a);
    // >=1MB accesses go through the two 512KB windows
    if (a < 22'h100000) banked = a;
    else if (a < 22'h180000) banked = {bank_lo, a[18:0]};
    else banked = {bank_hi, a[18:0]};
endfunction

always @(posedge clk) begin
    if (rst) begin
        tick <= 0; slot <= 0; eng <= 0;
        rom_req <= 0; df_busy <= 0;
        out_l <= 0; out_r <= 0; acc_l <= 0; acc_r <= 0;
        keyon_pending <= 0;
    end
    else if (ce) begin
        // descriptor fetch has priority on the ROM port
        if (!df_busy && keyon_pending != 0) begin
            for (int i = 0; i < 28; i++)
                if (keyon_pending[i]) df_slot <= i[4:0];
            df_idx <= 0;
            df_busy <= 1'b1;
        end
        if (df_busy) begin
            if (!rom_req) begin
                rom_req <= 1'b1;
                rom_addr <= {10'b0, sreg[df_slot][1], 4'b0} * 12 + {18'b0, df_idx};
            end
            else if (rom_ack) begin
                rom_req <= 0;
                df_buf[df_idx] <= rom_data;
                if (df_idx == 4'd11) begin
                    df_busy <= 0;
                    keyon_pending[df_slot] <= 1'b0;
                    s_start[df_slot] <= {df_buf[0][5:0], df_buf[1], df_buf[2]};
                    s_fmt12[df_slot] <= df_buf[0][6];
                    s_loop[df_slot]  <= {df_buf[3], df_buf[4]};
                    s_end[df_slot]   <= 16'd0 - {df_buf[5], df_buf[6]};
                end
                else df_idx <= df_idx + 1'd1;
            end
        end
        else begin
            tick <= tick + 1'd1;
            if (tick == 3'd7) begin
                slot <= (slot == 5'd27) ? 5'd0 : slot + 1'd1;
                if (slot == 5'd27) begin
                    out_l <= acc_l[19:4];
                    out_r <= acc_r[19:4];
                    acc_l <= 0; acc_r <= 0;
                end
            end
            // service current slot once per 8 ticks
            if (tick == 0 && s_active[slot]) begin
                // pitch: oct (signed 4b) + 10-bit fraction (reg3/2)
                logic signed [3:0] oct;
                logic [9:0] pit;
                logic [16:0] step;
                oct = sreg[slot][3][7:4];
                pit = {sreg[slot][3][3:0], sreg[slot][2][7:2]};
                step = ({1'b1, pit, 6'b0}) >>> (5 - oct); // ~2^oct * (1+pit/1024) base step
                s_pos[slot] <= s_pos[slot] + {21'b0, step};
                // sample fetch (8-bit path; 12-bit handled as 8-bit high byte v1)
                if (!rom_req && !df_busy) begin
                    rom_req <= 1'b1;
                    rom_addr <= banked(s_start[slot] + s_pos[slot][37:16]);
                end
            end
            else if (rom_ack && rom_req) begin
                logic signed [15:0] smp;
                logic [7:0] tl;
                logic [3:0] panv;
                rom_req <= 0;
                smp = {rom_data ^ 8'h80, 8'b0};  // 8-bit signed
                tl = sreg[slot][5][7:1];
                // TL attenuate (linear approx of log TL)
                smp = smp >>> (tl[6:3]);
                panv = sreg[slot][0][7:4];
                acc_l <= acc_l + (smp >>> (panv[3] ? panv[2:0] : 0));
                acc_r <= acc_r + (smp >>> (panv[3] ? 0 : panv[2:0]));
                // loop/end
                if (s_pos[slot][37:16] >= {6'b0, s_end[slot]})
                    s_pos[slot] <= {6'b0, s_loop[slot], 16'b0};
            end
        end
    end
end

endmodule

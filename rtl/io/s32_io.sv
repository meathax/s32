//============================================================================
//  System 32 I/O collection (DESIGN.md §8.7, Appendix D)
//    s32_io5296  — Sega 315-5296 8-port I/O
//    s32_eeprom93c46 — 93C46 16-bit serial EEPROM with NVRAM shadow
//    s32_msm6253 — 4-channel 8-bit ADC
//    s32_upd4701 — X/Y quadrature counter (trackballs)
//    s32_i8255   — PPI ports A/B/C (4/6-player)
//    s32_intc    — V60 interrupt controller + timers (§5.5)
//============================================================================

import s32_pkg::*;

// ---------------------------------------------------------------------------
module s32_io5296 (
    input             clk,
    input             rst,

    input             cs,
    input             we,
    input       [4:0] addr,        // reg = addr[4:1] (byte at even addresses)
    input       [7:0] wdata,
    output reg  [7:0] rdata,

    input       [7:0] in_pa, in_pb, in_pc, in_pe, in_pf,
    output reg  [7:0] out_pd, out_pg, out_ph,
    output reg        cnt0, cnt1, cnt2
);

// registers 0-7 = ports A-H, 8-B = 'S''E''G''A' signature, C/E = CNT,
// D/F = direction, 10-1F = unused (read 0xff).  Matches MAME 315_5296.cpp
// read()/write() in MAME's 315_5296 device.  System 32 wires
// A/B/C/E/F as inputs and D/G/H as outputs; the games program DIR to match, so
// the fixed port-direction hardcode below is equivalent to MAME's DIR-gated
// port 0-7 access for these boards (a documented-benign device-model divergence
// kept to avoid changing the proven boot behaviour of the output ports).
reg [7:0] dir;
reg [7:0] cnt_reg;   // full CNT byte for readback (cnt2/1/0 mirror the low bits)
always @(posedge clk) begin
    if (rst) begin
        out_pd <= 8'h00; out_pg <= 8'h00; out_ph <= 8'h00;
        {cnt2, cnt1, cnt0} <= 3'b000;
        cnt_reg <= 8'h00;   // MAME device_reset: m_cnt = 0
        dir     <= 8'h00;   // MAME device_reset: m_dir = 0
    end
    else if (cs && we) begin
        // register = full 5-bit index (A[5:1]); 315-5296 is byte-lane, 2-byte
        // spacing. Ports A-H = 0-7, CNT = 0xE, direction = 0xF (per MAME map).
        case (addr[4:0])
            5'h3: out_pd <= wdata;
            5'h6: out_pg <= wdata;
            5'h7: out_ph <= wdata;
            5'he: begin {cnt2, cnt1, cnt0} <= wdata[2:0]; cnt_reg <= wdata; end
            5'hf: dir <= wdata;
            default: ;
        endcase
    end
    case (addr[4:0])
        5'h0: rdata <= in_pa;
        5'h1: rdata <= in_pb;
        5'h2: rdata <= in_pc;
        5'h3: rdata <= out_pd;
        5'h4: rdata <= in_pe;
        5'h5: rdata <= in_pf;
        5'h6: rdata <= out_pg;
        5'h7: rdata <= out_ph;
        5'h8: rdata <= 8'h53;   // 'S'
        5'h9: rdata <= 8'h45;   // 'E'
        5'ha: rdata <= 8'h47;   // 'G'
        5'hb: rdata <= 8'h41;   // 'A'
        5'hc, 5'he: rdata <= cnt_reg;
        5'hd, 5'hf: rdata <= dir;
        default: rdata <= 8'hff;   // 0x10-0x1F: unused, read 0xff
    endcase
end

endmodule

// ---------------------------------------------------------------------------
// MiSTer index-3 NVRAM upload adapter. The MRA persists 128 bytes while the
// 93C46 is organized as 64 little-endian 16-bit words.
module s32_eeprom_nvram_if #(parameter WIDE=0) (
    input             ioctl_upload,
    input      [15:0] ioctl_index,
    input      [26:0] ioctl_addr,
    input      [15:0] eep_rd_data,
    output            eep_upload,
    output      [5:0] eep_rd_addr,
    output     [15:0] ioctl_din
);

assign eep_upload = ioctl_upload && (ioctl_index == 16'd3);
assign eep_rd_addr = ioctl_addr[6:1];
assign ioctl_din = WIDE
                 ? (eep_upload ? eep_rd_data : 16'h0000)
                 : {8'h00, (eep_upload
                     ? (ioctl_addr[0] ? eep_rd_data[15:8] : eep_rd_data[7:0])
                     : 8'h00)};

endmodule

// ---------------------------------------------------------------------------
// Compact dual-port storage for the serial EEPROM.  The owning EEPROM stores
// inverted data so the block RAM's zero-filled power-up state represents the
// 93C46 erased value (16'hffff) without a reset loop or initialization file.
module s32_eeprom_ram (
    input             clk,
    input       [5:0] address_a,
    input      [15:0] data_a,
    input             wren_a,
    output     [15:0] q_a,
    input       [5:0] address_b,
    output     [15:0] q_b
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clk),
    .address_a(address_a),
    .data_a(data_a),
    .wren_a(wren_a),
    .q_a(q_a),

    .clock1(clk),
    .address_b(address_b),
    .data_b(16'h0000),
    .wren_b(1'b0),
    .q_b(q_b),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a(1'b1),
    .byteena_b(1'b1),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = 64,
    ram.widthad_a = 6,
    ram.width_a = 16,
    ram.numwords_b = 64,
    ram.widthad_b = 6,
    ram.width_b = 16,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.indata_reg_b = "CLOCK1",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "BIDIR_DUAL_PORT",
    ram.outdata_aclr_a = "NONE",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    ram.ram_block_type = "M10K",
    ram.read_during_write_mode_mixed_ports = "OLD_DATA",
    ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    ram.width_byteena_a = 1,
    ram.width_byteena_b = 1,
    ram.wrcontrol_wraddress_reg_b = "CLOCK1";
`else
reg [15:0] mem [0:63];
reg [15:0] q_a_r;
reg [15:0] q_b_r;
assign q_a = q_a_r;
assign q_b = q_b_r;

integer __eep_init;
initial begin
    for (__eep_init = 0; __eep_init < 64; __eep_init = __eep_init + 1)
        mem[__eep_init] = 16'h0000;
end

always @(posedge clk) begin
    q_a_r <= mem[address_a];
    q_b_r <= mem[address_b];
    if (wren_a) mem[address_a] <= data_a;
end
`endif

endmodule

// ---------------------------------------------------------------------------
module s32_eeprom93c46 (
    input             clk,
    input             rst,

    input             di,          // data in (from io chip)
    input             cs,
    input             sk,          // clock
    output reg        dout,

    // NVRAM shadow load/save
    input             ld_wr,
    input       [5:0] ld_addr,
    input      [15:0] ld_data,
    output     [15:0] rd_data,
    input       [5:0] rd_addr,

    input             upload,
    output reg        modified = 1'b0
);

// 93C46, x16 organization: command frame = start(1) + opcode(2) + addr(6),
// i.e. 8 post-start bits. Opcodes: 10=READ, 01=WRITE(+16 data), 11=ERASE,
// 00 with addr[5:4]: 11=EWEN, 00=EWDS, 10=ERAL, 01=WRAL(+16 data).
// Behaviour mirrors MAME eepromser.cpp exactly (holo's boot depends on it):
//   - writes/erases execute immediately, then the device sits in a DONE
//     state that ignores every clock until CS falls (chained commands in
//     the same CS frame are dropped, as on the real self-timed part);
//   - DO idles high (tristate + pullup) in every state except the data
//     phase of a READ.
typedef enum logic [2:0] { E_IDLE, E_CMD, E_READ, E_WRDATA, E_DONE } est_t;
est_t es;
reg [6:0]  sr;
reg [3:0]  bitcnt;
reg [5:0]  eaddr;
reg [15:0] shifter;
reg        ewen;
reg        wr_all;
reg        sk_d;
reg        upload_d = 1'b0;
reg        serial_wr = 1'b0;
reg  [5:0] serial_wr_addr;
reg [15:0] serial_wr_data;
reg        bulk_active = 1'b0;
reg  [5:0] bulk_addr = 6'd0;
reg [15:0] bulk_data = 16'hFFFF;

wire        ram_wren = ld_wr || bulk_active || serial_wr;
wire  [5:0] ram_waddr = ld_wr       ? ld_addr :
                        bulk_active ? bulk_addr : serial_wr_addr;
wire [15:0] ram_wdata = ld_wr       ? ld_data :
                        bulk_active ? bulk_data : serial_wr_data;
wire  [5:0] ram_addr_a = ram_wren ? ram_waddr : eaddr;
wire [15:0] ram_q_a_phys;
wire [15:0] ram_q_b_phys;
wire [15:0] ram_q_a = ~ram_q_a_phys;
wire        serial_commit = serial_wr && !ld_wr && !bulk_active;
wire        bulk_final_commit = bulk_active && (bulk_addr == 6'd63) && !ld_wr;

assign rd_data = ~ram_q_b_phys;

s32_eeprom_ram storage (
    .clk(clk),
    .address_a(ram_addr_a), .data_a(~ram_wdata),
    .wren_a(ram_wren), .q_a(ram_q_a_phys),
    .address_b(rd_addr), .q_b(ram_q_b_phys)
);

always @(posedge clk) begin
    // Single-word serial writes are queued for the following core clock.
    // ERAL/WRAL are serialized over 64 clocks, far shorter than the real
    // EEPROM's self-timed busy interval and compatible with one RAM port.
    serial_wr <= 1'b0;
    if (ld_wr)
        bulk_active <= 1'b0;
    else if (bulk_active) begin
        if (bulk_addr == 6'd63) begin
            bulk_active <= 1'b0;
        end
        else
            bulk_addr <= bulk_addr + 1'd1;
    end

    sk_d <= sk;
    upload_d <= upload;
    if (rst) begin
        es <= E_IDLE; bitcnt <= 0; dout <= 1'b1;
        ewen <= 0; wr_all <= 0;
    end
    else if (!cs) begin
        // A self-timed WRAL/ERAL remains busy after CS drops.  Do not allow
        // a new frame to resynchronize in the middle of the 64-word sweep.
        es <= bulk_active ? E_DONE : E_IDLE;
        bitcnt <= 0; dout <= 1'b1;
    end
    else if (sk & ~sk_d) begin        // rising SK
        case (es)
        E_IDLE: if (di && !bulk_active) begin // start bit (ignore while busy)
            es <= E_CMD; sr <= 0; bitcnt <= 0;
        end
        E_CMD: begin
            sr <= {sr[5:0], di};
            bitcnt <= bitcnt + 1'd1;
            if (bitcnt == 4'd7) begin  // 8th post-start bit completes cmd
                logic [7:0] cmd;
                cmd = {sr[6:0], di};
                eaddr  <= cmd[5:0];
                wr_all <= 1'b0;
                case (cmd[7:6])
                    2'b10: begin       // READ: dummy 0 then MSB-first
                        es <= E_READ;
                        bitcnt <= 0; dout <= 1'b0;
                    end
                    2'b01: begin es <= E_WRDATA; bitcnt <= 0; end
                    2'b11: begin       // ERASE (immediate, then wait for CS)
                        if (ewen) begin
                            serial_wr_addr <= cmd[5:0];
                            serial_wr_data <= 16'hFFFF;
                            serial_wr <= 1'b1;
                        end
                        es <= E_DONE;
                    end
                    2'b00: begin
                        case (cmd[5:4])
                            2'b11: begin ewen <= 1'b1; es <= E_IDLE; end  // EWEN
                            2'b00: begin ewen <= 1'b0; es <= E_IDLE; end  // EWDS
                            2'b10: begin                                  // ERAL
                                if (ewen) begin
                                    bulk_active <= 1'b1;
                                    bulk_addr <= 6'd0;
                                    bulk_data <= 16'hFFFF;
                                end
                                es <= E_DONE;
                            end
                            2'b01: begin es <= E_WRDATA; bitcnt <= 0; wr_all <= 1'b1; end
                            default: es <= E_IDLE;
                        endcase
                    end
                endcase
            end
        end
        E_READ: begin
            if (bitcnt == 4'd0) begin
                dout <= ram_q_a[15];
                shifter <= {ram_q_a[14:0], 1'b0};
            end
            else begin
                dout <= shifter[15];
                shifter <= {shifter[14:0], 1'b0};
            end
            bitcnt <= bitcnt + 1'd1;
            if (bitcnt == 4'd15) begin
                es <= E_DONE;        // further clocks ignored until CS falls
                // (dout returns high once the final bit has been clocked)
            end
        end
        E_WRDATA: begin
            shifter <= {shifter[14:0], di};
            bitcnt <= bitcnt + 1'd1;
            if (bitcnt == 4'd15) begin
                if (ewen) begin
                    if (wr_all) begin
                        bulk_active <= 1'b1;
                        bulk_addr <= 6'd0;
                        bulk_data <= {shifter[14:0], di};
                    end
                    else begin
                        serial_wr_addr <= eaddr;
                        serial_wr_data <= {shifter[14:0], di};
                        serial_wr <= 1'b1;
                    end
                end
                es <= E_DONE;
                dout <= 1'b1;        // pullup: not in the read-data state
            end
        end
        E_DONE: ;                    // MAME WAIT_FOR_COMPLETION: CS ends it
        default: es <= E_IDLE;
        endcase
    end

    // Loading a factory/persisted image establishes a clean baseline. An
    // upload start acknowledges the current dirty generation. Deliberately
    // do not clear on rst: soft reset must not lose an unsaved EEPROM change.
    if (ld_wr)
        modified <= 1'b0;
    else if (serial_commit || bulk_final_commit)
        modified <= 1'b1;
    else if (upload && !upload_d)
        modified <= 1'b0;
end

endmodule

// ---------------------------------------------------------------------------
// Low-resource analog-stick conditioner for Alien 3: The Gun. MiSTer supplies
// signed two's-complement axes around zero;
// the System 32 ADC expects offset-binary channels around 8'h80.
//
// The response is radial so diagonal motion retains its direction:
//   * radius <= 6/128 is an inner deadzone (about 5%);
//   * radius >= 122/128 reaches the gun endpoint (about 5% outer saturation,
//     so the extreme of aim needs roughly 95% physical stick travel), and that
//     endpoint is 120/128 of the ADC span so the sight stops at the screen
//     border instead of tracking past it;
//   * the live band uses a 62.5% linear / 37.5% quadratic response, giving
//     precise small corrections without making large sweeps sluggish.
//
// Alien 3's four ADC ports are defined with 50% sensitivity.  The positional
// cabinet guns therefore occupy only +/-64 codes around 8'h80.  Feeding the
// full 0x00..0xff span makes the game hit a screen edge at half stick travel.
//
// One sequential restoring divider is shared by both axes and players. At the
// normal 2^16 clock sampling interval the complete calculation occupies far
// below 0.2% of the available cycles and avoids the duplicated variable-divide
// cones from the archived radial experiment.
module s32_gun_aim #(
    parameter integer TICK_BITS = 16
) (
    input              clk,
    input              rst,
    input              enable,
    input       [7:0]  p1_raw_x,
    input       [7:0]  p1_raw_y,
    input       [7:0]  p2_raw_x,
    input       [7:0]  p2_raw_y,
    input              invert_x,
    input              invert_y,
    output reg  [7:0]  p1_aim_x,
    output reg  [7:0]  p1_aim_y,
    output reg  [7:0]  p2_aim_x,
    output reg  [7:0]  p2_aim_y
);

localparam [8:0] GUN_INNER_R  = 9'd6;
localparam [8:0] GUN_OUTER_R  = 9'd122;
// Full stick deflection stops slightly short of the ADC end codes.  At the
// hardware limit the game's sight tracked past the visible border and vanished
// off screen, so the endpoint is pulled in to 0x08..0xf8.
localparam [7:0] GUN_PEAK_MAG = 8'd120;

// Precomputed curve magnitude for radii strictly between the two deadzones.
// Values are round(GUN_PEAK_MAG * (0.625*t + 0.375*t*t)), t=(r-6)/(122-6).
// The table is read by one shared processing state, so it synthesizes once.
function automatic [7:0] gun_curve_mag(input [8:0] radius);
begin
    if (radius <= GUN_INNER_R)
        gun_curve_mag = 8'd0;
    else if (radius >= GUN_OUTER_R)
        gun_curve_mag = GUN_PEAK_MAG;
    else begin
        case (radius)
            9'd7, 9'd8: gun_curve_mag = 8'd1;
            9'd9: gun_curve_mag = 8'd2;
            9'd10, 9'd11: gun_curve_mag = 8'd3;
            9'd12: gun_curve_mag = 8'd4;
            9'd13, 9'd14: gun_curve_mag = 8'd5;
            9'd15: gun_curve_mag = 8'd6;
            9'd16: gun_curve_mag = 8'd7;
            9'd17, 9'd18: gun_curve_mag = 8'd8;
            9'd19: gun_curve_mag = 8'd9;
            9'd20, 9'd21: gun_curve_mag = 8'd10;
            9'd22: gun_curve_mag = 8'd11;
            9'd23: gun_curve_mag = 8'd12;
            9'd24, 9'd25: gun_curve_mag = 8'd13;
            9'd26: gun_curve_mag = 8'd14;
            9'd27: gun_curve_mag = 8'd15;
            9'd28: gun_curve_mag = 8'd16;
            9'd29, 9'd30: gun_curve_mag = 8'd17;
            9'd31: gun_curve_mag = 8'd18;
            9'd32: gun_curve_mag = 8'd19;
            9'd33: gun_curve_mag = 8'd20;
            9'd34: gun_curve_mag = 8'd21;
            9'd35, 9'd36: gun_curve_mag = 8'd22;
            9'd37: gun_curve_mag = 8'd23;
            9'd38: gun_curve_mag = 8'd24;
            9'd39: gun_curve_mag = 8'd25;
            9'd40: gun_curve_mag = 8'd26;
            9'd41: gun_curve_mag = 8'd27;
            9'd42: gun_curve_mag = 8'd28;
            9'd43, 9'd44: gun_curve_mag = 8'd29;
            9'd45: gun_curve_mag = 8'd30;
            9'd46: gun_curve_mag = 8'd31;
            9'd47: gun_curve_mag = 8'd32;
            9'd48: gun_curve_mag = 8'd33;
            9'd49: gun_curve_mag = 8'd34;
            9'd50: gun_curve_mag = 8'd35;
            9'd51: gun_curve_mag = 8'd36;
            9'd52: gun_curve_mag = 8'd37;
            9'd53: gun_curve_mag = 8'd38;
            9'd54: gun_curve_mag = 8'd39;
            9'd55: gun_curve_mag = 8'd40;
            9'd56: gun_curve_mag = 8'd41;
            9'd57: gun_curve_mag = 8'd42;
            9'd58: gun_curve_mag = 8'd43;
            9'd59: gun_curve_mag = 8'd44;
            9'd60: gun_curve_mag = 8'd45;
            9'd61: gun_curve_mag = 8'd46;
            9'd62: gun_curve_mag = 8'd47;
            9'd63: gun_curve_mag = 8'd48;
            9'd64: gun_curve_mag = 8'd49;
            9'd65: gun_curve_mag = 8'd50;
            9'd66: gun_curve_mag = 8'd51;
            9'd67: gun_curve_mag = 8'd52;
            9'd68: gun_curve_mag = 8'd53;
            9'd69: gun_curve_mag = 8'd54;
            9'd70: gun_curve_mag = 8'd55;
            9'd71: gun_curve_mag = 8'd56;
            9'd72: gun_curve_mag = 8'd57;
            9'd73: gun_curve_mag = 8'd58;
            9'd74: gun_curve_mag = 8'd59;
            9'd75: gun_curve_mag = 8'd61;
            9'd76: gun_curve_mag = 8'd62;
            9'd77: gun_curve_mag = 8'd63;
            9'd78: gun_curve_mag = 8'd64;
            9'd79: gun_curve_mag = 8'd65;
            9'd80: gun_curve_mag = 8'd66;
            9'd81: gun_curve_mag = 8'd67;
            9'd82: gun_curve_mag = 8'd68;
            9'd83: gun_curve_mag = 8'd70;
            9'd84: gun_curve_mag = 8'd71;
            9'd85: gun_curve_mag = 8'd72;
            9'd86: gun_curve_mag = 8'd73;
            9'd87: gun_curve_mag = 8'd74;
            9'd88: gun_curve_mag = 8'd76;
            9'd89: gun_curve_mag = 8'd77;
            9'd90: gun_curve_mag = 8'd78;
            9'd91: gun_curve_mag = 8'd79;
            9'd92: gun_curve_mag = 8'd80;
            9'd93: gun_curve_mag = 8'd82;
            9'd94: gun_curve_mag = 8'd83;
            9'd95: gun_curve_mag = 8'd84;
            9'd96: gun_curve_mag = 8'd85;
            9'd97: gun_curve_mag = 8'd87;
            9'd98: gun_curve_mag = 8'd88;
            9'd99: gun_curve_mag = 8'd89;
            9'd100: gun_curve_mag = 8'd90;
            9'd101: gun_curve_mag = 8'd92;
            9'd102: gun_curve_mag = 8'd93;
            9'd103: gun_curve_mag = 8'd94;
            9'd104: gun_curve_mag = 8'd95;
            9'd105: gun_curve_mag = 8'd97;
            9'd106: gun_curve_mag = 8'd98;
            9'd107: gun_curve_mag = 8'd99;
            9'd108: gun_curve_mag = 8'd101;
            9'd109: gun_curve_mag = 8'd102;
            9'd110: gun_curve_mag = 8'd103;
            9'd111: gun_curve_mag = 8'd105;
            9'd112: gun_curve_mag = 8'd106;
            9'd113: gun_curve_mag = 8'd107;
            9'd114: gun_curve_mag = 8'd109;
            9'd115: gun_curve_mag = 8'd110;
            9'd116: gun_curve_mag = 8'd112;
            9'd117: gun_curve_mag = 8'd113;
            9'd118: gun_curve_mag = 8'd114;
            9'd119: gun_curve_mag = 8'd116;
            9'd120: gun_curve_mag = 8'd117;
            9'd121: gun_curve_mag = 8'd119;
            default: gun_curve_mag = 8'd0;
        endcase
    end
end
endfunction

function automatic [7:0] gun_offset_axis(
    input negative,
    input [7:0] magnitude
);
begin
    if (negative)
        gun_offset_axis = (magnitude >= GUN_PEAK_MAG)
                        ? (8'd128 - GUN_PEAK_MAG) : (8'd128 - magnitude);
    else
        gun_offset_axis = (magnitude >= GUN_PEAK_MAG)
                        ? (8'd128 + GUN_PEAK_MAG) : (8'd128 + magnitude);
end
endfunction

// Error-sensitive smoothing: large moves consume half the error per update;
// fine motion consumes a rounded quarter; the last three codes snap exactly.
function automatic [7:0] gun_filter(input [7:0] current, input [7:0] target);
    logic signed [9:0] err;
    logic signed [9:0] step;
    logic signed [10:0] next_value;
begin
    err = $signed({2'b00, target}) - $signed({2'b00, current});
    if (err >= -3 && err <= 3)
        gun_filter = target;
    else begin
        if (err >= 16)
            step = (err + 10'sd1) >>> 1;
        else if (err <= -16)
            step = -(((-err) + 10'sd1) >>> 1);
        else if (err > 0)
            step = (err + 10'sd3) >>> 2;
        else
            step = -(((-err) + 10'sd3) >>> 2);
        next_value = $signed({3'b000, current}) + step;
        if (next_value < 0)
            gun_filter = 8'h00;
        else if (next_value > 11'sd255)
            gun_filter = 8'hff;
        else
            gun_filter = next_value[7:0];
    end
end
endfunction

reg [TICK_BITS-1:0] tick_div;
reg signed [8:0] sample_x0, sample_y0, sample_x1, sample_y1;
reg player;

wire signed [8:0] selected_x = player ? sample_x1 : sample_x0;
wire signed [8:0] selected_y = player ? sample_y1 : sample_y0;
wire [8:0] selected_abs_x = selected_x[8] ? (~selected_x + 1'b1) : selected_x;
wire [8:0] selected_abs_y = selected_y[8] ? (~selected_y + 1'b1) : selected_y;
wire [8:0] selected_max = (selected_abs_x >= selected_abs_y)
                        ? selected_abs_x : selected_abs_y;
wire [8:0] selected_min = (selected_abs_x >= selected_abs_y)
                        ? selected_abs_y : selected_abs_x;
wire [10:0] selected_min_x3 = {2'b00, selected_min}
                            + ({2'b00, selected_min} << 1);
// max + 3/8*min is a close, shift-friendly Euclidean-radius approximation.
wire [8:0] selected_radius = selected_max + selected_min_x3[10:3];
// MAME's PORT_SENSITIVITY is host-input tuning, not an electrical limit on
// the cabinet ADC.  Feed the complete conditioned radius to the 8-bit ADC so
// 95% physical stick throw reaches the game's full 0x00..0xff aim range.
wire [7:0] selected_magnitude = gun_curve_mag(selected_radius);

typedef enum logic [2:0] {G_IDLE, G_PREP, G_DIV_X, G_DIV_Y, G_FILTER} gun_state_t;
gun_state_t state;
reg [8:0]  div_den;
reg [7:0]  div_rem;
reg [14:0] div_quot;
reg [3:0]  div_count;
wire [8:0] div_rem_shift = {div_rem, div_quot[14]};
wire       div_take = div_rem_shift >= div_den;
wire [8:0] div_rem_next = div_take ? div_rem_shift - div_den
                                   : div_rem_shift;
wire [14:0] div_quot_next = {div_quot[13:0], div_take};

reg [7:0] work_magnitude;
reg       work_negative_x, work_negative_y;
reg [7:0] work_out_x, work_out_y;

always @(posedge clk) begin
    if (rst) begin
        tick_div <= {TICK_BITS{1'b0}};
        state <= G_IDLE;
        player <= 1'b0;
        sample_x0 <= 9'sd0; sample_y0 <= 9'sd0;
        sample_x1 <= 9'sd0; sample_y1 <= 9'sd0;
        div_den <= 9'd1; div_rem <= 8'd0; div_quot <= 15'd0;
        div_count <= 4'd0;
        work_magnitude <= 8'd0;
        work_negative_x <= 1'b0; work_negative_y <= 1'b0;
        work_out_x <= 8'd0; work_out_y <= 8'd0;
        p1_aim_x <= 8'h80; p1_aim_y <= 8'h80;
        p2_aim_x <= 8'h80; p2_aim_y <= 8'h80;
    end
    else if (!enable) begin
        tick_div <= {TICK_BITS{1'b0}};
        state <= G_IDLE;
        p1_aim_x <= 8'h80; p1_aim_y <= 8'h80;
        p2_aim_x <= 8'h80; p2_aim_y <= 8'h80;
    end
    else begin
        tick_div <= tick_div + 1'b1;
        case (state)
            G_IDLE: if (tick_div == {TICK_BITS{1'b0}}) begin
                sample_x0 <= invert_x ? -$signed({p1_raw_x[7], p1_raw_x})
                                      :  $signed({p1_raw_x[7], p1_raw_x});
                sample_y0 <= invert_y ? -$signed({p1_raw_y[7], p1_raw_y})
                                      :  $signed({p1_raw_y[7], p1_raw_y});
                sample_x1 <= invert_x ? -$signed({p2_raw_x[7], p2_raw_x})
                                      :  $signed({p2_raw_x[7], p2_raw_x});
                sample_y1 <= invert_y ? -$signed({p2_raw_y[7], p2_raw_y})
                                      :  $signed({p2_raw_y[7], p2_raw_y});
                player <= 1'b0;
                state <= G_PREP;
            end

            G_PREP: begin
                work_negative_x <= selected_x[8];
                work_negative_y <= selected_y[8];
                work_magnitude <= selected_magnitude;
                if (selected_radius <= GUN_INNER_R) begin
                    work_out_x <= 8'd0;
                    work_out_y <= 8'd0;
                    state <= G_FILTER;
                end
                else begin
                    div_den <= selected_radius;
                    div_rem <= 8'd0;
                    div_quot <= selected_abs_x * selected_magnitude;
                    div_count <= 4'd0;
                    state <= G_DIV_X;
                end
            end

            G_DIV_X: begin
                div_rem <= div_rem_next[7:0];
                div_quot <= div_quot_next;
                if (div_count == 4'd14) begin
                    work_out_x <= (div_quot_next > {7'd0, GUN_PEAK_MAG})
                                ? GUN_PEAK_MAG : div_quot_next[7:0];
                    div_rem <= 8'd0;
                    div_quot <= selected_abs_y * work_magnitude;
                    div_count <= 4'd0;
                    state <= G_DIV_Y;
                end
                else
                    div_count <= div_count + 1'b1;
            end

            G_DIV_Y: begin
                div_rem <= div_rem_next[7:0];
                div_quot <= div_quot_next;
                if (div_count == 4'd14) begin
                    work_out_y <= (div_quot_next > {7'd0, GUN_PEAK_MAG})
                                ? GUN_PEAK_MAG : div_quot_next[7:0];
                    state <= G_FILTER;
                end
                else
                    div_count <= div_count + 1'b1;
            end

            G_FILTER: begin
                if (!player) begin
                    p1_aim_x <= gun_filter(p1_aim_x,
                        gun_offset_axis(work_negative_x, work_out_x));
                    p1_aim_y <= gun_filter(p1_aim_y,
                        gun_offset_axis(work_negative_y, work_out_y));
                    player <= 1'b1;
                    state <= G_PREP;
                end
                else begin
                    p2_aim_x <= gun_filter(p2_aim_x,
                        gun_offset_axis(work_negative_x, work_out_x));
                    p2_aim_y <= gun_filter(p2_aim_y,
                        gun_offset_axis(work_negative_y, work_out_y));
                    state <= G_IDLE;
                end
            end

            default: state <= G_IDLE;
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
module s32_msm6253 (
    input             clk,
    input             cs,
    input             we,
    input       [1:0] addr,
    output reg        dout_bit,    // d7_r: serial-ish MSB-first read per MAME
    input       [7:0] an0, an1, an2, an3
);

reg [7:0] shifter;
reg       rd_d;                  // read-strobe history: shift once per read (audit R20 IO-2)
always @(posedge clk) begin
    rd_d <= cs && !we;
    if (cs && we) begin
        case (addr)
            2'd0: shifter <= an0;
            2'd1: shifter <= an1;
            2'd2: shifter <= an2;
            2'd3: shifter <= an3;
        endcase
    end
    else if (cs && !we && !rd_d) begin   // rising edge only: MAME d7_r = one bit per read
        dout_bit <= shifter[7];
        shifter  <= {shifter[6:0], 1'b0};
    end
end

endmodule

// ---------------------------------------------------------------------------
module s32_upd4701 (
    input             clk,
    input             rst,

    // counter inputs: signed deltas accumulated from mouse/spinner
    input             delta_valid,
    input signed [8:0] dx,
    input signed [8:0] dy,

    input             cs,
    input             we,          // write = reset_xy
    input       [1:0] addr,        // 0=XL 1=XH 2=YL 3=YH
    output reg  [7:0] rdata,
    input       [7:0] buttons
);

reg signed [11:0] cx, cy;
reg [11:0] lx, ly;

always @(posedge clk) begin
    if (rst) begin cx <= 0; cy <= 0; end
    else begin
        if (delta_valid) begin
            cx <= cx + {{3{dx[8]}}, dx};
            cy <= cy + {{3{dy[8]}}, dy};
        end
        if (cs && we) begin cx <= 0; cy <= 0; end
        if (cs && !we) begin
            case (addr)
                2'd0: begin lx <= cx; rdata <= cx[7:0]; end
                // XH/YH high nibble = uPD4701 switch inputs; segas32 leaves them
                // unconnected (MAME sets no switch callbacks) so they read idle,
                // not the live joystick buttons. audit R20 IO-14
                2'd1: rdata <= {4'h0, lx[11:8]};
                2'd2: begin ly <= cy; rdata <= cy[7:0]; end
                2'd3: rdata <= {4'h0, ly[11:8]};
            endcase
        end
    end
end

endmodule

// ---------------------------------------------------------------------------
module s32_i8255 (
    input             clk,
    input             cs,
    input             we,
    input       [1:0] addr,
    input       [7:0] wdata,
    output reg  [7:0] rdata,
    input       [7:0] pa, pb, pc_in,
    output reg  [7:0] pc_out
);

// Control word powers up 0x9b (all ports input, mode 0) like MAME i8255
// device_reset(); a mode-set write (port 3, bit7=1) latches it and a
// control-port read returns it with bit7 set. audit R20 IO-16
reg [7:0] ctrl = 8'h9b;
always @(posedge clk) begin
    if (cs && we && addr == 2'd2) pc_out <= wdata;
    if (cs && we && addr == 2'd3 && wdata[7]) ctrl <= wdata;
    case (addr)
        2'd0: rdata <= pa;
        2'd1: rdata <= pb;
        2'd2: rdata <= pc_in;
        default: rdata <= ctrl;
    endcase
end

endmodule

// ---------------------------------------------------------------------------
//  V60 interrupt controller + timers (0xd00000) — DESIGN.md §5.5
// ---------------------------------------------------------------------------
module s32_intc (
    input             clk,          // clk_sys
    input             rst,
    input             is_multi32,

    // MAME interrupt_control_16_w: BOTH byte lanes are registers —
    // even byte -> ctl[offset*2], odd byte -> ctl[offset*2+1] (ga2 programs
    // vectors 0..4, the ack reg 7, and the timer highs 9/11 on both lanes;
    // found by real-ROM boot: dropped acks made an IRQ storm and timer1
    // never armed).
    input             cs,
    input             we,
    input       [3:1] addr,         // word index (byte-pair select)
    input       [1:0] be,           // lane enables: [0]=even byte, [1]=odd
    input      [15:0] wdata,
    output reg  [7:0] rdata,

    // interrupt sources (pulses)
    input             vblank_start,
    input             vblank_end,
    input             sound_irq,    // from Z80 doorbell

    // to V60
    output            irq_n,
    output      [7:0] irq_vector,
    input             irq_taken,    // CPU consumed vector

    // to Z80 (writes at offsets 12-15)
    output reg        z80_doorbell
);

reg [7:0] ctl [0:15];
reg [4:0] pending;

// Timers: t0 at MAIN/2 and t1 at the independent 50 MHz crystal /16.
reg [23:0] t0_cnt, t1_cnt;
reg        t0_run, t1_run;
reg [23:0] t1_acc;
// round((3.125 MHz / 48.317307 MHz) * 2^24)
localparam [23:0] T1_STEP = 24'd1085094;
wire [24:0] t1_sum = {1'b0, t1_acc} + {1'b0, T1_STEP};
wire        t1_tick = t1_sum[24];

wire       t0_expire = t0_run && (t0_cnt == 0);
wire       t1_expire = t1_run && t1_tick && (t1_cnt == 0);
wire [4:0] pending_sources = {t1_expire, t0_expire, sound_irq,
                              vblank_end, vblank_start};

wire [7:0] mask = ctl[6];
wire [4:0] eff = pending & ~mask[4:0];
assign irq_n = (eff == 0);

// lowest-numbered pending source's vector
reg [7:0] vec;
assign irq_vector = vec;
always @(*) begin
    vec = 8'h00;
    for (int i = 4; i >= 0; i--)
        if (eff[i]) vec = ctl[i];
end

always @(posedge clk) begin
    if (rst) begin
        // MAME device_reset (memset(m_v60_irq_control,0xff)) leaves the pending
        // byte (index 7) = 0xff -> all 5 sources pending, but ctl[6]=0xff below
        // masks them so no IRQ is delivered until the game unmasks. audit R20 IO-6
        // NOTE: verif/common/tb_intc.sv encodes the old pending==0 reset and must
        // be updated to ack all sources after reset (else its reset/timer0/timer1
        // checks now see the pre-set pending bits). Test not edited here.
        pending <= 5'h1f;
        z80_doorbell <= 1'b0;
        t0_run <= 1'b0; t1_run <= 1'b0;
        t0_cnt <= 24'd0; t1_cnt <= 24'd0;
        t1_acc <= 24'd0;
        rdata <= 8'hff;
        // MAME/device-reset contract: the complete 16-byte register file
        // starts at FF. Leaving vector/timer bytes uninitialized can expose
        // FPGA power-up state before a game has programmed every source.
        for (int i = 0; i < 16; i++) ctl[i] <= 8'hff;
    end
    else begin
        z80_doorbell <= 1'b0;
        // Accumulate every source first. An acknowledgement below applies to
        // this combined value so it cannot discard a different source that
        // arrives on the same clock.
        pending <= pending | pending_sources;

        // timer 0: period = 0x800*N ticks of MAIN/2 (~16.1 MHz)
        if (t0_run) begin
            if (t0_cnt == 0) begin
                t0_run <= 0;
            end
            else t0_cnt <= t0_cnt - 1'd1;
        end
        if (t1_run) begin
            t1_acc <= t1_sum[23:0];
            if (t1_tick) begin
                if (t1_cnt == 0) t1_run <= 0;
                else t1_cnt <= t1_cnt - 1'd1;
            end
        end

        if (cs && we) begin
            if (be[0]) ctl[{addr, 1'b0}] <= wdata[7:0];
            if (be[1]) ctl[{addr, 1'b1}] <= wdata[15:8];
            case (addr)
                3'd3: if (be[1]) pending <= (pending | pending_sources) & wdata[12:8]; // byte 7: ack = AND
                3'd4: begin           // bytes 8/9: timer 0 count, one-shot arm
                    logic [11:0] n;
                    n = {(be[1] ? wdata[11:8] : ctl[9][3:0]),
                         (be[0] ? wdata[7:0]  : ctl[8])};
                    if (n != 0) begin
                        // period in clk_sys ticks = 0x800*N / (xtal/2) * 48.317307MHz.
                        // System 32 xtal=32.2159MHz -> ratio 3 exactly -> N*0x1800.
                        // Multi 32 xtal=32MHz (16.0MHz source) -> N*0x1800*32.2159/32
                        // = N*6185, i.e. +N*41 (0.67% longer). audit R20 IO-5
                        // Store period-1: expiry is tested before the decrement.
                        t0_cnt <= ({n, 11'b0} + {n, 12'b0}
                                   + (is_multi32 ? ({n, 5'b0} + {n, 3'b0} + n) : 24'd0))
                                  - 1'b1;
                        t0_run <= 1'b1;
                    end
                    // n == 0: MAME only re-arms `if (duration)` — the write
                    // stores the register byte and leaves an in-flight
                    // one-shot running.  Do not cancel here.
                end
                3'd5: begin           // bytes 10/11: timer 1 count, one-shot arm
                    logic [11:0] n;
                    n = {(be[1] ? wdata[11:8] : ctl[11][3:0]),
                         (be[0] ? wdata[7:0]  : ctl[10])};
                    if (n != 0) begin
                        // MAME/hardware: 0x100*N ticks at exactly 50 MHz/16.
                        // Count in timer-source ticks and use the NCO above;
                        // the old 15.5x clk_sys approximation drifted early.
                        t1_cnt <= {n, 8'b0} - 1'b1;
                        t1_acc <= 24'd0;
                        t1_run <= 1'b1;
                    end
                    // n == 0: register write only, armed one-shot keeps
                    // running (MAME parity — see timer 0 above).
                end
                3'd6, 3'd7: z80_doorbell <= 1'b1;    // bytes 12-15: ring sound CPU
                default: ;
            endcase
        end

        rdata <= 8'hff;   // MAME int_control_r/hardware-visible readback
    end
end

endmodule

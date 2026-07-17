//============================================================================
//  Sega System 32 — ioctl ROM loader  (DESIGN.md §9.3)
//  Stream layout (ioctl index 0):
//    [0x00..0x3f]  board descriptor (64 bytes)
//    [maincpu 2MB][soundcpu 4MB][tiles 4MB][multipcm 4MB][mcu 64KB pad 2MB-]
//    [sprites up to 16MB]
//  The MRA pads every region to its fixed size so offsets are constant.
//  mcu bytes are address-descrambled into the V25 program BRAM here
//  (bitswap<16>(14,11,15,12,13,4,3,7,5,10,2,8,9,6,1,0) — DESIGN.md §8.1).
//  ioctl index 2 = 93C46 default image (128 bytes).
//============================================================================

import s32_pkg::*;

module s32_rom_loader (
    input             clk,
    input             rst,

    input             ioctl_download,
    input       [7:0] ioctl_index,
    input             ioctl_wr,
    input      [26:0] ioctl_addr,
    input       [7:0] ioctl_dout,
    output            ioctl_wait,

    // board descriptor out
    output board_desc_t board_desc,

    // SDRAM write port
    output reg        sdr_wr_req,
    output reg [24:1] sdr_wr_addr,
    output reg [15:0] sdr_wr_din,
    output reg  [1:0] sdr_wr_be,
    input             sdr_wr_ack,

    // V25 program BRAM write port (64KB)
    output reg        v25_wr,
    output reg [15:0] v25_waddr,
    output reg  [7:0] v25_wdata,

    // EEPROM default image write port (64 x 16)
    output reg        eep_wr,
    output reg  [5:0] eep_waddr,
    output reg [15:0] eep_wdata,
    output reg        eep_loaded,

    output reg        rom_loaded
);

// stream region boundaries (byte offsets within index-0 stream)
localparam [26:0] OFF_DESC     = 27'h000_0000;
localparam [26:0] OFF_MAINCPU  = 27'h000_0040;
localparam [26:0] OFF_SOUNDCPU = OFF_MAINCPU  + 27'h20_0000;
localparam [26:0] OFF_TILES    = OFF_SOUNDCPU + 27'h40_0000;
localparam [26:0] OFF_MULTIPCM = OFF_TILES    + 27'h40_0000;
localparam [26:0] OFF_MCU      = OFF_MULTIPCM + 27'h40_0000;
localparam [26:0] OFF_SPRITES  = OFF_MCU      + 27'h1_0000;
localparam [26:0] OFF_END      = OFF_SPRITES  + 27'h100_0000;

reg [7:0]  desc_bytes [0:15];
reg [7:0]  byte_lo;
reg        busy;
reg        index0_seen;
integer    desc_i;

assign ioctl_wait = busy;

// V25 address descramble: dst = bitswap16(src,14,11,15,12,13,4,3,7,5,10,2,8,9,6,1,0)
function automatic [15:0] v25_descramble(input [15:0] i);
    v25_descramble = { i[14], i[11], i[15], i[12], i[13], i[4], i[3], i[7],
                       i[5],  i[10], i[2],  i[8],  i[9],  i[6], i[1], i[0] };
endfunction

// map stream offset -> sdram byte address
function automatic [24:0] map_addr(input [26:0] a);
    if      (a < OFF_SOUNDCPU) map_addr = SDR_MAINCPU_BASE  + (a[24:0] - OFF_MAINCPU[24:0]);
    else if (a < OFF_TILES)    map_addr = SDR_SOUNDCPU_BASE + (a[24:0] - OFF_SOUNDCPU[24:0]);
    else if (a < OFF_MULTIPCM) map_addr = SDR_TILES_BASE    + (a[24:0] - OFF_TILES[24:0]);
    else if (a < OFF_MCU)      map_addr = SDR_MULTIPCM_BASE + (a[24:0] - OFF_MULTIPCM[24:0]);
    else                       map_addr = SDR_SPRITES_BASE  + (a[24:0] - OFF_SPRITES[24:0]);
endfunction

board_desc_t desc_r;
assign board_desc = desc_r;

always @(posedge clk) begin
    if (rst) begin
        sdr_wr_req <= 1'b0; sdr_wr_addr <= '0; sdr_wr_din <= '0; sdr_wr_be <= '0;
        v25_wr <= 1'b0; v25_waddr <= '0; v25_wdata <= '0;
        eep_wr <= 1'b0; eep_waddr <= '0; eep_wdata <= '0;
        eep_loaded <= 1'b0; rom_loaded <= 1'b0;
        byte_lo <= 8'd0; busy <= 1'b0; index0_seen <= 1'b0;
        desc_r <= '0;
        for (desc_i = 0; desc_i < 16; desc_i = desc_i + 1)
            desc_bytes[desc_i] <= 8'd0;
    end
    else begin
        v25_wr <= 1'b0;
        eep_wr <= 1'b0;

        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            busy       <= 1'b0;
        end

        if (ioctl_download && ioctl_wr) begin
            if (ioctl_index == 8'd0) begin
                if (ioctl_addr < OFF_MAINCPU) begin
                    // descriptor
                    if (ioctl_addr[26:4] == 0) desc_bytes[ioctl_addr[3:0]] <= ioctl_dout;
                    if (ioctl_addr == OFF_MAINCPU-1) begin
                        desc_r.multi32     <= desc_bytes[0][0];
                        desc_r.has_v25     <= desc_bytes[0][1];
                        desc_r.v25_table   <= desc_bytes[0][2];
                        desc_r.has_adc     <= desc_bytes[0][3];
                        desc_r.has_track   <= desc_bytes[0][4];
                        desc_r.has_ppi     <= desc_bytes[0][5];
                        desc_r.has_dsp_hle <= desc_bytes[0][6];
                        desc_r.has_cd_stub <= desc_bytes[0][7];
                        desc_r.dual_pcb    <= desc_bytes[1][0];
                        desc_r.prot_sel    <= desc_bytes[2][6:0];
                    end
                end
                else if (ioctl_addr >= OFF_MCU && ioctl_addr < OFF_SPRITES) begin
                    // V25 program -> BRAM with address descramble. Subtract
                    // the 64-byte stream descriptor before permuting the
                    // MCU-local address bits.
                    v25_wr    <= 1'b1;
                    v25_waddr <= v25_descramble(ioctl_addr[15:0] - OFF_MCU[15:0]);
                    v25_wdata <= ioctl_dout;
                end
                else begin
                    // SDRAM regions: global stream addresses are aligned, so
                    // parity is a deterministic byte-pair marker and cannot
                    // leak state between ioctl indexes.
                    if (!ioctl_addr[0]) byte_lo <= ioctl_dout;
                    else begin
                        sdr_wr_req <= 1'b1;
                        busy       <= 1'b1;
                        begin
                            logic [24:0] ma;
                            ma = map_addr(ioctl_addr);
                            sdr_wr_addr <= ma[24:1];
                        end
                        sdr_wr_din <= {ioctl_dout, byte_lo}; // little-endian stream
                        sdr_wr_be  <= 2'b11;
                    end
                end
            end
            else if (ioctl_index == 8'd2 || ioctl_index == 8'd3) begin
                // Factory image (2) or persisted NVRAM (3), 128 bytes ->
                // 64 little-endian words. A saved image naturally overrides
                // a factory image when both are supplied.
                if (!ioctl_addr[0]) byte_lo <= ioctl_dout;
                else begin
                    eep_wr     <= 1'b1;
                    eep_waddr  <= ioctl_addr[6:1];
                    eep_wdata  <= {ioctl_dout, byte_lo};
                    eep_loaded <= 1'b1;
                end
            end
        end

        // Only an actual index-0 transaction can change the boot gate. Wait
        // for its final SDRAM request to acknowledge before releasing reset.
        if (ioctl_download && ioctl_wr && ioctl_index == 8'd0 && ioctl_addr == 0) begin
            rom_loaded  <= 1'b0;
            eep_loaded  <= 1'b0;
            index0_seen <= 1'b1;
        end
        if (!ioctl_download && index0_seen && !busy && !sdr_wr_req) begin
            rom_loaded  <= 1'b1;
            index0_seen <= 1'b0;
        end
    end
end

endmodule

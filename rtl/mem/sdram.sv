//============================================================================
//  Sega System 32 for MiSTer — SDRAM controller
//  16-bit SDR SDRAM @ clk_ram (96.6 MHz), CL2, 4-bank interleaved.
//  Five request ports with fixed priority (DESIGN.md §4.2):
//    p0: V60 fetch/data (latency critical, 16-bit single)
//    p1: tile fetch      (64-bit burst = 4 words)
//    p2: sprite fetch    (128-bit burst = 8 words)
//    p3: Z80 ROM         (16-bit single, byte laned)
//    p4: MultiPCM        (16-bit single)
//  Write port (ROM download only): shares p0 path while ioctl_download.
//============================================================================

module sdram (
    input             clk,          // clk_ram
    input             init,         // reset/init request
    output reg        ready,

    // SDRAM chip interface
    inout      [15:0] SDRAM_DQ,
    output reg [12:0] SDRAM_A,
    output reg  [1:0] SDRAM_BA,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output reg        SDRAM_nCS,
    output reg        SDRAM_nCAS,
    output reg        SDRAM_nRAS,
    output reg        SDRAM_nWE,
    output            SDRAM_CKE,

    // download/write port (word writes, ROM load)
    input             wr_req,
    input      [24:1] wr_addr,
    input      [15:0] wr_din,
    input       [1:0] wr_be,
    output reg        wr_ack,

    // p0: V60
    input             p0_req,
    input      [24:1] p0_addr,
    output reg [15:0] p0_dout,
    output reg        p0_ack,

    // p1: tiles — 4-word burst, aligned to 8 bytes
    input             p1_req,
    input      [24:3] p1_addr,
    output reg [63:0] p1_dout,
    output reg        p1_ack,

    // p2: sprites — 8-word burst, aligned to 16 bytes
    input             p2_req,
    input      [24:4] p2_addr,
    output reg [127:0] p2_dout,
    output reg        p2_ack,

    // p3: Z80
    input             p3_req,
    input      [24:1] p3_addr,
    output reg [15:0] p3_dout,
    output reg        p3_ack,

    // p4: MultiPCM
    input             p4_req,
    input      [24:1] p4_addr,
    output reg [15:0] p4_dout,
    output reg        p4_ack
);

assign SDRAM_CKE  = 1'b1;
assign SDRAM_DQML = dqm[0];
assign SDRAM_DQMH = dqm[1];

localparam BURST_1   = 3'b000;
localparam CL        = 3'd2;

// commands {nCS,nRAS,nCAS,nWE}
localparam CMD_NOP   = 4'b0111;
localparam CMD_ACT   = 4'b0011;
localparam CMD_READ  = 4'b0101;
localparam CMD_WRITE = 4'b0100;
localparam CMD_PRE   = 4'b0010;
localparam CMD_REF   = 4'b0001;
localparam CMD_MRS   = 4'b0000;

reg  [3:0] cmd = CMD_NOP;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

reg [15:0] dq_out;
reg        dq_oe;
reg  [1:0] dqm;
assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

// init sequencer
reg [15:0] init_cnt = 16'hffff;
wire       init_done = (init_cnt == 0);

// refresh: 8192 rows / 64 ms @96.6MHz -> every ~755 cycles
reg [9:0]  ref_cnt;
reg        ref_pend;

typedef enum logic [3:0] {
    ST_IDLE, ST_ACT, ST_RCD1, ST_RCD2, ST_RD, ST_RDW, ST_WR, ST_WRRC,
    ST_PRE_REF, ST_REF, ST_REFW
} state_t;
state_t state = ST_IDLE;

reg [2:0]  grant;
reg [3:0]  rd_total;        // words to read (1/4/8)
reg [3:0]  rd_issued;
reg [3:0]  rd_captured;
reg [24:1] xfer_addr;
reg        is_write;
reg [15:0] din_r;
reg [1:0]  be_r;
reg [2:0]  wrrc_cnt;
reg [2:0]  refw_cnt;
reg [1:0]  ack_stretch;     // acks held 2 clk_ram cycles (clk_sys is /2 sync)

reg [15:0] din_pipe_d1, din_pipe_d2;   // unused placeholder (kept for clarity)

// request latches (edge -> level held until ack)
reg p0_pend, p1_pend, p2_pend, p3_pend, p4_pend, wr_pend;
always @(posedge clk) begin
    if (p0_req)  p0_pend <= 1'b1;
    if (p1_req)  p1_pend <= 1'b1;
    if (p2_req)  p2_pend <= 1'b1;
    if (p3_req)  p3_pend <= 1'b1;
    if (p4_req)  p4_pend <= 1'b1;
    if (wr_req)  wr_pend <= 1'b1;
    if (init) {p0_pend,p1_pend,p2_pend,p3_pend,p4_pend,wr_pend} <= '0;
    if (p0_ack) p0_pend <= 1'b0;
    if (p1_ack) p1_pend <= 1'b0;
    if (p2_ack) p2_pend <= 1'b0;
    if (p4_ack) p4_pend <= 1'b0;
    if (p3_ack) p3_pend <= 1'b0;
    if (wr_ack) wr_pend <= 1'b0;
end

// CL=2 capture pipeline: bit i set = a READ was issued i cycles ago
reg [1:0]  cl_pipe;
reg [15:0] cap_buf [0:7];

task automatic deliver;
    case (grant)
        3'd0: begin p0_dout <= cap_buf[0]; p0_ack <= 1'b1; end
        3'd1: begin p1_dout <= {cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]}; p1_ack <= 1'b1; end
        3'd2: begin p2_dout <= {cap_buf[7], cap_buf[6], cap_buf[5], cap_buf[4],
                                cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]}; p2_ack <= 1'b1; end
        3'd3: begin p3_dout <= cap_buf[0]; p3_ack <= 1'b1; end
        3'd4: begin p4_dout <= cap_buf[0]; p4_ack <= 1'b1; end
        default: ;
    endcase
endtask

always @(posedge clk) begin
    cmd    <= CMD_NOP;
    dq_oe  <= 1'b0;

    // acks: assert for 2 cycles so clk_sys (=clk/2, synchronous) always
    // samples exactly one rising edge with ack high
    if (ack_stretch != 0) ack_stretch <= ack_stretch - 1'd1;
    else begin
        p0_ack <= 1'b0; p1_ack <= 1'b0; p2_ack <= 1'b0;
        p3_ack <= 1'b0; p4_ack <= 1'b0; wr_ack <= 1'b0;
    end

    if (init) begin
        init_cnt <= 16'hffff;
        ready    <= 1'b0;
        state    <= ST_IDLE;
        ref_pend <= 1'b0;
        ref_cnt  <= 10'd0;
        dqm      <= 2'b11;
        cl_pipe  <= 2'b00;
        ack_stretch <= 0;
    end
    else if (!init_done) begin
        init_cnt <= init_cnt - 1'd1;
        dqm      <= 2'b11;
        // init: wait >100us, PRE-all, 8x REF, MRS (JEDEC)
        case (init_cnt)
            16'h0400: begin cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1; end
            16'h03c0, 16'h0380, 16'h0340, 16'h0300,
            16'h02c0, 16'h0280, 16'h0240, 16'h0200: cmd <= CMD_REF;
            16'h00a0: begin
                cmd      <= CMD_MRS;
                SDRAM_BA <= 2'b00;
                SDRAM_A  <= 13'b000_0_00_010_0_000; // CL2, sequential, burst 1
            end
            16'h0001: ready <= 1'b1;
            default: ;
        endcase
    end
    else begin
        dqm <= 2'b00;
        // refresh scheduling: 8192 rows / 64ms @ 96.65MHz -> every 755 cyc
        ref_cnt <= ref_cnt + 1'd1;
        if (ref_cnt == 10'd700) begin ref_cnt <= 0; ref_pend <= 1'b1; end

        // read capture (CL2: data valid 2 cycles after READ)
        cl_pipe <= {cl_pipe[0], 1'b0};
        if (cl_pipe[1]) begin
            cap_buf[rd_captured[2:0]] <= SDRAM_DQ;
            rd_captured <= rd_captured + 1'd1;
            if (rd_captured + 1'd1 == rd_total) begin
                deliver();
                ack_stretch <= 2'd1;   // hold ack this cycle + next
            end
        end

        case (state)
        ST_IDLE: begin
            if (ref_pend && cl_pipe == 0) begin
                cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1;
                refw_cnt <= 3'd1;             // tRP >= 2 cycles before REF
                state <= ST_PRE_REF;
            end
            else if (wr_pend | p0_pend | p1_pend | p2_pend | p3_pend | p4_pend) begin
                logic [24:1] a;
                if      (wr_pend) begin grant <= 3'd7; a = wr_addr;           rd_total <= 4'd1; is_write <= 1'b1; end
                else if (p0_pend) begin grant <= 3'd0; a = p0_addr;           rd_total <= 4'd1; is_write <= 1'b0; end
                else if (p1_pend) begin grant <= 3'd1; a = {p1_addr, 2'b00};  rd_total <= 4'd4; is_write <= 1'b0; end
                else if (p2_pend) begin grant <= 3'd2; a = {p2_addr, 3'b000}; rd_total <= 4'd8; is_write <= 1'b0; end
                else if (p3_pend) begin grant <= 3'd3; a = p3_addr;           rd_total <= 4'd1; is_write <= 1'b0; end
                else              begin grant <= 3'd4; a = p4_addr;           rd_total <= 4'd1; is_write <= 1'b0; end
                xfer_addr <= a;
                din_r     <= wr_din;
                be_r      <= wr_be;
                cmd       <= CMD_ACT;
                SDRAM_BA  <= a[24:23];
                SDRAM_A   <= a[22:10];
                rd_issued   <= 0;
                rd_captured <= 0;
                state     <= ST_RCD1;
            end
        end

        // tRCD >= 21ns = 3 cycles ACT->READ/WRITE
        ST_RCD1: state <= ST_RCD2;
        ST_RCD2: state <= is_write ? ST_WR : ST_RD;

        ST_WR: begin
            cmd      <= CMD_WRITE;
            SDRAM_BA <= xfer_addr[24:23];
            SDRAM_A  <= {2'b00, 1'b1, xfer_addr[10:1]};  // A10 = auto-precharge
            dq_out   <= din_r;
            dq_oe    <= 1'b1;
            dqm      <= ~be_r;
            wrrc_cnt <= 3'd4;   // tDAL ~= 42ns = 5 cycles before next ACT
            state    <= ST_WRRC;
        end
        ST_WRRC: begin
            if (wrrc_cnt == 3'd4) begin wr_ack <= 1'b1; ack_stretch <= 2'd1; end
            if (wrrc_cnt == 0) state <= ST_IDLE;
            else wrrc_cnt <= wrrc_cnt - 1'd1;
        end

        ST_RD: begin
            // issue one READ per cycle until rd_total issued
            cmd      <= CMD_READ;
            SDRAM_BA <= xfer_addr[24:23];
            SDRAM_A  <= {2'b00, (rd_issued + 1'd1 == rd_total) ? 1'b1 : 1'b0,
                         xfer_addr[10:1]};
            cl_pipe[0] <= 1'b1;
            xfer_addr[10:1] <= xfer_addr[10:1] + 1'd1;
            rd_issued <= rd_issued + 1'd1;
            if (rd_issued + 1'd1 == rd_total) state <= ST_RDW;
        end
        ST_RDW: begin
            // wait for capture pipeline to finish (delivery in capture logic);
            // also cover tRC for the single-read case with the drain cycles
            if (cl_pipe == 0) state <= ST_IDLE;
        end

        ST_PRE_REF: begin
            if (refw_cnt == 0) begin
                cmd      <= CMD_REF;
                ref_pend <= 1'b0;
                refw_cnt <= 3'd6;   // tRC(ref) >= 63ns = 7 cycles
                state    <= ST_REFW;
            end
            else refw_cnt <= refw_cnt - 1'd1;
        end
        ST_REF: state <= ST_REFW;   // (unused; kept for enum stability)
        ST_REFW: begin
            if (refw_cnt == 0) state <= ST_IDLE;
            else refw_cnt <= refw_cnt - 1'd1;
        end
        default: state <= ST_IDLE;
        endcase
    end
end

endmodule

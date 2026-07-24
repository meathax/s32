//============================================================================
//  V60 FAST_IFETCH wide-commit fetch-boundary regression.
//
//  Runs the SAME 20-byte double-displacement MOVW as tb_v60_long_ea, but through
//  the FAST_IFETCH=1 wide instruction-fetch port (8-byte icache lines + foff
//  alignment) that the full core uses -- previously only exercised end-to-end by
//  the (slow) romboot render.  The instruction spans bytes 14..33, i.e. fetch
//  lines 1,2,3,4 with a non-zero start offset, so the 8-byte commit, the foff
//  alignment, and the window realign are all stressed on a maximal instruction.
//  The if_ port is modelled exactly as s32_core drives it (line >> foff, held ack).
//============================================================================
`timescale 1ns/1ps

module tb_v60_fetch_wide;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire  [1:0] c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire  [1:0] m_be;

// dedicated wide instruction-fetch port
wire        if_req;
wire [23:0] if_addr;
reg  [63:0] if_data;
reg         if_served = 0;
wire        if_ack = if_served;

s32_v60 #(.START_PC(32'h0000_0000), .FAST_IFETCH(1'b1)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1),
    .dbg_pc(), .dbg_halted()
);

s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:32767];
reg ack_r = 0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;

always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

function [7:0] rambyte(input [23:0] a);
    rambyte = a[0] ? ram[a[15:1]][15:8] : ram[a[15:1]][7:0];
endfunction

// FAST_IFETCH model: serve the 8-byte line containing if_addr, pre-aligned so
// byte 0 is the byte at if_addr (== s32_core's if_hit_data = icache >> foff).
// ack is HELD until if_req drops, matching s32_core (ce-gated-safe handshake).
always @(posedge clk) begin
    logic [63:0] line;
    int bi;
    if (rst) if_served <= 1'b0;
    else begin
        if (!if_req) if_served <= 1'b0;
        else if (if_req && !if_served) begin
            for (bi = 0; bi < 8; bi = bi + 1)
                line[bi*8 +: 8] = rambyte({if_addr[23:3], 3'b000} + bi[23:0]);
            if_data   <= line >> {if_addr[2:0], 3'b000};
            if_served <= 1'b1;
        end
    end
end

integer pc_a;
task ab(input [7:0] b);
begin
    if (pc_a[0]) ram[pc_a >> 1][15:8] = b;
    else         ram[pc_a >> 1][7:0]  = b;
    pc_a = pc_a + 1;
end
endtask

task aw32(input [31:0] w);
begin
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
end
endtask

integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    pc_a = 0;

    // R0 = source pointer-table base, R1 = destination pointer-table base.
    ab(8'h2d); ab(8'h20); ab(8'hf4); aw32(32'h0000_1000);
    ab(8'h2d); ab(8'h21); ab(8'hf4); aw32(32'h0000_1010);

    // 20-byte MOVW [[R0+disp32(0)]+disp32(0)], [[R1+disp32(0)]+disp32(0)]
    // spans bytes 14..33; final displacement at fetch-buffer offset 16.
    ab(8'h2d); ab(8'he0);
    ab(8'h40); aw32(32'h0000_0000); aw32(32'h0000_0000);
    ab(8'h41); aw32(32'h0000_0000); aw32(32'h0000_0000);
    ab(8'h00); // HALT at byte 34.

    // Double-indirection tables and source/destination values.
    ram[16'h1000 >> 1]       = 16'h2000;
    ram[(16'h1000 >> 1) + 1] = 16'h0000;
    ram[16'h1010 >> 1]       = 16'h3000;
    ram[(16'h1010 >> 1) + 1] = 16'h0000;
    ram[16'h2000 >> 1]       = 16'h5678;
    ram[(16'h2000 >> 1) + 1] = 16'h1234;
    ram[16'h3000 >> 1]       = 16'hdead;
    ram[(16'h3000 >> 1) + 1] = 16'hbeef;

    repeat (8) @(posedge clk);
    rst = 0;
    repeat (12000) @(posedge clk);

    if (cpu.dbg_halted && cpu.dbg_pc == 32'd34 &&
        ram[16'h3000 >> 1] == 16'h5678 &&
        ram[(16'h3000 >> 1) + 1] == 16'h1234)
        $display("V60 FETCH WIDE PASS");
    else
        $display("V60 FETCH WIDE FAIL halted=%0d pc=%08x dest=%04x_%04x",
                 cpu.dbg_halted, cpu.dbg_pc,
                 ram[(16'h3000 >> 1) + 1], ram[16'h3000 >> 1]);
    $finish;
end

endmodule

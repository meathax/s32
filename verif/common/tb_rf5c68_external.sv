`timescale 1ns/1ps

module tb_rf5c68_external;
reg clk = 1'b0;
always #5 clk = ~clk;

reg rst = 1'b1;
reg ce = 1'b0;
reg cs = 1'b0;
reg we = 1'b0;
reg [12:0] addr = 13'd0;
reg [7:0] wdata = 8'd0;
wire [7:0] rdata;
wire cpu_wait;
wire rd_req, wr_req;
wire [15:0] rd_addr, wr_addr;
reg [15:0] rd_data = 16'd0;
reg rd_ack = 1'b0;
wire [7:0] wr_data;
reg wr_ack = 1'b0;

s32_rf5c68 #(.EXTERNAL_WAVE_RAM(1'b1)) dut (
    .clk(clk), .ce(ce), .rst(rst),
    .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .wave_rd_req(rd_req), .wave_rd_addr(rd_addr),
    .wave_rd_data(rd_data), .wave_rd_ack(rd_ack),
    .wave_wr_req(wr_req), .wave_wr_addr(wr_addr),
    .wave_wr_data(wr_data), .wave_wr_ack(wr_ack),
    .cpu_wait(cpu_wait), .out_l(), .out_r()
);

reg [15:0] backing [0:32767];
reg rd_seen = 1'b0, wr_seen = 1'b0;
reg [1:0] rd_delay = 2'd0, wr_delay = 2'd0;
integer i;
always @(posedge clk) begin
    rd_ack <= 1'b0;
    wr_ack <= 1'b0;

    if (rd_req && !rd_seen) begin
        rd_seen <= 1'b1;
        rd_delay <= 2'd2;
        rd_data <= backing[rd_addr[15:1]];
    end
    else if (rd_seen && rd_delay != 0) begin
        rd_delay <= rd_delay - 1'b1;
        if (rd_delay == 1) rd_ack <= 1'b1;
    end
    if (!rd_req) rd_seen <= 1'b0;

    if (wr_req && !wr_seen) begin
        wr_seen <= 1'b1;
        wr_delay <= 2'd2;
        if (wr_addr[0]) backing[wr_addr[15:1]][15:8] <= ~wr_data;
        else            backing[wr_addr[15:1]][7:0]  <= ~wr_data;
    end
    else if (wr_seen && wr_delay != 0) begin
        wr_delay <= wr_delay - 1'b1;
        if (wr_delay == 1) wr_ack <= 1'b1;
    end
    if (!wr_req) wr_seen <= 1'b0;
end

task automatic write_reg(input [3:0] ra, input [7:0] data);
begin
    @(negedge clk); cs = 1'b1; we = 1'b1; addr = {9'd0, ra}; wdata = data;
    @(posedge clk); #1;
    @(negedge clk); cs = 1'b0; we = 1'b0;
end
endtask

task automatic write_wave(input [11:0] wa, input [7:0] data);
integer guard;
begin
    @(negedge clk); cs = 1'b1; we = 1'b1; addr = {1'b1, wa}; wdata = data;
    guard = 0;
    while (!cpu_wait && guard < 10) begin @(posedge clk); #1; guard = guard + 1; end
    while (cpu_wait && guard < 100) begin @(posedge clk); #1; guard = guard + 1; end
    if (guard >= 100) $fatal(1, "external wave write timed out");
    @(negedge clk); cs = 1'b0; we = 1'b0;
    @(posedge clk); #1;
end
endtask

task automatic read_wave(input [11:0] wa, input [7:0] expected);
integer guard;
begin
    @(negedge clk); cs = 1'b1; we = 1'b0; addr = {1'b1, wa};
    guard = 0;
    while (!cpu_wait && guard < 10) begin @(posedge clk); #1; guard = guard + 1; end
    while (cpu_wait && guard < 100) begin @(posedge clk); #1; guard = guard + 1; end
    if (guard >= 100) $fatal(1, "external wave read timed out");
    if (rdata !== expected)
        $fatal(1, "wave read %04x got %02x expected %02x", {4'h2, wa}, rdata, expected);
    @(negedge clk); cs = 1'b0;
    @(posedge clk); #1;
end
endtask

initial begin
    // Production loader clears the inverted external wave aperture.
    for (i = 0; i < 32768; i = i + 1) backing[i] = 16'h0000;
    repeat (4) @(posedge clk);
    @(negedge clk); rst = 1'b0;

    write_reg(4'h7, 8'h02); // wave bank 2
    read_wave(12'h123, 8'hff); // cleared inverted storage reads erased

    write_wave(12'h123, 8'h5a);
    if (wr_addr !== 16'h2123 || wr_data !== 8'h5a)
        $fatal(1, "odd write payload/address mismatch");
    read_wave(12'h123, 8'h5a);
    read_wave(12'h122, 8'hff); // unwritten adjacent byte remains erased

    write_wave(12'h122, 8'ha5);
    if (wr_addr !== 16'h2122 || wr_data !== 8'ha5)
        $fatal(1, "even write payload/address mismatch");
    read_wave(12'h122, 8'ha5);
    read_wave(12'h123, 8'h5a);

    $display("RF5C68 EXTERNAL PASS");
    $finish;
end
endmodule

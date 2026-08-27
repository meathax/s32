`timescale 1ns/1ps

// Headless model of the production System 32 RF5C68 backing aperture. The
// external interface stores inverted bytes so a loader-cleared word reads as
// logical 0xff, matching the internal M10K implementation.
module s32_wave_ram_model (
    input             clk,
    input             rd_req,
    input      [15:0] rd_addr,
    output reg [15:0] rd_data = 16'd0,
    output reg        rd_ack = 1'b0,
    input             wr_req,
    input      [15:0] wr_addr,
    input       [7:0] wr_data,
    output reg        wr_ack = 1'b0
);

reg [15:0] backing [0:32767];
reg rd_seen = 1'b0;
reg wr_seen = 1'b0;
reg [1:0] rd_delay = 2'd0;
reg [1:0] wr_delay = 2'd0;
integer i;

initial begin
    for (i = 0; i < 32768; i = i + 1)
        backing[i] = 16'h0000;
end

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
        if (rd_delay == 1)
            rd_ack <= 1'b1;
    end
    if (!rd_req)
        rd_seen <= 1'b0;

    if (wr_req && !wr_seen) begin
        wr_seen <= 1'b1;
        wr_delay <= 2'd2;
        if (wr_addr[0])
            backing[wr_addr[15:1]][15:8] <= ~wr_data;
        else
            backing[wr_addr[15:1]][7:0] <= ~wr_data;
    end
    else if (wr_seen && wr_delay != 0) begin
        wr_delay <= wr_delay - 1'b1;
        if (wr_delay == 1)
            wr_ack <= 1'b1;
    end
    if (!wr_req)
        wr_seen <= 1'b0;
end

endmodule

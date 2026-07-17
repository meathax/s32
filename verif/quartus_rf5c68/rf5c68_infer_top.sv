module rf5c68_infer_top (
    input                    clk,
    input                    ce,
    input                    rst,
    input                    cs,
    input                    we,
    input             [12:0] addr,
    input              [7:0] wdata,
    output             [7:0] rdata,
    output signed      [15:0] out_l,
    output signed      [15:0] out_r
);

s32_rf5c68 dut (
    .clk(clk),
    .ce(ce),
    .rst(rst),
    .cs(cs),
    .we(we),
    .addr(addr),
    .wdata(wdata),
    .rdata(rdata),
    .out_l(out_l),
    .out_r(out_r)
);

endmodule

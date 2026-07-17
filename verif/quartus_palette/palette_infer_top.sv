module palette_infer_top (
    input             clk,
    input             cpu_we,
    input      [14:0] cpu_addr,
    input      [15:0] cpu_wdata,
    input       [1:0] cpu_be,
    input      [15:0] mixer_r4e,
    input      [13:0] mix_addr,
    output     [15:0] cpu_rdata,
    output     [15:0] mix_data
);

s32_palette dut (
    .clk(clk),
    .cpu_we(cpu_we),
    .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata),
    .cpu_be(cpu_be),
    .cpu_rdata(cpu_rdata),
    .mixer_r4e(mixer_r4e),
    .mix_addr(mix_addr),
    .mix_data(mix_data)
);

endmodule

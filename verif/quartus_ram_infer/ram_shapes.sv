// Isolated Quartus 17 inference probes for the three largest on-chip RAMs.
// These intentionally mirror the coding styles used by s32_core/s32_vram.

module infer_sprram (
    input              clk_cpu,
    input              clk_video,
    input              cpu_we,
    input       [15:0] cpu_addr,
    input       [15:0] cpu_wdata,
    input        [1:0] cpu_be,
    output reg  [15:0] cpu_rdata,
    input       [15:0] video_addr,
    output reg  [15:0] video_rdata
);
    wire [15:0] cpu_q;
    wire [15:0] video_q;
    assign cpu_rdata = cpu_q;
    assign video_rdata = video_q;
    s32_big_dpram #(
        .ADDR_WIDTH(16), .NUM_WORDS(65536), .MIXED_RDW_MODE("DONT_CARE")
    ) dut (
        .clock_a(clk_cpu), .address_a(cpu_addr),
        .data_a(cpu_wdata), .byteena_a(cpu_be), .wren_a(cpu_we), .q_a(cpu_q),
        .clock_b(clk_video), .address_b(video_addr),
        .data_b(16'h0000), .byteena_b(2'b00), .wren_b(1'b0), .q_b(video_q)
    );
endmodule

module infer_vram (
    input              clk_cpu,
    input              clk_video,
    input              cpu_we,
    input       [15:0] cpu_addr,
    input       [15:0] cpu_wdata,
    input        [1:0] cpu_be,
    output reg  [15:0] cpu_rdata,
    input       [15:0] video_addr,
    output reg  [15:0] video_rdata
);
    wire [15:0] cpu_q;
    wire [15:0] video_q;
    assign cpu_rdata = cpu_q;
    assign video_rdata = video_q;
    s32_big_dpram #(
        .ADDR_WIDTH(16), .NUM_WORDS(65536), .MIXED_RDW_MODE("DONT_CARE")
    ) dut (
        .clock_a(clk_cpu), .address_a(cpu_addr),
        .data_a(cpu_wdata), .byteena_a(cpu_be), .wren_a(cpu_we), .q_a(cpu_q),
        .clock_b(clk_video), .address_b(video_addr),
        .data_b(16'h0000), .byteena_b(2'b00), .wren_b(1'b0), .q_b(video_q)
    );
endmodule

module infer_wram (
    input              clk,
    input              cpu_we,
    input       [14:0] cpu_addr,
    input       [15:0] cpu_wdata,
    input        [1:0] cpu_be,
    output reg  [15:0] cpu_rdata,
    input              prot_we,
    input       [14:0] prot_addr,
    input       [15:0] prot_wdata,
    input        [1:0] prot_be,
    output reg  [15:0] prot_rdata
);
    wire [15:0] cpu_q;
    wire [15:0] prot_q;
    assign cpu_rdata = cpu_q;
    assign prot_rdata = prot_q;
    s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768)) dut (
        .clock_a(clk), .address_a(cpu_addr),
        .data_a(cpu_wdata), .byteena_a(cpu_be), .wren_a(cpu_we), .q_a(cpu_q),
        .clock_b(clk), .address_b(prot_addr),
        .data_b(prot_wdata), .byteena_b(prot_be), .wren_b(prot_we), .q_b(prot_q)
    );
endmodule

module infer_sound_shram (
    input             clk,
    input      [12:0] addr_a,
    input       [7:0] data_a,
    input             we_a,
    output      [7:0] q_a,
    input      [12:0] addr_b,
    input       [7:0] data_b,
    input             we_b,
    output      [7:0] q_b
);
    s32_byte_dpram #(.ADDR_WIDTH(13), .NUM_WORDS(8192)) dut (
        .clock(clk),
        .address_a(addr_a), .data_a(data_a), .rden_a(1'b1),
        .wren_a(we_a), .q_a(q_a),
        .address_b(addr_b), .data_b(data_b), .rden_b(1'b1),
        .wren_b(we_b), .q_b(q_b)
    );
endmodule

module infer_v25_dpram (
    input             clk,
    input      [10:0] addr,
    input       [7:0] data,
    input             re,
    input             we,
    output      [7:0] q
);
    s32_byte_dpram #(.ADDR_WIDTH(11), .NUM_WORDS(2048)) dut (
        .clock(clk),
        .address_a(addr), .data_a(data), .rden_a(re),
        .wren_a(we), .q_a(q),
        .address_b(11'd0), .data_b(8'd0), .rden_b(1'b0),
        .wren_b(1'b0), .q_b()
    );
endmodule

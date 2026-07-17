//============================================================================
// Directed VRAM -> tilemap fetch test.
//
// The video RAM has a synchronous registered read port.  Exercise each
// renderer client with a value that differs from the previously addressed
// word so a one-request-behind pipeline cannot pass accidentally.
//============================================================================
`timescale 1ns/1ps

module tb_tilemap_vram;

reg clk_sys = 0, clk_ram = 0, rst = 1;
always #10 clk_sys = ~clk_sys;
always #5  clk_ram = ~clk_ram;

reg         cpu_we = 0;
reg  [15:0] cpu_addr = 0;
reg  [15:0] cpu_wdata = 0;
reg   [1:0] cpu_be = 2'b11;
wire [15:0] cpu_rdata;
reg  [15:0] vid_addr;
wire [15:0] vid_rdata;

wire [15:0] r1ff00, r1ff02, r1ff04, r1ff06, r1ff5c, r1ff5e;
wire [15:0] r1ff88, r1ff8a, r1ff8c, r1ff8e;
wire [15:0] scrollx [0:3], scrolly [0:3], offsx [0:3], offsy [0:3];
wire [15:0] pages [0:7], zoomx [0:1], zoomy [0:1], clips [0:19];

s32_vram vram (
    .clk(clk_sys), .vid_clk(clk_ram),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_be(cpu_be), .cpu_rdata(cpu_rdata),
    .vid_addr(vid_addr), .vid_rdata(vid_rdata),
    .reg_1ff00(r1ff00), .reg_1ff02(r1ff02), .reg_1ff04(r1ff04),
    .reg_1ff06(r1ff06), .reg_scrollx(scrollx), .reg_scrolly(scrolly),
    .reg_offsx(offsx), .reg_offsy(offsy), .reg_pages(pages),
    .reg_zoomx(zoomx), .reg_zoomy(zoomy), .reg_1ff5c(r1ff5c),
    .reg_1ff5e(r1ff5e), .reg_clips(clips), .reg_1ff88(r1ff88),
    .reg_1ff8a(r1ff8a), .reg_1ff8c(r1ff8c), .reg_1ff8e(r1ff8e)
);

reg         line_start = 0;
wire        line_done;
wire        tile_req;
wire [21:3] tile_addr;
reg  [63:0] tile_data = 64'hAAAA_AAAA_AAAA_AAAA;
reg         tile_ack = 0;
wire        lb_we;
wire  [2:0] lb_layer;
wire  [8:0] lb_x;
wire [13:0] lb_pix;

s32_tilemap dut (
    .clk(clk_ram), .rst(rst), .line(9'd0), .line_start(line_start),
    .line_done(line_done), .mode_416(1'b0), .ext_tilebank(2'b00),
    .r1ff00(r1ff00), .r1ff02(r1ff02), .r1ff04(r1ff04),
    .r1ff06(r1ff06), .r1ff5c(r1ff5c), .r1ff5e(r1ff5e),
    .r1ff88(r1ff88), .r1ff8a(r1ff8a), .r1ff8c(r1ff8c),
    .r1ff8e(r1ff8e), .scrollx(scrollx), .scrolly(scrolly),
    .offsx(offsx), .offsy(offsy), .pages(pages), .zoomx(zoomx),
    .zoomy(zoomy), .clips(clips), .vram_addr(vid_addr),
    .vram_rdata(vid_rdata), .tile_req(tile_req), .tile_addr(tile_addr),
    .tile_data(tile_data), .tile_ack(tile_ack), .lb_we(lb_we),
    .lb_layer(lb_layer), .lb_x(lb_x), .lb_pix(lb_pix), .layer_off_o()
);

always @(posedge clk_ram) begin
    tile_ack <= 1'b0;
    if (tile_req && !tile_ack)
        tile_ack <= 1'b1;
end

task automatic cpu_write(input [15:0] a, input [15:0] d);
begin
    @(negedge clk_sys);
    cpu_addr = a; cpu_wdata = d; cpu_we = 1'b1;
    @(negedge clk_sys);
    cpu_we = 1'b0;
end
endtask

task automatic start_render;
begin
    @(negedge clk_ram); line_start = 1'b1;
    @(negedge clk_ram); line_start = 1'b0;
end
endtask

integer errors = 0;
integer timeout;
reg found;

task automatic expect_first_tile(input [18:0] want_addr,
                                 input [2:0] want_layer,
                                 input [13:0] want_pix);
begin
    found = 0;
    for (timeout = 0; timeout < 2000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (tile_req) begin
            found = 1;
            if (tile_addr !== want_addr) begin
                $display("FAIL tile address: got %05x want %05x", tile_addr, want_addr);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin $display("FAIL no tile request"); errors = errors + 1; end

    found = 0;
    for (timeout = 0; timeout < 2000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (lb_we && lb_layer == want_layer && lb_x == 0) begin
            found = 1;
            if (lb_pix !== want_pix) begin
                $display("FAIL tile pixel: got %04x want %04x", lb_pix, want_pix);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin $display("FAIL no first tile pixel"); errors = errors + 1; end
end
endtask

task automatic expect_first_pixel(input [2:0] want_layer,
                                  input [13:0] want_pix);
begin
    found = 0;
    for (timeout = 0; timeout < 5000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (lb_we && lb_layer == want_layer && lb_x == 0) begin
            found = 1;
            if (lb_pix !== want_pix) begin
                $display("FAIL layer %0d pixel: got %04x want %04x",
                         want_layer, lb_pix, want_pix);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin
        $display("FAIL no first pixel for layer %0d", want_layer);
        errors = errors + 1;
    end
end
endtask

task automatic wait_done;
begin
    found = 0;
    for (timeout = 0; timeout < 10000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (line_done) found = 1;
    end
    if (!found) begin $display("FAIL renderer timeout"); errors = errors + 1; end
    repeat (2) @(posedge clk_ram);
end
endtask

initial begin
    repeat (4) @(posedge clk_ram);
    rst = 0;

    // NBG0 name word 1 must request code 1, row 0 (address 0x10).
    cpu_write(16'h0000, 16'h0001);
    cpu_write(16'hff81, 16'h003e); // only NBG0 enabled
    start_render;
    expect_first_tile(19'h00010, 3'd1, 14'h200a);
    wait_done;

    // TEXT name and glyph are two distinct synchronous VRAM reads.
    cpu_write(16'h0000, 16'h0402); // palette 2, character 2
    cpu_write(16'h0020, 16'h00f0); // char 2, row 0: x0 pen F
    cpu_write(16'hff81, 16'h002f); // only TEXT enabled
    start_render;
    expect_first_pixel(3'd0, 14'h202f);
    wait_done;

    // 4bpp bitmap word x=0 uses the low nibble.
    cpu_write(16'h0000, 16'h4321);
    cpu_write(16'hff81, 16'h001f); // only BITMAP enabled
    start_render;
    expect_first_pixel(3'd5, 14'h2001);
    wait_done;

    if (errors == 0) $display("TILEMAP VRAM PASS");
    else             $display("TILEMAP VRAM FAIL (%0d errors)", errors);
    $finish;
end

endmodule

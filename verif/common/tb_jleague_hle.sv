`timescale 1ns/1ps
module tb_jleague_hle;
reg clk = 0, rst = 1, enable = 1;
always #5 clk = ~clk;

reg        cpu_write = 0;
reg [23:0] cpu_addr = 0;
reg [15:0] cpu_wdata = 0;
wire       rom_req;
wire [20:0] rom_addr;
wire [15:0] rom_data = 16'h12ab;
wire        rom_ack = rom_req;
wire        wram_req, wram_we;
wire [15:0] wram_addr, wram_wdata;
wire [1:0]  wram_be;
wire        wram_ack = wram_req;

integer errors = 0;
integer rom_seen = 0;
integer wram_seen = 0;

s32_prot_jleague dut (
    .clk(clk), .rst(rst), .enable(enable),
    .cpu_write(cpu_write), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ack(rom_ack),
    .wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr),
    .wram_wdata(wram_wdata), .wram_be(wram_be), .wram_ack(wram_ack)
);

always @(negedge clk) begin
    if (!rst && rom_req) begin
        rom_seen = rom_seen + 1;
        if (rom_addr != (21'h07bbc0 + {4'd0, 16'h0012, 1'b0})) begin
            $display("FAIL ROM address %05x", rom_addr);
            errors = errors + 1;
        end
    end
    if (!rst && wram_req) begin
        wram_seen = wram_seen + 1;
        if (!wram_we || wram_be != 2'b01) begin
            $display("FAIL WRAM control addr=%04x data=%04x be=%b",
                     wram_addr, wram_wdata, wram_be);
            errors = errors + 1;
        end
        if (wram_seen == 1 && (wram_addr != (16'hf708 >> 1) ||
                               wram_wdata != 16'h00ab)) begin
            $display("FAIL table publish addr=%04x data=%04x", wram_addr, wram_wdata);
            errors = errors + 1;
        end
        if (wram_seen == 2 && (wram_addr != (16'h0016 >> 1) ||
                               wram_wdata != 16'h0034)) begin
            $display("FAIL team publish addr=%04x data=%04x", wram_addr, wram_wdata);
            errors = errors + 1;
        end
    end
end

initial begin
    repeat (3) @(negedge clk);
    rst = 0;

    // The table-selection write is accepted once and causes one ROM lookup
    // followed by the low-byte write to 0x20f708.
    @(negedge clk);
    cpu_addr = 24'h20f700;
    cpu_wdata = 16'h0012;
    cpu_write = 1;
    @(negedge clk);
    cpu_write = 0;
    repeat (5) @(negedge clk);

    // The team-browser write publishes only its low byte at 0x200016.
    cpu_addr = 24'h20f704;
    cpu_wdata = 16'hab34;
    cpu_write = 1;
    @(negedge clk);
    cpu_write = 0;
    repeat (4) @(negedge clk);

    if (rom_seen != 1 || wram_seen != 2 || errors != 0)
        $fatal(1, "J.League HLE failed rom=%0d wram=%0d errors=%0d",
               rom_seen, wram_seen, errors);
    $display("J.LEAGUE HLE PASS");
    $finish;
end
endmodule

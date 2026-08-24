`timescale 1ns/1ps
module tb_s32_prot_sonic;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg enable = 1'b1;
    reg cpu_write = 1'b0;
    reg [23:0] cpu_addr = 24'd0;
    reg [7:0] cpu_wdata = 8'd0;
    wire wram_req, wram_we;
    wire [15:0] wram_addr, wram_wdata;
    wire [1:0] wram_be;
    wire wram_ack = wram_req;

    s32_prot_sonic dut (
        .clk(clk), .rst(rst), .enable(enable),
        .cpu_write(cpu_write), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
        .wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr),
        .wram_wdata(wram_wdata), .wram_be(wram_be), .wram_ack(wram_ack)
    );

    task automatic expect_req(input [15:0] want_addr, input [15:0] want_data, input [255:0] label);
        begin
            if (!wram_req || !wram_we || wram_addr !== want_addr || wram_wdata !== want_data || wram_be !== 2'b11) begin
                $display("FAIL %0s req=%b we=%b addr=%04x data=%04x be=%b", label, wram_req, wram_we, wram_addr, wram_wdata, wram_be);
                $finish(1);
            end
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        rst = 1'b0;

        // Cleared-level index 9 maps to final stage ID 0x10.
        @(negedge clk);
        cpu_addr = 24'h20e5c4;
        cpu_wdata = 8'h09;
        cpu_write = 1'b1;
        @(posedge clk); #1; cpu_write = 1'b0;
        expect_req(16'h7837, 16'h0010, "level publish");

        @(posedge clk); #1;
        expect_req(16'h785e, 16'h0000, "status zero");
        @(posedge clk); #1;
        expect_req(16'h785f, 16'h0000, "status zero second");
        @(posedge clk); #1;
        if (wram_req) begin
            $display("FAIL protection request did not finish");
            $finish(1);
        end

        // Other writes do not start the responder.
        @(negedge clk);
        cpu_addr = 24'h20e5c6;
        cpu_wdata = 8'h00;
        cpu_write = 1'b1;
        @(posedge clk); #1; cpu_write = 1'b0;
        @(posedge clk); #1;
        if (wram_req) begin
            $display("FAIL protection accepted wrong address");
            $finish(1);
        end

        $display("PASS tb_s32_prot_sonic");
        $finish;
    end
endmodule

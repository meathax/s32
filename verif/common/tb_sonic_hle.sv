`timescale 1ns/1ps

module tb_sonic_hle;
    import s32_pkg::*;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg [6:0] prot_sel = PROT_SONIC;
    reg cpu_wr = 1'b0;
    reg [23:0] cpu_addr = 24'h0;
    reg [15:0] cpu_wdata = 16'h0;
    wire wram_req;
    wire wram_we;
    wire [15:0] wram_addr;
    wire [15:0] wram_wdata;
    wire [1:0] wram_be;
    wire [15:0] wram_rdata = 16'h0;
    wire wram_ack = wram_req;
    wire rom_req;
    wire [23:0] rom_addr;
    wire [15:0] rom_data = 16'h1234;
    wire rom_ack = rom_req;

    s32_prot_hle dut (
        .clk(clk), .rst(rst), .prot_sel(prot_sel),
        .cpu_wr(cpu_wr), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
        .vblank(1'b0),
        .wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr),
        .wram_wdata(wram_wdata), .wram_be(wram_be),
        .wram_rdata(wram_rdata), .wram_ack(wram_ack),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack)
    );

    integer sonic_writes;
    integer sonic_rom_reads;
    integer errors;
    reg saw_zero_level;
    reg saw_zero_status0;
    reg saw_zero_status1;
    reg saw_table_addr;
    reg saw_table_level;

    always @(negedge clk) begin
        #1;
        if (!rst) begin
            if (rom_req) begin
                sonic_rom_reads = sonic_rom_reads + 1;
                if (rom_addr == 24'h00263a) saw_table_addr = 1'b1;
                else begin
                    $display("FAIL: table address=%06x expected=00263a", rom_addr);
                    errors = errors + 1;
                end
            end
            if (wram_req && wram_we) begin
                sonic_writes = sonic_writes + 1;
                if (wram_addr == 16'h7837 && wram_wdata == 16'h0007)
                    saw_zero_level = 1'b1;
                if (wram_addr == 16'h7837 && wram_wdata == 16'h1234)
                    saw_table_level = 1'b1;
                if (wram_addr == 16'h785e && wram_wdata == 16'h0000)
                    saw_zero_status0 = 1'b1;
                if (wram_addr == 16'h785f && wram_wdata == 16'h0000)
                    saw_zero_status1 = 1'b1;
                if (wram_addr != 16'h7837 && wram_addr != 16'h785e &&
                    wram_addr != 16'h785f) begin
                    $display("FAIL: unexpected Sonic HLE write addr=%04x data=%04x",
                             wram_addr, wram_wdata);
                    errors = errors + 1;
                end
            end
        end

    end
    task automatic trigger(input [15:0] value);
        begin
            @(negedge clk);
            cpu_addr = 24'h20e5c4;
            cpu_wdata = value;
            cpu_wr = 1'b1;
            @(negedge clk);
            cpu_wr = 1'b0;
            cpu_addr = 24'h0;
            cpu_wdata = 16'h0;
        end
    endtask

    initial begin
        sonic_writes = 0;
        sonic_rom_reads = 0;
        errors = 0;
        saw_zero_level = 1'b0;
        saw_zero_status0 = 1'b0;
        saw_zero_status1 = 1'b0;
        saw_table_addr = 1'b0;
        saw_table_level = 1'b0;

        repeat (3) @(negedge clk);
        rst = 1'b0;

        trigger(16'h0000);
        repeat (8) @(negedge clk);
        trigger(16'h0001);
        repeat (12) @(negedge clk);

        if (sonic_writes != 6) begin
            $display("FAIL: expected three writes for each Sonic trigger, got %0d", sonic_writes);
            errors = errors + 1;
        end
        if (sonic_rom_reads != 1) begin
            $display("FAIL: expected one Sonic table read, got %0d", sonic_rom_reads);
            errors = errors + 1;
        end
        if (errors != 0)
            $fatal(1, "Sonic HLE regression failed with %0d errors", errors);
        $display("SONIC HLE PASS writes=%0d rom_reads=%0d", sonic_writes, sonic_rom_reads);
        $finish;
    end
endmodule

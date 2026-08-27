// Focused contract test for Burning Rival's ROM-string protection copy.
`timescale 1ns/1ps

module tb_brival_protection;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg enable = 1'b1;
    reg cpu_wr = 1'b0;
    reg [23:0] cpu_addr = 24'h0;
    reg [15:0] cpu_wdata = 16'h0;
    reg cpu_rd = 1'b0;
    reg [1:0] cpu_be = 2'b11;
    wire trap_active;
    wire [15:0] trap_data;
    wire pram_we;
    wire [7:0] pram_addr;
    wire [7:0] pram_wdata;
    wire rom_req;
    wire [23:0] rom_addr;
    wire rom_ack = rom_req;
    wire [15:0] rom_data = {rom_byte({rom_addr[23:1], 1'b1}),
                            rom_byte({rom_addr[23:1], 1'b0})};

    function automatic [7:0] rom_byte(input [23:0] a);
        rom_byte = {4'h0, a[3:0]};
    endfunction

    s32_prot_brival dut (
        .clk(clk), .rst(rst), .enable(enable),
        .cpu_wr(cpu_wr), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
        .cpu_rd(cpu_rd), .cpu_be(cpu_be),
        .trap_active(trap_active), .trap_data(trap_data),
        .pram_we(pram_we), .pram_addr(pram_addr), .pram_wdata(pram_wdata),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack)
    );

    integer errors = 0;
    integer writes = 0;

    always @(posedge clk) begin
        #1;
        if (!rst && pram_we) begin
            if (pram_addr !== writes[7:0]) begin
                $display("FAIL Brival pram address=%02x expected=%02x",
                         pram_addr, writes[7:0]);
                errors = errors + 1;
            end
            if (pram_wdata !== {4'h0, (4'h7 + writes[3:0])}) begin
                $display("FAIL Brival byte[%0d]=%02x expected nibble sequence",
                         writes, pram_wdata);
                errors = errors + 1;
            end
            writes = writes + 1;
        end
    end

    initial begin
        repeat (2) @(posedge clk);
        rst = 1'b0;

        // MAME brival_protection_w offset 0x800/2 selects ROM 0x109517.
        cpu_addr = 24'hA00800;
        cpu_wr = 1'b1;
        @(posedge clk); #1;
        cpu_wr = 1'b0;

        repeat (80) @(posedge clk);

        if (writes != 16) begin
            $display("FAIL Brival copied %0d bytes expected 16", writes);
            errors = errors + 1;
        end

        // MAME installs this handler for full-word reads only.  Byte reads
        // must fall through to the normal protection/work-RAM path.
        cpu_addr = 24'h20BA04;
        cpu_be = 2'b11;
        cpu_rd = 1'b1;
        @(posedge clk); #1;
        if (!trap_active || trap_data !== 16'h0000) begin
            $display("FAIL Brival word read trap active=%b data=%04x",
                     trap_active, trap_data);
            errors = errors + 1;
        end
        cpu_be = 2'b01;
        @(posedge clk); #1;
        if (trap_active) begin
            $display("FAIL Brival byte read incorrectly trapped");
            errors = errors + 1;
        end
        cpu_rd = 1'b0;

        if (errors == 0) $display("BRIVAL PROTECTION PASS");
        else $fatal(1, "Brival protection failed (%0d errors)", errors);
        $finish;
    end
endmodule

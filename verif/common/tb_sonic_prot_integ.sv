`timescale 1ns/1ps
// SegaSonic level-load protection wired the way s32_core wires it: the real
// s32_ga_rom_cache protected-ROM client and the real work-RAM second port.
//
// The point of this bench is the two things a state-machine-only test cannot
// check -- that the cache's protected-read lane order really does put the even
// ROM byte in the low half of prot_data, and that the counter read-back on the
// work-RAM second port returns the word the CPU port stored.
//
// Reference stage ids come from MAME's sonic_level_load_protection running on
// epr-15787c.ic17: cleared 0 -> 0007, 1 -> 0006, 2 -> 0005, 9 -> 000c.
module tb_sonic_prot_integ;
    localparam integer WRAM_ADDR_WIDTH = 15;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ------------------------------------------------------------------
    // Main-ROM image: only the level-order table region is populated. Bytes
    // are packed little-endian into 64-bit lines, the same packing the V60
    // instruction fetch relies on.
    // ------------------------------------------------------------------
    reg [7:0] rom_image [0:'h3000-1];

    wire        rom_req;
    wire        rom_burst;
    wire [23:1] rom_line_addr;
    reg  [63:0] sdram_dout;
    reg         sdram_ack;
    integer     sd_i;
    reg  [23:0] sd_base;

    always @(posedge clk) begin
        sdram_ack <= 1'b0;
        if (rom_req) begin
            sd_base = {rom_line_addr, 1'b0};
            for (sd_i = 0; sd_i < 8; sd_i = sd_i + 1)
                sdram_dout[sd_i*8 +: 8] <= rom_image[sd_base + sd_i];
            sdram_ack <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Protected-ROM client port of the production cache.
    // ------------------------------------------------------------------
    wire        prot_rom_req;
    wire [20:0] prot_rom_addr;
    wire [15:0] prot_rom_data;
    wire        prot_rom_ack;

    s32_ga_rom_cache cache (
        .clk(clk), .rst(rst), .invalidate(1'b0),
        .if_req(1'b0), .if_line_addr(18'd0), .if_offset(3'd0),
        .if_data(), .if_ack(),
        .data_req(1'b0), .data_addr(21'd0), .data_data(), .data_ack(),
        .prot_req(prot_rom_req), .prot_addr(prot_rom_addr),
        .prot_data(prot_rom_data), .prot_ack(prot_rom_ack),
        .rom_req(rom_req), .rom_burst(rom_burst), .rom_addr(rom_line_addr),
        .rom_data(sdram_dout), .rom_ack(sdram_ack)
    );

    // ------------------------------------------------------------------
    // Work RAM: port A is the CPU, port B is the protection device, exactly
    // as s32_core connects them.
    // ------------------------------------------------------------------
    reg  [WRAM_ADDR_WIDTH-1:0] cpu_a = '0;
    reg  [15:0] cpu_d = 16'h0000;
    reg         cpu_we = 1'b0;

    wire        pr_req, pr_we;
    wire [15:0] pr_addr, pr_wdata;
    wire  [1:0] pr_be;
    wire [15:0] pr_q;
    reg         pr_ack;
    always @(posedge clk) pr_ack <= pr_req;

    s32_big_dpram #(.ADDR_WIDTH(WRAM_ADDR_WIDTH), .NUM_WORDS(32768)) work_ram (
        .clock_a(clk), .address_a(cpu_a), .data_a(cpu_d),
        .byteena_a(2'b11), .wren_a(cpu_we), .q_a(),
        .clock_b(clk), .address_b(pr_addr[WRAM_ADDR_WIDTH-1:0]),
        .data_b(pr_wdata), .byteena_b(pr_be),
        .wren_b(pr_req && pr_we), .q_b(pr_q)
    );

    reg cpu_write = 1'b0;
    reg [23:0] cpu_addr = 24'd0;

    s32_prot_sonic dut (
        .clk(clk), .rst(rst), .enable(1'b1),
        .cpu_write(cpu_write), .cpu_addr(cpu_addr),
        .rom_req(prot_rom_req), .rom_addr(prot_rom_addr),
        .rom_data(prot_rom_data), .rom_ack(prot_rom_ack),
        .wram_req(pr_req), .wram_we(pr_we), .wram_addr(pr_addr),
        .wram_wdata(pr_wdata), .wram_be(pr_be),
        .wram_rdata(pr_q), .wram_ack(pr_ack)
    );

    // Observe what the device publishes at 0x20f06e / 0x20f0bc / 0x20f0be.
    reg [15:0] pub_level = 16'hxxxx;
    integer    pub_status = 0;
    always @(posedge clk) begin
        if (pr_req && pr_we) begin
            if (pr_addr == (16'hf06e >> 1)) pub_level <= pr_wdata;
            if ((pr_addr == (16'hf0bc >> 1) || pr_addr == (16'hf0be >> 1)) &&
                pr_wdata == 16'h0000)
                pub_status <= pub_status + 1;
        end
    end

    integer i;

    // Store the counter through the CPU port, then pulse the accepted-write
    // strobe the core derives from wr_stb.
    task automatic clear_and_run(input [15:0] cleared, input [15:0] want);
        begin
            pub_level  = 16'hxxxx;
            pub_status = 0;
            @(negedge clk);
            cpu_a  = 16'he5c4 >> 1;
            cpu_d  = cleared;
            cpu_we = 1'b1;
            @(negedge clk);
            cpu_we = 1'b0;
            cpu_addr  = 24'h20e5c4;
            cpu_write = 1'b1;
            @(negedge clk);
            cpu_write = 1'b0;

            repeat (200) @(posedge clk);

            if (pub_level !== want) begin
                $display("FAIL cleared=%0d published %04x, want %04x",
                         cleared, pub_level, want);
                $finish(1);
            end
            if (pub_status != 2) begin
                $display("FAIL cleared=%0d status clears=%0d, want 2",
                         cleared, pub_status);
                $finish(1);
            end
        end
    endtask

    initial begin
        for (i = 0; i < 'h3000; i = i + 1) rom_image[i] = 8'h00;
        // epr-15787c.ic17 bytes 0x2638..0x265b, high byte first per entry.
        rom_image['h2638] = 8'hff; rom_image['h2639] = 8'h07;
        rom_image['h263a] = 8'h00; rom_image['h263b] = 8'h06;
        rom_image['h263c] = 8'h00; rom_image['h263d] = 8'h05;
        rom_image['h263e] = 8'h00; rom_image['h263f] = 8'h08;
        rom_image['h2640] = 8'h00; rom_image['h2641] = 8'h09;
        rom_image['h2642] = 8'h00; rom_image['h2643] = 8'h0a;
        rom_image['h2644] = 8'h00; rom_image['h2645] = 8'h03;
        rom_image['h2646] = 8'h00; rom_image['h2647] = 8'h04;
        rom_image['h2648] = 8'h00; rom_image['h2649] = 8'h10;
        rom_image['h264a] = 8'h00; rom_image['h264b] = 8'h0c;
        rom_image['h264c] = 8'h00; rom_image['h264d] = 8'h0d;
        rom_image['h264e] = 8'h00; rom_image['h264f] = 8'h0e;
        rom_image['h2650] = 8'h00; rom_image['h2651] = 8'h0f;
        rom_image['h2652] = 8'h00; rom_image['h2653] = 8'h0b;
        rom_image['h2654] = 8'h00; rom_image['h2655] = 8'h11;
        rom_image['h2656] = 8'h00; rom_image['h2657] = 8'h0a;
        rom_image['h2658] = 8'h00; rom_image['h2659] = 8'h0a;
        rom_image['h265a] = 8'h00; rom_image['h265b] = 8'h02;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // Game start runs the tutorial stage.
        clear_and_run(16'd0, 16'h0007);
        // Finishing the tutorial must advance, not repeat it.
        clear_and_run(16'd1, 16'h0006);
        clear_and_run(16'd2, 16'h0005);
        clear_and_run(16'd3, 16'h0008);
        // Repeat an entry to prove a cache hit takes the same lane order as
        // the miss that filled the line.
        clear_and_run(16'd1, 16'h0006);
        clear_and_run(16'd9, 16'h000c);
        clear_and_run(16'd17, 16'h0002);

        $display("SEGASONIC PROT INTEG PASS");
        $finish;
    end
endmodule

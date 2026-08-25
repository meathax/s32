`timescale 1ns/1ps
// SegaSonic level-load protection device.
//
// The reference vectors are the bytes epr-15787c.ic17 carries at 0x2638 and
// the stage ids MAME's sonic_level_load_protection derives from them:
//   cleared 0 -> 0007 (constant; the entry shares a word with 0xff)
//   cleared 1 -> 0006, 2 -> 0005, 3 -> 0008, 9 -> 000c, 17 -> 0002
module tb_s32_prot_sonic;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg enable = 1'b1;
    reg cpu_write = 1'b0;
    reg [23:0] cpu_addr = 24'd0;

    wire        rom_req;
    wire [20:0] rom_addr;
    wire        wram_req, wram_we;
    wire [15:0] wram_addr, wram_wdata;
    wire [1:0]  wram_be;

    // The protection port acks one cycle after the request, exactly as
    // s32_core's second work-RAM port does.
    reg wram_ack = 1'b0;
    always @(posedge clk) wram_ack <= wram_req;

    // Work RAM model: only the cleared-level counter word is needed.
    reg [15:0] cleared_word = 16'h0000;
    reg [15:0] wram_rdata = 16'h0000;
    always @(posedge clk)
        if (wram_req && !wram_we && wram_addr == (16'he5c4 >> 1))
            wram_rdata <= cleared_word;

    // Main-ROM model: the level-order table bytes at 0x2638, returned in the
    // cache's lane order (even address in the low byte).
    reg [7:0] rom_bytes [0:63];
    reg [15:0] rom_data = 16'hffff;
    reg        rom_ack  = 1'b0;
    always @(posedge clk) begin
        rom_ack <= rom_req;
        if (rom_req) begin
            rom_data <= {rom_bytes[(rom_addr - 21'h2638) + 1],
                         rom_bytes[(rom_addr - 21'h2638)]};
        end
    end

    s32_prot_sonic dut (
        .clk(clk), .rst(rst), .enable(enable),
        .cpu_write(cpu_write), .cpu_addr(cpu_addr),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack),
        .wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr),
        .wram_wdata(wram_wdata), .wram_be(wram_be),
        .wram_rdata(wram_rdata), .wram_ack(wram_ack)
    );

    integer i;
    reg [15:0] seen_level;
    reg [15:0] seen_status [0:1];
    integer    status_seen;

    // Collect what the device publishes for one counter value.
    task automatic run_case(input [15:0] cleared, input [15:0] want_level);
        integer guard;
        begin
            seen_level  = 16'hxxxx;
            status_seen = 0;
            cleared_word = cleared;
            @(negedge clk);
            cpu_addr  = 24'h20e5c4;
            cpu_write = 1'b1;
            @(posedge clk); #1; cpu_write = 1'b0;

            for (guard = 0; guard < 64; guard = guard + 1) begin
                @(posedge clk); #1;
                if (wram_req && wram_we) begin
                    if (wram_addr == (16'hf06e >> 1)) seen_level = wram_wdata;
                    else if (wram_addr == (16'hf0bc >> 1) ||
                             wram_addr == (16'hf0be >> 1)) begin
                        seen_status[status_seen[0]] = wram_wdata;
                        status_seen = status_seen + 1;
                    end
                    if (wram_be !== 2'b11) begin
                        $display("FAIL cleared=%0d byte enables %b", cleared, wram_be);
                        $finish(1);
                    end
                end
            end

            if (seen_level !== want_level) begin
                $display("FAIL cleared=%0d level=%04x want %04x", cleared, seen_level, want_level);
                $finish(1);
            end
            if (status_seen != 2 || seen_status[0] !== 16'h0000 || seen_status[1] !== 16'h0000) begin
                $display("FAIL cleared=%0d status writes=%0d", cleared, status_seen);
                $finish(1);
            end
        end
    endtask

    initial begin
        for (i = 0; i < 64; i = i + 1) rom_bytes[i] = 8'h00;
        // 0x2638: ff 07 (entry 0 overlaps the preceding data word)
        rom_bytes[0] = 8'hff; rom_bytes[1] = 8'h07;
        // 0x263a onwards: the final-game stage order, high byte first.
        rom_bytes[2]  = 8'h00; rom_bytes[3]  = 8'h06; // cleared 1
        rom_bytes[4]  = 8'h00; rom_bytes[5]  = 8'h05; // cleared 2
        rom_bytes[6]  = 8'h00; rom_bytes[7]  = 8'h08; // cleared 3
        rom_bytes[8]  = 8'h00; rom_bytes[9]  = 8'h09; // cleared 4
        rom_bytes[10] = 8'h00; rom_bytes[11] = 8'h0a; // cleared 5
        rom_bytes[12] = 8'h00; rom_bytes[13] = 8'h03; // cleared 6
        rom_bytes[14] = 8'h00; rom_bytes[15] = 8'h04; // cleared 7
        rom_bytes[16] = 8'h00; rom_bytes[17] = 8'h10; // cleared 8
        rom_bytes[18] = 8'h00; rom_bytes[19] = 8'h0c; // cleared 9
        rom_bytes[20] = 8'h00; rom_bytes[21] = 8'h0d; // cleared 10
        rom_bytes[22] = 8'h00; rom_bytes[23] = 8'h0e; // cleared 11
        rom_bytes[24] = 8'h00; rom_bytes[25] = 8'h0f; // cleared 12
        rom_bytes[26] = 8'h00; rom_bytes[27] = 8'h0b; // cleared 13
        rom_bytes[28] = 8'h00; rom_bytes[29] = 8'h11; // cleared 14
        rom_bytes[30] = 8'h00; rom_bytes[31] = 8'h0a; // cleared 15
        rom_bytes[32] = 8'h00; rom_bytes[33] = 8'h0a; // cleared 16
        rom_bytes[34] = 8'h00; rom_bytes[35] = 8'h02; // cleared 17

        repeat (2) @(posedge clk);
        rst = 1'b0;

        // Game start: the tutorial stage.
        run_case(16'd0, 16'h0007);
        // End of the tutorial selects the first real stage, not the tutorial.
        run_case(16'd1, 16'h0006);
        run_case(16'd2, 16'h0005);
        run_case(16'd3, 16'h0008);
        run_case(16'd9, 16'h000c);
        run_case(16'd17, 16'h0002);

        // Other addresses do not start the responder.
        cleared_word = 16'd1;
        @(negedge clk);
        cpu_addr  = 24'h20e5c6;
        cpu_write = 1'b1;
        @(posedge clk); #1; cpu_write = 1'b0;
        repeat (8) begin
            @(posedge clk); #1;
            if (wram_req || rom_req) begin
                $display("FAIL protection accepted wrong address");
                $finish(1);
            end
        end

        $display("PASS tb_s32_prot_sonic");
        $finish;
    end
endmodule

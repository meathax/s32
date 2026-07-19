`timescale 1ns/1ps
`default_nettype none

// Real-firmware smoke test for s32_v25_cpu.  This test loads the raw 64 KiB
// Golden Axe MCU image and performs MAME's destination-to-source address
// descramble, releases the CPU, and observes the mailbox exclusively through the
// V60-side interface.  There are no HLE writes or pre-seeded mailbox bytes.
module tb_v25_firmware;

reg clk = 1'b0;
always #10 clk = ~clk; // 50 MHz functional simulation

reg rst = 1'b1;
reg enable = 1'b0;
reg prg_wr = 1'b0;
reg [15:0] prg_waddr = 16'd0;
reg [7:0] prg_wdata = 8'd0;
reg cs = 1'b0;
reg we = 1'b0;
reg [11:1] addr = 11'd0;
reg [7:0] wdata = 8'd0;
wire [7:0] rdata;
wire debug_cpu_ce;
wire debug_io_seen;
wire [15:0] debug_last_io_addr;
wire debug_unmapped_seen;
wire [19:0] debug_last_unmapped_addr;

s32_v25_cpu dut (
    .clk(clk), .rst(rst), .enable(enable), .table_sel(1'b0),
    .prg_wr(prg_wr), .prg_waddr(prg_waddr), .prg_wdata(prg_wdata),
    .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .debug_cpu_clk(debug_cpu_ce),
    .debug_io_seen(debug_io_seen),
    .debug_last_io_addr(debug_last_io_addr),
    .debug_unmapped_seen(debug_unmapped_seen),
    .debug_last_unmapped_addr(debug_last_unmapped_addr)
);

reg [7:0] raw [0:65535];
integer fd;
integer got;
integer src;
integer cycles;
integer matched;
integer table_matched;
integer ce_pulses;
integer ce_last_cycle;
integer ce_gap;
reg [7:0] observed;

function automatic [15:0] descramble(input [15:0] i);
begin
    descramble = {i[14], i[11], i[15], i[12], i[13], i[4], i[3], i[7],
                  i[5], i[10], i[2], i[8], i[9], i[6], i[1], i[0]};
end
endfunction

function automatic [7:0] wake_byte(input integer i);
begin
    case (i)
         0: wake_byte="w";  1: wake_byte="a";  2: wake_byte="k";
         3: wake_byte="e";  4: wake_byte=" ";  5: wake_byte="u";
         6: wake_byte="p";  7: wake_byte="!";  8: wake_byte=" ";
         9: wake_byte="G"; 10: wake_byte="O"; 11: wake_byte="L";
        12: wake_byte="D"; 13: wake_byte="E"; 14: wake_byte="N";
        15: wake_byte=" "; 16: wake_byte="A"; 17: wake_byte="X";
        18: wake_byte="E"; 19: wake_byte=" "; 20: wake_byte="T";
        21: wake_byte="h"; 22: wake_byte="e"; 23: wake_byte=" ";
        24: wake_byte="R"; 25: wake_byte="e"; 26: wake_byte="v";
        27: wake_byte="e"; 28: wake_byte="n"; 29: wake_byte="g";
        30: wake_byte="e"; 31: wake_byte=" "; 32: wake_byte="o";
        33: wake_byte="f"; 34: wake_byte=" "; 35: wake_byte="D";
        36: wake_byte="e"; 37: wake_byte="a"; 38: wake_byte="t";
        39: wake_byte="h"; 40: wake_byte="-"; 41: wake_byte="A";
        42: wake_byte="d"; 43: wake_byte="d"; 44: wake_byte="e";
        45: wake_byte="r"; 46: wake_byte="!"; 47: wake_byte=" ";
        default: wake_byte=8'h20;
    endcase
end
endfunction

function automatic [7:0] ga2_table_byte(input integer i);
begin
    case (i)
         0: ga2_table_byte = 8'h0a;
         2: ga2_table_byte = 8'hc5;
         4: ga2_table_byte = 8'h11;
         6: ga2_table_byte = 8'h11;
         8: ga2_table_byte = 8'h18;
        10: ga2_table_byte = 8'h18;
        12: ga2_table_byte = 8'h1f;
        14: ga2_table_byte = 8'hc6;
        default: ga2_table_byte = 8'h00;
    endcase
end
endfunction

task automatic v60_read_byte(input integer byte_offset, output [7:0] value);
begin
    @(negedge clk);
    addr = byte_offset[11:1];
    cs = 1'b1;
    we = 1'b0;
    @(posedge clk);
    #1 value = rdata;
    @(negedge clk);
    cs = 1'b0;
end
endtask

task automatic check_wakeup(output integer count);
    integer i;
    reg [7:0] value;
begin
    count = 0;
    for (i = 0; i < 48; i = i + 1) begin
        // One mailbox byte occupies each V60 low-byte word lane.
        v60_read_byte(16'h0100 + (i * 2), value);
        if (value === wake_byte(i)) count = count + 1;
    end
end
endtask

initial begin
    fd = $fopen("roms/sim/ga2/mcu.bin", "rb");
    if (fd == 0) begin
        $display("V25_FIRMWARE FAIL: cannot open roms/sim/ga2/mcu.bin");
        $fatal(1);
    end
    got = $fread(raw, fd);
    $fclose(fd);
    if (got != 65536) begin
        $display("V25_FIRMWARE FAIL: MCU ROM is %0d bytes, expected 65536", got);
        $fatal(1);
    end

    // Keep both clients reset/disabled while filling program RAM.
    repeat (4) @(posedge clk);
    rst = 1'b0;
    for (src = 0; src < 65536; src = src + 1) begin
        @(negedge clk);
        prg_wr    = 1'b1;
        // MAME: descrambled[dst] = raw[bitswap(dst)].
        prg_waddr = src[15:0];
        prg_wdata = raw[descramble(src[15:0])];
    end
    @(negedge clk);
    prg_wr = 1'b0;

    // Verify the encrypted reset-vector byte is the expected table index.
    // ga2 table entry 02h translates to the far-jump opcode EAh.
    if (dut.program_rom.mem[16'hfff0] !== 8'h02) begin
        $display("V25_FIRMWARE FAIL: reset byte %02x, expected encrypted 02",
                 dut.program_rom.mem[16'hfff0]);
        $fatal(1);
    end

    @(negedge clk);
    enable = 1'b1;

    // One reduced accumulator period must contain exactly 2500 enables.
    // Consecutive virtual CPU edges are four or five clk_sys periods apart.
    ce_pulses = 0;
    ce_last_cycle = -1;
    for (cycles = 0; cycles < 12081; cycles = cycles + 1) begin
        @(negedge clk);
        if (debug_cpu_ce) begin
            if (ce_last_cycle >= 0) begin
                ce_gap = cycles - ce_last_cycle;
                if (ce_gap != 4 && ce_gap != 5) begin
                    $display("V25_FIRMWARE FAIL: CE gap=%0d expected 4 or 5", ce_gap);
                    $fatal(1);
                end
            end
            ce_last_cycle = cycles;
            ce_pulses = ce_pulses + 1;
        end
    end
    if (ce_pulses != 2500) begin
        $display("V25_FIRMWARE FAIL: CE pulses=%0d expected 2500/12081", ce_pulses);
        $fatal(1);
    end
    $display("V25_FIRMWARE CE: PASS (2500/12081, gaps 4 or 5)");

    // Poll in blocks rather than continuously occupying the V60 port.  The
    // 50 MHz test clock gives a 10.347 MHz virtual CPU; two million clk_sys
    // periods are ample for genuine firmware initialization and greeting.
    matched = 0;
    for (cycles = 0; cycles < 2000000 && matched != 48; cycles = cycles + 5000) begin
        repeat (5000) @(posedge clk);
        check_wakeup(matched);
        if ((cycles % 100000) == 0)
            $display("V25_FIRMWARE progress cycles=%0d wake_match=%0d/48", cycles, matched);
    end

    if (matched != 48) begin
        v60_read_byte(16'h0100, observed);
        $display("V25_FIRMWARE FAIL: wake mailbox matched %0d/48; byte100=%02x", matched, observed);
        $display("V25_FIRMWARE trace: io_seen=%0d last_io=%04x unmapped=%0d last_mem=%05x",
                 debug_io_seen, debug_last_io_addr,
                 debug_unmapped_seen, debug_last_unmapped_addr);
        $fatal(1);
    end

    // The greeting precedes the final table entries.  Poll the asynchronous
    // mailbox protocol with a bounded timeout instead of assuming a delay.
    table_matched = 0;
    for (cycles = 0; cycles < 100000 && table_matched != 16; cycles = cycles + 100) begin
        repeat (100) @(posedge clk);
        table_matched = 0;
        for (src = 0; src < 16; src = src + 1) begin
            v60_read_byte(src * 2, observed);
            if (observed === ga2_table_byte(src))
                table_matched = table_matched + 1;
        end
    end
    if (table_matched != 16) begin
        $display("V25_FIRMWARE FAIL: protection table matched %0d/16", table_matched);
        $fatal(1);
    end
    v60_read_byte(16'h0ffc, observed); // mailbox byte 7fe
    if (observed !== 8'h22) begin
        $display("V25_FIRMWARE FAIL: stack[7fe]=%02x expected 22", observed);
        $fatal(1);
    end
    v60_read_byte(16'h0ffe, observed); // mailbox byte 7ff
    if (observed !== 8'h04) begin
        $display("V25_FIRMWARE FAIL: stack[7ff]=%02x expected 04", observed);
        $fatal(1);
    end

    // MAME's GA2 firmware trace performs no I/O cycles and never leaves the
    // two mapped memory windows.  Treat either event as a decode/control-flow
    // failure rather than merely printing it after an otherwise passing run.
    if (debug_io_seen || debug_unmapped_seen) begin
        $display("V25_FIRMWARE FAIL: unexpected bus access io_seen=%0d last_io=%04x unmapped=%0d last_mem=%05x",
                 debug_io_seen, debug_last_io_addr,
                 debug_unmapped_seen, debug_last_unmapped_addr);
        $fatal(1);
    end

    $display("V25_FIRMWARE PASS: genuine GA2 firmware wrote wake-up, table, and stack state");
    $display("V25_FIRMWARE trace: io_seen=%0d last_io=%04x unmapped=%0d last_mem=%05x",
             debug_io_seen, debug_last_io_addr,
             debug_unmapped_seen, debug_last_unmapped_addr);
    $finish;
end

endmodule

`default_nettype wire


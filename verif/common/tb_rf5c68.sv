`timescale 1ns/1ps

module tb_rf5c68;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        ce    = 1'b0;
    reg        rst   = 1'b1;
    reg        cs    = 1'b0;
    reg        we    = 1'b0;
    reg [12:0] addr  = 13'd0;
    reg  [7:0] wdata = 8'd0;
    wire [7:0] rdata;
    wire signed [15:0] out_l;
    wire signed [15:0] out_r;

    s32_rf5c68 dut (
        .clk(clk), .ce(ce), .rst(rst),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
        .out_l(out_l), .out_r(out_r)
    );

    integer cycles = 0;
    always @(posedge clk) begin
        if (rst) cycles <= 0;
        else     cycles <= cycles + 1;
    end

    task automatic write_reg(input [3:0] reg_addr, input [7:0] data);
        begin
            @(negedge clk);
            cs    = 1'b1;
            we    = 1'b1;
            addr  = {9'd0, reg_addr};
            wdata = data;
            @(posedge clk);
            #1;
            @(negedge clk);
            cs    = 1'b0;
            we    = 1'b0;
            addr  = 13'd0;
            wdata = 8'd0;
        end
    endtask

    task automatic write_ram(input [11:0] ram_addr, input [7:0] data);
        begin
            @(negedge clk);
            cs    = 1'b1;
            we    = 1'b1;
            addr  = {1'b1, ram_addr};
            wdata = data;
            @(posedge clk);
            #1;
            @(negedge clk);
            cs    = 1'b0;
            we    = 1'b0;
            addr  = 13'd0;
            wdata = 8'd0;
        end
    endtask

    task automatic select_read(input [11:0] ram_addr);
        begin
            @(negedge clk);
            cs   = 1'b1;
            we   = 1'b0;
            addr = {1'b1, ram_addr};
        end
    endtask

    task automatic configure_voice(
        input [2:0] voice,
        input [7:0] start_page,
        input [15:0] loop_addr
    );
        begin
            // bit 6 selects the channel register bank; bit 7 remains clear so
            // voices cannot run while the directed setup is in progress.
            write_reg(4'h7, {1'b0, 1'b1, 3'b000, voice});
            write_reg(4'h0, 8'd32);      // ENV; with PAN=1 this preserves mag
            write_reg(4'h1, 8'h11);      // equal one-unit left/right pan
            write_reg(4'h2, 8'h00);
            write_reg(4'h3, 8'h08);      // FD=0x0800: advance exactly one byte
            write_reg(4'h4, loop_addr[7:0]);
            write_reg(4'h5, loop_addr[15:8]);
            write_reg(4'h6, start_page);
        end
    endtask

    integer timeout;
    integer first_frame_cycle;
    integer second_frame_cycle;

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // ------------------------------------------------------------------
        // Z80 port: bank selection, writes, and a one-clock registered read.
        // ------------------------------------------------------------------
        write_reg(4'h7, 8'h02);           // disabled, wave bank 2
        write_ram(12'h123, 8'h5a);
        write_ram(12'h124, 8'ha5);

        select_read(12'h124);
        @(posedge clk);
        #1;
        if (rdata !== 8'ha5)
            $fatal(1, "Z80 RAM prime read failed: %02x", rdata);

        @(negedge clk);
        addr = {1'b1, 12'h123};
        #1;
        if (rdata !== 8'ha5)
            $fatal(1, "Z80 RAM read changed before the sampling edge: %02x", rdata);
        @(posedge clk);
        #1;
        if (rdata !== 8'h5a)
            $fatal(1, "Z80 RAM registered read failed: %02x", rdata);

        @(negedge clk);
        addr = 13'h0000;
        @(posedge clk);
        #1;
        if (rdata !== 8'hff)
            $fatal(1, "RF5C68 register read must return ff: %02x", rdata);
        @(negedge clk);
        cs = 1'b0;

        // ------------------------------------------------------------------
        // Three active voices exercise a normal sample, marker/loop fetch,
        // and the last channel.  A second byte at each live address makes the
        // following frame deterministic for the cadence check.
        // ------------------------------------------------------------------
        write_reg(4'h7, 8'h00);           // disabled, wave bank 0
        write_ram(12'h000, 8'h81);        // ch0: +1, normal
        write_ram(12'h001, 8'h81);
        write_ram(12'h100, 8'hff);        // ch1: marker
        write_ram(12'h200, 8'h83);        // loop target: +3
        write_ram(12'h201, 8'h83);
        write_ram(12'h700, 8'h87);        // ch7: +7
        write_ram(12'h701, 8'h87);

        configure_voice(3'd0, 8'h00, 16'h0000);
        configure_voice(3'd1, 8'h01, 16'h0200);
        configure_voice(3'd7, 8'h07, 16'h0000);
        write_reg(4'h8, 8'h7c);           // active-low: enable ch0, ch1, ch7
        write_reg(4'h7, 8'h80);           // global enable, wave bank 0

        if (dut.caddr[0] !== 27'h0000000 ||
            dut.caddr[1] !== 27'h0080000 ||
            dut.caddr[7] !== 27'h0380000)
            $fatal(1, "start-address reload behavior is wrong");

        @(negedge clk);
        ce = 1'b1;

        // Normal ch0 fetch: one byte of FD advance and one unit accumulated.
        timeout = 0;
        while ((dut.caddr[0] !== 27'h0000800) && (timeout < 16)) begin
            @(posedge clk); #1;
            timeout = timeout + 1;
        end
        if (dut.caddr[0] !== 27'h0000800)
            $fatal(1, "normal sample did not retire");
        if (dut.acc_l !== 16'sd1 || dut.acc_r !== 16'sd1 || dut.ch !== 3'd1)
            $fatal(1, "normal sample/channel sequencing wrong: acc=%0d/%0d ch=%0d",
                   dut.acc_l, dut.acc_r, dut.ch);

        // Ch1's marker must cause a second synchronous read.  MAME advances
        // from the loop target after consuming its non-FF sample.
        timeout = 0;
        while ((dut.caddr[1] !== 27'h0100800) && (timeout < 80)) begin
            @(posedge clk); #1;
            timeout = timeout + 1;
        end
        if (dut.caddr[1] !== 27'h0100800)
            $fatal(1, "loop target was not fetched/advanced: %07x", dut.caddr[1]);
        if (dut.acc_l !== 16'sd4 || dut.acc_r !== 16'sd4 || dut.ch !== 3'd2)
            $fatal(1, "loop sample/channel sequencing wrong: acc=%0d/%0d ch=%0d",
                   dut.acc_l, dut.acc_r, dut.ch);
        if (out_l !== 16'sd0 || out_r !== 16'sd0)
            $fatal(1, "output committed before channel 7");

        // Ch7 must be included in the same frame (the former RTL dropped it).
        timeout = 0;
        while ((dut.caddr[7] !== 27'h0380800) && (timeout < 360)) begin
            @(posedge clk); #1;
            timeout = timeout + 1;
        end
        if (dut.caddr[7] !== 27'h0380800)
            $fatal(1, "channel 7 sample did not retire");
        first_frame_cycle = cycles;
        if (out_l !== 16'sd11 || out_r !== 16'sd11)
            $fatal(1, "frame mix must include ch0+ch1+ch7 (11), got %0d/%0d",
                   out_l, out_r);
        if (dut.acc_l !== 16'sd0 || dut.acc_r !== 16'sd0 || dut.ch !== 3'd0)
            $fatal(1, "frame accumulator/channel wrap wrong");

        // The RAM pipeline adds only intra-slot latency.  Consecutive frame
        // commits remain exactly 8*48 = 384 CE ticks apart.
        timeout = 0;
        while ((dut.caddr[7] !== 27'h0381000) && (timeout < 400)) begin
            @(posedge clk); #1;
            timeout = timeout + 1;
        end
        if (dut.caddr[7] !== 27'h0381000)
            $fatal(1, "second channel-7 sample did not retire");
        second_frame_cycle = cycles;
        if ((second_frame_cycle - first_frame_cycle) != 384)
            $fatal(1, "playback cadence changed: %0d clocks",
                   second_frame_cycle - first_frame_cycle);
        if (out_l !== 16'sd11 || out_r !== 16'sd11)
            $fatal(1, "second frame mix wrong: %0d/%0d", out_l, out_r);

        $display("RF5C68 PASS");
        $finish;
    end
endmodule

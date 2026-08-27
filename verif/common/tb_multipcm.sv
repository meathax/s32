`timescale 1ns/1ps

module tb_multipcm;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg ce = 1'b0;
    always @(posedge clk)
        ce <= ~ce;

    reg rst = 1'b1;
    reg cs = 1'b0;
    reg we = 1'b0;
    reg [1:0] addr = 0;
    reg [7:0] wdata = 0;
    wire rom_req;
    wire [21:0] rom_addr;
    reg [7:0] rom_data = 0;
    reg rom_ack = 1'b0;
    wire signed [15:0] out_l;
    wire signed [15:0] out_r;

    reg request_seen = 1'b0;
    reg first_descriptor_seen = 1'b0;
    integer timeout;

    s32_multipcm dut (
        .clk(clk), .ce(ce), .rst(rst),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack),
        .bank_lo(3'd0), .bank_hi(3'd0),
        .out_l(out_l), .out_r(out_r)
    );

    function automatic [7:0] rom_byte(input [21:0] a);
        reg [3:0] di;
    begin
        // Descriptor for 9-bit sample 0x102 begins at 0x0c18.
        if (a >= 22'h000c18 && a < 22'h000c24) begin
            di = a[3:0] - 4'h8;
            case (di)
                0: rom_byte = 8'h00; // start = 000100, 8-bit format
                1: rom_byte = 8'h01;
                2: rom_byte = 8'h00;
                3: rom_byte = 8'h00; // loop = 1
                4: rom_byte = 8'h01;
                5: rom_byte = 8'hff; // end = 0x10000-fffc = 4
                6: rom_byte = 8'hfc;
                7: rom_byte = 8'h1a; // default pitch LFO
                8: rom_byte = 8'hf0;
                9: rom_byte = 8'h00;
               10: rom_byte = 8'h0f; // release F: immediate key-off
               11: rom_byte = 8'h05; // default amplitude LFO
              default: rom_byte = 8'h00;
            endcase
        end
        else if (a >= 22'h000100 && a < 22'h000104)
            rom_byte = 8'h80; // signed minimum, catches offset-binary conversion
        else
            rom_byte = 8'h00;
    end
    endfunction

    // Drive the one-clock response at the falling edge after a CE launches a
    // request.  The DUT therefore observes rom_ack on an edge where ce=0,
    // proving that a short memory response cannot be lost between audio CEs.
    always @(negedge clk) begin
        rom_ack <= 1'b0;
        if (rom_req && !request_seen) begin
            rom_data <= rom_byte(rom_addr);
            rom_ack <= 1'b1;
            request_seen <= 1'b1;
            if (!first_descriptor_seen) begin
                if (rom_addr !== 22'h000c18)
                    $fatal(1, "descriptor address %h, expected sample 102 * 12 = 0c18", rom_addr);
                first_descriptor_seen <= 1'b1;
            end
        end
        if (!rom_req)
            request_seen <= 1'b0;
    end

    task automatic write_port(input [1:0] port, input [7:0] value);
    begin
        @(negedge clk);
        cs = 1'b1;
        we = 1'b1;
        addr = port;
        wdata = value;
        @(posedge clk);
        #1;
        @(negedge clk);
        cs = 1'b0;
        we = 1'b0;
    end
    endtask

    task automatic select_reg(input [7:0] value);
    begin
        write_port(2, value);
    end
    endtask

    task automatic write_data(input [7:0] value);
    begin
        write_port(0, value);
    end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Selector 7 is a hole and must not alias channel zero.
        write_port(1, 8'd7);
        select_reg(0);
        write_data(8'hf0);
        if (dut.sreg[0][0] !== 8'h00)
            $fatal(1, "invalid slot selector aliased channel zero");

        // Raw selector 8 maps to logical channel 7, not channel 8.
        write_port(1, 8'd8);
        select_reg(0);
        write_data(8'ha0);
        if (dut.sreg[7][0] !== 8'ha0 || dut.sreg[8][0] !== 8'h00)
            $fatal(1, "VALUE_TO_CHANNEL mapping is incorrect");

        // Register addresses above seven clamp to seven, matching MAME.
        write_port(1, 8'd0);
        select_reg(8'hff);
        write_data(8'h33);
        if (dut.sreg[0][7] !== 8'h33 || dut.sreg[0][0] !== 8'h00)
            $fatal(1, "register selector did not clamp to seven");

        // Reg2 bit zero supplies sample-index bit eight. A reg1 write loads
        // metadata immediately but does not start a key-off voice.
        select_reg(2);
        write_data(8'h01);
        select_reg(1);
        write_data(8'h02);
        timeout = 0;
        while ((dut.df_busy || dut.desc_pending != 0) && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 1000) $fatal(1, "descriptor fetch timeout");
        if (!first_descriptor_seen) $fatal(1, "descriptor request missing");
        if (dut.s_start[0] !== 22'h000100 || dut.s_loop[0] !== 16'h0001 ||
            dut.s_end[0] !== 17'h00004)
            $fatal(1, "descriptor fields decoded incorrectly");
        if (dut.sreg[0][6] !== 8'h1a || dut.sreg[0][7] !== 8'h05)
            $fatal(1, "descriptor LFO defaults were not copied");
        if (dut.s_active[0]) $fatal(1, "sample-register write started key-off voice");

        // MAME's octave convention makes octave zero half a sample/frame and
        // octave one exactly one sample/frame at pitch zero.
        if (dut.pitch_step(4'h0, 10'h000) !== 25'h08000 ||
            dut.pitch_step(4'h1, 10'h000) !== 25'h10000)
            $fatal(1, "pitch step/octave convention incorrect");

        // Pan 8 mutes both outputs; lower pans attenuate left, upper pans
        // attenuate right. These assertions catch the historical swap.
        if (dut.pan_sample(16'sh4000, 4'h8, 1'b1) !== 0 ||
            dut.pan_sample(16'sh4000, 4'h8, 1'b0) !== 0 ||
            dut.pan_sample(16'sh4000, 4'h1, 1'b1) !== 16'sh2000 ||
            dut.pan_sample(16'sh4000, 4'h1, 1'b0) !== 16'sh4000 ||
            dut.pan_sample(16'sh4000, 4'h9, 1'b1) !== 16'sh4000 ||
            dut.pan_sample(16'sh4000, 4'h9, 1'b0) !== 0)
            $fatal(1, "pan direction/mute semantics incorrect");

        // Key-on reloads current metadata then starts at offset zero.
        select_reg(4);
        write_data(8'h80);
        timeout = 0;
        while (!dut.s_active[0] && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 1000) $fatal(1, "key-on descriptor/retrigger timeout");

        // Signed ROM byte 80h must produce negative stereo output.
        timeout = 0;
        while ((out_l >= 0 || out_r >= 0) && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 2000)
            $fatal(1, "signed PCM mix missing: %0d/%0d", out_l, out_r);

        // Descriptor release=F makes key-off immediate in MAME.
        select_reg(4);
        write_data(8'h00);
        @(posedge clk);
        if (dut.s_active[0]) $fatal(1, "key-off did not stop release-F voice");

        $display("MULTIPCM PASS");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "MULTIPCM timeout");
    end
endmodule

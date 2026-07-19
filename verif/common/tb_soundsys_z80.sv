`timescale 1ns/1ps

// Mixed-language integration test: the production T80 executes a tiny sound
// ROM, writes the System 32 RF5C68 through the real bus decode, and produces
// a stable PCM sample. This closes the behavioral-Z80-stub coverage gap.
module tb_soundsys_z80;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    wire        zrom_req;
    wire [23:0] zrom_addr;
    reg  [15:0] zrom_data = 16'h0000;
    reg         zrom_ack  = 1'b0;
    wire signed [15:0] audio_l, audio_r;

    reg [7:0] rom [0:65535];
    integer i;
    integer timeout;

    s32_soundsys #(.SYSTEM32_ONLY(1'b1)) dut (
        .clk(clk), .ce_z80(1'b1), .ce_fm(1'b0), .ce_pcm(1'b1),
        .rst(rst), .z80_reset(1'b0), .is_multi32(1'b0),
        .sh_cs(1'b0), .sh_we(1'b0), .sh_addr(13'd0), .sh_wdata(8'd0),
        .sh_rdata(), .v60_doorbell(1'b0), .irq_to_v60(),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr),
        .zrom_data(zrom_data), .zrom_ack(zrom_ack),
        .mpcm_req(), .mpcm_addr(), .mpcm_data(8'd0), .mpcm_ack(1'b0),
        .audio_l(audio_l), .audio_r(audio_r)
    );

    // One-cycle SDRAM response. The sound subsystem performs the byte select
    // from this little-endian 16-bit word and holds WAIT_n until it is cached.
    always @(posedge clk) begin
        zrom_ack <= zrom_req;
        if (zrom_req)
            zrom_data <= {rom[zrom_addr + 1'b1], rom[zrom_addr]};
    end

    initial begin
        for (i = 0; i < 65536; i = i + 1) rom[i] = 8'h00;

        // Z80 program:
        //   select wave bank 0; write +1,+1,loop-marker at 0000..0002
        //   configure channel 0 at full ENV/PAN, FD=0800, loop/start=0000
        //   enable channel and chip; spin forever
        rom[ 0]=8'h3e; rom[ 1]=8'h00;
        rom[ 2]=8'h32; rom[ 3]=8'h07; rom[ 4]=8'hc0;
        rom[ 5]=8'h3e; rom[ 6]=8'h81;
        rom[ 7]=8'h32; rom[ 8]=8'h00; rom[ 9]=8'hd0;
        rom[10]=8'h3e; rom[11]=8'h81;
        rom[12]=8'h32; rom[13]=8'h01; rom[14]=8'hd0;
        rom[15]=8'h3e; rom[16]=8'hff;
        rom[17]=8'h32; rom[18]=8'h02; rom[19]=8'hd0;
        rom[20]=8'h3e; rom[21]=8'h40;
        rom[22]=8'h32; rom[23]=8'h07; rom[24]=8'hc0;
        rom[25]=8'h3e; rom[26]=8'hff;
        rom[27]=8'h32; rom[28]=8'h00; rom[29]=8'hc0;
        rom[30]=8'h3e; rom[31]=8'hff;
        rom[32]=8'h32; rom[33]=8'h01; rom[34]=8'hc0;
        rom[35]=8'h3e; rom[36]=8'h00;
        rom[37]=8'h32; rom[38]=8'h02; rom[39]=8'hc0;
        rom[40]=8'h3e; rom[41]=8'h08;
        rom[42]=8'h32; rom[43]=8'h03; rom[44]=8'hc0;
        rom[45]=8'h3e; rom[46]=8'h00;
        rom[47]=8'h32; rom[48]=8'h04; rom[49]=8'hc0;
        rom[50]=8'h32; rom[51]=8'h05; rom[52]=8'hc0;
        rom[53]=8'h32; rom[54]=8'h06; rom[55]=8'hc0;
        rom[56]=8'h3e; rom[57]=8'hfe;
        rom[58]=8'h32; rom[59]=8'h08; rom[60]=8'hc0;
        rom[61]=8'h3e; rom[62]=8'h80;
        rom[63]=8'h32; rom[64]=8'h07; rom[65]=8'hc0;
        rom[66]=8'hc3; rom[67]=8'h42; rom[68]=8'h00;

        repeat (12) @(posedge clk);
        rst = 1'b0;

        timeout = 0;
        while ((!dut.rf5c68.enable || dut.rf5c68.chan_off_m[0]) &&
               timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 100000)
            $fatal(1, "T80 did not configure the RF5C68");

        // Physical RAM is inverted so zero-filled M10Ks represent logical ff.
        if (dut.rf5c68.wave_ram.mem[0] !== 8'h7e ||
            dut.rf5c68.wave_ram.mem[1] !== 8'h7e ||
            dut.rf5c68.wave_ram.mem[2] !== 8'h00)
            $fatal(1, "T80 wave-RAM writes did not traverse the PCM bus");

        timeout = 0;
        while ((dut.rf_l !== 16'sd64 || dut.rf_r !== 16'sd64) &&
               timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 2000)
            $fatal(1, "real-Z80 PCM output missing: %0d/%0d", dut.rf_l, dut.rf_r);

        $display("SOUNDSYS Z80 PASS");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "SOUNDSYS Z80 timeout");
    end
endmodule


// Focused conformance checks for the official MAME System 32 main map.
`timescale 1ns/1ps

module tb_core_map_decode;
    import s32_pkg::*;

    reg clk = 0;
    always #5 clk = ~clk;

    board_desc_t bd = '0;
    wire [7:0] adc [0:7];
    wire dv [0:2];
    wire signed [8:0] dx [0:2], dy [0:2];
    wire [7:0] tb [0:2];
    for (genvar i=0;i<8;i++) assign adc[i] = 8'h80;
    for (genvar i=0;i<3;i++) begin
        assign dv[i]=0; assign dx[i]=0; assign dy[i]=0; assign tb[i]=8'hff;
    end

    s32_core core (
        .clk_sys(clk), .clk_ram(clk), .rst(1'b1), .video_rst(1'b1), .board(bd),
        .ce_cpu(1'b0), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0),
        .sdr_p0_dout(16'h0), .sdr_p0_ack(1'b0),
        .sdr_p1_dout(64'h0), .sdr_p1_ack(1'b0),
        .sdr_p2_dout(128'h0), .sdr_p2_ack(1'b0),
        .sdr_p3_dout(16'h0), .sdr_p3_ack(1'b0),
        .sdr_p4_dout(16'h0), .sdr_p4_ack(1'b0),
        .sdr_p5_dout(64'h0), .sdr_p5_ack(1'b0),
        .fb_er_ack(1'b0), .fb_rd_ack(1'b0), .fb_rd_pix(16'hffff),
        .fb_wr_busy(1'b0),
        .v25_prg_wr(1'b0), .v25_prg_waddr(16'h0), .v25_prg_wdata(8'h0),
        .eep_ld_wr(1'b0), .eep_ld_addr(6'h0), .eep_ld_data(16'h0),
        .eep_rd_addr(6'h0), .eep_upload(1'b0),
        .in_p1a(8'hff), .in_p2a(8'hff), .in_portc(8'hff),
        .in_svc12(8'hff), .in_svc34(8'hff),
        .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff),
        .in_svc12_b(8'hff), .in_svc34_b(8'hff),
        .adc_ch(adc), .trk_dv(dv), .trk_dx(dx), .trk_dy(dy), .trk_btn(tb),
        .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff)
    );

    reg [23:0] probe;
    integer errors = 0;

    task automatic expect_decode(
        input [23:0] addr,
        input pal0, input mix0, input io0, input ioex,
        input ppi, input v25
    );
    begin
        probe = addr;
        #1;
        if (core.is_pal0 !== pal0 || core.is_mix0 !== mix0 ||
            core.sel_io0 !== io0 || core.sel_ioex !== ioex ||
            core.sel_ppi !== ppi || core.sel_v25 !== v25) begin
            $display("FAIL map %06x pal=%b/%b mix=%b/%b io=%b/%b ex=%b/%b ppi=%b/%b v25=%b/%b",
                addr, core.is_pal0,pal0, core.is_mix0,mix0,
                core.sel_io0,io0, core.sel_ioex,ioex,
                core.sel_ppi,ppi, core.sel_v25,v25);
            errors = errors + 1;
        end
    end
    endtask

    initial begin
        bd.has_ppi = 1'b1;
        bd.has_v25 = 1'b1;
        force core.A = probe;

        // 0x600000/0x610000 windows, including MAME's A19:A17 mirrors.
        expect_decode(24'h600000, 1,0,0,0,0,0);
        expect_decode(24'h6e1234, 1,0,0,0,0,0);
        expect_decode(24'h610000, 0,1,0,0,0,0);
        expect_decode(24'h6f807e, 0,1,0,0,0,0);

        // 315-5296: 00-1f only; A19:A7 are mirrors. Expansion has A6 set.
        expect_decode(24'hc00000, 0,0,1,0,0,0);
        expect_decode(24'hc51280, 0,0,1,0,0,0);
        expect_decode(24'hc00020, 0,0,0,0,0,0);
        expect_decode(24'hc00040, 0,0,0,1,0,0);
        expect_decode(24'hcabc60, 0,0,0,1,1,0);
        expect_decode(24'hc00068, 0,0,0,1,0,0);

        // GA2's MB8421 right-side window is not mirrored across 0xAxxxxx.
        expect_decode(24'ha00000, 0,0,0,0,0,1);
        expect_decode(24'ha00ffe, 0,0,0,0,0,1);
        expect_decode(24'ha01000, 0,0,0,0,0,0);

        if (errors == 0) $display("CORE MAP DECODE PASS");
        else $fatal(1, "CORE MAP DECODE FAIL (%0d errors)", errors);
        $finish;
    end
endmodule

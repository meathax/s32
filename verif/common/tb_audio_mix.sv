`timescale 1ns/1ps

module tb_audio_mix;
    logic is_multi32;
    logic signed [15:0] fm1_l, fm1_r, fm2_l, fm2_r;
    logic signed [15:0] rf_l, rf_r, mp_l, mp_r;
    wire  signed [15:0] audio_l, audio_r;
    integer errors = 0;

    s32_audio_mix dut (.*);

    task automatic check_output(input signed [15:0] want_l, input signed [15:0] want_r, input [255:0] label_text);
        begin
            #1;
            if ((audio_l !== want_l) || (audio_r !== want_r)) begin
                $display("FAIL %0s: got L=%0d R=%0d want L=%0d R=%0d",
                         label_text, audio_l, audio_r, want_l, want_r);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        is_multi32 = 1'b0;
        fm1_l = '0; fm1_r = '0; fm2_l = '0; fm2_r = '0;
        rf_l = '0; rf_r = '0; mp_l = '0; mp_r = '0;
        check_output(16'sd0, 16'sd0, "zero");

        fm1_l = 16'sd1000; fm2_l = 16'sd2000; rf_l = 16'sd3000;
        fm1_r = -16'sd1000; fm2_r = -16'sd2000; rf_r = -16'sd3000;
        check_output(16'sd3750, -16'sd3750, "System32 ratios");

        fm1_l = 16'sh7fff; fm2_l = 16'sh7fff; rf_l = 16'sh7fff;
        fm1_r = 16'sh8000; fm2_r = 16'sh8000; rf_r = 16'sh8000;
        check_output(16'sh7fff, 16'sh8000, "System32 saturation");

        is_multi32 = 1'b1;
        fm1_l = 16'sd400; fm1_r = 16'sd800;
        mp_l = 16'sd1000; mp_r = -16'sd1000;
        check_output(16'sd1900, -16'sd1300, "Multi32 cross-route");

        fm1_l = 16'sh7fff; fm1_r = 16'sh7fff;
        mp_l = 16'sh7fff; mp_r = 16'sh7fff;
        check_output(16'sh7fff, 16'sh7fff, "Multi32 saturation");

        if (errors == 0) $display("AUDIO MIX PASS");
        else             $display("AUDIO MIX FAIL errors=%0d", errors);
        $finish;
    end
endmodule



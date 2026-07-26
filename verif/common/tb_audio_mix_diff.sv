`timescale 1ns/1ps

// Frozen pre-optimization behavior used as the independent differential
// oracle. Keep this implementation deliberately identical to the original
// runtime-selectable System 32 / Multi 32 mixer.
module s32_audio_mix_reference (
    input                    is_multi32,
    input  signed     [15:0] fm1_l,
    input  signed     [15:0] fm1_r,
    input  signed     [15:0] fm2_l,
    input  signed     [15:0] fm2_r,
    input  signed     [15:0] rf_l,
    input  signed     [15:0] rf_r,
    input  signed     [15:0] mp_l,
    input  signed     [15:0] mp_r,
    output signed     [15:0] audio_l,
    output signed     [15:0] audio_r
);

localparam logic signed [19:0] AUDIO_MAX = 20'sd32767;
localparam logic signed [19:0] AUDIO_MIN = -20'sd32768;

wire signed [19:0] fm1_l_w = {{4{fm1_l[15]}}, fm1_l};
wire signed [19:0] fm1_r_w = {{4{fm1_r[15]}}, fm1_r};
wire signed [19:0] fm2_l_w = {{4{fm2_l[15]}}, fm2_l};
wire signed [19:0] fm2_r_w = {{4{fm2_r[15]}}, fm2_r};
wire signed [19:0] rf_l_w  = {{4{rf_l[15]}},  rf_l};
wire signed [19:0] rf_r_w  = {{4{rf_r[15]}},  rf_r};
wire signed [19:0] mp_l_w  = {{4{mp_l[15]}},  mp_l};
wire signed [19:0] mp_r_w  = {{4{mp_r[15]}},  mp_r};

wire signed [19:0] mix_l = is_multi32
    ? (fm1_r_w <<< 1) + fm1_r_w + (mp_r_w <<< 3) - mp_r_w
    : (fm1_l_w <<< 1) + fm1_l_w + (fm2_l_w <<< 1) + fm2_l_w
      + (rf_l_w <<< 2);
wire signed [19:0] mix_r = is_multi32
    ? (fm1_l_w <<< 1) + fm1_l_w + (mp_l_w <<< 3) - mp_l_w
    : (fm1_r_w <<< 1) + fm1_r_w + (fm2_r_w <<< 1) + fm2_r_w
      + (rf_r_w <<< 2);

function automatic signed [15:0] scale_and_clip(input logic signed [19:0] sample);
    logic signed [19:0] scaled;
    begin
        scaled = is_multi32 ? (sample / 20'sd20) : (sample / 20'sd10);
        if (scaled > AUDIO_MAX)      scale_and_clip = 16'sh7fff;
        else if (scaled < AUDIO_MIN) scale_and_clip = 16'sh8000;
        else                         scale_and_clip = scaled[15:0];
    end
endfunction

assign audio_l = scale_and_clip(mix_l);
assign audio_r = scale_and_clip(mix_r);

endmodule

module tb_audio_mix_diff;

logic                    dut_multi32;
logic                    ref_multi32;
logic signed      [15:0] fm1_l;
logic signed      [15:0] fm1_r;
logic signed      [15:0] fm2_l;
logic signed      [15:0] fm2_r;
logic signed      [15:0] rf_l;
logic signed      [15:0] rf_r;
logic signed      [15:0] mp_l;
logic signed      [15:0] mp_r;
wire  signed      [15:0] dut_l;
wire  signed      [15:0] dut_r;
wire  signed      [15:0] ref_l;
wire  signed      [15:0] ref_r;

integer errors = 0;
integer checks = 0;
integer seed = 32'h32a0_10d5;
integer mode;
integer i;

s32_audio_mix dut (
    .is_multi32(dut_multi32),
    .fm1_l(fm1_l), .fm1_r(fm1_r),
    .fm2_l(fm2_l), .fm2_r(fm2_r),
    .rf_l(rf_l), .rf_r(rf_r),
    .mp_l(mp_l), .mp_r(mp_r),
    .audio_l(dut_l), .audio_r(dut_r)
);

s32_audio_mix_reference reference (
    .is_multi32(ref_multi32),
    .fm1_l(fm1_l), .fm1_r(fm1_r),
    .fm2_l(fm2_l), .fm2_r(fm2_r),
    .rf_l(rf_l), .rf_r(rf_r),
    .mp_l(mp_l), .mp_r(mp_r),
    .audio_l(ref_l), .audio_r(ref_r)
);

task automatic check_current(input [8*48-1:0] label_text);
begin
    #1;
    checks = checks + 1;
    if (dut_l !== ref_l || dut_r !== ref_r) begin
        if (errors < 16)
            $display("FAIL %0s mode(dut/ref)=%0d/%0d got=%0d,%0d want=%0d,%0d inputs=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                     label_text, dut_multi32, ref_multi32,
                     dut_l, dut_r, ref_l, ref_r,
                     fm1_l, fm1_r, fm2_l, fm2_r, rf_l, rf_r, mp_l, mp_r);
        errors = errors + 1;
    end
end
endtask

task automatic set_all(input signed [15:0] value);
begin
    fm1_l = value; fm1_r = value;
    fm2_l = value; fm2_r = value;
    rf_l  = value; rf_r  = value;
    mp_l  = value; mp_r  = value;
end
endtask

initial begin
    dut_multi32 = 1'b0;
    ref_multi32 = 1'b0;
    set_all(16'sd0);

`ifdef S32_GOLDENAXE_ONLY
    // Prove the RTL shift/add implementation against the language's signed
    // division semantics for every possible 20-bit input, including -2^19.
    begin : exhaustive_div10
        logic signed [19:0] sample;
        logic signed [19:0] got;
        logic signed [19:0] want;
        integer n;
        for (n = -524288; n <= 524287; n = n + 1) begin
            sample = n;
            got = dut.divide_by_10_exact(sample);
            want = sample / 20'sd10;
            if (got !== want) begin
                $display("FAIL exhaustive /10 sample=%0d got=%0d want=%0d", sample, got, want);
                errors = errors + 1;
                n = 524288;
            end
        end
    end
`endif

    for (mode = 0; mode < 2; mode = mode + 1) begin
        dut_multi32 = mode[0];
`ifdef S32_GOLDENAXE_ONLY
        // The dedicated profile is physically System 32 and must have no
        // runtime Multi 32 route/divisor cone, even if this unused port toggles.
        ref_multi32 = 1'b0;
`else
        // Generic source must remain bit-exact for both board families.
        ref_multi32 = mode[0];
`endif

        set_all(16'sd0);
        check_current("all zero");
        set_all(16'sh7fff);
        check_current("all positive full scale");
        set_all(16'sh8000);
        check_current("all negative full scale");

        fm1_l = 16'sh7fff; fm1_r = 16'sh8000;
        fm2_l = 16'sh8000; fm2_r = 16'sh7fff;
        rf_l  = 16'sd9;    rf_r  = -16'sd9;
        mp_l  = 16'sd19;   mp_r  = -16'sd19;
        check_current("mixed signed edges");

        fm1_l = 16'sd1;  fm1_r = -16'sd1;
        fm2_l = 16'sd3;  fm2_r = -16'sd3;
        rf_l  = 16'sd7;  rf_r  = -16'sd7;
        mp_l  = 16'sd10; mp_r  = -16'sd10;
        check_current("division truncation below zero");

        fm1_l = 16'sd32760; fm1_r = -16'sd32760;
        fm2_l = 16'sd32761; fm2_r = -16'sd32761;
        rf_l  = 16'sd32762; rf_r  = -16'sd32762;
        mp_l  = 16'sd32763; mp_r  = -16'sd32763;
        check_current("near saturation limits");

        for (i = 0; i < 10000; i = i + 1) begin
            fm1_l = $random(seed); fm1_r = $random(seed);
            fm2_l = $random(seed); fm2_r = $random(seed);
            rf_l  = $random(seed); rf_r  = $random(seed);
            mp_l  = $random(seed); mp_r  = $random(seed);
            check_current("random differential");
        end
    end

    if (errors == 0)
        $display("PASS: audio mixer differential checks=%0d", checks);
    else
        $fatal(1, "FAIL: audio mixer differential errors=%0d checks=%0d", errors, checks);
    $finish;
end

endmodule

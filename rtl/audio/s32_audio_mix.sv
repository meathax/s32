// Sega System 32 / Multi 32 stereo output mixer.
// Keep the route ratios used by the core, but accumulate at full precision and
// saturate after gain scaling so loud legal samples cannot wrap polarity.
module s32_audio_mix (
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

// MAME-derived route ratios retained from the original core implementation:
// System 32: two FM routes at x2 plus RF5C68 at x3.
// Multi 32: cross-routed FM at x2 plus MultiPCM at x6.
wire signed [19:0] mix_l = is_multi32
    ? (fm1_r_w <<< 1) + (mp_l_w <<< 2) + (mp_l_w <<< 1)
    : ((fm1_l_w + fm2_l_w) <<< 1) + (rf_l_w <<< 1) + rf_l_w;
wire signed [19:0] mix_r = is_multi32
    ? (fm1_l_w <<< 1) + (mp_r_w <<< 2) + (mp_r_w <<< 1)
    : ((fm1_r_w + fm2_r_w) <<< 1) + (rf_r_w <<< 1) + rf_r_w;

function automatic signed [15:0] scale_and_clip(input logic signed [19:0] sample);
    logic signed [19:0] scaled;
    begin
        scaled = sample >>> 2;
        if (scaled > AUDIO_MAX)      scale_and_clip = 16'sh7fff;
        else if (scaled < AUDIO_MIN) scale_and_clip = 16'sh8000;
        else                         scale_and_clip = scaled[15:0];
    end
endfunction

assign audio_l = scale_and_clip(mix_l);
assign audio_r = scale_and_clip(mix_r);

endmodule


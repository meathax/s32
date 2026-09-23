// Tilemap layer-position capture coherence (s32_tilemap_regcap).
//
// Scroll and page-select are one coupled address in s32_tilemap:
//     sx = (scrollx - offsx) + x ;  pg = sx[9] ? pg_word[14:8] : pg_word[6:0]
// so a scroll value must only ever be rendered against the page words that
// coexisted with it in the CPU register file.
//
// The regression this pins: scroll used to be captured on the vblank-start
// edge while pages were captured at the first line snapshot of the frame.
// vblank-start is the same pulse that raises the V60 vblank IRQ, so the game's
// register burst is causally AFTER it -- pages saw the burst, scroll did not,
// and pages permanently led scroll by one frame.
//
// Stimulus is the real thing, not an invented pattern.  Measured from MAME
// 0.289 spidman attract chapter 1 (probe of the $1FF00 register writes):
//     $1FF22 / $1FF2A (NBG2/NBG3 scrollx) step -7 every frame
//     every 73 frames they wrap +505 (= -7 mod 512) and the game rotates the
//     matching page words $1FF48/$1FF4A/$1FF4C/$1FF4E in the SAME vblank burst
// Observed wraps: frames 2027, 2100, 2173 -- gaps of exactly 73, matching the
// 73-frame on-screen flicker period in the user's capture (frames 224/297/370).
//
// The test asserts the invariant directly: every scroll value the renderer
// observes must be paired with the page words written in the same frame.

`timescale 1ns/1ps

module tb_tilemap_regcap;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst = 1'b1;

reg vbl_start = 1'b0;
reg line_start = 1'b0;

reg [15:0] w_pages       [0:7];
reg [15:0] w_scrollx     [0:3];
reg [15:0] w_scrolly     [0:3];
reg [15:0] w_offsx       [0:3];
reg [15:0] w_offsy       [0:3];
reg [15:0] w_scrollfracx [0:1];
reg [15:0] w_scrollfracy [0:1];
reg [15:0] w_zoomx       [0:1];
reg [15:0] w_zoomy       [0:1];

wire [15:0] tm_pages       [0:7];
wire [15:0] tm_scrollx     [0:3];
wire [15:0] tm_scrolly     [0:3];
wire [15:0] tm_offsx       [0:3];
wire [15:0] tm_offsy       [0:3];
wire [15:0] tm_scrollfracx [0:1];
wire [15:0] tm_scrollfracy [0:1];
wire [15:0] tm_zoomx       [0:1];
wire [15:0] tm_zoomy       [0:1];
wire        frame_capture;

s32_tilemap_regcap dut (
    .clk(clk), .rst(rst),
    .vbl_start(vbl_start), .line_start(line_start),
    .w_pages(w_pages),
    .w_scrollx(w_scrollx), .w_scrolly(w_scrolly),
    .w_offsx(w_offsx), .w_offsy(w_offsy),
    .w_scrollfracx(w_scrollfracx), .w_scrollfracy(w_scrollfracy),
    .w_zoomx(w_zoomx), .w_zoomy(w_zoomy),
    .tm_pages(tm_pages),
    .tm_scrollx(tm_scrollx), .tm_scrolly(tm_scrolly),
    .tm_offsx(tm_offsx), .tm_offsy(tm_offsy),
    .tm_scrollfracx(tm_scrollfracx), .tm_scrollfracy(tm_scrollfracy),
    .tm_zoomx(tm_zoomx), .tm_zoomy(tm_zoomy),
    .frame_capture(frame_capture)
);

integer fails = 0;
integer i;

// Values the renderer actually latched for this frame.  The CPU file is only
// written by the vblank burst, so after that burst the register file is
// stable for the whole frame: a correct capture must equal it exactly.
reg [15:0] seen_scrollx2;
reg [15:0] seen_pages4;
reg        captured_this_frame;

task fail(input [511:0] why);
    begin
        $display("REGCAP FAIL: %0s", why);
        fails = fails + 1;
    end
endtask

// one line snapshot pulse
task do_line_start;
    begin
        @(negedge clk); line_start = 1'b1;
        @(negedge clk); line_start = 1'b0;
        if (frame_capture) begin
            seen_scrollx2 = tm_scrollx[2];
            seen_pages4   = tm_pages[4];
            captured_this_frame = 1'b1;
        end
    end
endtask

task do_vbl_start;
    begin
        @(negedge clk); vbl_start = 1'b1;
        @(negedge clk); vbl_start = 1'b0;
    end
endtask

// The game's vblank ISR burst for frame f.
task game_burst(input integer f, input integer is_wrap);
    begin
        if (is_wrap) begin
            // scroll wraps +505 and the page words rotate together
            w_scrollx[2] = (w_scrollx[2] + 16'd505) & 16'h01FF;
            w_scrollx[3] = (w_scrollx[3] + 16'd505) & 16'h01FF;
            w_pages[4]   = w_pages[4] + 16'h0101;   // stand-in rotation
            w_pages[5]   = w_pages[5] + 16'h0101;
            w_pages[6]   = w_pages[6] + 16'h0101;
            w_pages[7]   = w_pages[7] + 16'h0101;
        end
        else begin
            w_scrollx[2] = (w_scrollx[2] - 16'd7) & 16'h01FF;
            w_scrollx[3] = (w_scrollx[3] - 16'd7) & 16'h01FF;
        end
    end
endtask

// One full frame: vblank edge, the game's ISR burst, then 224 line snapshots.
task run_frame(input integer f, input integer is_wrap);
    begin
        captured_this_frame = 1'b0;
        do_vbl_start();          // vblank starts; IRQ raised here
        game_burst(f, is_wrap);  // ISR runs AFTER the vblank edge
        for (i = 0; i < 224; i = i + 1) do_line_start();

        if (!captured_this_frame)
            fail("no frame capture occurred");

        // The CPU file is stable for the whole frame after the burst, so a
        // coherent capture must equal it exactly -- both halves of the pair.
        if (seen_scrollx2 !== w_scrollx[2]) begin
            $display("  frame %0d: renderer scrollx[2]=%04x but CPU file holds %04x (stale by %0d px)",
                     f, seen_scrollx2, w_scrollx[2],
                     $signed(w_scrollx[2]) - $signed(seen_scrollx2));
            fail("scroll snapshot does not match the frame it is rendered with");
        end
        if (seen_pages4 !== w_pages[4]) begin
            $display("  frame %0d: renderer pages[4]=%04x but CPU file holds %04x",
                     f, seen_pages4, w_pages[4]);
            fail("page snapshot does not match the frame it is rendered with");
        end
    end
endtask

integer f;
integer wraps;

initial begin
    for (i = 0; i < 8; i = i + 1) w_pages[i] = 16'h0000;
    for (i = 0; i < 4; i = i + 1) begin
        w_scrollx[i] = 16'h0000; w_scrolly[i] = 16'h0000;
        w_offsx[i]   = 16'h000A; w_offsy[i]   = 16'h0000;  // measured offsx = 0x0A
    end
    for (i = 0; i < 2; i = i + 1) begin
        w_scrollfracx[i] = 0; w_scrollfracy[i] = 0;
        w_zoomx[i] = 16'h0200; w_zoomy[i] = 16'h0200;
    end
    seen_scrollx2 = 16'hxxxx; seen_pages4 = 16'hxxxx;
    captured_this_frame = 1'b0;

    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    // 201-frame truck pass, wrapping every 73 frames as measured.
    wraps = 0;
    for (f = 0; f < 201; f = f + 1) begin
        if (f > 0 && (f % 73) == 0) begin
            wraps = wraps + 1;
            run_frame(f, 1);
        end
        else
            run_frame(f, 0);
    end

    if (wraps != 2)
        fail("stimulus did not produce the expected two scroll wraps");

    // Robustness: a frame whose first line kick is dropped (renderer busy)
    // must still capture the pair together, just later in the frame.
    captured_this_frame = 1'b0;
    do_vbl_start();
    game_burst(500, 1);
    @(negedge clk);              // first kick of the frame is dropped
    for (i = 0; i < 224; i = i + 1) do_line_start();
    if (!captured_this_frame)
        fail("late capture never happened");
    if (seen_scrollx2 !== w_scrollx[2] || seen_pages4 !== w_pages[4])
        fail("late capture split the coupled pair");

    if (fails == 0) $display("TILEMAP REGCAP PASS (%0d wraps exercised)", wraps);
    else begin
        $display("TILEMAP REGCAP: %0d failure(s)", fails);
        $fatal(1);
    end
    $finish;
end

endmodule

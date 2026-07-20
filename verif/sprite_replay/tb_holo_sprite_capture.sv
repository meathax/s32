//============================================================================
//  Non-invasive real-ROM state capture wrapper for tb_core_romboot.
//
//  Select this module as the only simulation top.  It instantiates the normal
//  full-core harness and snapshots the exact live controller bytes, all 128
//  KiB of sprite RAM, and both physical 416x224 framebuffer images immediately
//  before the vblank-end swap/render command is consumed.
//============================================================================
`timescale 1ns/1ps

module tb_holo_sprite_capture;

tb_core_romboot harness();

string capture_root;
integer capture_first, capture_last, capture_stop;
reg vblank_seen = 1'b0;
integer captures = 0;

initial begin
    if (!$value$plusargs("CAPROOT=%s", capture_root)) capture_root = ".";
    if (!$value$plusargs("CAPFIRST=%d", capture_first)) capture_first = 1;
    if (!$value$plusargs("CAPLAST=%d", capture_last)) capture_last = capture_first;
    if (!$value$plusargs("CAPSTOP=%d", capture_stop)) capture_stop = 1;
end

task automatic dump_state(input integer frame_number);
    string path;
    integer fd, index, x, y;
    integer current_front, render_target, other_buffer;
begin
    // The engine swaps first, then draws to the old visible buffer.  Thus the
    // current display buffer is the direct-render oracle's initial back image.
    current_front = harness.core.sprite.disp_buf[0];
    render_target = current_front;
    other_buffer = current_front ^ 1;

    path = $sformatf("%s/frame_%0d/controls.hex", capture_root, frame_number);
    fd = $fopen(path, "w");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    for (index = 0; index < 8; index = index + 1)
        $fdisplay(fd, "%02x", harness.core.sprite.ctl[index]);
    $fclose(fd);

    path = $sformatf("%s/frame_%0d/previous_latched_controls.hex", capture_root, frame_number);
    fd = $fopen(path, "w");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    for (index = 0; index < 8; index = index + 1)
        $fdisplay(fd, "%02x", harness.core.sprite.ctl_latched[index]);
    $fclose(fd);

    path = $sformatf("%s/frame_%0d/sprite_ram.hex", capture_root, frame_number);
    fd = $fopen(path, "w");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    for (index = 0; index < 65536; index = index + 1)
        $fdisplay(fd, "%04x", harness.core.sprite_ram.sim_peek(index));
    $fclose(fd);

    path = $sformatf("%s/frame_%0d/pre_erase_target.hex", capture_root, frame_number);
    fd = $fopen(path, "w");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    for (y = 0; y < 224; y = y + 1)
        for (x = 0; x < 416; x = x + 1)
            $fdisplay(fd, "%04x", harness.fbmem[render_target][y][x]);
    $fclose(fd);

    path = $sformatf("%s/frame_%0d/front.hex", capture_root, frame_number);
    fd = $fopen(path, "w");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    for (y = 0; y < 224; y = y + 1)
        for (x = 0; x < 416; x = x + 1)
            $fdisplay(fd, "%04x", harness.fbmem[other_buffer][y][x]);
    $fclose(fd);

    path = $sformatf("%s/frame_%0d/capture_meta.txt", capture_root, frame_number);
    fd = $fopen(path, "w");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    $fdisplay(fd, "frame=%0d", frame_number);
    $fdisplay(fd, "current_display_buffer=%0d", current_front);
    $fdisplay(fd, "direct_render_target=%0d", render_target);
    // The core video timing width and the sprite controller's latched outer
    // clip can differ briefly during boot.  MAME's object renderer uses
    // sprite control byte 6, so record both instead of treating the timing
    // mode as the sprite-render width.
    $fdisplay(fd, "sprite_control_width=%0d",
              harness.core.sprite.ctl[6][0] ? 416 : 320);
    $fdisplay(fd, "video_timing_width=%0d", harness.core.mode_416 ? 416 : 320);
    $fdisplay(fd, "renderer_was_active=%0d", harness.core.debug_sprite_rendering);
    // Automatic 30 Hz mode renders only when this down-counter is zero.
    // Preserve it so post-processing can distinguish real render callbacks
    // from the intentionally skipped alternate frame.
    $fdisplay(fd, "render_count=%0d", harness.core.sprite.render_count);
    $fdisplay(fd, "v60_pc=%08x", harness.core.v60.dbg_pc);
    $fclose(fd);
    captures = captures + 1;
    $display("HOLO SPRITE CAPTURE frame=%0d target=%0d sprite_width=%0d video_width=%0d pc=%08x",
             frame_number, render_target,
             harness.core.sprite.ctl[6][0] ? 416 : 320,
             harness.core.mode_416 ? 416 : 320, harness.core.v60.dbg_pc);
end
endtask

// vbl_end spans clock domains.  Sample its first clk_ram falling edge so the
// state is stable and before the next rising-edge renderer transition.
always @(negedge harness.clk_ram) begin
    if (!harness.core.vbl_end)
        vblank_seen = 1'b0;
    else if (!vblank_seen) begin
        vblank_seen = 1'b1;
        if (!harness.rst && harness.cur_frame >= capture_first &&
            harness.cur_frame <= capture_last) begin
            if (harness.core.debug_sprite_rendering)
                $fatal(1, "previous sprite pass still active at Holo capture frame %0d",
                       harness.cur_frame);
            dump_state(harness.cur_frame);
            if (capture_stop != 0 && harness.cur_frame == capture_last) begin
                $display("HOLO SPRITE CAPTURE PASS count=%0d", captures);
                $finish;
            end
        end
    end
end

endmodule

# Video output contract evidence

Date: 2026-08-26

## Observation

The core emits the complete MiSTer video interface, but `HDMI_BLACKOUT` was
tied low while `rtl/video/s32_video.sv` can change the native horizontal size
at a frame boundary (320/410 total versus 416/512 total).

## Evidence

- `Arcade-SegaSystem32.sv` emits `CLK_VIDEO`, `CE_PIXEL`, native RGB/sync/DE,
  aspect metadata, scanline control, analog controls, and HDMI controls.
- `sys/sys_top.v` preserves user-controlled `direct_video` (`cfg[10]`), routes
  native direct HDMI and analog VGA separately from the HDMI scaler, and passes
  `HDMI_BLACKOUT` to `ascal.swblack`.
- `sys/ascal.vhd` uses `swblack` to blank resolution-change frames while it
  re-measures the input.
- `rtl/crt_adjust.sv` is in `files.qip` and is selected only for the native
  15 kHz CRT path; HDMI scaler dimensions disable that core-side adjustment.

## Change

`HDMI_BLACKOUT` is now enabled continuously. This is an enable for the
framework's resolution-transition handling, not a forced direct-video mode;
direct video remains selected by the MiSTer framework configuration.

## Verification

The native 320/416 timing test and the profile contract tests cover the raster
transition, CRT path, direct-video selection, analog path, HDMI scaler path,
framework sources, and the enabled blackout control. Physical MiSTer, analog
CRT, and HDMI-sink validation remains outstanding.

Receipts: the two focused profile tests passed; Icarus 13.0 reported
`VIDEO TIMING STABLE` and `VIDEO MODE LATCH PASS`; headless Verilator 5.050
reported the same markers and `VERILATOR VIDEO PASS` with assertions enabled,
unique X initialization, one runtime thread, and a unique `R:\Verilator`
workspace. No MAME/Verilator MCP capability was exposed in this session, so the
repository-owned headless adapter was used.

## Direct-video cadence fix — 2026-08-29

### Observation

The supplied `arabian_fight_scrolling.mp4` shows narrow, full-height vertical
column splits while the Arabian Fight title/background scrolls (about
0:00–0:02.9). The same failure was reported for Golden Axe: The Revenge of
Death Adder. The failure is limited to direct video; the HDMI-scaled path does
not expose it.

### Evidence and conclusion

- **KNOWN:** `rtl/video/s32_video.sv` generates 320-mode `ce_pix` with a
  32/240 accumulator, so its pixel intervals alternate 8 and 7 `clk_sys`
  cycles. 416 mode is an exact 40/240 interval.
- **KNOWN:** `sys/sys_top.v` uses the core `CLK_VIDEO` and `CE_PIXEL` directly
  when direct video is selected, while the scaler path buffers and re-times
  the stream.
- **INFERRED:** a fixed-stride direct-video sampler sees the 320-mode 8/7
  cadence as a phase beat, duplicating/dropping a column at a repeatable
  interval. The spacing appears as tile-column artifacts only when scroll
  changes the image under that sampling phase.
- The 416-mode control is exact and the artifact is not a tile ROM or priority
  decode symptom. The shared cross-core lesson on uniform `CE_PIXEL` for
  direct-video sinks predicts the same failure mechanism.

### Change

`Arcade-SegaSystem32.sv` now exports `clk_ram` as `CLK_VIDEO` and routes the
finished RGB/sync/DE stream through `rtl/video/s32_video_retime.sv`. The retimer
uses an HSync-anchored uniform 15-`clk_ram` grid in 320 mode and 12-`clk_ram`
grid in 416 mode, sampling mid-pixel. CRT Adjust retains its intentional
fractional read cadence through the retimer bypass; the vendored `sys/` framework
is unchanged.

### Verification

`verif/common/tb_video_retime.sv` checks both modes for exact output spacing,
no duplicated/dropped pixel indices, sideband alignment, and the CRT-Adjust
bypass cadence. Icarus 13.0 and strict headless Verilator 5.050 both report
`VIDEO RETIME PASS` with assertions, unique X initialization, one runtime
thread, and `display_backend=none`. The output contract test also passes.
Physical MiSTer direct-video A/B validation remains outstanding; no final RBF
was built.

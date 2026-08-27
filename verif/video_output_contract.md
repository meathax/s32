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

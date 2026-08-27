# MAME reference captures

## Generic frame captures and image comparison

For a bounded no-input capture, use `capture_frames.lua` with MAME's native
snapshot options. `S32_MAME_FRAMES` is a comma-separated emulated-frame list;
the Lua script exits after the final requested frame. For example:

```powershell
$env:S32_MAME_FRAMES = "80,85,90"
$env:S32_MAME_TRACE = "D:\\Arcade\\AI\\s32\\scratch\\mame_frames.log"
mame svf -rompath D:\\Arcade\\AI\\s32\\roms -video none -sound none `
  -autoboot_script D:\\Arcade\\AI\\s32\\verif\\mame\\capture_frames.lua `
  -snapshot_directory D:\\Arcade\\AI\\s32\\scratch\\mame_frames `
  -snapname svf-%i
```

`compare_sonic_frame.py` is also used for the generic 320x224 System 32
captures. It accepts the Verilator 416-wide image when the rightmost 96 pixels
are all black, and `--y-offset` records a measured vertical capture offset.
The retained Holo comparison uses `--y-offset -1` and is an exact RGB match.

## Holosseum

`capture_holo_reference.ps1` runs the verified local `holo` ROM set in stock
MAME through WSL.  The Lua autoboot script drives coin, Start, movement and one
attack at fixed frame numbers.  It records native PNG snapshots, an AVI, WAV,
V60-PC/event trace, MAME XML, ROM verification result and SHA-256 manifest under
the ignored `roms/reference/holo/` directory.

Run from the repository root:

```powershell
pwsh -File verif/mame/capture_holo_reference.ps1
```

The harness is deterministic with respect to emulated frames.  It is intended
as a reference generator for RTL comparisons, not as a replacement for the
RTL's directed tests.

## Golden Axe PLAYER SELECT differential trace

Capture the MAME reference from the repository root:

```powershell
pwsh -File verif/mame/capture_ga2_select_trace.ps1
```

Capture the two Verilator address ranges with the same fixed RTL input schedule.
They are separate runs so tracing the controller does not flood the log with the
large work-RAM gap between the state and object ranges:

```powershell
wsl bash -lc 'bash verif/verilator/run_romboot.sh ga2 90 +COINAT=41 +COINLEN=4 +STARTAT=51 +STARTLEN=4 +TRACELO=20ac7a +TRACEHI=20ac83' *> scratch/rtl_ga2_select_state.log
wsl bash -lc 'bash verif/verilator/run_romboot.sh ga2 90 +COINAT=41 +COINLEN=4 +STARTAT=51 +STARTLEN=4 +TRACELO=204a60 +TRACEHI=204aff' *> scratch/rtl_ga2_select_object.log
```

Then compare ordered semantic events; absolute MAME and RTL frame numbers are
metadata and are deliberately ignored:

```powershell
python verif/mame/compare_ga2_select_trace.py
```

The comparator checks the two coinage SETF byte lanes, the `00 -> 01 -> 00`
credit lifecycle, final coinage/player state, and these exact controller writes:
PC `101EAC` one byte, PC `101F23` state `0000`, PC `101F56` stream
`001020C5`, and PC `102097` palette `0191`. Use `--help` for alternate paths or
JSON output, and `--self-test` for the lightweight embedded positive/negative
test.

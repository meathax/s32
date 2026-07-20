# Holosseum MAME reference capture

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

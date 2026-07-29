# MAME reference captures

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

## Golden Axe PCB-accuracy register trace (T-A..T-D)

`ga2_regtrace.lua` answers the four open questions that gate the remaining work
in `docs/ga2-pcb-accuracy-plan.md`. Run it against a local `ga2` set:

```sh
mame ga2 -autoboot_script verif/mame/ga2_regtrace.lua -autoboot_delay 0
```

Environment: `GA2_TRACE_OUT` (default `/tmp/ga2_regtrace.txt`),
`GA2_TRACE_FRAMES` (default 3600, `0` = unlimited).

Play into the **stage-2 cave and light the wall torch** while it records — that
is the scene MAME's own source names as broken, and the one MAMETesters 05233
has real-PCB reference footage for.

What each answer decides:

| Look for | Decides |
| --- | --- |
| writes to `61004E` with bits 4-7 set | the torch is the **gradation/blur** effect, which MAME implements *not at all* (it reads only bits 8-11) |
| writes to `1FF00_06` touching `$1FF04` | the torch is the **rowscroll/rowselect line window**, and we must extend those tables to NBG0/1 |
| `$1FF00` bits 12/13 ever set | whether our NBG2/3 disable decode is right — it is undocumented in MAME's own register block *and* in MacDonald |
| `$1FF8E` bits 8-11 ever set | whether the tilemap opaque feature matters for ga2 (FBNeo enables it only for `darkedge`/`radr`) |
| any `sprstat` read | whether ga2 polls the render status MAME and FBNeo both hardcode to "normal" |
| any `timercnt` read | whether ga2 polls the timer counts MAME returns `0xFF` for |

A trace with **no** `61004E` bit-4-7 writes and **no** `$1FF04` writes in the
torch scene would mean both current hypotheses are wrong and the effect comes
from somewhere else entirely — that is a useful result too.

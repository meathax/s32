# MAME capture adapter

`capture_template.lua` is a deliberately incomplete board adapter. Codex must wire it to the exact
MAME device/address-space and event phase proved in `docs/OBSERVABILITY.json`.

The capture task receives these environment variables:

- `MISTER_TRACE_OUT`
- `MISTER_INPUT_FILE`
- `MISTER_SCENARIO`
- `MISTER_SEED`
- `MISTER_STOP_KIND`
- `MISTER_STOP_VALUE`

A normal launch shape is:

```json
{
  "enabled": true,
  "argv": [
    "${MAME_EXE}",
    "GAME_SHORTNAME",
    "-rompath", "${MAME_ROMS}",
    "-window", "-nothrottle", "-video", "none", "-sound", "none",
    "-autoboot_script", "${PROJECT}\\sim\\mame\\capture.lua"
  ]
}
```

The exact options should be validated against the pinned MAME build. Do not use MAME MCP discovery
helpers as the golden ordered bus trace unless their width, device, phase and deduplication behavior
have been proven. MAME MCP remains excellent for source/runtime exploration, register inspection,
watchpoints and targeted experiments.

The adapter must:

1. create one JSON object per accepted canonical source event;
2. maintain a contiguous `seq` per domain starting at zero;
3. emit native address/data/lane values exactly as declared by the observability contract;
4. replay semantic inputs using the same shared timebase as RTL;
5. stop deterministically;
6. avoid modifying MAME state during a reference run.

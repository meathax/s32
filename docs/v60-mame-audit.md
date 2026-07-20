# V60 MAME contract audit (2026-07-19)

This audit compares the production V60 RTL against the official MAME source
at commit `a8c5e5346af728a35269a6ecd50c8e4a8df59b0b`.  The files were downloaded
from `https://raw.githubusercontent.com/mamedev/mame/<commit>/src/devices/cpu/v60/`
into the ignored reference snapshot at
`scratch/upstream/mame-master-20260719/src/devices/cpu/v60/`.

## Added reference files

| File | SHA-256 |
| --- | --- |
| `am.hxx` | `9D8487A6580C918209408D1F406BD9053E842CB722520F7F135934CC174BAA69` |
| `op12.hxx` | `34858E79374AADAE5940409668CB9B448160018213D467F56CBB718816C3E76E` |
| `op2.hxx` | `E5C5924526C2BC776C35B27D84008ED73CDA0C52AAB52F9130303099B4EC5E12` |
| `op3.hxx` | `BEAAF4B62B79F819CAC577C23C6F6E2731B4483E7F3A2D0ED4961A29B64540CB` |
| `op4.hxx` | `44D61A79413B81ADFA752529C9E8CEACE78B84CB5DF854BA3E1E738A9513E2D7` |
| `op5.hxx` | `F890D81A10E12428E1607877171B6C2B28A9AFF5346B17945C5326735398D32C` |
| `op6.hxx` | `681B7F3708DDF98030852519FAF7BD560F736913B8CB6C28EEC1BCB484EB4EFF` |
| `op7a.hxx` | `04BB70601D69015CB6FBB6E577D22392DA5221AC7620479C5CB85FC0EB1921F8` |
| `optable.hxx` | `6A963502A50D9795ADB9DD0C8C71AED69ADBBA46B5CF13FFD573AE4C16812BBD` |

MAME is BSD-3-Clause.  These files are used as a behavioral oracle; they are
not compiled or included in the FPGA build.

## Correctness changes

- `ROT.B/H/W` now matches `op12.hxx`: positive counts place the result LSB in
  CY, negative counts place the result MSB in CY, and a zero count clears CY.
- Negative `ROTC.B/H` now inserts carry at bit 7/15 rather than bit 31.
  Positive and negative ROTC paths are explicitly width-limited, and a zero
  count clears CY as MAME specifies.
- The NMI edge-history flop is reset, removing an undefined first-edge state.
- The 16-bit V60 bus adapter required no logic change.  A new directed test
  verifies byte, halfword and dword reads/writes at even and odd addresses,
  including exact 1/2/3 external-cycle counts.

## Completeness pass (2026-07-20)

The primary and grouped dispatch tables were audited again against the pinned
MAME files.  This pass closed the following independent gaps:

- reserved primary opcodes `0x6b`/`0x7b` now enter vector 8 instead of acting
  as never-taken branches;
- reserved `0x58`/`0x5a` string sub-opcodes now enter vector 8 instead of
  entering an undefined string-engine state;
- CLRTLB consumes its complete addressing-mode operand before advancing PC;
- privileged-register indices 16..28 now implement ATBR0/ATLR0 through
  ADTMR1, including deterministic reset state and STPR/LDPR access; PIR resets
  to `0x6000` for V60 and `0x7000` for V70;
- BRKV emits MAME's four-word frame (fault PC, code, old PSW, return PC);
- synchronous exceptions preserve PSW.IS, while IRQ/NMI alone force the
  interrupt stack;
- TRAPFL uses the MAME TKCW/PSW floating-cause intersection rather than PSW.TP;
- CALL decodes operand 1 as an address and pushes the full decoded return PC;
- CHLVL implements the target execution level, vector, PSW transition, and
  four-word frame;
- LDTASK/STTASK transfer TKCW, enabled level stacks, and selected R0..R30 words
  through the normal bus, update TR, and reload the active stack bank.

`tb_v60_audit.sv` now proves all of these paths, including a variable-length
F1 CALL/RET, exact BRKV and CHLVL stack layouts, and a task save/destroy/load
round trip.  The complete 35-tier regression, including 50/50 independent V60
differential seeds, passed after the final exception/task tranche
(`verif/modelsim-v60-complete-gate.log`).

The remaining deliberate ISA exclusion is the single-precision floating-point
subset in MAME groups `0x5c` and `0x5f`.  No System 32 game is known to execute
it, but MAME does implement CMPF/MOVFS/NEGFS/ABSFS/SCLFS/ADDFS/SUBFS/MULFS/
DIVFS and CVTWS/CVTSW.  The RTL currently raises the reserved-instruction
exception for those groups and must not be described as a complete general-
purpose V60 until that exclusion is resolved or formally bounded to the arcade
software profile.

## Regression evidence

- `tb_v60_rotate.sv`: 7 of 8 oracle cases fail against the exact pre-fix RTL;
  all 8 pass after the fix (`V60 ROTATE PASS`).
- `tb_v60_bus_lanes.sv`: all lane/alignment cases pass
  (`V60 BUS LANES PASS`).
- Existing `smoke`, `directed`, `audit`, `search`, `divx`, `decimal`, `bits`,
  and `long_ea` V60 benches all pass.
- Verilator 5.032 lint exits successfully; only expected multi-top/timescale
  warnings are emitted when both testbench tops are linted together.

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
| `am1.hxx` | `15C87B1F85A1A35165889F16B806A28945BF46DAEA2762384768339040F480C7` |
| `am2.hxx` | `749B91A81862BB984B6D40B0B275C0D8CD6413D0C9DC99CE66A6B293E5B42718` |
| `am3.hxx` | `DDD3E3CEC7AD4475A667C6EB404DC9191AF6951FDAA5DB199DF2839BAB2439DA` |
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

The single-precision floating-point subset in MAME groups `0x5c` and `0x5f` is
now implemented (audit round 2026-07-22).  A binary32 unit provides CMPF, MOVFS,
NEGFS, ABSFS, SCLFS, ADDFS, SUBFS, MULFS, DIVFS, CVTWS and CVTSW with round-to-
nearest-even and gradual underflow (subnormals), matching MAME's host-`float`
contract; the FDIV mantissa divide is iterative (27 restoring steps), the rest
combinational.  No System 32 game is known to execute these ops, so the change
cannot regress the shipping path — it only replaces the former reserved-op trap.
`tb_v60_fp.sv` verifies the arithmetic against `numpy.float32` over 1,800+
directed + full-range random vectors (normals, subnormals, zero, infinity, NaN,
and rounding ties) with zero mismatches; `tb_v60_fpdecode.sv` runs real ADDFS/
MULFS instructions (register and memory operand forms) end to end.  The only
un-dispatched `0x5c`/`0x5f` sub-opcodes now are those MAME itself marks
UNHANDLED (fatalerror), which the RTL maps to the reserved-instruction vector.

The remaining bounded item is the V70 (`IS_V70=1`) 32-bit external data bus:
`s32_v60_bus` documents a 1..2 aligned 32-bit-cycle mode but still issues 16-bit
cycles.  System 32 is V60-only (System Multi 32 with its V70 is out of scope and
`is_multi32` is forced 0 in the shipping profile), so the parameter is presently
unused; a Multi 32 build would need the 32-bit path added and re-timed.

## Regression evidence

- `tb_v60_rotate.sv`: 7 of 8 oracle cases fail against the exact pre-fix RTL;
  all 8 pass after the fix (`V60 ROTATE PASS`).
- `tb_v60_bus_lanes.sv`: all lane/alignment cases pass
  (`V60 BUS LANES PASS`).
- Existing `smoke`, `directed`, `audit`, `search`, `divx`, `decimal`, `bits`,
  and `long_ea` V60 benches all pass.
- Verilator 5.032 lint exits successfully; only expected multi-top/timescale
  warnings are emitted when both testbench tops are linted together.

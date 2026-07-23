# Spider-Man early enemy-trigger fix

## Result

The shared V60 `XCH` F2-D=0 decode bug was the cause of Spider-Man activating
distant scripted enemies on the first small camera pan. The functional fix is
in `rtl/cpu/v60/s32_v60.sv`: opcodes `0x41/0x43/0x45` now decode operand 1 as a
register lvalue, so register-to-register `XCH.B/H/W` exchanges registers instead
of entering the register/memory path.

Spider-Man uses the affected halfword form twice in its waiting-object window
constructor:

```
087EA3 cmp.h R0,R1
087EA6 bge   087EAB
087EA8 xch.h R0,R1       ; bytes 43 40 61
...
087ECD cmp.h R0,R1
087ED0 bge   087ED5
087ED2 xch.h R0,R1       ; bytes 43 40 61
```

The constructor orders each object's endpoint pair and expands it into signed
camera bounds at `R20+{38,3A,3C,3E}`. The manager at `0x087A99` admits the
object only while both camera coordinates are inside those bounds.

Before the fix, the literal Spider-Man `XCH.H R0,R1` produces
`R0=AAAA1111, R1=BBBB0000` instead of exchanging the low halves. Running the
complete literal `0x087E9B..0x087EEB` constructor gives malformed bounds:

```
x=fbc0..0140 y=0240..0140
```

On current RTL the same instruction gives `R0=AAAA2222, R1=BBBB1111`, and the
complete constructor gives the correct ordered/expanded bounds:

```
x=fac0..0340 y=fe40..0840
```

This explains the hardware symptom: a zeroed endpoint corrupts many waiting
objects' camera windows, allowing future Scorpion, heavy-enemy, and Venom events
to become eligible together on the first pan.

## Regression coverage

- `verif/v60/tb_v60_spidman_xchh.sv` executes the exact `43 40 61` instruction.
- `verif/v60/tb_v60_spidman_window.sv` executes the complete literal window
  constructor with reversed endpoint pairs.
- `verif/v60/tb_v60_spidman_gate.sv` executes the literal double-indirect camera
  loads and signed `CMP.H/BGT/BLT` gate for six inside/outside cases.
- `verif/verilator/run_spidman_trigger_regression.sh` runs all three with
  Verilator 5.032. Result: `SPIDMAN TRIGGER REGRESSION: PASS`.

The constructor test was also run against the parent of the XCH fix and fails
with the malformed bounds above, giving a direct pre-fix/current A/B.

## Hardware acceptance

Use `releases/SegaS32.rbf` (4,603,732 bytes, built 2026-07-23 10:40 local):

```
SHA-256 876A3553CA4DC489BA7260B3D1CEDE5A46610346D783AF91927749F34EEBF6FC
```

Acceptance sequence:

1. Insert one coin and press Start.
2. Let the normal opening Scorpion run/speech finish.
3. Walk right only until the screen pans a small amount, then release Right.
4. The first encounter must contain exactly two enemies.
5. Wait about 20 seconds without progressing: green Scorpion must not arrive and
   the Venom boss-health bar must not appear.

The generic ROM-boot autopilot accepted coin/start/right and ran cleanly for
1,150 frames, but did not execute `0x087A99` within that limit. It is therefore
inconclusive as an end-to-end encounter test; it is not counted as a visual
acceptance pass.

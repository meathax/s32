# Spider-Man early-trigger investigation (Venom / Scorpion)

**Symptom (hardware, spidman World on MiSTer):** scripted boss events that are
supposed to wait until the camera pans right to a specific point (the truck
opening → Venom from the coffin; Scorpion likewise) fire **almost immediately,
on the first rightward pan**. Systematic across the *camera-scroll-position-gated*
events; regular enemy waves and other triggers are fine. The **camera itself
pans smoothly and correctly** — only the event gating is wrong.

## Established facts (MAME 0.285 reference, device `:mainpcb:maincpu`)

- **Display scroll register `0x31FF12` (NBG0 scrollx) WRAPS every 0x200** — it is
  a per-page value (0..0x1FF), NOT what events gate on. The game does **not** read
  it back (a read tap over `0x31FF00-0x31FFFF` during a full pan showed only 6
  reads, all at `0x31FF00`).
- **World-camera variable = work-RAM `0x208032` (16-bit).** Found by correlating
  three work-RAM dumps at world 0x080/0x180/0x280 (user drove; only this value
  climbed ~0x100 per capture: 0x0004 → 0x0104 → 0x0206 ≈ `world - 0x7C`). A 4×
  copy exists at `0x208304/08/44/48/50`.
  - **Low byte `0x208032`** sources the (correct) display scroll.
  - **High byte `0x208033` = the page/segment counter** that scripted events gate
    on. Truck/Venom triggers at **world ≈ 0x2C0** (page 2, scrollx 0xC0).
- **Dominant reader of the camera var: PC `0x00063179`** (1043 reads over ~1600
  gameplay frames — the per-frame camera/event routine `0x63140-0x631E6`).
  Camera var written inside that routine (`0x63154` low, `0x63161` high) and the
  work-RAM clear loop at `0x60886` (init).

## Working hypothesis

Display (low byte) is correct but the **page/segment counter (high byte 0x208033)
runs ahead**, so every `page ≥ threshold` event gate trips early while the smooth
scroll looks perfect. The `0x63140` routine advances the segment via a timer
(`dec.h 34[R25]` reload `#0x708`) and/or the moving path (`add.b #2, 32[R25]`),
with a step table at `0x63229` (`sub.b/add.b 63229[PC](R1)`, PC-relative +index).

## 2026-07-21 update — hardware re-test + full disassembly of 0x63140

**New hardware symptom (Camera Var build):** the "Camera Var" OSD stays **totally
black** through the whole early game (until *after* Venom) — so **0x208032 is NOT
the variable the events gate on** (it reads ~0 early; it is a slow/late var, and
the earlier world-correlation was coincidental). And **all camera-gated events
fire at once on the first rightward pan** (truck + Scorpion + fat guy + Venom),
not one-a-little-early — i.e. the *logical* position the spawn logic reads jumps
straight to max while the *display* scroll stays smooth. That signature is an
**overflow / saturation**, not a slow drift.

**Full disassembly of the camera routine (MAME dasm, `scratch/cam.asm`).** R25 =
0x208000. Decoded mechanism:
- `0x63154 mov.b R0,32[R25]` — display camera low byte (0x208032), advanced ±2/
  frame by the movement flags at `0x30[R25]` (`add.b #2 / sub.b #2, 32[R25]`).
- `0x63161 mov.b #0,33[R25]` — page/segment byte (0x208033), init 0.
- `0x63166 mov.h #708,34[R25]` — **halfword timer** (0x208034), reload 0x708 =
  1800 frames ≈ 30 s.
- `0x631B9 dec.h 34[R25]` / `0x631BC bne` — timer tick; on expiry only:
  `0x631C5 cmp.b #7,33[R25]` / `0x631CA bge` (page capped at 7) then
  `0x631D0/D8 sub.b/add.b 63229[PC](R1)` + `inc.b` → `0x631DE mov.b R1,33[R25]`
  advances the page by 1 through the step table.
- Gated signed compare: `0x63185 cmp.b 32[R25],R0` / `0x63189 ble`.

**Every V60 op in this routine is now verified MAME-correct in sim:**
- `shl.w #7` (object-slot index, 0x62EEA): SHL always OV=0 — correct.
- signed `cmp.b` + `ble`/`bge`: differential-covered — correct.
- **halfword `dec.h` memory-RMW timer**: new directed test
  `verif/v60/tb_v60_incdecmem.sv` (tier `t07_v60_incdecmem`, 15 checks incl. the
  discriminating `dec.h 0x0701→0x0700 ⇒ Z=0`, proving it does **not** false-expire
  when the low byte hits 0). **PASS.** → the timer does not race.

**Therefore the Venom bug is NOT a V60 ALU/flag error in the camera routine.**
The `sha_left_ov` fix applied this session (a real, separately-verified bug —
`t07_v60_shaov`) is **not** in this path (the lone `sha.b` in the linear dump was
mis-decoded data) and is unlikely to fix Venom. The corruption is elsewhere:
most likely the **enemy-spawn manager** (a separate routine that reads a position
var and compares it to per-enemy thresholds) or a **data/memory** issue — not a
flag bug. Confirming it needs a *runtime* trace, below.

## Ruled out (verified correct in the RTL by inspection)

- Scroll-register readback (game doesn't use it).
- V60 condition-code table LT/GE/LE/GT (`0xc-0xf`): correct (`GE = ~(S^OV)` etc.).
- `CMP`/`SUB` overflow+carry: standard formula, correct.
- `ADD`/`ADDC` carry: byte/half use explicit zero-extended carry (`0x2893`), correct.
- `INC`/`DEC` memory RMW value + Z/borrow/OV flags (`S_RMW_EX`, ~line 1478): correct.

## Diagnostic deployed

Build with **"Camera Var" debug video mode** (OSD → Debug Video, last option) is
on the MiSTer (RBF SHA `59a666ab...`). GREEN = display low byte, MAGENTA = page
(`0x208033`) scaled. **If magenta shoots up while green is still low → page runs
ahead → hypothesis confirmed.** Also carries PF-6 (FB Overrun mode).

## Next steps (in order)

1. ~~Confirm via the Camera Var view~~ — **done: inconclusive** (0x208032 is not
   the gate; see 2026-07-21 update). The V60-flag hypotheses are exhausted; the
   camera routine executes correctly in sim.
2. **Runtime trace to find the true spawn gate (needs one short drive).** In MAME:
   set a write-tap on the enemy-object activation flags / spawn table AND read-tap
   the candidate position vars (`0x208006`, `0x208032/33`, and any var the spawn
   routine reads) with PC, then drive coin→start→char→**pan right once**. The
   variable that jumps to max on the first pan — and the PC that reads it for the
   spawn compare — is the target. (The spawn manager is a *different* routine from
   `0x63140`; find it by what writes the enemy-active flags.)
3. Compare that read/compare's core execution to MAME. If it is a genuine core
   divergence, fix + add a directed test; if the *value in memory* is already
   wrong, walk back to whoever wrote it (likely a MOV/arith width or an indexed
   addressing-mode issue rather than a flag).

## Also open (unrelated)

- **Display tearing line ~1/3 down**: sprite display-buffer swap applied ~50us
  into the visible frame (`s32_sprite.sv` R_SWAP). A deferred-to-vblank fix was
  implemented then **reverted** — it broke the sprite-FB test because it also
  delayed the game-visible buffer readback `~disp_buf` by a frame (risk of
  desyncing sprite double-buffering). Needs a triple-buffer-style approach that
  keeps the readback timing exact and defers only the mixer's view.
  - **Feasibility confirmed:** `s32_fb_if.sv` allocates **4 DDR3 buffers**
    (A/B × 2 screens; `pix_addr` indexes `buf_i[1:0]`, stride 512×256×2 =
    0x40000 each from `FB_BASE=0x30000000`). System 32 uses only buffers 0/1
    (bit 1 = screen = 0 in the shipping profile), so **buffers 2/3 are free** —
    a triple/rotating-buffer scheme needs no new DDR3 allocation.
  - **Fix sketch (needs dedicated, hardware-verified effort):** rotate three
    buffers — mixer displays X, render into Y, Z idles/erases; at vblank the
    mixer advances to the just-finished buffer. Keep the game-visible readback
    `~disp_buf` tied to the render/command rotation (unchanged timing, so no
    double-buffer desync — the failure mode of the reverted 2-buffer attempt),
    and switch only the mixer's `rd_buf` view at the frame boundary (no tear).
    Verify against `t27_sprite_fb` + the sprite differential before shipping.

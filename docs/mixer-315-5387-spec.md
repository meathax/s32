# 315-5387 mixer / 315-5388 pixel-path contract

Reference: pinned MAME `segas32_v.cpp::mix_all_layers`, `update_bitmap`, and
`update_background` at commit `a8c5e5346af728a35269a6ecd50c8e4a8df59b0b`.
The Python oracle in `verif/reference/s32_mixer_ref.py` is scalar and ordered
like MAME; it does not reproduce the RTL pipeline structure.

## Pixel sources and order

The mixer scans SPRITE, TEXT, NBG0, NBG1, NBG2, NBG3, BITMAP, and BACKGROUND
by effective priority. Non-sprite priority zero removes a layer. Background
always has effective priority 8. Equal priorities use the fixed order shown
above. Sprite grouping is selected by mixer `$4C[3:0]`; the raw pixel group
indexes the layer-order table while the OR-adjusted group chooses the sprite
priority/palette register.

Non-sprite line-buffer bit 13 is the explicit opacity bit. Sprite erase
pixels `$FFFF/$7FFF`, the group-masked `$7FFE` shadow pen, and `$4C[2]`
read-modify-write shadow behavior follow MAME's special scan rules.

## Palette and effects

For the selected layer:

```
index = (palbase + ((pixel >> mixshift) & $FFF0) + (pixel & $F)) & $3FFF
```

Signed six-bit RGB offsets are selected by `$3E` plus the layer flag and
applied in the 5-bit channel domain. If the winner's blend mask accepts the
first opaque layer below it, including the raw sprite-group comparison when
that partner is a sprite:

```
channel = (front * (7-factor) + back * (factor+1)) >>> 3
```

Sprite shadow halves the result after blending. Each channel is clamped to
0..31 only at the end and expanded to eight bits by appending three zeros.

The backdrop pixel comes from VRAM `$1FF5E`:

```
static: $1FF5E & $1E00
line:   ($1FF5E & $1E00) + (($1FF5E + display_y) & $1FF)
```

Mixer `$5E` is unrelated and must not affect the backdrop.

## Registered palette schedule

One mixer palette port serves both operands. The pixel pipeline issues the
winner index while registering the winner, switches to the runner-up at P0,
retains the winner result at P2, forms offset channels at P4, blends/shadows
at P5, and registers RGB at P6. Winner-blend control is registered with the
winner, so runner resolution and final-context capture share T3; this commits
P6 one fast clock before the next 416-wide pixel can pre-empt it. The schedule
was checked across both phases
of the 2:1 `clk_ram:clk_sys` relationship by the inferred-palette directed
test and independently generated differential vectors.

## Verification evidence

- `tb_mixer.sv`: priorities, palette index, blend, shadow, sprite raw/effective
  groups, parity RAM alignment, all color-offset modes, `$1FF5E` backdrop,
  extreme signed offsets, and distinct two-operand palette timing.
- `tb_tilemap_vram.sv`: 4-bpp nibble order; 8-bpp byte order; scroll/wrap;
  palette bases; byte opacity; bitmap clip-in and clip-out.
- `s32_mixer_ref.py`: independent MAME-ordered scalar oracle.
- `verif/mixer_diff`: randomized packed-vector comparison. Four seeds × 1,024
  cases pass; seed 5387 × 512 cases is a permanent tier-10 release gate.
- A post-change full-core Holosseum run reaches 63,383 non-black pixels at
  frame 19 and captures populated frame 20. Its sprite list independently
  replays with zero visible mismatches. Fitted hardware validation is still
  pending and is not implied by these simulation gates.

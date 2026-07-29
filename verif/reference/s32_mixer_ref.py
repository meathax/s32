"""Independent, scalar reference for the System 32 315-5388 mixer.

Structure follows MAME ``segas32_v.cpp::mix_all_layers`` rather than the
pipelined shape of ``rtl/video/s32_mixer.sv``.  Line-buffer pixels use the RTL
boundary format: bit 13 is opaque and bits 12:0 are the layer pixel value.

TWO SEMANTICS, SELECTED BY ``semantics=``
-----------------------------------------
``"hardware"`` (default) is the **accuracy gate**.  Where MAME's C code and the
real board disagree, this models the board.

``"mame"`` is a **legacy change-detector only**.  It reproduces MAME's integer
semantics bit-for-bit.  Passing it does NOT mean the RTL is correct -- it means
the RTL still matches MAME.  Never promote a "mame" comparison to an accuracy
argument.

Where the two differ, and why:

1. Colour packing.  MAME zero-fills 5-bit channels into 8 bits
   (``(r << 19) | (g << 11) | (b << 3)``), so code 31 emits 0xF8 and full white
   is unreachable.  Hardware replicates the high bits.
   Evidence: furrtek's decap of the 315-5242 shows it contains an OKI M71064,
   "a triple DAC made of printed resistors and 3 output transistors" -- a
   passive linear ladder with nothing between it and the monitor.  MacDonald
   measured the mixer colour-offset endpoints directly: ``$1F,$1F,$1F`` =
   "Screen is completely white", ``$20,$20,$20`` = "completely black".

2. Saturation.  MAME applies colour offset, blend and shadow to unclamped C
   integers and clamps once at the very end, so an out-of-range intermediate
   can propagate through the blend.  Hardware saturates at each stage.
   Evidence: MacDonald documents the offset stage as a clamped signed add in
   5-bit colour space ("result CLAMPED (no wrapping)") with the measured
   endpoints above.

See docs/ga2-pcb-accuracy-plan.md (MX8, MX3) and
docs/reference/s32tech-macdonald-2005.txt.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Sequence


TEXT, NBG0, NBG1, NBG2, NBG3, BITMAP, SPRITE, BACKGROUND = range(8)

#: Accuracy gate -- models the real 315-5388/315-5242 behaviour.
SEM_HARDWARE = "hardware"
#: Legacy change-detector -- reproduces MAME's integer semantics exactly.
SEM_MAME = "mame"


def _clamp5(value: int) -> int:
    """Saturate one colour channel into the 5-bit display domain."""
    return 31 if value > 31 else 0 if value < 0 else value


def _pack_rgb(rgb: Sequence[int], semantics: str) -> int:
    """Pack three 5-bit channels into 24-bit RGB.

    Hardware replicates the high bits so 31 -> 0xFF (full-scale on the
    315-5242's resistor ladder).  MAME zero-fills, so 31 -> 0xF8.
    """
    if semantics == SEM_MAME:
        return (rgb[0] << 19) | (rgb[1] << 11) | (rgb[2] << 3)
    expand = [(value << 3) | (value >> 2) for value in rgb]
    return (expand[0] << 16) | (expand[1] << 8) | expand[2]


@dataclass(frozen=True)
class MixResult:
    rgb: int
    winner: int
    partner: int | None
    first_palette_index: int
    second_palette_index: int | None
    blended: bool
    shadowed: bool


@dataclass(frozen=True)
class _Layer:
    index: int
    effpri: int
    palbase: int
    mixshift: int
    blendmask: int
    sprblendmask: int
    coloroffs: int


def sprite_group_params(mode: int) -> tuple[int, int, int]:
    """Return ``(shift, mask, or_value)`` for mixer register $4C."""

    table = (
        (14, 0x0, 0x1), (14, 0x1, 0x2), (13, 0x3, 0x4), (12, 0x7, 0x8),
        (14, 0x1, 0x0), (13, 0x3, 0x0), (12, 0x7, 0x0), (11, 0xF, 0x0),
        (14, 0x1, 0x0), (13, 0x3, 0x0), (12, 0x7, 0x0), (11, 0xF, 0x0),
        (13, 0x1, 0x0), (12, 0x3, 0x0), (11, 0x7, 0x0), (10, 0xF, 0x0),
    )
    return table[mode & 0xF]


def sprite_blend_mask(encoding: int) -> int:
    value = encoding & 0xF
    mode = (encoding >> 4) & 3
    if mode == 0:
        return 1 << value
    if mode == 1:
        return (1 << (value + 1)) - 1
    if mode == 2:
        return (~((1 << value) - 1)) & 0xFFFF
    return 0xFFFF


def _signed6(value: int) -> int:
    value &= 0x3F
    return value - 0x40 if value & 0x20 else value


def _color_offset(regs: Sequence[int], layer: int, layerflag: bool) -> int:
    r3e = regs[0x1F]
    bit = 8 if layer == BACKGROUND else 6 if layer == SPRITE else layer
    mode = ((r3e & 0x8000) >> 14) | ((r3e >> bit) & 1)
    if mode in (0, 3):
        return int(not layerflag)
    if mode == 1:
        return 2
    return 2 if not layerflag else 0


def _palette_index(layer: _Layer, pixel: int) -> int:
    return (
        layer.palbase
        + ((pixel >> layer.mixshift) & 0xFFF0)
        + (pixel & 0xF)
    ) & 0x3FFF


def mix_pixel(
    regs: Sequence[int],
    layer_pixels: Sequence[int],
    sprite_pixel: int,
    layer_off: int,
    bg_ctrl: int,
    y: int,
    palette: Callable[[int], int],
    semantics: str = SEM_HARDWARE,
) -> MixResult:
    """Mix one visible pixel using the layer-scan contract.

    ``regs`` contains 64 mixer words. ``layer_pixels`` contains TEXT through
    BITMAP in that order, each as ``{opaque, pixel[12:0]}``.

    ``semantics`` selects :data:`SEM_HARDWARE` (default, the accuracy gate) or
    :data:`SEM_MAME` (legacy change-detector).  See the module docstring.
    """
    if semantics not in (SEM_HARDWARE, SEM_MAME):
        raise ValueError(f"unknown semantics {semantics!r}")
    saturating = semantics == SEM_HARDWARE

    if len(regs) != 64 or len(layer_pixels) != 6:
        raise ValueError("expected 64 mixer registers and six layer pixels")

    r4c = regs[0x26]
    r4e = regs[0x27]
    shift, group_mask, group_or = sprite_group_params(r4c)
    raw_group = (sprite_pixel >> shift) & group_mask
    effective_group = group_or | raw_group
    sprreg = regs[effective_group]

    layers: list[_Layer] = []
    for layer in range(6):
        control = regs[0x10 + layer]
        priority = control & 0xF
        if not ((layer_off >> layer) & 1) and priority:
            blendreg = regs[0x18 + layer]
            layers.append(_Layer(
                index=layer,
                effpri=(priority << 3) | (6 - layer),
                palbase=(control & 0xF0) << 6,
                mixshift=(control >> 8) & 3,
                blendmask=((blendreg >> 6) & 0xFF) if r4e & 0x0800 else 0,
                sprblendmask=sprite_blend_mask(blendreg & 0x3F),
                coloroffs=_color_offset(regs, layer, bool(blendreg & 0x4000)),
            ))

    bgreg = regs[0x16]
    layers.append(_Layer(
        index=BACKGROUND,
        effpri=8,
        palbase=(bgreg & 0xF0) << 6,
        mixshift=(bgreg >> 8) & 3,
        blendmask=0,
        sprblendmask=0,
        coloroffs=_color_offset(regs, BACKGROUND, bool(regs[0x1F] & 0x4000)),
    ))

    sprite_pal = r4c if (r4c & 3) == 3 else sprreg
    layers.append(_Layer(
        index=SPRITE,
        effpri=((sprreg & 0xF) << 3) | 7,
        palbase=(sprite_pal & 0xF0) << 6,
        mixshift=(sprreg >> 8) & 3,
        blendmask=0,
        sprblendmask=0,
        coloroffs=_color_offset(regs, SPRITE, bool(r4c & 0x8000)),
    ))
    layers.sort(key=lambda item: item.effpri, reverse=True)

    sprshadowmask = 0x8000 if r4c & 4 else 0
    sprpixmask = ((1 << shift) - 1) & 0x3FFF
    sprshadow = 0x7FFE & sprpixmask

    def scan(start: int, shadow: bool) -> tuple[int, _Layer, int, bool]:
        for pos in range(start, len(layers)):
            layer = layers[pos]
            if layer.index != SPRITE:
                pixel = (bg_pixel if layer.index == BACKGROUND
                         else layer_pixels[layer.index] & 0x1FFF)
                opaque = layer.index == BACKGROUND or bool(layer_pixels[layer.index] & 0x2000)
                if opaque:
                    return pos, layer, pixel, shadow
            else:
                pixel = sprite_pixel & 0xFFFF
                shadow = bool((~pixel) & sprshadowmask)
                if (pixel & 0x7FFF) != 0x7FFF:
                    pixel &= sprpixmask
                    if (pixel & 0x7FFE) != sprshadow:
                        return pos, layer, pixel, shadow
                    shadow = True
        raise AssertionError("background must terminate every layer scan")

    bg_pixel = (bg_ctrl & 0x1E00)
    if bg_ctrl & 0x8000:
        bg_pixel += ((bg_ctrl & 0x1FF) + y) & 0x1FF

    first_pos, first, first_pixel, shadow = scan(0, False)
    first_index = _palette_index(first, first_pixel)
    first_color = palette(first_index) & 0xFFFF

    offsets = (
        tuple(_signed6(regs[0x20 + channel]) for channel in range(3)),
        tuple(_signed6(regs[0x23 + channel]) for channel in range(3)),
        (0, 0, 0),
    )
    first_delta = offsets[first.coloroffs]
    rgb = [((first_color >> (5 * channel)) & 0x1F) + first_delta[channel]
           for channel in range(3)]
    # Hardware saturates at the offset adder (MacDonald: "result CLAMPED (no
    # wrapping)"); MAME lets the intermediate run out of range into the blend.
    if saturating:
        rgb = [_clamp5(value) for value in rgb]

    partner: _Layer | None = None
    second_index: int | None = None
    blended = False
    if first.blendmask:
        _, partner, second_pixel, shadow = scan(first_pos + 1, shadow)
        if ((first.blendmask >> partner.index) & 1) and (
            partner.index != SPRITE or
            ((first.sprblendmask >> raw_group) & 1)
        ):
            second_index = _palette_index(partner, second_pixel)
            second_color = palette(second_index) & 0xFFFF
            second_delta = offsets[partner.coloroffs]
            factor = (r4e >> 8) & 7
            for channel in range(3):
                second_value = ((second_color >> (5 * channel)) & 0x1F) + second_delta[channel]
                if saturating:
                    second_value = _clamp5(second_value)
                rgb[channel] = (rgb[channel] * (7 - factor)
                                + second_value * (factor + 1)) >> 3
            blended = True
            # Saturate the blend result before the shadow stage.
            if saturating:
                rgb = [_clamp5(value) for value in rgb]

    if shadow:
        rgb = [value >> 1 for value in rgb]

    rgb = [_clamp5(value) for value in rgb]
    packed = _pack_rgb(rgb, semantics)
    return MixResult(
        rgb=packed,
        winner=first.index,
        partner=partner.index if partner else None,
        first_palette_index=first_index,
        second_palette_index=second_index,
        blended=blended,
        shadowed=shadow,
    )

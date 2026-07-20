# Sega 315-5386A OBJECT reference contract

## Scope and authority

This document freezes the software-visible and pixel-visible contract used to
complete the System 32 sprite engine for Holosseum. The authority is official
MAME commit `a8c5e5346af728a35269a6ecd50c8e4a8df59b0b`, whose provenance and
SHA-256 inventory are recorded in `mame-reference-snapshot.md`. Line references
below are to the pinned `scratch/segas32_v.cpp` unless another file is named.

The independent executable oracle is
`verif/reference/s32_sprite_ref.py`. It is deliberately event-level Python,
not a translation of `rtl/video/s32_sprite.sv`, and it has no dependency on
game ROMs. `verif/reference/test_s32_sprite_ref.py` supplies synthetic fixtures.

The oracle covers one ordinary System 32 OBJECT chip. Multi 32's second sprite
chip/buffer pair is outside the Holosseum target.

## Physical and event model

MAME allocates both physical sprite framebuffers as 416x224 words regardless
of active mode (`segas32_v.cpp:259-264`). Control byte 6 bit 0 changes only the
outer render clip from 320 to 416 pixels (`1533-1536`). The oracle therefore
always stores 416x224 words in each physical framebuffer.

At the callback scheduled 50 microseconds after VBLANK ends (`343-348`), the
controller performs operations in this order (`318-340`):

1. In automatic mode, schedule command 3 every frame at 60 Hz or every other
   frame at 30 Hz.
2. If command bit 1 is set, erase the currently visible/front buffer to
   `0xffff`.
3. If command bit 0 is set, swap front/back buffers, latch all eight control
   bytes, and render the list into the new back buffer.
4. Clear live command byte 0.

This order matters: automatic command 3 erases the old visible buffer, swaps
it behind the display, and then renders the next scene into that erased buffer.

The Python model exposes atomic `erase`, `swap`, `render`, and `vblank` events.
It does not claim cycle timing for the 50-microsecond delay, render busy, or
external memory backpressure.

## Source-traceable feature checklist

“Complete” means represented in the oracle and covered by at least one named
synthetic test. It does not mean the production RTL or MiSTer hardware has
passed the same behavior yet.

| ID | Required behavior | Pinned MAME lines | Oracle test | Oracle status |
| --- | --- | --- | --- | --- |
| CTL-01 | Eight live control bytes; writes alias on offset bits 2:0 | `401-462` | `test_manual_pending_command_and_register_latch` | Complete |
| CTL-02 | Automatic 60 Hz cadence | `318-340` | `test_erase_then_swap_then_render_order` | Complete |
| CTL-03 | Automatic 30 Hz every-other-frame cadence | `320-328` | `test_automatic_30hz_cadence` | Complete |
| CTL-04 | Manual command processing and command clear | `331-340`, `430-433` | `test_manual_pending_command_and_register_latch` | Complete |
| CTL-05 | Erase visible buffer to `0xffff` | `1194-1202` | `test_erase_then_swap_then_render_order` | Complete |
| CTL-06 | Swap front/back identity and metadata | `1205-1218` | `test_erase_then_swap_then_render_order` | Complete |
| CTL-07 | Latch all controls only at swap | `1220-1222` | `test_manual_pending_command_and_register_latch` | Complete |
| CTL-08 | Selected-buffer and latched-control reads | `401-455` | `test_manual_pending_command_and_register_latch` | Complete to MAME behavior |
| MEM-01 | Two physical 416x224 sprite buffers | `259-264` | `test_320_and_416_active_widths_share_416_word_storage` | Complete |
| MEM-02 | Sprite RAM 16-bit CPU view to graphics 32-bit lane repacking | `471-484` | `test_from_sprite_ram_repacking` | Complete |
| LIST-01 | 8192-command execution bound and 13-bit entry wrap | `1543-1548` | `test_jump_loop_is_bounded_at_8192_commands` | Complete |
| LIST-02 | DRAW command and inline-palette entry skip | `1550-1553`, `1515-1517` | `test_inline_indirect_palette_and_entry_skip`, `test_zero_dimension_inline_palette_still_skips_two_entries` | Complete |
| LIST-03 | Inclusive and exclusive CLIP commands; persistent clip-out | `1555-1579` | `test_clip_in_and_clip_out_are_inclusive` | Complete |
| LIST-04 | JUMP, optional signed X/Y offsets, and target replacement | `1581-1591` | `test_jump_sets_offsets_and_target` | Complete |
| LIST-05 | END termination | `1593-1598` | all ordinary render tests | Complete |
| DESC-01 | Command/indirect/local/shadow/from-RAM/8-bpp/opaque/flip/offset/anchor flags | `1232-1249`, `1335-1346` | pixel, palette, shadow, geometry, and list suites | Complete |
| DESC-02 | Source/destination dimensions, signed positions, source address, palette/group word | `1250-1260`, `1347-1357` | pixel and geometry suites | Complete |
| DRAW-01 | Zero dimensions suppress drawing but preserve inline skip | `1365-1367`, `1515-1517` | `test_zero_dimension_inline_palette_still_skips_two_entries` | Complete |
| DRAW-02 | 16-entry external or inline indirect palette | `1374-1380` | `test_external_indirect_palette`, `test_inline_indirect_palette_and_entry_skip` | Complete |
| DRAW-03 | All 16 control-byte-4/5 indirect transparency masks | `1322-1330`, `1369-1372` | `test_all_16_indirect_transparency_masks` | Complete |
| DRAW-04 | 8-bpp indirect table high nibble plus source low nibble | `1293-1320`, `1377-1379` | `test_8bpp_indirect_palette_preserves_low_nibble` | Complete |
| DRAW-05 | ROM versus sprite-RAM graphics and address masks | `1382-1394` | `test_from_sprite_ram_repacking`, `test_rom_address_wraps_within_4mib_bank` | Complete |
| DRAW-06 | Physical 4 MiB ROM banks; raw bank modulo installed bank count | `1333`, `1349-1351`, `1388-1394` | `test_rom_bank_modulo_and_trace_raw_vs_effective` | Complete |
| GEO-01 | Exact integer 16.16 horizontal and vertical zoom | `1396-1398`, `1452-1513` | `test_horizontal_scaling_exact_fixed_point_sequence`, `test_vertical_scaling_and_flip` | Complete |
| GEO-02 | Jump offsets and all four X/Y anchor encodings; even-size rounding | `1400-1420` | `test_jump_sets_offsets_and_target`, `test_all_anchor_encodings_and_even_center_rounding` | Complete |
| GEO-03 | Per-object X/Y flip and signed/off-screen positions | `1422-1450` | `test_horizontal_flip_reverses_destination_direction`, `test_vertical_scaling_and_flip`, `test_signed_offscreen_position_clips_safely` | Complete |
| GEO-04 | Inclusive clip-in, exclusive clip-out, and 320/416 outer clip | `1438-1459`, `1533-1541`, `1555-1575` | clip and active-width tests | Complete |
| PIX-01 | Direct 4-bpp extraction and palette composition | `1264-1291`, `1462-1485` | `test_direct_4bpp_and_normal_end_code` | Complete |
| PIX-02 | Direct 8-bpp extraction and palette composition | `1293-1320`, `1487-1506` | `test_direct_8bpp` | Complete |
| PIX-03 | Edge transparency, low-edge end code, and opaque-mode behavior | `1264-1320`, `1471-1505` | `test_end_code_only_terminates_on_low_edge_pixel`, `test_opaque_mode_disables_end_code_but_zero_remains_empty` | Complete |
| PIX-04 | Shadow clears destination bit 15 rather than replacing color | `1272-1289`, `1301-1318`, `1337` | `test_shadow_clears_bit15_of_existing_destination` | Complete |
| SCAN-01 | Global control-byte-2 X/Y flip is applied at sprite scanout | `1800-1850` | `test_global_flip_is_scanout_only_not_physical_render` | Complete |
| MODE-01 | 320- and 416-pixel active modes over 416-word storage | `446-448`, `1533-1536` | `test_320_and_416_active_widths_share_416_word_storage` | Complete |

## Deterministic oracle schema

Invoke the oracle from the repository root:

```text
python -m verif.reference.s32_sprite_ref render capture/manifest.json --output-dir capture/oracle
```

Schema `s32.sprite.v1` is JSON. Blob paths are relative to the manifest:

```json
{
  "schema": "s32.sprite.v1",
  "width": 320,
  "controls": [0, 0, 0, 2, 0, 0, 0, 0],
  "latched_controls": [0, 0, 0, 2, 0, 0, 0, 0],
  "selected_buffer": 1,
  "render_count": 0,
  "sprite_ram": {"path": "sprite-ram.bin", "format": "u16le"},
  "sprite_rom": {"path": "sprite-region.bin", "format": "mame-region-bytes"},
  "front_fb": {"path": "front.bin", "format": "u16le"},
  "back_fb": {"path": "back.bin", "format": "u16le"},
  "events": ["render"],
  "repeat": 1,
  "trace_level": "fetches"
}
```

Inputs are:

| Input | Required size/meaning |
| --- | --- |
| `controls` | Eight live bytes |
| `latched_controls` | Eight bytes currently governing rendering; defaults to `controls` |
| `sprite_ram` | Exactly 131072 bytes: 65536 unsigned 16-bit little-endian words |
| `sprite_rom` | Raw bytes of the reconstructed MAME `ROM_REGION32_BE`; a nonzero whole number of 4 MiB banks |
| `front_fb`, `back_fb` | Optional, each exactly 186368 bytes: 416x224 unsigned 16-bit little-endian words; default `0xffff` |
| `selected_buffer` | Observable selected-buffer bit, 0 or 1; defaults to MAME reset identity 1 |
| `render_count` | Automatic 30 Hz cadence state |
| `events` | Any sequence of `erase`, `swap`, `render`, and `vblank` |
| `trace_level` | `none`, `commands`, `fetches`, or `pixels` |

If supplied, `width` must agree with latched control byte 6 bit 0. A bare path
may replace any blob object, but an explicit wrong `format` is rejected.

Outputs are deterministic:

| Output | Meaning |
| --- | --- |
| `front.fb16le` | Full physical 416x224 visible buffer |
| `back.fb16le` | Full physical 416x224 render buffer |
| `scanout.fb16le` | Active 320x224 or 416x224 visible sprite plane after global control-byte-2 flip |
| `result.json` | Controls, status reads, termination, counters, installed ROM-bank count, and SHA-256 hashes |
| `trace.jsonl` | Ordered command/geometry/fetch/pixel events at the selected trace level |

Fetch trace records include raw and effective bank and word address. This is
required to diagnose bank mirroring and per-bank 20-bit wrapping independently.

## Holosseum ROM-bank contract

Holosseum declares an 8 MiB `ROM_REGION32_BE` populated by eight 1 MiB lanes
(`scratch/segas32.cpp:4107-4115`). MAME views that as two physical 4 MiB
OBJECT banks and computes `effective_bank = raw_bank % 2`. An oracle replay
must therefore trim its reconstructed region to exactly 8 MiB. Feeding the
oracle a generic 16 MiB image padded with `0xff` would incorrectly advertise
four physical banks and is rejected by the Holosseum capture workflow.

The core's MRA descriptor now carries the same physical fact in byte 3:

- bit 7: sprite-bank metadata is valid;
- bits 1:0: physical 4 MiB bank mask (`0`, `1`, or `3` for 4, 8, or 16 MiB);
- Holosseum: byte 3 is `0x81`, so descriptor bank 3 mirrors to bank 1;
- legacy descriptor byte 3 value `0x00`: metadata absent, so the core defaults
  to mask 3 for backward-compatible 16 MiB behavior.

For power-of-two bank populations, the RTL mask and MAME modulo are equivalent.
The software oracle derives the population from the unpadded ROM byte length;
it does not consume MRA metadata.

## Global-flip equivalence rule

MAME stores an unflipped physical sprite buffer and reverses sprite X/Y reads
during mixer scanout (`1800-1850`). The production RTL may instead mirror
framebuffer write coordinates and then scan memory sequentially. Those storage
orientations are architecturally equivalent if the visible active image is
identical.

Therefore:

- with control byte 2 equal to zero, physical back-buffer comparison is exact;
- with a global flip active, compare the oracle's `scanout.fb16le` to visible
  RTL output, or apply an explicit storage-orientation adapter before comparing
  raw framebuffers;
- do not normalize descriptor-local X/Y flips; those are part of object
  rendering and must match directly.

MAME's `ORIENTATION_FLIP_Y` declaration for the Holosseum cabinet is frontend
display orientation, not a 315-5386A object-list operation, and is outside this
oracle.

## Known limits and honest gaps

The pinned MAME implementation itself hardcodes control status 1 to “normal”
and does not expose a real overdraw state (`401-423`). Its erase is an atomic
bitmap fill, so neither MAME nor this oracle can specify the brief erase-busy
bit or cycle-accurate renderer deadline. Those require RTL protocol assertions
and bounded-latency tests, not pixel-oracle inference.

The oracle intentionally does not model:

- cycle timing, ROM/DDR request acknowledgements, or backpressure;
- the undocumented hardware meaning of control bytes 4/5 beyond behavior MAME
  actually consumes for indirect transparency and shadow enable;
- invalid indirect-palette tables that cross the end of sprite RAM (the oracle
  wraps physical RAM addresses deterministically; valid game lists do not rely
  on this boundary);
- Multi 32's second sprite target and routing bit;
- mixer priority, final RGB palette conversion, or cabinet orientation.

## RTL verification status (2026-07-20)

The executable contract and production RTL now pass these pre-hardware gates:

- independent Python oracle: 28/28 unit tests;
- complete System 32 ModelSim regression: 35/35 tiers, including the directed
  OBJECT pixel, divider, framebuffer-backpressure, ROM-loader, boot, and soak
  tests;
- differential replay: 32/32 cases with zero visible-pixel mismatches.  This
  is the Cartesian product of 4/8/16 MiB OBJECT regions, all four control-byte-2
  flip values, and both 320/416 active widths, plus eight no-DRAW preservation
  baselines;
- every differential replay randomizes sprite-ROM acknowledgement latency and
  framebuffer backpressure and asserts stable requests, balanced pixel runs,
  bounded list execution, and renderer liveness;
- a 1024-DRAW Holo-bank stress fixture also matches exactly, including raw
  banks 0..3, from-RAM pixels, indirect palettes, shadow, zoom, clipping, and
  535,598 accepted framebuffer writes.
- Quartus 17 analysis and elaboration of the complete MiSTer project succeeds
  with zero errors.  This gate performs no fitter, assembler, RBF generation,
  or hardware deployment.

At the production 96.634615 MHz renderer clock, the maximum ordinary 32-DRAW
matrix case used 74,228 cycles (0.77 ms).  The deliberately pathological
1024-DRAW fixture used 1,538,111 cycles (15.92 ms) without external stalls,
1,622,501 cycles (16.79 ms) with normal randomized contention, and 1,688,756
cycles (17.48 ms) with the ROM-latency mask doubled.  The latter two are
liveness/overload results, not a promise that arbitrary 1024-object, 535k-write
overdraw completes inside every 60 Hz frame.  A real-game deadline must be
checked against captured production lists after the main CPU reaches attract
mode.

The real-ROM Holo capture workflow is operational.  Automatic-mode frames
1..3 and manual-mode render events at frames 15 and 17 all replay with zero
mismatches.  Frames 1..3 are early initialization only: frame 1 walks a
bounded all-zero 8192-entry list without drawing, while frames 2 and 3 contain
only CLIP/END.  Frames 13, 14, 16, and 18 issue manual command 0 and are
retained as audited raw captures rather than being misrepresented as render
events.  Frame 15 issues manual command 3 (erase, swap, render); its all-zero
list finishes in 94,990 renderer cycles with no ROM fetches or pixel writes
and an exact 416x224 framebuffer match.

The full core progresses through Holo's initialization clears.  MAME
disassembly identifies the earlier `0x000604e8`/`0x000604eb` sequence as
`MOV.W R2,[R0+]` / `DBR R1`, clearing 0x7000 words from 0x300000; the later
`0x0006050f` sequence is likewise observed while CPU sprite-RAM writes advance
by tens of thousands per frame.  These are not CPU or interrupt failures.  A
frame-19 capture then exits the clear with a minimal CLIP/END list, and frames
20..24 contain the first nontrivial production list.

Each frame-20..24 replay executes JUMP, two DRAWs, and END; performs 2,432 ROM
requests; accepts 256 pixel runs and 25,043 pixel writes; and completes in at
most 100,024 renderer cycles (1.04 ms).  Both DRAWs request raw OBJECT bank 3,
which is correctly mirrored to Holosseum's installed bank 1.  Control byte 2
globally flips Y, so the RTL's intentionally mirrored physical-buffer storage
does not byte-match MAME's unflipped physical bitmap.  After the documented
scanout orientation adapter, every visible pixel across all five frames
matches the independent oracle exactly.  This closes the nontrivial real-Holo
OBJECT-list gate for the pre-hardware phase.

MiSTer validation remains a later system-integration gate and is intentionally
not implied by these simulation results.

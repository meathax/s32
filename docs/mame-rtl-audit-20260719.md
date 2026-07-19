# MAME-driven RTL audit — 2026-07-19

This milestone uses official MAME commit
`a8c5e5346af728a35269a6ecd50c8e4a8df59b0b` as the behavioral contract.
The pinned source inventory and hashes are in `mame-reference-snapshot.md` and
`v60-mame-audit.md`. No RBF was built in this phase.

## Implemented corrections

- Real V25 execution: vendored GPL-3.0 s80x86, opcode-only GA2/Arabian Fight
  decryption, inverse ROM address descramble, exact ROM/mailbox mapping, and a
  synchronous 2500/12081 clock-enable. Genuine GA2 firmware writes the complete
  wake string, response table, and stack state with no unexpected I/O/unmapped
  accesses.
- Sprites/mixer: clip-out persistence, widened signed jump/position arithmetic,
  16.16 zoom, global sprite flip, and separate raw/effective sprite groups for
  blend-mask versus palette/priority selection.
- Tile/background: independently masked palette write-both, separate NBG2/3
  rowselect tables, row-feature disable bits, X offsets, zoom-Y selection,
  layer/global/text flips, and flipped clipping coordinates.
- MultiPCM: channel-selector holes, register/sample widths, descriptor `sample*12`
  addressing, retrigger sequencing, pitch convention, signed PCM, pan/mute,
  loop-end representation, accumulation/saturation, deterministic reset, and
  ROM ACK capture outside the audio CE.
- Sound integration: CNT2 now resets only the T80, reset state matches MAME,
  and bank/IRQ/WAIT contracts have directed coverage.
- V60/bus: corrected ROT/ROTC carry, active-width insertion and zero-count
  behavior; deterministic NMI edge history; verified all external lane/alignment
  cycle patterns.
- Top-level decode: corrected palette/mixer and I/O mirrors, exact expansion
  subranges, and the GA2 MB8421 window at `0xA00000-0xA00FFF`.

## Verification

The native regression passes **35/35 tiers** with **10/10 V60 differential
seeds**. It includes full-core boot/soak, GA2 path, production mixed-language
T80, sprite/tile/palette/framebuffer, MultiPCM, sound bus, V60 rotate/bus,
top-level map decode, and genuine encrypted V25 firmware/cadence checks.

## Remaining qualification

- Run a new Quartus fit and static-timing analysis; the real V25 CE fanout and
  the updated video/audio logic are not yet fitted.
- Build/deploy only after the fit is timing-clean, then repeat sustained GA2
  gameplay through the waterfall/magic-heavy scene.
- MultiPCM still lacks packed 12-bit decode, interpolation, complete TL/ADSR/KRS
  envelopes, and LFO modulation.
- Tilemap fractional 12.20 scroll words `$1FF10/$1FF14` are not exposed through
  the current VRAM/top interface.

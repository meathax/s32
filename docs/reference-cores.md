# Reference-core improvement ledger

This project uses mature open FPGA cores as implementation references for
shared chips and proven MiSTer architecture. Reference checkouts live under
ignored `scratch/upstream/`; they are not vendored or built into this core.

## Source and license policy

The System 32 repository currently has no top-level license. GPL reference RTL
must therefore not be copied into the tracked source tree. We may compare
observable architecture and behavior, then implement the required behavior
independently and cover it with original tests. Existing third-party blocks
already carried by this repository retain their own license notices.

## Primary reference: Jotego System 18 / System 16

- Repository: `jotego/jtcores`
- Audited commit: `de942955dce4accd6c242cc408e2c27cb347b0ac`
- License: GPL-3.0
- Local reference: `scratch/upstream/jtcores`

System 18 is the closest FPGA hardware match for System 32 audio. Its
`jtpcm568`, dual `jt12`, and Z80 integration confirm the important structure:

- RF5C68 processing is eight channels at 48 chip clocks per channel, producing
  one output every 384 chip clocks.
- CPU wave-RAM access and PCM playback use distinct RAM ports.
- Channel address, enable, loop, pan, envelope, and frequency state are kept
  per voice.
- RF5C68 output is a 10-bit signal, not an unrestricted 16-bit sum.
- The sound CPU must remain stalled until a requested ROM word is actually
  valid; the pending SDRAM request and valid cache tag are separate state.

System 16/16B is the primary comparative source for Sega sprite scan/draw
separation, priority, shadow, ROM scheduling, and bounded video work. Its
sprite encoding is not System 32-compatible, so its command decoder is not a
source of truth for the 315-5386A.

### Improvements derived from this comparison

- `s32_rf5c68` now uses a wide eight-voice accumulator, final signed clipping,
  and RF5C68 10-bit quantization; wave RAM is stored inverted so zero-filled
  FPGA block RAM represents the chip's logical `0xff` start state.
- A real mixed-language T80 simulation mode and sound-ROM boot test now execute
  Z80 code through the production bus decode into RF5C68 wave RAM/registers.
- The sound-ROM cache now has separate pending-request and valid-data tags.
  Previously the request address was treated as valid before SDRAM returned,
  allowing the T80 to consume stale opcode bytes.
- T80 internal direct-entity instantiations use standard VHDL syntax, and its
  save-state/debug inputs are explicitly tied inactive instead of relying on
  cross-language default-port behavior.
- The sprite framebuffer now gives a pending display-line fetch priority over
  a deferred draw flush, matching the reference cores' separation of
  deadline-bound scanout from deferrable rendering. One explicit acceptance
  condition retains the queued run until it really starts.
- Sprite control registers 4 and 5 now return their latched low bits, matching
  the System 32 controller contract instead of always returning `0xfc`.

## Secondary reference: MiSTer S32X

- Repository: `MiSTer-devel/S32X_MiSTer`
- Audited commit: `b438679e897eecca6926fff22083d6f86a8265a3`
- GitHub reports no SPDX license; use as read-only architecture reference.
- Local reference: `scratch/upstream/S32X_MiSTer`

Useful patterns are restricted to Sega double-framebuffer ownership, latching
the display-select state at a safe video boundary, write FIFO/backpressure,
and explicit separation of draw and display ports. The 32X VDP pixel format
and CPU architecture are unrelated to System 32 and must not be transplanted.

## Secondary reference: MiSTer Irem M92

- Repository: `MiSTer-devel/Arcade-IremM92_MiSTer`
- Audited commit: `68a4683e237eafca02e3df56dd84bacc255fba55`
- License: GPL-2.0
- Local reference: `scratch/upstream/Arcade-IremM92_MiSTer`

M92 is useful for bounded sprite processing, explicit DMA-busy lifetime,
sprite-buffer ownership, line-buffer limits, and a NEC-family CPU connected to
an arcade memory system. Its GA21/GA22 object formats and V33/V35 CPU behavior
are not compatible with Sega System 32.

## JTFRAME SDRAM reference

The sparse Jotego checkout also includes JTFRAME SDRAM cache/arbitration RTL
and tests. It is used to audit request/ack ownership, cache-tag validity,
download backpressure, starvation bounds, and CDC assumptions. Its modules are
GPL-3.0 and are not copied into this project.

The local SDRAM controller now uses a true mailbox per client: request address,
and write data/byte enables where applicable, are captured with the request.
Previously only the pending bit was latched, so a delayed pulsed request could
execute at a later live address. The new directed test holds p4 behind a p2
burst, changes p4's live address, and proves the original RTL fails while the
mailbox implementation returns data for the captured address.

## Verification snapshot

The reference-derived revision passes the native Windows regression at
**30/30 tiers** with **10/10 V60 differential seeds**. This includes Golden
Axe II release/path checks, framebuffer contention, SDRAM capture/mailbox,
sprite rendering/control, RF5C68, production T80 sound-ROM execution, and
full-core soak. Transcript:
`verif/modelsim-regression-reference-improvements.log`.

## Comparison rule

For every adopted pattern:

1. identify the shared hardware property;
2. verify that it applies to System 32 rather than merely to the reference
   board;
3. implement it independently in this core;
4. add a directed regression that fails on the old behavior; and
5. record the reference commit and the resulting local change here.

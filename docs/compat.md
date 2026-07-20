# Compatibility matrix — Sega System 32 / Multi 32 core

Status legend: `rtl` = RTL implemented, not yet exercised with that real set ·
`sim` = actual ROM ZIP reaches a meaningful boot/render milestone in the
full-core simulator · `hw` = boots and reaches playable operation on MiSTer,
but still has known correctness gaps · `gold` = verified against reference
output and hardware · `wip` = known gaps without the `hw` milestone ·
`unsupported` = out of scope (see DESIGN.md §1.3)

`sim` is deliberately not `gold`: the real-ROM harness idealizes external
DDR/audio service and does not prove physical timing, sustained gameplay, or
pixel/audio equivalence.

The core is in the **simulation bring-up / Quartus integration phase**.
Current verification evidence:

- V60 smoke + directed suites (memory operands, stack, JSR/RET, full
  interrupt entry/RETIU) — PASS
- **Full-core integration boot** — a synthetic V60 program boots from the
  reset vector inside `s32_core`, its stores land in palette/VRAM through
  the complete bus decode, the CRT generates sync, and the vblank IRQ
  propagates through `s32_intc` into the CPU handler — PASS
- Cyclone V module synthesizability proven with yosys (`docs/synthesis.md`):
  V60 ≈ 12.3K ALUTs (matches the §10.3 budget), sprite/mixer well inside
  their budgets
- MAME co-simulation harness ready in `verif/cosim/` plus an **independent
  Python V60 reference** for differential testing (100/100 seeds in the
  historical stress run; 50/50 in the latest complete Windows regression)
- **§11.6 synthetic simulator-tier acceptance passes** (`tb_core_soak`):
  the assembled core boots, drives the full bus decode to a clean HALT,
  delivers a vblank interrupt to its handler, and soaks the render/audio
  pipeline over an
  extended multi-frame window with zero X-propagation
- The regression script now contains **35 tiers**. In addition to the CPU,
  full-core boot/soak, ROM-loader, EEPROM, video, BRAM, and V25 coverage, the
  final tiers exercise SDRAM input capture, an integrated sprite renderer
  under DDR backpressure, interrupt reset/source-ack/timer behavior, and
  signed audio-route saturation, MultiPCM semantics, V60 rotate/bus behavior,
  top-level map decode, and genuine V25 firmware. The native Windows ModelSim
  runner completes the combined matrix with **35/35 tiers PASS** and **50/50 V60 differential
  seeds PASS**; its detailed transcript is
  `verif/modelsim-regression.log`.
- The ga2-only Quartus profile completes Analysis & Synthesis at a **map-only
  estimate of 26,851 / 41,910 ALMs**. This is not a fitter resource or timing
  result.

## Real-ROM simulation milestones

`tools/make_sim_images.py` now consumes MAME ZIPs directly and constructs the
same descriptor/region layout streamed by an MRA. Locally available `holo`, `ga2`, `svf`, `arabfgt`, and `spidman` sets
have been used; the ZIPs and generated images remain
under the ignored `roms/` tree.

| Set | Evidence from the full-core real-ROM harness | Current limit |
|---|---|---|
| `holo` | EEPROM initialization completes, IRQs run, and the final-mixer run reaches 63,383 non-black pixels at frame 19 before capturing populated frame 20. That frame's JUMP/two-DRAW/END list replays with zero visible mismatches. A production-T80 full-core trace proves CNT2 release and 130,470 sound-CPU opcode cycles by frame 1. The focused real-ROM audio gate initializes both production JT12 YM cores (2,208/2,184 writes) and RF5C68 (156 register + 12,287 wave-RAM writes) with no unknown FM, PCM, or mixed-output samples. On MiSTer it boots into gameplay with working controls, sound, and the expected mirrored-sprite floor effect. | Hardware colors/palette remain wrong after the dual-clock palette-read correction. Reference audio, extended play, and start-to-end certification remain open. |
| `arabfgt` | An eight-frame universal-RTL probe reaches mixer, VRAM, palette, and sprite-list writes by frames 2–5 and completes without simulator errors. | Early initialization evidence only; no recognizable frame or sustained-play result yet. |
| `spidman` | An eight-frame universal-RTL probe executes real code and I/O traffic without simulator errors. On MiSTer it boots into gameplay with correct colors/palette, working controls and working sound. | Hardware sound is incomplete/incorrect in places, and enemy attack behavior has known gameplay defects. Extended-play and reference-accuracy certification remain open. |
| `ga2` | V25 wake-up/protection passes and interrupts enable. Scripted coin is sampled at frames 41/42 and Start at 51/52; after the Start transition, frame 63 reaches the first populated sprite list (`spr_cmd=4`, `srom=5968`, `sprpx=52722`). Frame 64 reports `spr_opq=42393` with real pixels reaching the mixer. A 90-frame run (0–89) completes with `ROMBOOT DONE`, zero errors/warnings; rendering remains stable through frame 89 at four commands and about 5.8–6.0K sprite-ROM requests/frame (`sprpx=1374558` cumulative). The frame-80 capture visibly resolves the skull/candle Golden Axe character-select screen, `STERN`, a player sprite, and `Credits 0`. | Recognizable renderer output in simulation only: no pixel/audio equivalence, full play-through, or hardware result yet. |
| `svf` | Startup delay exits around frame 46 versus about 45 expected; display/rendering is active by frame 79; an 82-frame run and frame-80 PPM completed. | Harness does not validate real DDR/audio timing. |

For four-state simulation, `tb_core_romboot.sv` initializes V60 R0–R30 once
at testbench startup, mirroring MAME's deterministic device-start state and
preventing an `X`-valued GPR from poisoning game RAM. This does not alter the
production CPU or its soft-reset semantics.

The ga2 frame-80 artifacts are retained at
`verif/modelsim_romboot/dump80.png`.

The V60 fetch-performance tier that came from `svf` measures 3,130 cycles and
10 bus reads for the directed loop, versus the pre-fix 12,310 cycles and 2,305
reads (3.93× faster). Short backwards branches can reuse the retained prior
fetch window while other opcodes use conservative fetch thresholds.

Per-game acceptance still requires a fitted, timing-clean RBF and sustained
play on a physical DE10-Nano. No set is hardware-`gold` yet.

| Set | Title | Board | Protection path | Status |
|---|---|---|---|---|
| arescue (+2) | Air Rescue | dual-direct + DSP | DSP HLE + bridge | rtl |
| alien3 (+2) | Alien3: The Gun | analog | — | rtl |
| arabfgt (+2) | Arabian Fight | V25 (arf table) | real V25 CPU | rtl |
| brival (+1) | Burning Rival | 4-player | string DMA HLE | rtl |
| darkedge (+1) | Dark Edge | 4-player | FD1149 vblank HLE | rtl |
| dbzvrvs | Dragon Ball Z V.R.V.S. | analog | copy HLE | rtl |
| f1en (+2) | F1 Exhaust Note | dual-direct | bridge responder | rtl |
| f1lap (+2) | F1 Super Lap | analog | FD1149 vblank HLE (f1lapt: none) | rtl |
| ga2 (+2) | Golden Axe: Revenge of Death Adder | V25 (ga2 table) | real V25 CPU | sim |
| holo | Holosseum | regular | — | hw |
| jpark (+3) | Jurassic Park | analog | MRA patch | rtl |
| kokoroj (+1), kokoroj2 | Soreike Kokology 1/2 | CD | SCSI stubs; CD audio stretch | wip |
| radm (+1) | Rad Mobile | analog | — (EEPROM preload) | rtl |
| radr (+2) | Rad Rally | analog | — (EEPROM preload) | rtl |
| slipstrm (+1) | Slip Stream | analog | — | rtl |
| sonic (+1) | SegaSonic The Hedgehog | trackball | level-load HLE (rev C) | rtl |
| spidman (+2) | Spider-Man | 4-player | — | hw |
| svf (+4) | Super Visual Football / J.League | regular | jleague hook | sim |
| harddunk (+1) | Hard Dunk | Multi 32 6P | — | rtl |
| orunners (+2) | OutRunners | Multi 32 analog | — | rtl |
| scross (+2) | Stadium Cross | Multi 32 analog | — | rtl |
| titlef (+2) | Title Fight | Multi 32 | — | rtl |
| as1 (+3) | AS-1 Controller | Multi 32 + LD | — | **unsupported** |

Holosseum's current `sim` evidence includes a complete EEPROM/IRQ boot to
populated frame 20 with the final V60 System 32 profile. Its real sprite list
replays as JUMP, two DRAWs, END (2,432 ROM requests, 25,043 written pixels)
with zero visible mismatches against the independent 315-5386A oracle. The
post-mixer full-core run reaches 63,383 non-black pixels at frame 19. The
bitmap/mixer path also has directed 4/8-bpp coverage, 4,096 randomized stress
pixels, and a permanent 512-case 315-5387 differential gate, but this remains
simulator evidence rather than an RBF or physical-gameplay certification.

## Remaining release and compatibility gaps

- **Quartus:** Analysis & Synthesis completes for the ga2-only profile at an
  estimated 26,851 / 41,910 ALMs. That is a **map-only estimate**; no
  successful fitter resource report or timing-closure result is recorded
  yet, and a release RBF is not available for deployment.
- **MiSTer:** GA2 has reached attract mode and controllable gameplay; Start,
  movement, attack, and jump were confirmed. That run used the earlier V25/HLE
  candidate and exposed video/sprite faults, so the new real-V25 and MAME-audited
  RTL still requires a fitted, timing-clean RBF and sustained board validation.
- **Persistence:** index-2 defaults and index-3 saves load; enabled EEPROM
  writes/erases raise `ioctl_upload_req`, survive soft reset, and upload the
  64×16 shadow as 128 little-endian bytes. The shadow now infers an explicit
  dual-port M10K and stores inverted data so zero power-up reads as erased
  `0xFFFF`. The focused serial/NVRAM test, isolated Quartus inference test,
  and full regression pass; an actual MiSTer save/reload cycle remains part
  of board validation.
- **Real-ROM coverage:** `holo`, `ga2`, and `svf` have current full-core
  simulation evidence. Holosseum and Spider-Man additionally reach playable
  operation on MiSTer. Holosseum's palette remains wrong after the palette
  clock-domain correction; Spider-Man's
  palette and controls are correct, but its missing/incorrect sounds and
  enemy-attack behavior prevent accuracy or extended-play certification.
- **V60:** the integer/string/decimal/bit-string paths now have directed
  coverage, including a 20-byte F1 instruction whose second displacement is
  at fetch-buffer offset 16 and ga2's encoded `SKPCUH` found/exhausted
  behavior. Uncommon-instruction and exception edge cases still need a
  larger MAME trace corpus. Floating-point groups 0x5C/0x5F remain trapped
  (MAME's System 32 core also leaves these unhandled).
- **Video/audio edge cases:** from-RAM sprites, cocktail/mix-time screen flip,
  worst-case sprite overdraw, and final PCM envelope/LFO/loop fidelity need
  game-driven validation.
- **Multi 32:** the second palette/mixer exists, but independent screen-B
  fetch/output, side-by-side presentation, analog variants, and six-player
  behavior are not hardware-validated.
- **CD/laserdisc sets:** Kokology CD support remains WIP; AS-1 laserdisc sets
  remain out of scope.

## Full-repository audit

The initial file-by-file audit against the MAME sources
([docs/audit.md](audit.md)) found and fixed **18 additional items**: 9 V60
CPU correctness bugs (string-op operand encoding, TRAP/BRKV 3-word exception
frames, RET/CALL AP handling, RSR pop width, MULX/DIVX operand sizes, BRK
no-op), 7 integration/I-O bugs (sound-ROM fetch address hardwired to 0,
EEPROM readback on the wrong port, DIP switches unreachable, trackball
chip-select decode, 416/320 mode select, palette blend-pair mirror, Multi 32
second mixer/palette), and generator self-checks. Later real-ROM and MiSTer
integration rounds added the Round 10–12 findings and focused regression
tiers described above.

## Bugs already found and fixed by the in-repo verification tiers

These are defects the §11 tiers caught before any hardware existed —
the design doc's verification-first approach working as intended:

1. **Signed divide** (differential co-sim): DIV/DIVU selector tested the
   wrong opcode bit; divider lacked magnitude/sign handling.
2. **Bus ack handshake** (integration boot): single-cycle ack pulses could
   phase-lock against the CE-gated adapter and never be sampled; ack is now
   held until consumed, side-effect registers strobe once per transaction.
3. **p0 ROM-fetch mapping** (soak bring-up): fetches above address 0
   mis-mapped through the testbench/core address chain.
4. **315-5296 register decode** (soak/§11.6): registers decoded at 4-byte
   spacing instead of the chip's 2-byte byte-lane map, making CNT
   (display enable) unreachable — no game could ever have un-blanked the
   screen.
5. **Line-buffer bank aliasing** (soak/§11.6): the render-kick toggled the
   bank the mixer was about to read; now parity-indexed (line L in bank
   L[0]).
6. **BRAM power-on X** (soak/§11.6): deterministic simulation-only
   initialization prevents unwritten RAM from X-poisoning RGB. Large RAM
   clears are excluded from synthesis because game software initializes the
   memories and Quartus 17 cannot elaborate the loops efficiently.
7. **Video register file power-on X** (soak/§11.6): the latched $31FF00
   register file (scroll/zoom/page selects) powered up X in simulation,
   X-poisoning the tilemap's address arithmetic so every rendered pen
   collapsed to 0 in the mixer — a permanently black tilemap layer. Now
   zero-initialized (zoom = 0x200 neutral) matching Cyclone V flop
   power-on. With this fix the soak renders 84,864 visible pixels through
   the complete CPU->VRAM->SDRAM->line-buffer->mixer->palette->RGB chain,
   and the soak's acceptance gate requires non-black output.

# Sega System 32 / Multi 32 — MiSTer FPGA Core

An in-development MiSTer FPGA core for the **Sega System 32** and
**Sega Multi 32** arcade platforms (1990–1995): Golden Axe: The Revenge of
Death Adder, SegaSonic the Hedgehog, Spider-Man, Arabian Fight, Burning
Rival, Dark Edge, Alien3: The Gun, Jurassic Park, Rad Mobile, Rad Rally,
F1 Exhaust Note, F1 Super Lap, Air Rescue, Dragon Ball Z V.R.V.S.,
Holosseum, Slip Stream, Super Visual Football, OutRunners, Stadium Cross,
Title Fight, Hard Dunk, and more.

**Goal: every game in the MAME `segas32` driver running correctly on a
DE10-Nano.** This includes a from-scratch NEC V60/V70 CPU core — the first
FPGA implementation of this processor family.

## Current status

🕹️ **Current release focus: Holosseum (US, Rev A).** Its non-V25 regular
System 32 profile now boots through frame 20 in full-core simulation, reaches
320-wide display activity, and produces a populated JUMP/two-DRAW/END sprite
list whose 25,043 visible writes match the independent MAME-derived oracle
exactly. The release descriptor also applies Holosseum's required cabinet Y
orientation. The Holo-only Quartus Lite 17.1 seed-6 build now fits at 74% ALM
and 89% RAM use, meets the 96.63 MHz core clock with +0.314 ns setup slack,
and emits a current RBF. On MiSTer, Holosseum boots into controllable gameplay
with sound and the expected mirrored-sprite floor effect; its hardware palette
remains incorrect after the dual-clock palette-read correction and is the
active video acceptance issue. Spider-Man
also reaches gameplay on this build with correct colors/palette and controls;
its sound has missing/incorrect elements and enemy attacks remain defective.
Earlier GA2 hardware runs reached controllable gameplay and remain useful
historical integration evidence, but GA2 is not this profile's current target.

The regression now has **35 tiers** (`verif/run_regression.sh`, plus the
native Windows ModelSim runner `verif/run_regression.ps1`): RTL lint, V60
smoke/directed/differential suites, full-core boot and soak, ga2 boot path,
framebuffer/mixer/sprite tests, decimal and bit-string groups, V60 fetch
performance, ROM-loader/reset gating, EEPROM NVRAM semantics, SDRAM capture,
integrated sprite/DDR backpressure, interrupt-controller collision/timer
coverage, and signed audio-route saturation. The latest complete native
Windows run passes **35/35 tiers** with **50/50 V60 differential seeds**.
The dedicated game profiles also retain independent structural elaboration
and compatibility boot coverage.

The copyrighted ROMs are kept locally under ignored `roms/`. The image
builder (`tools/make_sim_images.py`) reads MAME ZIPs directly and has produced
full SDRAM-layout images for `holo`, `ga2`, and `svf`:

- **holo:** completes its EEPROM/IRQ boot path. A fresh final-mixer run reaches
  63,383 non-black pixels at frame 19 and captures a populated frame 20. A
  production-T80 full-core gate also proves the V60's CNT2 release starts the
  real sound CPU (130,470 opcode cycles by frame 1). In the focused real-ROM
  audio gate, Holo performs 2,208/2,184 writes to the two production JT12 YM
  interfaces, 156 RF5C68 register writes, and 12,287 wave-RAM writes with no
  unknown FM, PCM, or mixed-output samples.
- **ga2:** reaches the V25 wake-up/protection path, enables interrupts, and
  advances into attract code; the indexed-jump error found on this path is
  fixed. Its object-bucket scan also exposed an inverted V60 `SKPCUH` zero
  flag; the MAME-compatible result flags/registers and the exact instruction
  encoding now have a directed test. In the corrected scripted-input run,
  coin is sampled at frames 41/42 and Start at frames 51/52. After the Start
  transition, frame 63 is the first populated sprite list (`spr_cmd=4`,
  `srom=5968`, `sprpx=52722`); frame 64 reports `spr_opq=42393` and real
  sprite pixels reach the mixer. Frames 64–69 sustain about 5.9K sprite-ROM
  requests and 42K opaque sprite pixels per frame. The requested 90-frame
  run (frames 0–89) then completes with `ROMBOOT DONE`, zero errors, and zero
  warnings. Rendering remains stable through frame 89 at four sprite commands
  and roughly 5.8–6.0K sprite-ROM requests per frame, with cumulative
  `sprpx=1374558`. The frame-80 capture visibly resolves the Golden Axe
  character-select screen—skull/candle portraits, `STERN`, the player sprite,
  and `Credits 0`—in `verif/modelsim_romboot/dump80.png`. This is
  renderer-path evidence in simulation, not full gameplay, pixel-accuracy,
  or hardware validation.
- **svf:** its million-iteration startup delay now exits around frame 46
  (the real-machine expectation is about frame 45), display/rendering becomes
  active by frame 79, and an 82-frame run completed with a frame-80 PPM dump.

On physical MiSTer hardware, GA2 now reaches attract mode and controllable
gameplay. Two normal screenshots five seconds apart confirm a displayed-frame
stall, while PC diagnostic captures continue changing across hundreds of V60
addresses; the CPU is still running when the picture freezes. The palette
alias bit mapping has since been corrected, the sprite list is bounded to
8,192 commands so a bad JUMP/missing END cannot trap rendering forever, and a
raw framebuffer/DDR diagnostic is included for the next approved hardware
run. These fixes are locally verified but not yet deployed.

A subsequent RTL audit also corrected the fifth tilemap clip-rectangle index,
byte-enable handling in VRAM and mixer register shadows, interrupt reset/
source-ack/timer races, invalid high-byte accesses to low-byte peripherals,
and full-scale audio-mix polarity wrap. All are covered by directed tests;
none of these new changes is claimed as hardware-proven until a fresh
timing-qualified RBF is exercised on MiSTer.

The real-ROM testbench initializes V60 R0–R30 once at simulation startup,
matching MAME's deterministic device-start state and preventing four-state
`X` values from poisoning game RAM. This initialization is testbench-only;
the production CPU's architectural and soft-reset semantics are unchanged.

The V60 short-backward-branch fetch path is now **3.93× faster** in its
directed benchmark (12,310 → 3,130 cycles and 2,305 → 10 memory reads),
using a conservative per-op fetch threshold and one retained previous fetch
window. This closes the real-ROM `svf` performance finding.

The maximum-length F1 decoder is also covered: a legal 20-byte MOVW with two
double-displacement operands can place its final displacement at fetch-buffer
offset 16. Effective-address offsets and total instruction length now retain
five bits, and the `LONG EA` tier proves the transfer and next-PC value.

The ga2 object code uses `SKPCUH [R15],R14,#0` to find its first populated
sprite bucket. MAME's V60 contract reports a match with `Z=0`, `R27=index`,
and `R28=entry address`, and exhaustion with `Z=1`, `R27=count`, and
`R28=end address`. The RTL previously inverted that result and forced ga2
onto its END-only path; this is fixed and covered by `tb_v60_search.sv`.

Implemented RTL includes:

- **NEC V60 CPU core** (`rtl/cpu/v60/`) — first known FPGA implementation:
  full addressing-mode engine, F1/F2 formats, integer ISA, string ops,
  exceptions/interrupts per the NEC/MAME contract. Passes its directed
  smoke suite in simulation (immediate loads, ALU+flags, branches, calls).
- **Video** (`rtl/video/`) — VRAM+register file, 4 zooming/rowscroll
  tilemaps, text, bitmap, framebuffer sprite engine (DDR3-backed),
  16-priority mixer with sprite grouping, dual-format palette, 416/320 CRT.
- **Audio** (`rtl/audio/`) — Z80 (T80) + banking + vectored sound IRQs,
  2× YM3438 (jt12), RF5C68, MultiPCM.
- **I/O** (`rtl/io/`) — 315-5296 ×2, 93C46 EEPROM protocol plus index-2
  defaults and index-3 load/save persistence, MSM6253 ADC, µPD4701
  trackballs, i8255, V60 interrupt controller + timers. EEPROM changes raise
  the MiSTer upload request, survive soft reset, and stream back as 128
  little-endian bytes. Its inverted 64×16 shadow is now an explicit
  dual-port Cyclone V M10K (zero power-up still reads as erased `0xFFFF`),
  and the focused serial/NVRAM persistence test passes.
- **Protection** (`rtl/prot/`) — sonic/brival/darkedge/f1lap/dbzvrvs/
  jleague HLE, arescue DSP HLE, and the dual-PCB bridge.
- **Real V25 CPU** (`rtl/cpu/v25/`) — vendored GPL-3.0 s80x86 execution core,
  GA2/Arabian Fight opcode-only decryption, mixed-width ROM/mailbox memories,
  and an exact 10 MHz fractional clock-enable with stretched bus acknowledgements.
- **Platform** — SDRAM 5-port controller, DDR3 framebuffer service, ioctl
  ROM loader (including corrected V25 address descramble), ROM-complete reset
  gating, MiSTer `emu` top, generated Cyclone V PLL integration, and **59
  generated MRAs** (`mra/`, one per supported set, parsed from MAME with real
  CRCs/interleaves). DDR writes now use MiSTer-safe single-beat transfers,
  line reads remain 128-beat bursts, and request/ack state is held across
  backpressure.
- **ga2 release profile** — `S32_GA2_ONLY` retains the V25 and i8255 paths
  while compiling out the ADC, three trackballs, generic/Burning Rival
  protection HLE, and Air Rescue DSP. Universal builds retain those blocks.

Per-game verification status: [docs/compat.md](docs/compat.md).
Known gaps are tracked there and in DESIGN.md §11.

## Memory requirements — single SDRAM stick

The core runs on **one** MiSTer SDRAM add-on module — **32 MB is sufficient**
(any larger stick also works). Dual-SDRAM is **not** used and never required:
the Quartus project sources the standard single-SDRAM framework
(`sys/sys.tcl`), the RTL instantiates exactly one SDRAM controller, and the
ROM map totals exactly 32 MB (2 maincpu + 4 sound + 4 tiles + 4 MultiPCM +
2 spare + 16 sprites). Sprite framebuffers live in the DE10-Nano's onboard
HPS DDR3, which every MiSTer has — it is not an add-on.

## Building

To produce `SegaS32.rbf` see **[docs/BUILD.md](docs/BUILD.md)** — the normal
path is a local Docker build with Quartus Lite 17.0.2 Build 602, with CI and
native Quartus available as fallbacks. The generated PLL now elaborates
through the Quartus project. A pre-R15 candidate fitted at 27,793 / 41,910
ALMs, used 492 / 553 RAM blocks, met setup/hold timing, and booted GA2 on the
DE10-Nano. The current palette/watchdog/DDR-diagnostic candidate is rebuilding
locally and will not be deployed or launched until the user explicitly
approves another MiSTer run. Audit history and fixes:
[docs/audit.md](docs/audit.md).

The complete engineering specification lives in
**[docs/DESIGN.md](docs/DESIGN.md)**:

- §1–2 Goals, board variants, full 63-set game/compatibility matrix
- §3–4 Clocking, SDRAM/DDR3 memory system and bandwidth budgets
- §5 NEC V60/V70 microcoded CPU core design + co-simulation plan
- §6 Video: 4 zooming tilemaps, text/bitmap layers, framebuffer sprite
  engine, 16-priority mixer with blending/fades
- §7 Audio: Z80 + 2× YM3438 (jt12) + RF5C68 + MultiPCM
- §8 Protection: V25 MCU (ga2/arabfgt) and per-game HLE modules
- §9–12 MiSTer integration (MRA/ioctl, inputs, EEPROM persistence), resource
  budget, verification plan, milestones
- §13 Register-level appendices (memory maps, video/mixer registers, I/O)

## References

Behavioral reference is the MAME `segas32` driver (BSD-3-Clause). See
DESIGN.md Appendix F for the full reference list.

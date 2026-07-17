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

🔩 **Simulation bring-up and Quartus integration. Real game ROMs now boot
and render in simulation; a fitted/timing-clean RBF and MiSTer gameplay are
still pending.**

The regression now has **25 tiers** (`verif/run_regression.sh`, plus the
native Windows ModelSim runner `verif/run_regression.ps1`): RTL lint, V60
smoke/directed/differential suites,
full-core boot and soak, ga2 boot path, framebuffer/mixer/sprite tests,
decimal and bit-string groups, V60 fetch performance, ROM-loader/reset
gating, EEPROM NVRAM save/upload semantics, the legal 20-byte F1
effective-address case, and focused RF5C68, palette, line-buffer, tilemap,
dual-port BRAM, and V25-mailbox timing tests. The V60 audit tier also runs
the exact encoded ga2 `SKPCUH` search case. A complete native Windows
ModelSim invocation now passes **25/25 tiers**, including **50/50 V60
differential seeds**. Its detailed transcript is
`verif/modelsim-regression.log`.

The copyrighted ROMs are kept locally under ignored `roms/`. The image
builder (`tools/make_sim_images.py`) reads MAME ZIPs directly and has produced
full SDRAM-layout images for `holo`, `ga2`, and `svf`:

- **holo:** completes its EEPROM/IRQ boot path and renders about 36K non-black
  pixels per frame in the real-ROM harness.
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
  jleague HLE, arescue DSP HLE, dual-PCB bridge, V25 subsystem with the
  real opcode-decrypt tables staged for the full-core swap.
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

To produce `SegaS32.rbf` see **[docs/BUILD.md](docs/BUILD.md)** — build in CI
or locally with Quartus 17.0.2 Standard. The generated PLL now elaborates
through the Quartus project. The latest **map-only** result estimates 40,434
of 41,910 ALMs; this is not a fitter utilization or timing result. A
successful full fit, timing report, release RBF, and hardware deployment have
not yet been recorded. Audit history and fixes:
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

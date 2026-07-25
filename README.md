# Sega System 32 / Multi 32 for MiSTer

An open FPGA recreation of Sega's System 32 and Multi 32 arcade hardware
(1990–1994) for the MiSTer DE10-Nano. The project is source-first and does
not distribute commercial arcade ROMs.

This is an active work in progress. The compatibility table below is the
release truth: `hw` means the title has reached playable operation on a real
MiSTer, `sim` means the real ROM set has reached a meaningful full-core
simulation milestone, `rtl` means the board variant is represented in RTL but
has not reached a complete real-ROM milestone, and `wip`/`unsupported` mark
known gaps or out-of-scope hardware. None of the titles is presented as
cycle-perfect or fully arcade-certified yet.

## Compatibility

| Set(s) | Game | Current support | Known limits |
| --- | --- | --- | --- |
| `holo` | Holosseum | **hw** — boots to gameplay with controls and sound | Palette/colors and extended-play accuracy remain open |
| `spidman` (+2) | Spider-Man: The Videogame | **hw** — boots to gameplay with correct palette and controls | Sound is incomplete in places; scripted enemy attacks still need work |
| `ga2` (+2) | Golden Axe: The Revenge of Death Adder | **sim** — real V25 firmware and recognizable renderer output | No current hardware certification or full play-through |
| `svf` (+4) | Super Visual Football / J.League | **sim** — startup and rendering milestones | Harness does not prove physical DDR/audio timing |
| `arabfgt` (+2) | Arabian Fight | **rtl** — V25 board path present; early simulation probes exist | No sustained playable milestone yet |
| `arescue` (+2) | Air Rescue | **rtl** | DSP daughterboard behavior is still an approximation |
| `alien3` (+2) | Alien3: The Gun | **rtl** | Light-gun ADC and complete game validation remain |
| `brival` (+1) | Burning Rival | **rtl** | Protection/I/O and full gameplay validation remain |
| `darkedge` (+1) | Dark Edge | **rtl** | Protection/I/O and full gameplay validation remain |
| `dbzvrvs` | Dragon Ball Z V.R.V.S. | **rtl** | Analog controls and game validation remain |
| `f1en` (+2) | F1 Exhaust Note | **rtl** | Dual-board bridge path is not hardware-qualified |
| `f1lap` (+2) | F1 Super Lap | **rtl** | Analog controls and full gameplay validation remain |
| `jpark` (+3) | Jurassic Park | **rtl** | Light-gun ADC and complete game validation remain |
| `kokoroj` (+1), `kokoroj2` | Soreike Kokology 1/2 | **wip** | CD/SCSI and audio support are incomplete |
| `radm` (+1) | Rad Mobile | **rtl** | Analog controls and full gameplay validation remain |
| `radr` (+2) | Rad Rally | **rtl** | Analog controls and full gameplay validation remain |
| `slipstrm` (+1) | Slip Stream | **rtl** | Analog controls and full gameplay validation remain |
| `sonic` (+1) | SegaSonic The Hedgehog | **rtl** | Trackball input and complete game validation remain |
| `harddunk` (+1) | Hard Dunk | **rtl** | Multi 32 second-screen/6-player behavior is not validated |
| `orunners` (+2) | OutRunners | **rtl** | Multi 32 dual-screen and analog behavior remain |
| `scross` (+2) | Stadium Cross | **rtl** | Multi 32 dual-screen and analog behavior remain |
| `titlef` (+2) | Title Fight | **rtl** | Multi 32 dual-screen behavior is not validated |
| `as1` (+3) | AS-1 Controller | **unsupported** | Laserdisc/controller hardware is out of scope |

The detailed evidence, protection paths, inputs, and open issues are tracked
in [docs/compat.md](docs/compat.md). The status labels are deliberately
conservative; a simulation pass is not a hardware guarantee.

## What the core implements

- System 32 video: four scrolling/zooming tilemap layers, text and bitmap
  layers, a hardware-style sprite list with zoom, priority, blending, fades,
  and 320/416-pixel display modes.
- Audio: Z80 sound CPU, two YM3438-compatible FM channels, RF5C68-family PCM,
  and the Multi 32 MultiPCM path.
- Board devices: 315-5296 I/O, 93C46 EEPROM save/load, MSM6253 gun ADC,
  µPD4701 trackball counters, 8255 PPI, timers/interrupt controller, and the
  V25 protection path used by Golden Axe 2 and Arabian Fight.
- MiSTer integration: MRA-based ROM loading, 16-bit HPS transfers, Cyclone V
  SDRAM for ROM regions, and the DE10-Nano DDR3 framebuffer for sprites.

## NEC V60/V70 CPU

`rtl/cpu/v60/s32_v60.sv` is a from-scratch, synthesizable NEC V60 core with a
parameterized V70 profile. System 32 uses the µPD70616 V60 at about 16.108 MHz
with a 16-bit external bus; Multi 32 uses the µPD70632 V70 profile at 20 MHz
with a 32-bit board bus (the current adapter keeps the proven 16-bit cycle
interface where required). Both are little-endian 32-bit CISC processors.

The implementation is a sequential micro-sequencer with a bounded prefetch
queue and a small instruction-stream cache. It models the programmer-visible
registers, banked interrupt stacks, PSW/system registers, traps and interrupts,
full integer/bit/string/decimal instruction groups, effective-address modes,
unaligned accesses, and V60↔Z80 synchronization. MMU paging and floating-point
groups are intentionally outside the System 32 arcade profile; unsupported FP
opcodes take the reserved-instruction path. Directed tests and differential
traces against MAME cover the implemented arcade instruction set.

## Core architecture and the V60 data path

The top level separates a `clk_sys` domain (CPU, bus, I/O, sound and most video)
from a 2× `clk_ram` domain (SDRAM and sprite datapath). The PLL requests about
48.324 MHz for `clk_sys` and 96.648 MHz for `clk_ram`; fractional clock enables
derive the original board rates. ROMs stream through the MiSTer HPS loader into
SDRAM. The V60 bus decoder arbitrates work RAM, VRAM, palette, I/O, protection,
sound and ROM accesses. Tilemaps and the sprite engine feed the priority mixer;
sprite pixels are rendered into DDR3-backed line buffers so SDRAM ROM traffic
cannot starve the display path.

For the block-level design and memory map, see
[docs/DESIGN.md](docs/DESIGN.md). For build and deployment instructions, see
[docs/BUILD.md](docs/BUILD.md).

## Requirements and installation

- MiSTer DE10-Nano with an SDRAM expansion (32 MB is sufficient for the
  supported System 32 profiles).
- A matching MAME ROM set. ROMs remain the user's responsibility and are not
  included here.

Copy `SegaS32.rbf` to `_Arcade/cores/` and the matching `.mra` files to
`_Arcade/`, then launch a title from the MiSTer arcade menu. The deployment
helper accepts the MiSTer host at runtime; no host, password, token, or SSH key
is stored in the repository.

## Public-release hygiene

The repository intentionally contains RTL, testbenches, documentation, MRA
metadata, and build scripts only. ROM archives, Quartus databases, RBF output,
simulator work directories, local logs, machine-specific credentials, and
private keys are ignored. Before publishing, run the repository's CI checks and
review `git diff --cached`; never commit a MiSTer password or private SSH key.

## Licence and credits

The behavioral reference is MAME's `segas32` driver. The V25 execution core is
vendored from the GPL s80x86 project; see that directory for its licence. Other
RTL is original or carries its upstream licence header. Arcade ROMs remain the
property of their respective owners.

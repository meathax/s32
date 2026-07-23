# Sega System 32 / Multi 32 for MiSTer

An FPGA recreation of Sega's **System 32** and **Multi 32** arcade hardware
(1990–1994) for the MiSTer platform (DE10-Nano).

The board is a tough one to emulate: a 16/32-bit NEC V60/V70 main CPU, a
sprite engine with hardware zoom and a deep priority mixer, four scaling/
row-scroll tilemaps, a Z80 sound section with dual YM3438s plus Ricoh PCM, and
on several titles a second NEC V25 microcontroller used for copy protection.
The CPU cores here are written from scratch — this is the first FPGA
implementation of the NEC V60/V70 and of the System 32 V25 protection setup.

This is a **work in progress**. One game is fully playable today; the rest
range from "boots and plays with issues" to "not yet supported." Read the
compatibility list below before you expect a game to run.

## Compatibility

| Game | Status |
| --- | --- |
| **Holosseum** | **Working** — correct video, sound, and controls. The reference title for this core. |
| Golden Axe: The Revenge of Death Adder | In development — boots and plays; uses the V25 protection MCU. Current focus. |
| Arabian Fight | In development — boots and plays; also a V25 title. |
| Spider-Man: The Videogame | Playable — correct graphics and controls, but sound is incomplete and some scripted enemy events fire early. |
| Everything else in the `segas32` set | Experimental — many boot; several need hardware the core doesn't fully support yet (trackballs, light-gun ADC, Multi 32 dual-screen). Expect problems. |

Only **Holosseum** should be treated as finished. Everything else is being
actively worked on and may glitch, freeze, or fail to boot.

The full per-title matrix — inputs, protection type, and known issues — is in
[docs/compat.md](docs/compat.md).

## Current focus

Development is targeting the three 4-player brawlers that share the V25
protection and I/O layout:

- **Golden Axe: The Revenge of Death Adder**
- **Arabian Fight**
- **Spider-Man: The Videogame**

These exercise the hardest parts of the design — the V25 MCU, the sprite list,
and the priority mixer — so getting them right moves the whole core forward.

## What's implemented

- **NEC V60/V70 CPU** — full instruction set, addressing modes, exceptions and
  interrupts, modelled against the documented behaviour of the real part.
- **NEC V25 protection MCU** — real execution core with the Golden Axe /
  Arabian Fight opcode decryption and the dual-port mailbox to the main CPU.
- **Video** — four zooming, row-scrolling tilemaps, text and bitmap layers, the
  DDR-backed framebuffer sprite engine with hardware zoom, and the 16-level
  priority mixer with blending and fades. 416- and 320-pixel display modes.
- **Audio** — Z80 sound CPU with banking, two YM3438 FM chips, Ricoh RF5C68
  PCM, and Sega MultiPCM.
- **I/O** — the 315-5296 I/O chips, 93C46 EEPROM with save/restore, the
  MSM6253 gun ADC, µPD4701 trackball counters, an 8255 PPI, and the interrupt
  controller and timers.
- **Platform** — single-chip SDRAM controller, HPS DDR3 framebuffer, ROM
  loader with the V25 descramble, and one MRA per supported ROM set.

## Requirements

- A MiSTer setup (DE10-Nano + SDRAM module). **One 32 MB SDRAM stick is
  enough**; dual-SDRAM is not used.
- Sprite framebuffers use the DE10-Nano's onboard DDR3, which every MiSTer
  already has.
- The original arcade ROMs. This project does not distribute them.

## Installing

1. Copy `SegaS32.rbf` to `_Arcade/cores/` on the SD card.
2. Copy the `.mra` files from `mra/` to `_Arcade/`.
3. Provide the matching MAME ROM sets so the MRA loader can find them.

Then launch a game from the MiSTer arcade menu.

## Building

See [docs/BUILD.md](docs/BUILD.md). The core builds with Quartus Lite 17.x
(Cyclone V) and produces `SegaS32.rbf`.

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md) — the full hardware and implementation
  reference: clocking, memory system, CPU cores, video, audio, protection,
  MiSTer integration, and register-level appendices.
- [docs/compat.md](docs/compat.md) — per-game status and known issues.

## Credits and licence

Behavioural reference is the MAME `segas32` driver. The V25 execution core is
vendored from the GPL s80x86 project; see that directory for its licence. All
other RTL is original. Arcade ROMs are the property of their respective owners
and are not included.

# External reference sources for the System 32 core

Curated engineering sources for this core, in order of authority. Raw
third-party files are kept out of the repo (no license grants); links and
extracted facts live here.

## Silicon reverse engineering (furrtek SiliconRE)

- **315-5242 video DAC / OKI M71064** — the gold standard: decap-traced
  schematic **and Verilog** for the color latch / greyscale / shadow output
  stage used by System 32 (and System 24 / X / Y / C2).
  - https://github.com/furrtek/SiliconRE/tree/master/Sega/315-5242
  - `M71064.v` behaviour to mirror in our `s32_palette`/output stage:
    RGB555 in; per-channel registered outputs on CLK; `nGREY` selects a
    5-bit greyscale (luma-weighted sum) substituted for all channels;
    `nSHADE`/`HI_LO` drive a tri-stated per-channel `*OUT_SH` pin that adds
    the half/double intensity step (our "shadow/highlight" path); blanking
    forces outputs low. Only tested in simulation by its author.
- **315-5385 system controller** — die trace + pinout skeleton only
  (pin names not yet filled in as of 2026-07); no schematic/HDL yet.
  Our intc/timer/mapper behaviour therefore still follows MAME.
  - https://github.com/furrtek/SiliconRE/tree/master/Sega/315-5385

## Official Sega schematics (complete 11-page set, 1990/7/12)

Set 171-5964D (main board, sheets 1-9) + 171-5965C (ROM board, 2 sheets).
Copies are in the project scratchpad; source scan by Nemesis1207:
https://www.arcade-projects.com/threads/new-schematics-scans-system-32-system-18-system-16a-2-0-super-hang-on.25889/

Sheet map and facts confirmed against this core:

| Sheet | Title | Contents / confirmations |
|-------|-------|--------------------------|
| 1 | MAIN CPU | µPD70616 V60, 2× 32K/128K work RAM, **315-5385** system controller (IRQ/timer/mapper), 315-5441 GAL |
| 2 | SCROLL | **315-5387** = tilemap chip, 4× 256K dual-port RAM (VRAM), FXON/S0ON-S3ON/BTON layer-enable outs |
| 3 | OBJECT | **315-5386** = sprite chip, 4× 256K dual-port RAM (spriteram), OWAT wait line |
| 4 | FRAME MEMORY | 16× 256K dual-port RAM in two banks = double-buffered sprite framebuffer (our fb service) |
| 5 | COLOR/PRIORITY | **315-5388** mixer, 4× 8Kx8 palette SRAM, **315-5242** DAC |
| 6 | INPUT/OUTPUT | **315-5296** io chip; **BR93C46AP EEPROM: CS/SK/DI on port D bits 5/6/7, DO on port F bit 7** (both confirmed = our wiring); 4-bit DIP; JAMMA |
| 7 | SOUND CPU | Z80 (8 MHz), 8K SRAM battery-backed, MB3771 reset supervisors |
| 8 | FM/PCM | **2× YM3438**, RF5C105 (RF5C68 family) + 2× 32K PCM RAM, LC7881 DAC, TDA1518Q amp |
| 9 | CONNECTOR | Clock tree: 32 MHz xtal → 16M×3 + 8M×3; 50 MHz xtal → 24M/12MA/12MB/6M |

**Naming correction**: many older sites swap the two video customs. Per the
official drawings: **315-5386 = OBJECT (sprites), 315-5387 = SCROLL
(tilemaps)**.

## MAME (behavioural specification)

Cached under the session scratchpad (`s32/sources/`):
- `segas32.cpp` — memory maps, interrupt control (`int_control_w`: both
  byte lanes are registers; `effirq = pending & ~mask & 0x1f`; vector =
  `control[i]`, CPU adds 0x40), timers (t0: 0x800·N @ MAIN/2, t1: 0x100·N
  @ 50 MHz/16), game configs.
- `segas32_v.cpp` — video pipeline.
- `segas32_m.cpp` — protection (ga2 V25 wakeup/table, sonic, brival, ...).
- `v60*.cpp/.hxx` — CPU: opcode table, addressing modes (class-7 quick
  immediates!), F12 operand dims (shift/rotate counts are BYTE ops).
  `op7a.hxx` is the direct contract for SEARCH results used by ga2:
  found clears Z and returns the match index/address in R27/R28; exhaustion
  sets Z and returns the count/end address.
  - https://raw.githubusercontent.com/mamedev/mame/master/src/devices/cpu/v60/op7a.hxx
- `eepromser.cpp` — 93C46 contract: write executes on the 16th data bit,
  then the device ignores clocks until CS falls; `do_read` returns READY
  status only in WAIT_FOR_START_BIT, else data/tristate-high.

## Not yet fetched (network egress blocked in this environment)

- NEC V60 Programmer's Reference Manual: https://multimedia.cx/NEC_V60pgmRef.pdf
  (also on bitsavers). Authoritative ISA doc; fetch when egress allows.
- Guru's System 32 pages (FD1149 decap, ROM board jumpers, trackball RE):
  https://gurudumps.otenko.com/system32/index.html ,
  https://gurudumps.otenko.com/re/index.html
- JAMMArcade Golden Axe II repair (board photos, clock measurements):
  https://jammarcade.net/golden-axe-ii-sega-system-32-repair/

## Gap summary

No public die trace exists for 315-5386 (OBJECT), 315-5387 (SCROLL) or
315-5388 (MIXER); MAME remains the only behavioural source for those, plus
the pin-level context from sheets 2/3/5.

# ga2 (Golden Axe: The Revenge of Death Adder) readiness

## Current answer

`ga2` now runs actual code on the DE10-Nano: the World Rev B MRA boots, attract
mode advances, Start enters gameplay, and physical movement, attack, and jump
controls work. This closes the design-only boot/input milestone.

It is **not yet fully functional**. The deployed pre-R15 image renders
recognizable scene geometry with severely corrupted colors, does not present
sprites correctly, stutters during the demo, and can leave the visible frame
frozen. Diagnostic captures prove the V60 continues executing after that
visible freeze, so current work is focused on palette, sprite framebuffer/DDR,
and renderer-progress faults rather than basic ROM boot or controller input.

## Evidence completed

- The MRA-to-SDRAM builder resolves files from the ZIP by name/CRC, applies
  the real interleaves, emits the board descriptor and every ROM region, and
  applies the V25 address descramble.
- The production RTL now executes the genuine encrypted `mcu.bin` through the
  real s80x86/V25 path. It writes the complete wake string, result table, and
  stack state at an exact nominal 10 MHz cadence with zero unexpected I/O or
  unmapped accesses.
- F1 immediate handling, odd interrupt-controller byte lanes, V25 DPRAM
  window placement, and JMP/JSR/TASI indexed dimensions were corrected from
  observations made on the real program.
- The object-bucket scan at `0x132983` executes
  `SKPCUH [R15],R14,#0`. The RTL had the search zero flag backwards: MAME
  returns `Z=0` plus the match index/address when found and `Z=1` plus the
  count/end address when exhausted. The fix is covered through the exact
  encoded instruction and direct found/exhausted/zero-length cases in
  `tb_v60_search.sv`.
- A corrected scripted-input ROM run samples active-low coin at frames 41/42
  and Start at frames 51/52, then observes the post-Start state transition.
  Frame 63 reaches the first populated sprite list with `spr_cmd=4`,
  `srom=5968`, and `sprpx=52722`. At frame 64, `spr_opq=42393` and real
  sprite pixels reach the mixer; frames 64–69 sustain about 5.9K sprite-ROM
  requests and about 42K opaque sprite pixels per frame. This proves the
  corrected ROM-driven sprite path is active in simulation, not that output
  is pixel-exact or gameplay-complete.
- The same run completes all 90 requested frames (0–89) with `ROMBOOT DONE`,
  zero ModelSim errors, and zero warnings. The sprite path remains stable
  through frame 89 at four commands per frame and roughly 5.8–6.0K sprite-ROM
  requests per frame; cumulative `sprpx` reaches 1,374,558. The frame-80 dump
  visibly resolves the skull/candle Golden Axe character-select screen,
  `STERN`, the player sprite, and `Credits 0`. Capture artifacts are
  `verif/modelsim_romboot/dump80.png`.
- The real-ROM testbench initializes V60 R0–R30 once at simulation startup,
  matching MAME's deterministic device-start state and preventing ModelSim
  four-state `X` values from poisoning game RAM. It is a testbench-only
  startup condition; production architectural and soft-reset behavior is
  unchanged.
- The synthetic ga2-path tier covers CPU reads from registered BRAM, the V25
  wake-up path, VRAM/palette writes, sprite-list JUMP/draw/END, and vblank IRQ
  delivery into a handler.
- Decimal, bit-string/bit-field, sprite, mixer, and framebuffer paths have
  focused directed tiers. The V60 short-branch fetch optimization is 3.93x
  faster in its benchmark and brings `svf`'s timing loop in line with the real
  V60 expectation, reducing a systemic risk for ga2 as well.
- The legal 20-byte F1 memory-to-memory decoder path now has a directed tier;
  five-bit offsets preserve a second double displacement at fetch-buffer byte
  16 and advance to the correct next PC.
- The runner now contains **35 tiers**. The latest complete native Windows
  run passes **35/35 tiers** with **10/10** V60 differential seeds, including
  the ga2 path, integrated sprite/DDR backpressure, interrupt-controller
  reset/source-ack/timer cases, signed audio-route saturation, MultiPCM,
  V60 rotate/bus semantics, map decode, and genuine V25 firmware. The ga2-only
  full core also passes an independent Verilator 5.032 structural elaboration.
- The audit corrected the fifth tilemap clip rectangle (which had aliased the
  third), byte-enable handling in VRAM and mixer register shadows, simultaneous
  interrupt source/ack retention, timer cancel/period behavior, low-byte-only
  peripheral lane gating, and full-scale audio wraparound.
- MAME verifies `ga2`, `arabfgt`, `spidman`, `holo`, and `svf`.
  Eight-frame real-ROM probes built from the same current universal RTL all
  complete without simulator errors. GA2 reaches video register/list setup by
  frame 7; Arabian Fight reaches VRAM, palette, mixer, and sprite-list writes
  by frames 2–5; Spider-Man remains in an early I/O polling path through frame
  7 and is retained as a non-V25 diagnostic case.
- Physical MiSTer testing reaches both attract mode and controllable gameplay.
  Start, movement, attack, and jump have all been confirmed on the real
  controller path.
- Identical normal screenshots five seconds apart confirm the displayed-frame
  stall, while PC diagnostic frames continue to change across hundreds of V60
  addresses. The CPU therefore does not hard-halt when the picture freezes.
- Palette alias bit routing is corrected and covered by independent one-hot
  R/G/B vectors. A bounded 8,192-command sprite-list watchdog prevents a bad
  JUMP/missing END from trapping rendering forever.
- `tb_sprite_fb.sv` connects the real sprite renderer and framebuffer module
  to a backpressured MiSTer-style DDR model for three alternating-buffer
  frames. The exact stored pixels pass with zero simulation errors/warnings.
  The integrated test remains in the complete passing 29-tier matrix.

## Hardware-integration work completed

- The ioctl loader resets deterministically, subtracts `OFF_MCU` before V25
  descramble, accepts EEPROM indexes 2 and 3, and asserts `rom_loaded` only
  after the final index-0 SDRAM write acknowledgement. The top holds the game
  core in reset until that gate opens.
- DDR framebuffer writes use stable single-beat transfers; 128-beat line
  reads retain a stable base; requests and acknowledgements follow a
  four-phase handshake under backpressure. The CRT frame wrap now prefetches
  line 0 after line 261.
- The scripted Cyclone V PLL is included through its generated synthesis QIP,
  the top uses the generated Qsys port names, and local/CI builds fail if the
  hardware PLL is missing.
- EEPROM index-3 load/save is connected through `hps_io`: enabled writes and
  erases request an upload, soft reset preserves pending changes, and the
  shadow streams as 128 little-endian bytes. The 64×16 shadow is an explicit
  dual-port M10K with inverted storage so zero power-up reads as `0xFFFF`.
  The focused test covers serial READ/WRITE/WRAL/ERAL, synchronous upload
  latency, and dirty/ack ordering; isolated Quartus mapping confirms 1,024
  block-memory bits.
- The `S32_GA2_ONLY` release profile keeps V25 and i8255 while compiling out
  ga2-unreachable ADC, trackball, generic/Burning Rival protection, and Air
  Rescue DSP logic. Universal builds retain those blocks.
- Quartus Analysis & Synthesis completes for that profile. Its latest
  **map-only** estimate is 26,851 / 41,910 ALMs, with 41,440 combinational
  ALUTs, 23,171 dedicated registers, 3,934,136 block-memory bits, 42 DSP
  blocks, and 3 PLLs. These are not fitted resource or timing results.
- Before the V60 write-port refactor, seeds 5–7 all completed placement but
  failed routing with 70–77% peak interconnect use. Consolidating scattered
  dynamic register writes into two masked write ports reduced the map estimate
  by 13,227 ALMs while preserving two writes per CPU cycle and byte/bit update
  semantics. A later pre-R15 candidate fitted and met timing as recorded
  below; the current palette/watchdog/diagnostic candidate is being rebuilt.
- Both native Windows Quartus 17.0.0 and the Quartus Lite 17.0.2 Docker path
  are available locally. The current native build selects 16 of 24 processors.
  One placement attempt ended unexpectedly while ModelSim regression was
  consuming memory concurrently; the rerun is isolated from heavy simulation.
- MiSTer hardware preflight and first gameplay are complete: the World Rev B
  MRA is staged at
  `/media/fat/_Arcade/Golden Axe The Revenge of Death Adder (World, Rev B).mra`
  with SHA-256 `558322a51018e4f889b38222dd87260c721185bfc782c86b95ddf22ca9812000`;
  `ga2.zip` is staged under `/media/fat/games/mame/` with SHA-256
  `2befa4aa4f5927480595f28cfb5e0daf52003d92db69e43e9091358e2ba45cf3`.
- A pre-R15 RBF fitted at 27,793 / 41,910 ALMs with 492 / 553 RAM blocks and
  positive setup/hold slack, then loaded the real game. It is useful hardware
  evidence but is not the current palette/watchdog candidate and is not a
  release-quality gameplay result.

## Remaining ga2 release gates

1. Complete and qualify the current palette/watchdog/DDR-diagnostic Quartus
   build. Do not deploy or launch it until the user explicitly approves the
   next MiSTer run.
2. On that approved run, verify corrected palette output and use the raw
   Sprite FB/DDR mode to isolate any remaining missing-sprite or stall point.
3. Validate real DDR3 framebuffer behavior under sprite-heavy scenes and
   compare captured frames against MAME, including zoom, clipping, blending,
   shadow, and palette effects.
4. Run several sustained attract/gameplay scenes without stutter or visible
   freeze and verify coin/start plus all already-working controls remain stable.
5. Validate the Z80/YM3438/RF5C68 audio path on hardware. Signed route
   arithmetic and saturation are now directed-test clean, but the real-ROM
   harness does not provide equivalent external-audio timing coverage.
6. Confirm EEPROM changes survive an actual MiSTer save/reload cycle.

## Protection posture

The production source now selects a real cycle-executed 80186-compatible core
for V25 games. Opcode bytes alone pass through the MAME-derived GA2/Arabian
Fight translation tables; operands remain raw. The genuine GA2 firmware passes
strict wake-string, table, stack, address-map, and 10 MHz cadence checks. The
older HLE remains useful only as a legacy unit-test/reference path. A new
Quartus fit and MiSTer run are still required to qualify the real CPU in hardware.

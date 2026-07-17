# ga2 (Golden Axe: The Revenge of Death Adder) readiness

## Current answer

`ga2` has crossed the design-only threshold: the actual `ga2.zip` is consumed
directly by `tools/make_sim_images.py`, boots in the full-core ROM harness,
passes the V25 wake-up/protection exchange, enables interrupts, and advances
through scripted coin/Start input to a recognizable character-select screen.
The real-ROM run exposed V60, interrupt-controller, V25, and video faults that
the synthetic tests did not; those faults are fixed and recorded in
`docs/audit.md` Rounds 10 and 13.

That is strong simulation evidence, but it is **not yet an honest claim that
ga2 runs on MiSTer**. There is no recorded fitted/timing-clean RBF, physical
boot, sustained gameplay session, or audio/video comparison from a DE10-Nano.

## Evidence completed

- The MRA-to-SDRAM builder resolves files from the ZIP by name/CRC, applies
  the real interleaves, emits the board descriptor and every ROM region, and
  applies the V25 address descramble.
- The real boot reaches ga2's `0xA00100` wake-up string, passes the V25 HLE
  response, programs the byte-lane-correct interrupt controller, and runs
  attract logic.
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
- The runner now contains **25 tiers**. The native Windows ModelSim runner
  (`verif/run_regression.ps1`) passes the complete **25/25-tier** matrix,
  including **50/50 V60 differential seeds**. The detailed transcript is
  `verif/modelsim-regression.log`.

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
  **map-only** estimate is 40,434 / 41,910 ALMs, with 63,251 combinational
  ALUTs, 23,981 dedicated registers, 3,993,510 block-memory bits, 52 DSP
  blocks, and 3 PLLs. These are not fitted resource or timing results.

## Remaining ga2 release gates

1. Complete Quartus fitting and static timing analysis. Replace the map-only
   estimate with fitted ALM/M10K/DSP use and require non-negative slack; no
   successful fitter or timing result is claimed yet.
2. Install the resulting RBF/MRA on a DE10-Nano and verify ROM loading,
   attract mode, controls, coin/start, and several sustained gameplay scenes.
3. Validate real DDR3 framebuffer behavior under sprite-heavy scenes and
   compare captured frames against MAME, including zoom, clipping, blending,
   shadow, and palette effects.
4. Validate the Z80/YM3438/RF5C68 audio path on hardware. The real-ROM harness
   does not provide equivalent external-audio timing coverage.
5. Confirm EEPROM changes survive an actual MiSTer save/reload cycle.

## Protection posture

The present V25 HLE implements the ga2 wake-up string and result-table
behavior used by MAME for years before the MCU dump was available. It is a
practical path to boot and play, while a cycle-executed V25 remains a future
authenticity improvement rather than a prerequisite for first hardware
bring-up.

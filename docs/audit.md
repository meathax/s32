# Full repository audit — findings and resolution

Audit scope: every RTL module, the emu top, the MRA generator, and docs,
cross-checked against the MAME `segas32` sources (driver, video, protection,
V60 core op/addressing tables). Each finding is classified
**BUG** (wrong behavior vs hardware/MAME), **GAP** (unimplemented spec item),
or **QUALITY** (correctness-neutral improvement). All are implemented in the
same change set; status shown per row.

## A. NEC V60 CPU core (`rtl/cpu/v60/`)

| # | Class | Finding (vs MAME) | Resolution |
|---|---|---|---|
| A1 | BUG | String ops (MOVC/CMPC/SCHC/SKPC) used fixed regs R26/R27 as src/dst. MAME `F7aDecodeOperands` decodes **op1=source addr, len1, op2=dest addr, len2** from the instruction stream; results write R27/R28. | Rewrote the string engine to the F7a operand+length encoding; src/dst are decoded EAs, counts are `min(len1,len2)`, R27/R28 updated on completion. |
| A2 | BUG | `TRAP` pushed the 2-word interrupt frame. MAME pushes a **3-word exception frame**: `code+size = 0x3000+0x100*(n&0xF)`, then old PSW, then return PC; vector = `48+(n&0xF)`. | Added exception-frame path with the code+size word; TRAP vector and mask corrected. |
| A3 | BUG | `BRKV` treated as generic exception. MAME: only if `OV`, 3-word frame with code `0x1501`, vector **21**. | Implemented exact BRKV frame/vector. |
| A4 | BUG | `BRK` raised an exception. MAME **skips** it (logged no-op). | Changed to logged no-op. |
| A5 | BUG | `RET` popped only PC. MAME `opRET` also **restores AP (R30)** from the stack, then adds the frame-size operand to SP. | RET now pops PC then AP, then applies the operand. |
| A6 | BUG | `CALL` approximated without AP handling. MAME: push AP, `AP=op2`, push return PC, `PC=op1`. | Implemented exact CALL semantics. |
| A7 | BUG | `f12_dim1` mapped MULX/MULUX/DIVX/DIVUX (0x86/96/A6/B6) operands to half-word; they are word-sized (DIVX 2nd operand dword — 64-bit path). | Corrected operand sizes; 64-bit MULX/DIVX now uses the word datapath. |
| A8 | QUALITY | Exception entry duplicated the level-switch inline. | Factored the code+size push into the shared exception path so IRQ (2-word) and TRAP/BRKV (3-word) share one sequencer. |
| A9 | BUG | `RSR` was routed through the RETI pop sequence, popping **PC and PSW**. MAME `opRSR` pops **PC only** (`PC=[SP]; SP+=4`). Surfaced by the new directed test (E1). | Gave RSR its own single-pop state. |

## B. Core integration & I/O wiring (`rtl/s32_core.sv`, `rtl/io/`)

| # | Class | Finding | Resolution |
|---|---|---|---|
| B1 | BUG | **Sound ROM fetch address was hardwired to 0** (`sdr_p3_addr`/`sdr_p4_addr` tied off; the soundsys `zrom_addr`/`mpcm_addr` outputs were unconnected). Z80 and MultiPCM would fetch garbage. | Exposed `zrom_addr`/`mpcm_addr` from `s32_soundsys` and mapped them to the SDRAM soundcpu/multipcm region bases. |
| B2 | BUG | EEPROM `do_read` was wired to `in_portc` bit 0. MAME reads it on **SERVICE34 bit 7** (port F). | Rewired EEPROM data-out to `in_svc34[7]`; portc restored. |
| B3 | BUG | `in_svc34` was tied to `0xff` — DIP switches (SW1:1-4) and service3/test4 unreachable. | Built `in_svc34` from DIP + service/test + EEPROM bit. |
| B4 | BUG | Trackball chip-select decode used `A[5:3]=={2'b01,t[0]}` (→ 0x50/0x58), but µPD4701s sit at 0x40/0x48/0x50 (`A[5:3]==t`). | Corrected per-chip decode to `A[5:3]==t`. |
| B5 | BUG | `mode_416` hardwired to 1. Should follow sprite control reg 6 (416/320 select) so narrow-mode games (radm attract) switch. | Exposed a latched `mode_416` from the sprite engine's control reg 6 and drove CRT + tilemap + sprite from it. |
| B6 | BUG | `mix0_r4e` tied to 0, so palette blend-pair mirror writes never happened. | Exposed mixer reg `0x4E` and fed it to the palette write-both logic. |
| B7 | GAP | Multi 32 second mixer/palette (`mix1`/`pal1`) not instantiated — screen B mirrored A. | Instantiated the second palette+mixer, decoded `0x680000`/`0x690000`, and routed `rgb_b` from it. |
| B8 | BUG | **CPU reads of every BRAM/register region returned stale data** — the read mux acked on the same clock edge the target's registered `q` updated (wram/vram/sprram/palette/prot/io all affected). Undetected for months of tiers 1-7 because no prior test CPU-read RAM back. Found by the tier-8 ga2-path test. | One-cycle `rd_wait` in the s32_core ack path: reads ack the cycle *after* the q registers settle. |
| B9 | BUG | V25 HLE wakeup-string index used `addr[5:0]` on the `[11:1]`-ranged addr port — bit 0 doesn't exist, index went X, every wakeup byte read returned the case default `' '`. ga2/arabfgt protection could never wake. | Select the word-index low bits as `addr[6:1]`. |
| B10 | BUG | Sprite control registers (`ctl`/`ctl_latched`) were never reset; in sim the auto-swap decision compared X and the sprite walker never left `R_IDLE`. | Cleared on reset (MAME zeroes them at machine start). |
| B11 | BUG | **Sprite list fetch off-by-one** — `slist_data` is a registered BRAM read (q lags addr by one clock) but `R_FETCHW` sampled one cycle early, so every entry's 8 words were shifted (`sw[k]=mem[base+k-1]`); no sprite could decode. Same defect in the indirect-table fetch. | Prime states `R_FETCHP`/`R_INDTABP` before sampling. |

## C. Audio (`rtl/audio/`)

| # | Class | Finding | Resolution |
|---|---|---|---|
| C1 | QUALITY | `s32_soundsys` did not surface the computed SDRAM byte addresses (root of B1). | Added `zrom_addr`/`mpcm_addr` region-base offsets on the outputs. |
| C2 | QUALITY | RF5C68 sample sign handling used an ad-hoc path. | Aligned to the MAME sign-magnitude convention with explicit accumulate. |

## D. Tools & MRA (`tools/gen_mra.py`, `mra/`)

| # | Class | Finding | Resolution |
|---|---|---|---|
| D1 | QUALITY | Generator ignored `ROM_CONTINUE` and multi-part regions across region size. | Region padding already correct; documented the 32-bit-BE sprite map assumption and added a self-check that every emitted region ≤ its declared size. |
| D2 | QUALITY | No machine-checkable link between MRA region offsets and the SDRAM map. | Added an assertion in the generator that stream offsets equal `s32_pkg` region bases. |

## E. Verification (`verif/`)

| # | Class | Finding | Resolution |
|---|---|---|---|
| E1 | GAP | No directed coverage for the areas fixed here. | Added directed V60 tests for string ops, TRAP/BRKV frames, RET/CALL with AP, and MULX; a core test asserting sound-ROM fetch address correctness and EEPROM readback. |
| E2 | GAP | No full-core test ever CPU-**read** memory back (tiers 1-7 only wrote and checked hierarchically) — masked B8/B9/B11. | Tier 8 `tb_core_ga2path`: synthetic ga2 boot path — V25 wakeup byte reads, VRAM/palette writes, sprite list JUMP→draw→END rendered to pixels, vblank vector → handler → HALT. Wired into `run_regression.sh` as [8/8]. |

Every row above is implemented in this change set; the regression
(`verif/run_regression.sh`) is extended accordingly and re-run green.

# Round 10 — real-ROM boot audit (ga2 / svf / holo images)

The first audit round driven by the actual game ROMs (built into SDRAM-layout
sim images by `tools/make_sim_images.py`, run by `verif/common/tb_core_romboot.sv`
under Verilator). Every finding below was invisible to all 13 synthetic tiers
and fatal on real hardware.

## R10 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R1 | BUG | **F1-format op2 immediates returned a stale address**: the op2 EA phase hard-set "want address", and quick/full immediates fell into the `ea_addr` arm, so `LDPR #0x100000, #5` loaded SBR with garbage and ga2's first vblank IRQ vectored to nowhere (PC 0x1a7a0025). | New `ea_isval` marker on quick/full immediate modes: value passes through even when an address was requested, and op2 immediates pre-fill `op2val` so `S_OP2_LD` never dereferences. Matches MAME's LDPR-quirk semantics. |
| R2 | BUG | **intc ignored the odd byte lane**: MAME `interrupt_control_16_w` maps even bytes to `control[2k]`, odd bytes to `control[2k+1]`. Our intc took only `wdata[7:0]` at word index `A[4:1]` — ga2's vectors 1/3/5, the ack register (byte 7), and both timer high bytes (9/11) were silently dropped, and the mask write landed on the wrong register. Result: IRQ storm (~100/frame, acks lost) and timer1 never armed. | Rewrote the intc write port: `addr[3:1]` + `be[1:0]` + 16-bit data, both lanes registered, ack/mask/timer side-effects per lane, mask resets to 0xFF. Synthetic TBs updated to the correct mask address (0xD00006). |
| R3 | BUG | ga2 V25 HLE served the wakeup string at byte window 0x000 and the sprite table at 0x100 — **swapped**. The ga2 boot code (loop at 0x1009CE) polls 0xA00100 for 'w' and string-compares 0x30 bytes against its ROM copy at 0x1009FF. | Wakeup string now at byte window 0x100-0x15F, results table at 0x000-0x01F. ga2 passes its wakeup check and enables interrupts. |
| R4 | BUG | **93C46 EEPROM model was off-protocol**: consumed 9 post-start command bits (real x16 frame is 8), had no ERASE/ERAL/WRAL, no completion semantics, and read as all-zeros when fresh. holo's boot (EWEN → per-word WRITE with in-frame chained commands → re-read) could never converge. | Rewrote to mirror MAME `eepromser.cpp`: 8-bit command frame, all opcodes, write/erase execute immediately then the device ignores clocks until CS falls, DO idles high outside READ data, fresh part reads 0xFFFF. |
| R5 | BUG | **ROTH/ROTCH rotate-count immediates decoded as halfwords**: `f12_dim1` listed 0x8B/0x9B in the half group ahead of the byte-count group (casez first-match), so `ROT.H #imm8, rN` measured 5 bytes instead of 4. holo's EEPROM bit-bang entered its 16-bit loop mid-instruction with an uninitialized counter → clocked forever. | Removed 8x8B/8x9B from the half group (counts are byte per MAME `F12DecodeOperands(ReadAM, 0, ...)`); also added IN/OUT byte/half dims. |
| R6 | PERF | svf's boot delay loop (1M iterations of `MOVW #imm / DBNZ`) takes ~300 sim frames vs ~45 on real V60 — every taken branch flushes and refills the 20-byte fetch buffer. Confirmed systemic (all branchy code ~3-6x slow). | **Closed in Round 11.** Conservative per-op fetch thresholds plus a one-entry previous fetch window let tight backwards branches reuse bytes without making general fetch speculative. The directed loop improved from 12,310 cycles / 2,305 reads to 3,130 / 10 (3.93×); real `svf` now leaves the delay at frame 46. |
| R7 | BUG | **JMP/JSR/TASI scaled indexed-mode indexes**: the single-operand decode set dim=word, but MAME's opJMP/opJSR/opTASI force moddim=0, so `JMP [PC+d](rN)` over ga2's 3-byte branch tables quadrupled the index and landed mid-table on a reserved op (trap at 0x1381B7). CALL's op1 dim fixed to byte for the same reason. | JMP/JSR/TASI use dim 0; CALL op1 added to the byte-dim group. |
| R8 | BUG | **All-black frames from three stacked video bugs**: (a) the tilemap render kick (`hcnt==416`) and sprite line prefetch (`hcnt==420`) can never fire in 320-wide mode (htotal=409) — holo runs 320 mode, so no line ever rendered; (b) the mixer register file initialized to 0 where MAME memsets 0xFF — holo programs only sprite group 0 and relies on the r4c=0 default group reading all-ones, so every sprite mixed at priority 0 and lost; (c) disabled tilemap layers were not gated in the mixer (MAME's enablemask) and their line buffers keep stale boot-time pixels, so a dead layer at priority 0xF beat everything. | Mode-aware kick/prefetch positions; mixer regs initialize to 0xFFFF; `layer_off` exported from the tilemap (now including the 0x1FF00 bit-12/13 NBG2/3 disables) and gated in both mixers. holo now renders ~36k nonblack pixels/frame — the first real-game imagery out of the core. |
| R9 | GAP | The synthetic ga2-path tier and boot/soak tiers had drifted from corrected hardware behaviour (old intc mask address 0xD0000C, old V25 wakeup window). | TBs updated to the MAME-correct addresses; full regression re-run. |

## R10 verification additions

- `tools/make_sim_images.py`: byte-exact MRA→SDRAM image builder (CRC-based
  ROM-file resolution for extension-less sets).
- `verif/common/tb_core_romboot.sv`: full-size memory models, per-frame
  progress counters (RAM/VRAM/palette/sprite/io/intc writes, IRQs, sprite
  pixels, nonblack pixels, display enable), jump-trace and bus-read rings,
  derail trap (PC above 24 bits dumps and stops), intc/io/EEPROM-pin logs,
  LDPR/SBR trace, windowed instruction trace (+TRLO/+TRHI), stuck-PC
  watchdog, bus-hang detector, and a +DUMPAT PPM frame dumper.
- EEPROM transaction decoding done offline from the pin log (see
  `docs/references.md` for the MAME/silicon contract used).

Current real-ROM posture: `holo` completes its EEPROM/IRQ path and renders;
`ga2` reaches V25 protection, enables interrupts, and advances into attract
logic with R7 fixed; `svf` is no longer throttled by R6, leaves its delay at
frame 46, enables display/rendering by frame 79, and completed an 82-frame
run with a frame-80 PPM dump. These are simulation milestones, not hardware
or full-game certification.

# Round 11 — V60 performance and MiSTer integration audit

This round followed the first real-ROM results into the paths that the
full-core ROM harness necessarily idealizes: the HPS loader, generated PLL,
and DE10-Nano DDR framebuffer protocol.

## R11 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R11-1 | PERF | R6 made branch-heavy V60 code 3–6× slower than the target. | Added a conservative instruction-byte threshold and retained one previous fetch window. New `tb_v60_fetch.sv` enforces cycle/read budgets; result is 3,130 cycles and 10 reads versus 12,310/2,305 before the optimization. |
| R11-2 | BUG | The ioctl loader had no deterministic reset and paired bytes through a fragile `have_lo` flag. Its V25 descramble also used the absolute stream address instead of subtracting `OFF_MCU`, shifting the MCU image by the descriptor/region offset. | Added explicit reset initialization, pair selection from `ioctl_addr[0]`, fixed-width mapping arithmetic, and `ioctl_addr-OFF_MCU` before V25 descramble. |
| R11-3 | BUG | The game core could leave reset before an index-0 ROM stream completed, and the loader could advertise completion before the final SDRAM write acknowledgement. Unrelated ioctl indexes could also disturb boot state. | Added `rom_loaded`; the top holds all game subsystems in reset until the actual index-0 transfer ends and its final SDRAM request drains. Loader state resets only with PLL loss, so a game soft-reset does not forget an already-loaded ROM. |
| R11-4 | GAP | Only default EEPROM index 2 was accepted even though every MRA declares persisted NVRAM at index 3. | Both index 2 and index 3 now load little-endian EEPROM words without changing the ROM boot gate. The upload/save half was completed and verified in Round 12. |
| R11-5 | BUG | Framebuffer requests crossed the core/DDR boundary as pulses and acknowledgements could remain asserted or retrigger under a held request. This was unsafe under MiSTer backpressure. | The core now latches read buffer/line/request until acknowledgement; `s32_fb_if` uses a four-phase request/ack contract and accepts a request only once until its producer drops it. |
| R11-6 | BUG | Run and erase writes described multi-beat bursts while changing addresses/data as separately accepted transfers, which does not obey the MiSTer DDR/Avalon contract. | Erase and run writes are pipelined single-beat transfers (`burstcount=1`) with stable signals while busy. A line fetch remains one 128-beat read burst with a stable base address. |
| R11-7 | BUG | The final CRT line prefetched line 6 instead of wrapping to line 0. | Frame wrap now explicitly requests line 0 after line 261. |
| R11-8 | BUILD | Hardware builds could use the 50 MHz placeholder PLL or miss the nested Qsys QIP; the top used non-generated port names. Quartus 17 also exposed source-order, identifier-shadowing, large initialization-loop, hierarchy, and enum-function frontend problems. | The top uses generated ports (`refclk_clk`, `reset_reset`, `outclk0_clk`, `outclk1_clk`, `outclk2_clk`, `locked_export`); `rtl/pll/pll.qip` includes `synthesis/pll.qip`; local and CI builds gate that file. Quartus-specific source blockers were removed without changing simulated behavior. |
| R11-9 | GAP | Loader completion/mapping and DDR stalls/burst semantics lacked focused regression coverage. | Added `tb_rom_loader.sv`; strengthened `tb_fb_if.sv` with deterministic randomized busy, stability assertions, read bubbles, exact erase count, and held-request duplicate checks. Both directed tests pass under Icarus and the available ModelSim checks. |

## R11 release status

At the end of this round, V60 fetch performance and loader/reset/mapping were
the newest regression gates. Round 12 adds persistence and maximum-length
decoder coverage and records the next complete combined run.

The scripted Cyclone V PLL now generates and elaborates with Quartus 17. Its
requested 96.648/48.324 MHz outputs quantize to approximately
96.634615/48.317307 MHz. There is still **no recorded successful full fit,
timing-closure result, release RBF, or MiSTer gameplay result**; none should be
inferred from the mapping fixes above.

# Round 12 — EEPROM persistence and maximum-length V60 decoding

## R12 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R12-1 | GAP | Index-3 EEPROM images could be downloaded, but the 93C46 shadow was not connected to MiSTer's NVRAM upload request/data path. A soft reset could also have discarded an unsaved-change indication. | Added `s32_eeprom_nvram_if`, wired `ioctl_upload_req` and upload index 3 through `hps_io`, and exposed the 64×16 EEPROM shadow as 128 little-endian bytes. Enabled WRITE/ERASE/ERAL/WRAL operations mark it dirty; soft reset preserves data and dirty state; loader writes establish a clean baseline; an actual index-3 upload start acknowledges that generation. |
| R12-2 | BUG | A legal F1 instruction can be 20 bytes long. With two 32-bit double-displacement operands, operand 2's final displacement starts at fetch-buffer offset 16. Four-bit effective-address offsets wrapped that field to offset 0, and a four-bit total length could advance PC by 4 instead of 20. | Effective-address offsets/lengths, displacement helper bases, and `total_len` now use five bits across the 24-byte fetch buffer. `tb_v60_long_ea.sv` executes the 20-byte memory-to-memory MOVW, checks the destination value, and proves HALT is reached at the correct next PC. |
| R12-3 | GAP | Neither new path had a release-gating regression tier. | Added `tb_eeprom_nvram.sv` at tier 16 and `tb_v60_long_ea.sv` at tier 17. The complete 17-tier regression passes. |

## R12 release status

`verif/run_regression.sh` now contains **17 tiers and the complete combined
run passes**. EEPROM index-3 load/save logic and the V60 20-byte F1 decoder
are therefore closed at the RTL/regression level. A physical MiSTer NVRAM
round trip is still part of hardware validation.

Quartus full fit, timing closure, a release RBF, and MiSTer gameplay remain
pending and are not implied by this regression result.

# Round 13 — ga2 sprite search and release-profile area

Round 12's 17-tier result above is the historical state at the end of that
round. The current regression subsequently grew to 25 tiers; the additions
and the latest ga2-specific findings are recorded here without rewriting the
earlier milestone.

## R13 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R13-1 | BUG | ga2 scans 0x3C0 halfwords for the first nonzero sprite bucket at `0x132983` with `SKPCUH [R15],R14,#0`, then branches on Z. The RTL reported a found predicate with `Z=1` and intermediate/exhausted misses with `Z=0`, the inverse of MAME's V60 behavior. That forced a populated bucket onto ga2's END-only path before the renderer could request sprite ROM data. | SEARCH completion now follows MAME `op7a.hxx`: found → `Z=0`, `R27=index`, `R28=entry address`; exhausted (including zero length) → `Z=1`, `R27=count`, `R28=end address`. `tb_v60_search.sv` executes ga2's exact bytes `5A 9A 6F 8E E0` through normal decode for found and exhausted lists and directly covers seeded `SCHCUH` and zero length. The focused ModelSim run passes without errors or warnings. |
| R13-2 | AREA | The 64×16 EEPROM shadow synthesized as a large register/mux structure, despite being a natural 1,024-bit memory. Its serial port, loader, bulk WRAL/ERAL writes, synchronous MiSTer upload reads, and generation-based dirty acknowledgement also needed an explicit single-write-port ordering contract. | Added `s32_eeprom_ram`, an explicit dual-port Cyclone V `altsyncram`. Inverted storage makes zero power-up read as erased `0xFFFF`; port A serves loader/serial writes and serial reads, port B serves synchronous uploads; WRAL/ERAL commit one word per core clock. Commit wins a same-edge upload acknowledgement and the serial state remains busy until a bulk operation completes. The focused ModelSim test passes READ/WRITE/WRAL/ERAL, upload-latency, loader-baseline, and dirty/ack cases. An isolated Quartus map reports 81 ALMs, 147 combinational ALUTs, 90 registers, and 1,024 block-memory bits. |
| R13-3 | AREA | The first release target is ga2, but the System 32 build still carried board peripherals and protection engines that ga2 can never select. | `S32_GA2_ONLY` now retains V25 and i8255 and compiles out the ADC, all three trackballs, generic protection HLE, Burning Rival protection, and Air Rescue DSP; the protection/I/O read selectors reduce accordingly. Universal builds are unchanged. |
| R13-4 | BUILD | The prior documentation had only module synthesis and failed/full-chip mapping attempts, so it could not state whether the ga2 release profile was even within the Cyclone V map estimate. | Quartus 17 Analysis & Synthesis now succeeds for `S32_SYSTEM32_ONLY` + `S32_GA2_ONLY`: **40,434 / 41,910 estimated ALMs**, 63,251 combinational ALUTs, 23,981 dedicated registers, 3,993,510 block-memory bits, 52 DSP blocks, and 3 PLLs. This is explicitly a **map-only** result; fitter utilization, placement/routing, timing closure, release RBF generation, and hardware behavior remain unproven. |
| R13-5 | TEST | BRAM timing/inference changes after Round 12 lacked focused gates for the audio, palette, tile/bitmap line buffers, synchronous tilemap VRAM, generic byte-wide dual-port RAM, and V25 mailbox. | Added tiers 20–25 for RF5C68, palette, line buffer, tilemap VRAM, byte-wide dual-port BRAM, and V25 DPRAM. The native Windows ModelSim runner `verif/run_regression.ps1` now passes the complete **25/25 tiers**, including **50/50 V60 differential seeds**; the detailed transcript is `verif/modelsim-regression.log`. |
| R13-6 | TEST | The real-ROM harness left V60 R0–R30 as four-state `X` at simulator startup because architectural reset deliberately does not rewrite every GPR. ga2 uses R26 as a startup zero, so the undefined testbench state could poison game RAM instead of matching MAME's deterministic V60 device-start state. | `tb_core_romboot.sv` initializes R0–R30 once at testbench startup, matching MAME's V60 device-start initialization without changing production reset RTL or soft-reset semantics. With that simulation-only startup condition and the corrected SEARCH behavior, coin is sampled at frames 41/42 and Start at 51/52; after the Start transition, frame 63 reaches a populated sprite list (`spr_cmd=4`, `srom=5968`, `sprpx=52722`). Frame 64 reports `spr_opq=42393` with real pixels at the mixer, and frames 64–69 sustain about 5.9K sprite-ROM requests and 42K opaque sprite pixels/frame. |
| R13-7 | SIM | The initial post-SEARCH run established first sprite activity but had not yet shown that rendering survived the requested window or produced recognizable game imagery. | The 90-frame ga2 ModelSim run completes frames 0–89 with `ROMBOOT DONE`, zero errors, and zero warnings. Sprite rendering remains stable through frame 89 at four commands/frame and about 5.8–6.0K sprite-ROM requests/frame, reaching cumulative `sprpx=1374558`. The frame-80 capture visibly resolves the skull/candle Golden Axe character-select screen, `STERN`, the player sprite, and `Credits 0`; the retained artifact is `verif/modelsim_romboot/dump80.png`. This remains simulator evidence, not pixel-equivalence or hardware acceptance. |

## R13 release status

The complete native Windows ModelSim regression passes 25/25 tiers and its
V60 differential tier passes 50/50 seeds. Real ga2 ROM execution also reaches
the post-Start sprite renderer path described in R13-6 and completes the
recognizable 90-frame capture milestone in R13-7. These simulation results do
not change the hardware gate: map success is not fitter or timing success,
and a fitted resource report, non-negative static-timing result, assembled
release RBF, and physical ga2 boot/gameplay validation are still required.

# Round 14 — local fitting and V60 write-network reduction

Round 14 moved the Quartus flow back onto the development PC with an
unrestricted Quartus Lite 17.0.2 Docker build, then used fitter evidence rather
than simulator intuition to identify the routing blocker.

## R14 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R14-1 | BUILD | Native Windows Quartus 17.0.0 repeatedly crashed in its TBB routing code, while the hosted CI runner exposed only two CPUs and took more than an hour to reach the same failure. | Added `tools/build-docker.ps1` using the MiSTer-compatible `raetro/quartus:17.0` image. Quartus 17.0.2 now runs locally without a project CPU cap, regenerates the PLL, performs the full flow, qualifies the result, and stages an RBF only after all release gates pass. |
| R14-2 | ROUTE | The 40,078-ALM design placed but did not route. Seeds 5–7 all failed with 70–77% peak interconnect use; seed 5 failed both in CI and locally in the same X11_Y35–X21_Y45 region. | The repeated failures rule out a stalled worker or one unlucky seed. Fitter hierarchy data identified `s32_v60` as the dominant block at about 25,015 fitted ALMs, so optimization moved to its register network instead of spending more time on unchanged seeds. |
| R14-3 | AREA | The monolithic V60 FSM updated the 32×32-bit architectural register array at more than 50 syntactic sites. Quartus rebuilt variable write-selection logic throughout the FSM, dominating ALMs and routing fanout. | Every full, byte, halfword, and single-bit update now queues into two explicit masked write ports; port ordering preserves same-register nonblocking priority and covers the V60's maximum two writes per cycle. The complete 25-tier ModelSim suite passes with 50/50 differential seeds. Quartus mapping falls from 40,078 to **26,851 / 41,910 estimated ALMs**, and from 62,897 to **41,440 combinational ALUTs**, with memory/DSP use unchanged. |
| R14-4 | RELEASE | A copied or stale RBF could previously be transferred even if the latest fit failed or timing was negative. | Added `tools/report-quartus.ps1` to classify map, fit, congestion, timing, and RBF freshness. Both the build and `tools/deploy-mister.ps1` require a successful fit, non-negative reported slack, and a hash match to the report-qualified RBF before deployment; MiSTer uploads are hash-checked and atomically activated. |

## R14 release status

The reduced V60 candidate is regression-clean and its full local fit is in
progress. Until that flow completes successfully, produces a current RBF, and
passes static-timing qualification, the hardware release gate remains open.

# Round 15 — first ga2 hardware gameplay and freeze isolation

## R15 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R15-1 | HARDWARE | The release MRA and a timing-clean pre-R15 RBF now boot the real World Rev B ROM on the DE10-Nano. The V25/protection path reaches attract/gameplay, and physical Start, movement, attack, and jump inputs all work. This is the first actual-gameplay result, but the video is badly corrupted and the demo can stutter and freeze. | Hardware boot, CPU execution, protection, ROM mapping, and the complete controller path are no longer design-only claims. They remain partial acceptance because sustained gameplay, correct video, and audio are not yet proven. |
| R15-2 | VIDEO | Recognizable landscape geometry was rendered with neon/speckled colors. The palette alias conversion promoted each channel's MSB into the alternate-layout flag bit; current MAME promotes the channel LSB. | Corrected both alias directions in `s32_palette.sv`. Independent one-hot R/G/B vectors and write/read alias cases in `tb_palette.sv` pass under ModelSim with zero errors or warnings. An analytical remap of the captured hardware frame becomes a coherent green/brown scene; only a newly deployed RBF can turn that preview into hardware proof. |
| R15-3 | DIAG | Two normal screenshots five seconds apart were byte-identical after the visible freeze, but PC-video diagnostic captures still showed hundreds of changing V60 addresses, including main/handler regions around `0x1009xx`, `0x100cxx`, `0x1014xx`, and `0x133xxx`. | The failure is not a hard V60 halt. Added a raw Sprite FB/DDR diagnostic that reports renderer-run, run-end, accepted DDR-write, DDR-read-data, and line-read-ack activity and exposes exact framebuffer words. This will separate renderer, DDR write/read, and mixer faults on the next approved hardware run. |
| R15-4 | BUG | The sprite-list FSM had no overdraw/list bound. A missing END or self-referential JUMP could therefore trap rendering forever while the V60 and tile display continued, matching the observed frozen-picture failure mode. | Added the reference controller's 8,192-command bound. A directed self-JUMP test reaches exactly 8,192 commands, drops `rendering`, and returns to idle; the full existing 26-tier native regression passes with the new guard. |
| R15-5 | TEST | The real-ROM harness models framebuffer service behaviorally, so its recognizable ga2 sprite output did not exercise the actual `s32_sprite` -> `s32_fb_if` -> MiSTer DDR path. | Added `tb_sprite_fb.sv`, which runs three alternating-buffer erase/render/flush frames through the real modules under deterministic DDR backpressure and verifies the exact stored pixels. It passes in 1.25 ms simulated time with zero errors/warnings and is wired as the new final regression tier. |

## R15 release status

ga2 now has real hardware boot and working physical controls, but it is not
fully functional: the deployed pre-R15 image has corrupted color, missing or
incorrect sprite presentation, demo stutter, and a repeatable visible freeze.
The palette correction, sprite-list watchdog, raw DDR diagnostic, and new
integrated regression are locally verified. A current fit/timing-qualified RBF
is being built, but deployment and launch are explicitly paused until the user
approves another MiSTer run.

# Round 16 — broad RTL audit and cross-ROM differential probes

## R16 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R16-1 | BUG | The fifth tilemap clip rectangle used a four-bit concatenated index, mapping its four words onto clip entries 8–11 and overwriting the third rectangle instead of entries 16–19. VRAM register shadows also ignored CPU byte enables. | Corrected the fifth-rectangle index width and added byte-enable merging to every scroll, zoom, page, clip, and control shadow. The focused test proves the third rectangle is unchanged, the fifth lands at 16–19, and independent low/high byte writes merge to `0xBBAA`. |
| R16-2 | BUG | Interrupt-control bytes 0–5 and 8–15 reset unknown, same-cycle source arrival plus acknowledgement could lose an unrelated interrupt, zero timer writes did not stop a running timer, and timer expiry was one clock late. | Reset all 16 control bytes to `0xFF`, combine new sources before applying the acknowledgement mask, make zero writes cancel timers, and store period-minus-one. `tb_intc.sv` covers reset, vector/mask/ack, source+ack collision, exact N=1 timer cadence, cancellation, and sound doorbell behavior. |
| R16-3 | BUG | Several byte-wide peripherals could still see high-byte/odd-lane bus cycles, and mixer register shadows accepted both bytes regardless of lane enables. These paths could create unintended side effects or replace the untouched byte with zero. | Gate sprite control, mode 416, shared Z80 RAM, I/O, ADC, analog-bank, trackball, PPI, and V25 mailbox selects with the valid low-byte lane. Mixer registers now update only enabled bytes; directed low/high-lane writes reconstruct `0xBBAA`. |
| R16-4 | BUG | System 32 and Multi 32 audio routes accumulated signed 16-bit terms into only 18 bits, allowing loud legal positive samples to wrap negative before the final divide. | Added `s32_audio_mix` with explicit 20-bit sign extension, unchanged route ratios/cross-routing, arithmetic scaling, and signed 16-bit saturation. Directed zero, ratio, stereo, positive, and negative full-scale cases pass. |
| R16-5 | TEST | The Windows runner had drifted from the shell runner and omitted the SDRAM tier; the real-ROM and ga2-path benches also omitted five newly added debug outputs. | Restored the SDRAM tier, synchronized both runners, connected the debug outputs, and added interrupt/audio tiers. The complete native ModelSim run passes **30/30 tiers** with **10/10 differential V60 seeds**. The ga2-only full core also passes Verilator 5.032 structural elaboration. |
| R16-6 | DIAG | Testing only ga2 made it hard to distinguish shared video/interrupt defects from V25/game-specific initialization. | MAME 0.285 verifies `ga2`, `arabfgt`, `spidman`, `holo`, and `svf`. New ignored simulation images were generated for Arabian Fight and Spider-Man. Eight-frame probes from the same universal RTL complete without simulator errors: ga2 reaches video/list setup by frame 7; Arabian Fight reaches mixer, VRAM, palette, and sprite-list writes by frames 2–5; Spider-Man remains in an early I/O polling sequence through frame 7 and becomes a useful non-V25 follow-up. |

## R16 release status

The local RTL audit is regression-clean, but it does not close hardware
acceptance. The fixes have not yet been proven in a newly fitted,
timing-qualified RBF on the DE10-Nano. Golden Axe remains the release target;
Arabian Fight and Spider-Man are diagnostic comparison cases only. The next
hardware gate is sustained GA2 gameplay through the first-level waterfall/
flame-heavy scene with correct palette, persistent sprites, stable DDR
framebuffer activity, and working audio.

# Round 17 — Holosseum hardware-first CPU, sprite, and mixer closure

This round deliberately stopped RBF generation and physical MiSTer testing.
It completed the hardest Holosseum-relevant blocks against pinned MAME source,
directed RTL tests, independent scalar oracles, and full-core ROM simulation.

## R17 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R17-1 | CPU | The V60 audit still had reserved-opcode, privileged-register, BRKV/TRAPFL, CALL-length, CHLVL, and task-transfer gaps. | Implemented the missing System 32 integer/system semantics and exact exception frames. `tb_v60_audit.sv` covers them directly; the final 35-tier gate retains 50/50 independent V60 differential seeds. The only deliberate general-purpose ISA exclusion is MAME's unused-on-System-32 single-precision `0x5C/0x5F` subset. |
| R17-2 | TEST | The sprite engine had strong synthetic coverage but no frozen, populated Holosseum command-list proof using the completed V60. | A fresh full-core run reaches frame 20 and captures JUMP, two DRAWs, END. Replay performs 2,432 ROM requests, 256 runs, and 25,043 pixel writes. The physical framebuffer differs only by the known global-Y storage orientation; the visible adapter gives zero mismatches against the independent oracle. |
| R17-3 | BUG | The backdrop generator read mixer word `$5E`. MAME reads VRAM `$1FF5E`; Holosseum normally uses `$0200`, so the old path selected palette entry zero instead of `$0200`. | Added a current-scanline `$1FF5E` snapshot and routed it into both mixers. Directed static and line-color tests explicitly program the unrelated mixer `$5E` to a different value. |
| R17-4 | BUG | The time-multiplexed palette schedule was phase-sensitive. In one 48/96 MHz phase, a blended pixel could consume the winner color for both operands; moving the second request naively could instead replace the winner before it was retained. | The winner address now launches during winner selection, the runner-up address at P0, and the winner result is retained at P2. This fits the existing pixel budget and is safe for both 2:1 phases with the real inferred palette RAM. |
| R17-5 | BUG | Blend expressions relied on implicit SystemVerilog sizing even though signed color offsets expand each pre-clamp channel to `-32..62`. | Added explicit signed wide products. Offset, blend, shadow, and final clamp now preserve MAME's operation order and full intermediate range. |
| R17-6 | TEST | Bitmap coverage checked only the first low nibble of one 4-bpp word; mixer tests did not explore the cross-product of priorities, sprite modes, offsets, blends, and shadows. | Expanded the bitmap test across all 4-bpp nibbles, both 8-bpp bytes, X/Y scroll and wrap, palette formation, full-byte opacity, and clip-in/clip-out. Added an independent scalar mixer model plus deterministic packed-vector RTL harness. Four 1,024-case seeds pass, and a 512-case seed is now permanent in regression tier 10. |
| R17-7 | BUG | In 416-wide mode the mixer receives exactly 12 `clk_ram` edges per pixel. The old control sequence attempted its P6 RGB commit on the same edge that the next `disp_x` change took priority, so most pixels retained black/stale output even though their palette fetches were correct. | Registered the winner's blend control one stage earlier and merged runner resolution/final-context capture into T3. P6 now commits one edge before the next pixel. The full-core soak rises from 2,652 to 167,076 non-black active samples without weakening its threshold, and still reports zero RGB/audio unknowns. |

## R17 status

The V60 System 32 software profile and 315-5386A sprite engine are frozen at
the simulation level for Holosseum. The 315-5387/315-5388 bitmap/mixer path
now has direct MAME-contract coverage and independent randomized evidence. A
fresh final-mixer Holosseum run reaches 63,383 non-black pixels at frame 19;
its populated frame-20 list again replays 2,432 ROM requests, 256 runs, and
25,043 writes with zero visible mismatches. The complete regression passes
35/35 tiers with 50/50 V60 seeds, and Quartus analysis/elaboration completes
with zero errors. No fitter, assembler, RBF, deployment, or MiSTer launch was
part of this phase.

# Round 18 — Holosseum production audio closure

This round continued without an RBF or MiSTer launch. It checked the regular
System 32 sound board against the pinned MAME driver/RF5C68 device and current
official Jotego JT12 source (`eaab7e1de6594982a299bc9101dc882384b85685`).

## R18 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R18-1 | BUG | Port `F1` was hardwired to zero, although MAME models it as a stateful byte latch. Ports `D8-DF` also incorrectly aliased the `D0-D7` interrupt-control mirror, and Multi 32 returned YM1 data from its unmapped `90-9F` range. | Added the `F1` latch, restricted the interrupt-control high page to its real mirror, and return open-bus `FF` for the absent Multi 32 second YM. Directed bus cases cover all three. |
| R18-2 | BUG | Separate nonblocking updates of the sound pending bits allowed a same-cycle ACK to overwrite a fresh YM/V60 source event. | Added a merged pending-bit next-state calculation. ACK is applied first and new source events win, so an arriving interrupt remains pending. The collision is now a directed test. |
| R18-3 | TEST | The fast full-core simulator used a stub Z80 and no aggregate sound evidence; the production T80 test only proved a synthetic program. | Added production-T80 real-ROM and full-core Holo gates. CNT2 is low through frame 0, then the V60 releases it; by frame 1 the T80 has executed 130,470 opcode cycles and made 15,659 ROM transactions with no unknown audio. The focused five-million-cycle Holo sound-ROM run uses both production JT12s and records 560,905 opcode cycles, 2,208/2,184 FM writes, 156 RF5C68 register writes, 12,287 wave-RAM writes, and 63,314 shared-RAM reads, with zero unknown FM, PCM, or mixed samples. |
| R18-4 | BUG/TEST | The top stopped `ce_fm` during board/ROM-load reset, but JT12's internally divided operator/envelope rings only flush while its enabled clock advances. The JT12 operator-slot sequencer also relied on a `SIMULATION`-only initializer instead of its reset input. A clean production-style compile therefore left FM outputs `X`. | Split FM onto its own fractional NCO, rephased only while the PLL is unlocked, so the YM clock keeps running throughout board reset while the Z80 remains halted. Added a synchronous reset to JT12's 24-slot sequencer plus `tb_jt12_reset.sv`, long-reset modeling, prerelease knownness checks, and per-source X counters. The isolated clean-build gate and real Holo ROM run now pass with deterministic outputs; regression tier 30 compiles the production JT12 QIP without the simulation initializer. |
| R18-5 | ACCURACY | The full-core ROM harness generated RF5C68 CE with an integer `/4` approximation (12.081 MHz). | Replaced it with the exact production `16952/65536` fractional NCO for 12.5 MHz from 48.324 MHz. |

## R18 status

The regular System 32 sound address map, banking, latch behavior, interrupt
collision semantics, T80 boot path, dual-YM programming, RF5C68 programming,
and output-knownness now have direct evidence. Copyrighted ROM data remains
under ignored `roms/`; committed tests expose only aggregate counters. Audio
waveform equivalence and a complete Holo command/music sequence still require
a captured main-to-sound command trace or later physical/reference-audio test.

# Round 19 — Holosseum release-profile closure

This pass converts the generic/GA2-oriented release path into a deterministic
Holosseum target and closes the highest-risk pre-fit platform/video findings.
It uses MAME 0.285 as the pinned behavioral reference; ROMs and generated
captures remain under ignored `roms/`.

## R19 findings

| # | Class | Finding | Resolution |
|---|---|---|---|
| R19-1 | REFERENCE | There was no reproducible Holosseum reference session and the documented controls incorrectly listed four buttons. | Added a fixed-frame MAME Lua/PowerShell capture harness with ROM verification, XML, input pulses, screenshots, AVI/WAV, trace, and SHA manifest. MAME reports two players, 8-way controls, and two buttons. |
| R19-2 | RESET/LOAD | ROM download could start before SDRAM initialization, and the V60 depended on simulator seeding for deterministic cold power-up. | Synchronize SDRAM `ready` into `clk_sys`, hold the loader/CPU until ready, backpressure ioctl, initialize architectural GPRs once at power-up, and preserve normal soft-reset register semantics. `tb_rom_loader` proves no early descriptor/write side effects. |
| R19-3 | ORIENTATION/TIMING | Holosseum's `ORIENTATION_FLIP_Y` was absent and width writes could change pixel cadence/totals mid-frame. | Descriptor byte 1 bit 1 now selects final cabinet Y orientation for tile source lines and sprite scanout. Horizontal mode is latched only at a complete frame boundary; `tb_video_mode` covers both live transition directions without runt lines. |
| R19-4 | SPRITES | Combined auto erase/swap physically cleared the displayed DDR buffer before ownership changed, exposing partially erased lines. | Publish the completed back buffer first, erase the now-hidden old front, and render the next frame into it. Erase-only semantics remain unchanged. The directed controller and real sprite-to-`s32_fb_if` tests pass; synthesized underrun telemetry now records any line fetch still outstanding at active-line start. |
| R19-5 | TILEMAP | NBG0/1 used reduced 10.10 coordinates, ignored `$1FF10/$1FF14` fractional words, truncated the 12-bit zoom denominator, and always treated centers as signed 10-bit. | Implemented MAME's exact `(0x200<<20)/zoom` 12.20 reciprocal, 12-bit clamp/range, fractional X/Y origins, modulo-32-bit coordinate math, global/layer flips, and the neutral 9-bit versus zoomed 10-bit signed-center rule. Directed tests cover power-of-two/arbitrary/max denominators, fractional shadows, the neutral `$1FF` center case, and backpressure. |
| R19-6 | AUDIO | The mixer ratios were only approximate and clipped too early relative to MAME's configured routes. | System 32 now mixes YM1 `0.30` + YM2 `0.30` + RF5C68 `0.40`; Multi 32 keeps the documented cross-YM `0.15` + MultiPCM `0.35` routes, with wide signed accumulation and final saturation. |
| R19-7 | MEMORY/IRQ | Fixed read priority could starve lower SDRAM clients, while timer 1 used an approximate 15.5× host-clock period. | Added bounded six-client round-robin read arbitration (download writes remain highest only while reset) and an exact 50 MHz/16 NCO for timer 1. Directed tests prove a low-priority request completes under continuous p0 demand and bound the N=1 timer period to 3,959 host clocks. |
| R19-8 | REAL ROM | The post-fix sprite path needed fresh game-driven proof. | A new Holo run reaches frame 20 with no V60 exception and captures JUMP, two DRAWs, and END. Replay performs 2,432 ROM requests, 256 runs, and 25,043 pixel writes. Visible output matches the independent sprite oracle exactly; physical-only differences are the intentional global-Y storage adapter. |
| R19-9 | FIT/TIMING | The first fitted Holo profile exposed a 16-level mixer path from the serialized eight-layer priority scan through palette-index arithmetic, missing the 96.63 MHz core clock by 2.501 ns. Quartus Standard evaluation mode also withheld programming files. | Replaced both winner scans with balanced max trees and moved each layer's variable-shift/palette-base calculation before the existing candidate snapshot. Directed and 512-case independent mixer tests remain exact. Quartus Lite 17.1 seed 5 now fits at 30,560/41,910 ALMs (73%) and 492/553 RAM blocks (89%), with +0.485 ns setup and +0.245 ns hold slack. Assembler emits a current 4,266,012-byte RBF with SHA-256 `11BEE5770FB394E6CCB837C3165B649DF88D777210E167E6518EF9D23281542D`. |
| R19-10 | HARDWARE | Spider-Man was previously retained only as an early non-V25 simulation diagnostic. | A real MiSTer run now reaches gameplay with correct colors/palette, working controls, and working sound. Missing/incorrect sound effects and defective enemy attacks remain; this is a hardware-playable milestone, not compatibility certification. Its correct palette is useful control evidence that the common RGB extraction and DAC channel order are sound, narrowing Holosseum's bad colors toward its palette addressing/clocking behavior. |
| R19-11 | VIDEO/FIT | The palette BRAM mixer address crossed from the 2x mixer clock while its physical-bank bit was selected in the system-clock domain, so the row and bank could become misaligned. | Moved the palette read port and its bank selection fully into `clk_ram`, registered the complete logical address together, and added behavioral plus Quartus-primitive palette/mixer tests. Seed 6 fits at 30,821/41,910 ALMs (74%) and 492/553 RAM blocks (89%), with +0.314 ns setup and at least +0.248 ns hold slack. The resulting RBF has SHA-256 `0C241D4FBBD202A8EFACFBD7261ED31DDD4AB74BE515FBF7E1E9E5A1956094D2`. MiSTer testing showed Holosseum's colors unchanged, disproving this clock-domain defect as the palette-corruption root cause; Holo-specific mixer offsets/blending remain under investigation. |

## R19 release status

The checked-in Quartus profile is now `S32_SYSTEM32_ONLY + S32_HOLO_ONLY`.
`S32_REAL_V25` remains absent; `S80X86_PSEUDO_286_INT=0` is defined only so
the dormant V25 source list parses in Quartus 17. The deploy helper defaults
to the Holosseum MRA and refuses any RBF without successful current fitter,
timing, and hash checks. Seed 6 now meets timing and produces a release RBF.
Deployment confirms gameplay, audio, controls, and mirrored sprite output;
correct Holosseum colors and structured extended-play acceptance remain open.

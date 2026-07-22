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

# Round 20 — Full-core audit against pinned MAME with instrumented ground truth

This round is an audit only: **no RTL was changed, no RBF was built, and no
MiSTer run occurred.** Six parallel subsystem audits (tilemap/VRAM/CRT,
sprites/DDR, audio, V60, platform/ROM path, I/O/interrupts/protection)
compared every block line-by-line against the pinned MAME snapshot, alongside
a core-glue/palette/mixer audit and — new this round — **instrumented MAME
reference captures**: Holosseum, Spider-Man, and GA2 were run under
MAME-in-WSL with Lua register/palette dumps and palette-write-window taps.
Capture tools are committed (`verif/mame/holo_regdump.lua`,
`verif/mame/holo_palwtrace2.lua` — note MAME write taps must be pinned in a
Lua global or GC silently removes them); dump evidence is under ignored
`roms/reference/holo/audit-r20/`.

## R20 Holosseum palette investigation — RTL logic proven correct; defect is below RTL

Ground truth captured from MAME at title/post-start/gameplay frames:

- Holosseum runs `$4C=0xBE4D` (sprite groups from pix[13:12], **RMW shadow
  bit 2 set** — the floor mirror), `$4E=0x0C00` (**blend enable bit 11 set,
  factor 4** — so the palette **write-both mirror is active for every
  palette write the game ever makes**), `$3E=0xC000`, `$2C=0x0000`,
  sprite groups 0–3 = `0011/0014/0018/001F` (sprite palbase nibble 1 →
  entries 0x400+). Mixer regs `$50+` are never written and stay `0xFFFF` —
  the RTL `mreg` power-up default is exactly right, and the seed-6 fit
  report proves the fitter honors it (discrete ALM registers, not MLAB).
- VRAM `$1FF02=0x002F` disables NBG0-3 and bitmap (text stays on);
  `$1FF5E=0x0200` → the backdrop reads **palette entry 0x0200, which MAME
  holds at 0x0000 = black**. Color offsets `$40-$44` are 0 at gameplay
  (`ff00`) and −16 during the post-start fade (`fff0`).
- Write-window taps: Holosseum writes its palette **exclusively through the
  converted-format alias window** (byte 0x8000-0xBFFF → lower half), in
  back-to-back bursts up to 4,129 words per frame, with both 16K halves in
  lockstep in MAME (write-both active). **Spider-Man and GA2 also write
  exclusively through the alias window** — and both show correct colors on
  MiSTer, which **exonerates the alias write-conversion path on hardware**.
- Decisive replay: feeding the captured register state, layer enables,
  backdrop control, and palette contents through
  `verif/reference/s32_mixer_ref.py` (equivalent to the RTL mixer by the
  permanent 512-case differential) yields **rgb=000000 black** for the
  empty-screen pixel (winner=background, index 0x0200), correct sprite
  colors, and correct halved shadows, in both the fade and gameplay states.

Conclusion: the RTL palette+mixer algorithm is correct for Holosseum's real
programming. The blue background on hardware is a **below-RTL divergence**.
Verified-clean this round: layer-enable logic (bit-exact vs
`update_tilemaps`), backdrop `$1FF5E` routing, palette format converters
(both directions, byte-enable permutation), mixer index/blend/offset/shadow
arithmetic, `mreg` power-up initials in the actual fit, SDC clock
relationships (clk_sys/clk_ram are same-PLL related and timed;
V60/sprite multicycle exceptions verified correctly scoped — the V60 is
fully ce-gated and its bus adapter lies outside the exception), RGB output
chain (no color-touching stage; spidman control case), and the sprite
pixel encode/erase/DDR/line-fetch chain. Remaining ranked suspects, each
with a concrete next test:

1. **Palette bitplane primitive behavior in the real dual-clock config.**
   The 32× `altsyncram` 8K×1 planes run port A on clk_sys and port B on
   clk_ram with `read_during_write_mode_mixed_ports="DONT_CARE"`, and
   Holosseum animates the palette continuously (collisions every frame).
   The Quartus-level harness (`verif/quartus_palette/palette_infer_top.sv`)
   ties `mix_clk = clk`, so the production dual-clock configuration has
   never been validated at the primitive level. Next test: post-fit
   (gate-level) simulation of the palette sub-project in its dual-clock
   arrangement, replaying the captured Holosseum alias-window write
   sequence (including the 4,129-word back-to-back burst and write-both
   mirroring) against concurrent mixer-port reads of entries 0x0200/0x04xx,
   diffed against the behavioral model.
2. **Value/index-range-dependent addressing fault.** Follow-up captures
   show spidman and ga2 ALSO run with blend enable set (`$4E=0x0B00` /
   `0x0800` — write-both active) and burst comparable back-to-back palette
   writes (spidman 3,584/frame), so the write-both mechanism and cadence
   are **common to all three games** and cannot alone be the divergence.
   What is holo-unique is only the value set: sprite group mode 0xD
   (shift 12) vs 0xE, sprite palbase nibble 1 (entries 0x400-0x13FF), and
   bg palbase 0 with entry 0x0200 — vs spidman/ga2 backgrounds at palbase
   3 (0xC00+). A defective palette row/bank address bit or plane in the
   synthesized primitive corrupts exactly some index ranges and not
   others — matching "holo wrong, spidman right" — and the gate-level
   replay in (1) detects any such fault directly. The pend-copy's "idle
   clock after a write" bus assumption was verified to hold for the V60
   adapter but remains an unasserted convention (see CG-1).
3. **On-hardware readback diagnostic.** Add a debug path (OSD-selectable
   video mode or HPS readback) that dumps palette entries 0x0000-0x000F /
   0x0200 / 0x0410-0x041F and mixer regs 0x20-0x27 live on MiSTer. One
   capture then splits the fault between palette content (write side),
   palette read path, and mixer arithmetic with certainty.

## R20 findings

All findings are **open** (audit-only round). Prior-round fixes were spot
verified and are not re-listed. Per-area IDs match the detailed subsystem
reports produced during the audit.

### Critical

| # | Area | Finding | Proposed action |
|---|---|---|---|
| IO-1 / AU-1 | V60↔Z80 shared RAM | The V60 side of the 8 KB sound shared RAM is word-strided and low-lane-only (`s32_core.sv:668-670`: byte *k* at `0x700000+2k`, `m_be[0]` only, 16 KB footprint). MAME (no `umask16`) byte-packs: byte *k* at `0x700000+k`, both lanes, 8 KB mirror. **Proven from game code**: ga2's V60 absolutely addresses `0x701F00/02` while its Z80 addresses `0xFF00/02`; spidman's Z80 command area uses odd addresses (`E001/E061/E081/E083/E085`) the RTL makes unreachable from the V60. Odd command bytes are dropped; even ones land at halved Z80 addresses. Holosseum's minimal protocol survives by accident. Prime suspect for **spidman missing/incorrect SFX** and a credible mechanism for the **ga2 freeze** (V60 spinning on a Z80-owned status byte it can never see change). | Rebuild as a byte-packed 8 KB window serving both lanes (`{A[12:1], lane}`), mirror per MAME; add the directed V60↔Z80 addressing test (AU-9) that today does not exist; regression-check holo audio afterward. |
| V60-1 | V60 XCH | `XCH` decodes operand 1 as a value, so the reg/reg form does a bus RMW at the address equal to the register's *content*, memory forms use loaded data as the address, and the reg,mem form swaps nothing (`s32_v60.sv:2541-2549, 2902-2932` vs `op12.hxx:2178-2224`). ga2 uses `XCH.W` as a lock idiom. | Add 0x41/43/45 to the address-decode set and implement the four operand-form cases; directed test for all forms. |
| V60-2 | V60 HALT | HALT wakes with return PC = the HALT's own address, so RETI re-executes HALT forever: interrupt handlers keep running while the main thread is permanently parked (`s32_v60.sv:698, 2514-2520` vs `op5.hxx:58-63` where MAME treats 0x00 as a one-byte no-op). Exactly matches the ga2 hardware signature — frozen displayed frame, V60 PC still changing. | Match MAME (one-byte no-op) or push `pc+1` on wake; update benches that exploit halt-as-test-end. |

### High

| # | Area | Finding | Proposed action |
|---|---|---|---|
| V60-5 | V60 INC/DEC | INC/DEC never update OV (both register and memory RMW paths), and register-form `INC.W` computes CY from a constant-zero expression. Signed branches (BGT/BLT/DBcc…) after an INC/DEC evaluate stale OV — the classic AI counter/loop shape; **strongest CPU candidate for spidman's defective enemy attacks**. | Implement per-width add/sub OV in both paths; fix INC.W CY; add flag-consumer directed tests. |
| V60-3 | V60 GETPSW | Operand decoded as value instead of write destination: register form writes PSW to wild RAM at the register's current value and never updates the register (`s32_v60.sv:845, 2959-2972`). Silent memory corruption wherever games use it. | Decode 0xF6/F7 with `ea_want_addr=1`; use flag1 reg/mem write paths. |
| V60-4 | V60 TRAP/cc | Conditional TRAP ignores its condition nibble and always vectors (`s32_v60.sv:2975-2985` vs `op3.hxx:222-300`). Compiler overflow/bounds-check idioms would spuriously trap. | Evaluate the Bcc condition table; fall through when false. |
| V60-14 | V60 string ops | `MOVCD` (down copy) walks physically descending addresses; MAME copies descending element order over the *ascending* range — the RTL reads/writes entirely wrong memory. `MOVCF` fill and `MOVCS` stop variants silently behave as plain copies. Final R27/R28 short by one element; zero-length forms skip register/flag updates. | Rebase the down walk at `base+(len-1)*step`; implement fill/stop; fix final registers. |
| SP-1 | Sprite status | Framebuffer-select status bit read back at `$C00000` is inverted at every instant vs MAME (RTL resets displaying buffer 0/reads 0; MAME reads 1 at power-up, 0 after first swap — confirmed by the project's own sprite oracle defaults). A game polling the absolute value desyncs its double-buffering by one frame permanently. | Reset `disp_buf` to `2'b01` (or invert the readback); directed status-poll test. |
| PF-5 | Timing signoff | `TIMEQUEST_MULTICORNER_ANALYSIS OFF` in the QSF: release RBFs (and the deploy gate) are signed off at a single corner with only +0.248 ns hold margin reported; fast-corner hold is unchecked. Also timing-driven synthesis silently skips because the SDC's hard `error` guards fail at map stage. | Enable multicorner for release qualification; make the SDC guards executable-aware. |
| AU-2 | MultiPCM ROM port | No byte-lane select on SDRAM p4: every odd sample/descriptor byte returns the even byte (`s32_core.sv:676,682`). Fatal for all Multi 32 audio when that profile is built. | Latch `mpcm_ba[0]` and mux the SDRAM half-word. |

### Medium

| # | Area | Finding | Proposed action |
|---|---|---|---|
| V60-6/7/8/16/17 | V60 flags | MUL/MULU OV wrong for all widths (signed-product-high test missing); SHA-left OV hardwired 0 and SHL/SHA count-0 must clear CY; divide-by-zero updates no flags, DIV min/−1 overflow OV missing, REM/REMU leave OV stale; SUBC.B/H OV constant 0 and a SUBC.W CY wrap case; MOVT truncation OV missing. Any of these ahead of a signed/overflow branch misbranches. | Implement per the MAME macros; extend the differential harness to compare PSW (V60-20) so the whole class stays closed. |
| V60-9/10/11/12/13/18 | V60 instructions | DIVX/DIVUX with memory operand skip the operation; MULX/MULUX never store to memory; MOVD moves 32 of 64 bits; PUSHM/POPM mask bit 31 pushes SP instead of PSW and discards the popped PSW; TASI flags diverge (CY inverted) and register form dereferences; CMPC S-flag inverted with wrong final R27/R28 and missing length-tail rules; CHLVL/UPDPSW/LDTASK memory-operand forms use the EA or stale data as the value. | Implement per MAME; add directed tests per op (none are covered today). |
| V60-19 | V60 prefetch | Neither the 24-byte fetch window nor the retained previous window is invalidated by data writes: self-modifying code within ~24 bytes ahead of PC, or a two-instruction backward loop patching itself, executes stale bytes forever (beyond even real-V60 prefetch behavior). | Two range comparators clear the windows on overlapping data writes; self-modifying-code directed test. |
| V60-20 | Verification | The "50/50 differential seeds" gate emits only 10 reg-reg word-form ALU ops, straight-line, and **never compares flags**; the Python reference's scope is defined circularly as "the RTL's tested subset". None of the V60 findings above is reachable by it. | Dump PSW into `.expected`, widen the op mix (widths, memory forms, flag-consumer branches), diversify generators. |
| IO-2/IO-3 | ADC | MSM6253 shifter shifts on every clk_sys cycle while a read is held (one V60 read consumes 4-6 bits), and the serial data bit is returned on D0 where the chip drives D7. Breaks all analog games (radm/radr/f1en/alien3/jpark/dbzvrvs) once enabled. | Per-transaction read one-shot (`rd_stb` mirror of `wr_stb`); move the bit to D7. |
| AU-8 | Z80 timing | Every Z80 ROM read missing the 1-deep word cache stalls on SDRAM (~65-85% effective speed on ROM-resident code; `LDIR` thrashes opcode/data in the same cache word). Real hardware is zero-wait. Secondary suspect for load-dependent spidman SFX dropouts; holo tolerates it. | Two-entry I/D-split cache or next-word prefetch. |
| SP-3 | Sprite frame sync | The vblank event is consumed only in `R_IDLE`: if erase+render overruns one frame (reachable under contention per the spec's own worst-case numbers), that frame's command processing is silently skipped. | Latch vblank as pending while busy; consume on return to idle. |
| PF-6 | SDRAM closure | Aggregate tile-fetch bandwidth under simultaneous V60 thrash + sprite saturation + max zoom-out is not formally closed, and the existing `tm_line_overrun` telemetry is not surfaced in any debug video mode — a mid-line underrun on hardware is invisible. | Surface the counter in a debug mode; add a saturating-traffic regression tier. |
| PF-2 | Display aspect | "Original" aspect is hardwired 13:7 (416-wide assumption): Holosseum's 320-wide mode displays stretched ~1.86:1 instead of 4:3; the ARC1/ARC2 entries never emit the custom-aspect encoding. | Original → 4:3; fix the ARC status encoding. |
| TM-6 | Tilemap tests | No directed vector covers NBG2/3 rowscroll+rowselect combined with global flip, flipped text, or 416-mode clip mirroring — exactly the paths holo/ga2 exercise least. | Add the scalar-model-checked directed TB. |
| CG-2 | Palette Quartus harness | `verif/quartus_palette/palette_infer_top.sv` ties `mix_clk=clk`: the production dual-clock M10K configuration (the R19-11 area, and prime holo suspect) has never been validated at the Quartus-primitive level. | Extend the harness to true dual clocks and replay the captured holo write sequence post-fit (investigation step 1 above). |
| CG-3 | Pixel-exact gate | No simulation tier compares RTL RGB output against MAME pixel-for-pixel — the strongest full-core gates count non-black pixels only, which is exactly why a palette-class defect could survive to hardware twice. | Add a frame-diff tier: replay a captured MAME state (tools now in `verif/mame/`) and diff a full frame against a MAME screenshot. |

### Low / accuracy / hygiene

| # | Area | Finding |
|---|---|---|
| TM-1 | Video | 416/320 width authority: RTL derives everything from sprite control reg 6; MAME uses VRAM `$1FF00` bit 15 for the tilemap/CRT side (games set both consistently today). |
| TM-2 / SP-4 | Video | Backdrop line-color gradient (`$1FF5E` bit 15) is not mirrored under the cabinet FLIP_Y adapter (holo uses the constant mode — unaffected). |
| TM-3 | Video | Multi 32 per-layer 2-bit external tilebank not implemented (System 32 formula used unconditionally). |
| TM-4 | Video | Zoom shadows power up 0x200-neutral vs MAME's zeroed videoram (pre-first-write frames only, display blanked). |
| TM-5 | Perf | Full 6-layer render pipeline runs during the 38 vblank lines each frame, wasting SDRAM p1 bandwidth (~15% of frame time) on undisplayed lines. |
| SP-2 | Sprites | 30 Hz auto mode discards a CPU-written manual command on skip frames (MAME executes it). |
| SP-5 | Sprites | Flip-bit changes take effect one frame later than MAME (write-side flip), and the swap lands ~50 µs into line 0 so the first scanline shows the previous frame's buffer. |
| SP-6 | Sprites | Sprite ROM bank mirror uses an AND mask (correct for 1/2/4-bank sets; a hypothetical 3-bank set diverges). |
| SP-7 | Sprites | No regression asserts the sprite line-fetch worst-case deadline (single, non-double-banked line buffer). |
| PF-1 | Platform | `VGA_SL = status[5:4]` mis-slices the 3-bit scanline field: CRT 50% gives 25%, 75% unreachable; HQ2x entry is inert. |
| PF-3 | Platform | ROM loader accept path doesn't qualify on `!busy`: an ioctl word arriving during an outstanding SDRAM write is silently dropped (only the V25 byte window is realistically exposed; saved today by HPS pacing). |
| PF-4 | Platform | DDR reads launch with stale byte enables from the previous partial write (works on Cyclone V f2sdram; not Avalon-conformant). |
| PF-7 | Platform | `GAME_ONLY` builds return V25 mailbox data at 0xA00000 even when `board.has_v25=0` (should be open-bus 0xFFFF). |
| PF-8 | Platform | Z80/V60 shared RAM and V25 mailbox byte-DPRAMs synthesize `POWER_UP_UNINITIALIZED="TRUE"` — random at power-up on hardware vs zeros in sim. |
| PF-9 | Platform | `forced_scandoubler` unconsumed (direct-VGA users always get 15 kHz); no pause option. |
| AU-3/4/5/6 | Audio (Multi 32) | MultiPCM: no envelope/TL-interpolation/LFO, key-off cuts instantly, 12-bit samples decoded as 8-bit; register decode aliases mod 4 across 0xC000-0xDFFF; PCM stereo not cross-routed like MAME; scross's variant bank decoder missing. |
| AU-7 | Audio | Z80 reads of the RF5C68 register page return 0xFF vs MAME's unmapped 0x00. |
| AU-10 | Reference | `gew.cpp/.h` (MultiPCM base class) missing from the pinned snapshot — AU-3/AU-5 cannot be closed byte-exactly until vendored. Likewise `am1/am2/am3.hxx` are missing for the V60 EA bodies. |
| AU-11 | Audio | Audio NCO rates are 14-58 ppm off exact (inaudible; recorded). |
| IO-4 | I/O | 315-5296 SEGA-signature/CNT/DIR readbacks missing (read 0xFF). |
| IO-5 | I/O | Multi 32 TIMER0 should count 16.000 MHz, not 16.108 MHz (0.67% fast). |
| IO-6 | I/O | Interrupt `pending` resets to 0; MAME resets to all-pending-masked 0xFF. |
| IO-7 | I/O | 0x800000 s32comm share RAM reads 0xFFFF instead of behaving as RAM (link games). |
| IO-8/9/10 | Protection | dbzvrvs HLE trigger window too narrow (0xA00000-0xA0FFFF vs 0xA7FFFF); brival read trap fires on byte reads (MAME: word-wide only); dual-PCB id served across 32 KB instead of 4 bytes and f1en comm RAM powers up 0 vs 0xFF. |
| IO-11/12 | Inputs | US sets (ga2u, spidmanu) take coins on PPI EXTRA3 bits 3/2 — the MiSTer Coin button drives what those sets read as COIN3/4; service-credit and PCB Push SW1/SW2 buttons unmapped. |
| IO-13 | I/O | 0xD80000 RNG is a correlated 16-bit LFSR stepped per CPU clock vs MAME's full-width rand(); all three target games read it (weak spidman-AI suspect). |
| IO-14 | I/O | Trackball read-back injects joystick buttons into the counter high nibbles (MAME: unconnected switches). |
| IO-15 | I/O | `analog_bank` has no reset/initializer — X in sim for System 32 analog games (hardware powers up 0). |
| IO-16 | I/O | i8255 control word not latched/readable; ports hardwired input (sufficient for current games). |
| IO-17 | Loader | Index-2 factory EEPROM images likely byte-swapped vs MAME's big-endian region (affects jpark/radm/radr/scross/titlef/harddunk preloads; holo/spidman/ga2 unaffected). |
| V60-15 | V60 | Down-direction SCHC/SKPC scan below the base address (up forms exact; already noted in R13). |
| V60-21/22 | V60 | Reset PC upper byte 0x00FFFFF0 vs 0xFFFFFF0; soft reset clears privileged regs MAME preserves; BAM bit-offset divide signed vs MAME unsigned (both unreachable in practice). |
| IO — misc | I/O | Prot-HLE write triggers can re-fire on held writes (idempotent today); EEPROM over-clocked READ holds last bit vs MAME shifting zeros (games clock exactly 16). |
| CG-1 | Palette | The write-both pend-copy's "idle clock after write" bus assumption holds for the V60 adapter but is unasserted; a future second write master (or pipelined bus change) would silently drop mirror copies. Add an SVA assertion. |

## R20 status and forward plan

**Holosseum (release target):** the palette defect is isolated to below-RTL
with the RTL algorithm proven against instrumented MAME ground truth. Next
actions in order: (1) dual-clock gate-level palette replay of the captured
write sequence (extends `verif/quartus_palette`); (2) the write-both
pend-copy directed/assertion tests; (3) an on-hardware palette/mixer
readback diagnostic in the next approved RBF, which splits
content-vs-read-vs-mix with one capture. Independent of the palette:
PF-2 (320-mode aspect) is user-visible and trivial.

**Spider-Man (next target):** fix IO-1/AU-1 (shared RAM byte packing —
also re-run holo audio after), then V60-5 and the V60 flag family
(V60-6/7/8/16/17) with the upgraded differential harness (V60-20), then
AU-8 (Z80 wait states) if SFX dropouts persist. SP-1 and IO-13 are
second-line suspects for the enemy-attack defect.

**GA2 (later):** V60-2 (HALT) + V60-1 (XCH) directly match the
freeze-with-running-CPU signature; IO-1 provides the I/O-side deadlock
mechanism. All three land as part of the above.

**Process:** V60-20 (differential flags), CG-3 (pixel-exact MAME frame
diff), AU-9 (shared-RAM seam test), PF-5 (multicorner signoff), and
vendoring `gew.cpp`/`am1-3.hxx` into the reference snapshot keep these
classes closed once fixed.

# Round 21 — Implementing the R20 audit fixes

This round implements the R20 findings in RTL. It is verified with the native
ModelSim regression (all 35 tiers, now including two new directed tiers) plus
per-module targeted runs. **No RBF was fitted and no MiSTer run occurred** —
the changes are simulation- and lint-verified only, and a fresh
timing-qualified hardware run is still required before any accuracy claim.

## What was implemented (verified)

### Critical
- **IO-1 / AU-1 — V60↔Z80 shared RAM byte-packing.** Rebuilt the 0x700000
  window as a 4K×16 dual-port RAM: the V60 gets a true 16-bit byte-enabled
  port at word address `A[12:1]`, and the Z80's 8-bit port selects a lane by
  its low address bit, so V60 byte *k* now maps to Z80 `0xE000+k` on both
  lanes with an 8 KB mirror (`rtl/audio/s32_soundsys.sv`, `rtl/s32_core.sv`).
  New directed test `verif/common/tb_soundsys_shared.sv` (AU-9) drives a real
  T80 complement-copy of a V60-seeded block and checks the round trip through
  both byte lanes — the seam every other sound bench left at `sh_cs=0`.
- **V60-2 — HALT resume.** S_HALT now advances PC past the HALT only on wake,
  so the interrupt frame returns to the instruction after the HALT instead of
  re-executing it forever (the ga2 freeze-with-running-CPU signature). A
  no-interrupt HALT still parks at its own PC, so end-marker benches are
  unaffected.
- **V60-5 — INC/DEC overflow.** Both the register and memory RMW paths now
  produce full ADDB/SUBB flags (overflow and the previously constant-0 INC.W
  carry). New directed tier `verif/v60/tb_v60_flags.sv` captures the PSW with
  GETPSW after INC/DEC of `0x7FFFFFFF`/`0xFFFFFFFF`/`0x80000000`/`0`/`0x7F` and
  confirms OV/CY/S/Z exactly — the flag class the differential harness never
  observes.
- **V60-1 — XCH.** Added 0x41/43/45 to `f12_op1_is_addr` so both XCH operands
  resolve as addresses: the reg-reg and reg-mem forms (including ga2's lock
  idiom) now use the correct swap address instead of a register's *value*.
  (The rare mem-mem form remains a documented TODO.)

### High / medium
- **V60 flag family:** conditional TRAP/cc (V60-4, evaluate the Bcc condition;
  0xB never traps), GETPSW decode as a write destination (V60-3), signed/
  unsigned MUL overflow via a retained-operand product (V60-6), SHA left-shift
  overflow + zero-count carry clear for SHL/SHA (V60-7), signed DIV min/-1
  overflow and REM/REMU OV-clear (V60-8), PUSHM/POPM mask-bit-31 = PSW
  (V60-11), TASI = SUBB(old,0xFF) flags (V60-12), SUBC 33-bit borrow + per-
  width overflow (V60-16), MOVT truncation overflow (V60-17). All verified by
  the 10 V60 tiers plus the new flag tier.
- **AU-2 — MultiPCM ROM byte lane** selected from the 16-bit SDRAM word
  (`rtl/s32_core.sv`).
- **SP-1/2/3 — sprite** frame-select readback polarity (invert only the CPU-
  visible bit, no internal/golden churn), 30 Hz skip-frame manual command,
  and vblank-pending latch across a render overrun.
- **IO-2/5/6/8/9/14/16 — I/O + protection:** MSM6253 one-shift-per-read, Multi
  32 timer0 rate, all-pending-masked interrupt reset (`tb_intc` updated),
  wider dbzvrvs window, word-only brival read trap (new `cpu_be` port),
  unconnected trackball switch nibbles, and i8255 control-word latch/readback.
- **IO-3/13/15 — core I/O:** ADC bit on D7, a 32-bit per-clock xorshift RNG
  fold at 0xD80000, and a defined power-up for `analog_bank`.
- **PF-1/2/3/4/5/7/8 — platform:** correct scanline-strength bits and 4:3/
  custom-aspect encoding, ioctl accept gated on `!busy`, all-ones byte enables
  on DDR reads, multicorner timing analysis with synthesis-tolerant SDC
  guards, open-bus at 0xA00000 when no V25, and deterministic byte-DPRAM
  power-up. IO-10b (dual-PCB comms power-up 0xFF) and PF-8 (V25 mailbox)
  likewise.

## Verification

- Native ModelSim regression: **35/35 tiers** on the post-change tree
  (`verif/modelsim-r20-batch1.log`, `-batch2.log`), including the 50-seed V60
  differential, the mixer/sprite/palette/intc/soundsys tiers, and the two new
  tiers (`t07_v60_flags`, `t30_soundsys_shared`).
- Full-core lint compiles clean (0 errors, 0 warnings) in both the universal
  and `S32_SYSTEM32_ONLY + S32_HOLO_ONLY` profiles.
- MAME ground-truth captures for holo/spidman/ga2 (register/palette dumps,
  write-window traces) are retained under ignored `roms/reference/holo/
  audit-r20/`; the capture tooling is in `verif/mame/`.

## Deliberately deferred (with rationale)

These R20 findings are **not** implemented this round. Each is either low
value for the current targets, high regression risk without the verification
infrastructure to confirm it, or blocked on a paused build step.

- **V60-9/10/13/14/18 (DIVX/MULX memory operand, MOVD 64-bit, CMPC flags,
  MOVCD/fill/stop, CHLVL/UPDPSW/LDTASK memory operand):** intricate exec/
  decode changes for instructions the directed suite does not cover and the
  differential harness cannot flag-check. Making unverifiable CPU changes is
  riskier than deferring; these should land together with **V60-20** (extend
  the differential to dump/compare PSW and widen the op mix), which is the
  prerequisite that makes them provable. **V60-15** (down-direction search) is
  already tracked from R13; **V60-19** (prefetch self-modify invalidation) and
  **V60-21/22** (reset-PC upper byte, BAM signedness) are latent/nano.
- **AU-3/4/5/6 (MultiPCM envelope/TL/LFO, decode aliasing, PCM cross-route,
  scross bank):** Multi 32 only (the current profile is System 32) and blocked
  on **AU-10** — `gew.cpp/.h`, the MultiPCM base class, is absent from the
  pinned MAME subset, so they cannot be closed byte-exactly yet. **AU-8**
  (Z80 wait-state cache) is a performance item on a currently-working sound
  path; deferred to avoid destabilizing it before the AU-1 fix is
  hardware-confirmed. **AU-7** (RF5C68 register read value) is intentionally
  left at the floating-bus `0xFF` (the audit's own "decide and document").
- **TM-1/2/3/5 (416 width authority, backdrop line-color flip, Multi 32 per-
  layer tilebank, vblank-line render suppression):** no current-target game
  exercises them (holo runs 320-wide with a constant backdrop; the tilebank is
  Multi 32), and TM-2 would add a port to the holo-critical mixer for zero
  current benefit.
- **IO-7/10a/11/12/17 (s32comm RAM, dual-PCB id-window restriction, US-set
  coin routing, factory-EEPROM endianness):** link-game / dual-PCB / preload-
  only, none affecting holo/spidman/ga2; IO-11/12 additionally needs a board-
  descriptor flag and MRA change while credits still register today.
- **CG-2/CG-3 (dual-clock palette gate-level replay, pixel-exact MAME frame
  diff):** the highest-value follow-ups for the Holosseum palette, but they
  require Quartus gate-level output (the suspected defect lives in the
  `altsyncram` primitive, which behavioral simulation does not model) and a
  fresh fit — the build step paused this session. They remain the recommended
  next diagnostic step from R20.

## Round 21 addendum — second implementation pass

A follow-up pass implemented more of the R20 findings. All are verified by the
native ModelSim regression (35/35 tiers, now including `t07_v60_movd`) plus
targeted per-module runs. Still no RBF/MiSTer.

Additionally implemented (moved out of the deferred list):

- **V60-10 — MOVD 64-bit move.** Replaced the 32-bit-only exec with a full
  register-pair / memory-qword transfer: op1/op2 now decode as lvalues
  (`f12_op1_is_addr`), register ends use direct pair access, and memory ends
  use the new `S_MOVD_RL/RH/WL/WH` qword phases. New directed tier
  `verif/v60/tb_v60_movd.sv` checks pair→pair, pair→memory, and memory→pair.
- **V60-18 — CHLVL/UPDPSW/LDTASK memory operand.** Added these to
  `f12_reads_dest` so a memory operand is loaded into `op2val` before exec
  instead of the exec falling back to the effective address / stale value.
- **V60-19 — self-modifying-code fetch invalidation.** A completing data write
  that overlaps the live or retained fetch window now clears it, so a
  subsequent execution refetches. Verified by no-regression on all V60 tiers
  including the fetch-performance tier (the guard is a conservative additive
  overlap check that never fires on non-overlapping data writes).
- **V60-21 — reset PC** set to `0xFFFFFFF0` (MAME `m_start_pc`; bus-identical
  after 24-bit masking). The privileged-register soft-reset-preservation half
  is intentionally left as-is to avoid undefined power-up state.
- **AU-7 — RF5C68 register reads** return `0x00` (unmapped, no
  `unmap_value_high`) instead of `0xFF`; the wave-RAM window still reads RAM.
- **AU-8 — Z80 fetch cache** widened from one word to a 2-entry cache so copy
  loops (LDIR opcode/data alternation) stop thrashing. Verified with the real
  production T80 sound-ROM boot (`tb_soundsys_z80`).
- **TM-2 — backdrop line-color flip.** The mixer takes a `flip_y` input and
  indexes the CRAM line table in game coordinates (`223 - y`) under the cabinet
  ORIENTATION_FLIP_Y adapter. The 512-case mixer differential passes with
  `flip_y=0` (identical to before), confirming the constant-backdrop path is
  unchanged.
- **TM-5 — vblank render suppression.** The tile renderer is kicked only for
  visible lines 0-223, freeing the ~15% of SDRAM p1 bandwidth previously spent
  rendering never-displayed vblank lines. The backdrop snapshot keeps the
  ungated boundary.
- **IO-10a — dual-PCB id window** restricted to 0x818000-0x818003 with open-bus
  elsewhere in the window.

Running total: roughly **46 of 72** R20 findings implemented and verified.

### Still deferred / blocked (accurate as of this addendum)

- **Blocked on the paused Quartus build / a missing reference (7):** CG-2, CG-3
  (dual-clock palette gate-level replay and pixel-exact frame diff need a fitted
  netlist), and AU-3/AU-4/AU-5/AU-6/AU-10 (MultiPCM envelope/LFO/TL/cross-route
  need `gew.cpp`, which is absent from the pinned MAME subset).
- **V60-9 — MULX/DIVX memory operand (implemented).** MULX/MULUX with a memory
  op2 store the 64-bit product as a qword; DIVX/DIVUX read the high dividend word
  (`S_DIVXM_RH`), run the restoring divide, and write quotient/remainder back to
  `[op2]`/`[op2]+4`. New tier `verif/v60/tb_v60_divxmem.sv`.
- **V60-13 — CMPC flags/registers (implemented).** On the first difference
  S = (source > dest) — was inverted; R28/R27 hold len1+i / len2+i, not the raw
  addresses; the equal-common-prefix tail sets S/Z from the length compare; and
  zero-length now sets flags/registers. New tier `verif/v60/tb_v60_cmpc.sv`.
  (CMPCF fill / CMPCS stop still behave as plain CMPC — a smaller residual gap.)
- **V60-14 — MOVCD down copy (implemented).** The down copy now transfers the
  ascending range base..base+min-1 in descending element order (MAME
  opMOVSTRD) instead of walking physically below the base and corrupting memory.
  New tier `verif/v60/tb_v60_movcd.sv`.  (MOVCF fill / MOVCS stop and the exact
  R27/R28 completion remain a smaller residual gap.)
- **V60-20 — differential flags (implemented).** The Python reference now
  computes MUL/DIV overflow (matching MAME) and models GETPSW; the generator
  captures the final PSW into R7/M7 so the co-sim compares flags across all
  seeds — the harness previously observed no flags at all.  Verified: 0/20 seeds
  diverge with the PSW comparison enabled.
- **Still deferred:** V60-15 (down-direction search): the shared search FSM plus
  MAME's byte-vs-half start-index quirk make this high-risk for a form ga2 does
  not use (tracked from R13); V60-13/14 fill/stop variants and the MOVCD R27/R28
  completion are smaller residual gaps on top of the core fixes above.
- **Verification infrastructure:** V60-20 (extend the differential to emit
  flag-consuming ops and compare PSW; the current Python reference lacks
  MUL/DIV/SHL overflow and does not model INC/DEC/SHA/SUBC/MOVT/TASI, so this is
  a reference-model rebuild). The directed `tb_v60_flags` covers the key fixes
  independently in the meantime.
- **Low value for the current targets / needs descriptor+MRA plumbing:** IO-7
  (link-game comm RAM), IO-11/IO-12 (US-set coin routing — credits still
  register today), IO-17 (factory-EEPROM endianness), TM-1 (416 width
  authority), TM-3 (Multi 32 per-layer tilebank), AU-11 (audio NCO ppm —
  inaudible, the audit marks it optional).
- **Documented decisions / accept / nano:** V60-22 (BAM offset signedness — the
  RTL matches the NEC manual; the audit explicitly allows leaving it), TM-4
  (pre-first-write zoom init), SP-5 (flip-timing, accepted), SP-6 (bank mirror
  — nothing needed for shipping sets), SP-7 (line-fetch deadline regression),
  PF-6 (surface the overrun telemetry in a debug mode), PF-9 (needs a
  scandoubler module), CG-1 (future-master palette pend-copy SVA assertion).

## Round 22 addendum — video width/tilebank pass and a TM-4 reversal

A third implementation pass closed the two remaining video-side findings that
are provable without a fitted netlist, and reverted one earlier change that
turned out to cost more than it gave.

Implemented and verified:

- **TM-3 — Multi 32 per-layer external tilebank.** `s32_tilemap` now takes
  `is_multi32` + an 8-bit `ext_tilebank`, and the tile code high bits come from
  a per-layer selector `tilebank_of(lay)`: on Multi 32 it takes the 2-bit field
  `ext_tilebank[2*lay +: 2]` (MAME `m_system32_tilebank_external` per-layer
  slice); on System 32 it collapses to the original
  `{ext_tilebank[0], r1ff00[10]}`, so the shipping-profile behaviour is
  bit-identical. Verified: `tb_tilemap_vram` (pixel/address exactness) and
  `tb_tile_backpressure` both PASS with `is_multi32=0`.
- **TM-1 — screen-width authority.** The CRT/tilemap width select `mode_416`
  now follows VRAM `$1FF00` bit 15 (MAME `screen_update_system32` /
  `multi32_update` `set_visible_area`: `52*8` = 416 vs `40*8` = 320), instead of
  the sprite-side control reg 6 bit 0. The sprite engine keeps its own width bit
  (`ctl_latched[6][0]`) for sprite clipping — exactly MAME's split. Both sources
  power up 416 (`$1FF00` = 0x8000, sprite default 1), so the reset default is
  unchanged; games program both consistently, so no current-target behaviour
  changes, but the CRT side is now driven by the register MAME treats as
  authoritative.
- **IO-7 — s32comm share RAM.** 0x800000-0x800fff now behaves as byte-wide RAM
  (D[7:0] mapped; MAME `map(0x800000,0x800fff).rw(share_r,share_w).umask16(0x00ff)`)
  instead of returning open-bus 0xFFFF. The regular-PCB machine config
  instantiates `S32COMM` (`segas32_regular_state::device_add_mconfig`), so the
  share window is real RAM even standalone — a game that writes then reads it
  back must see its own data. The cn/fg link registers at 0x801000/2 and the
  rest of the 0x80xxxx page still read link-not-connected (0xFFFF). Verified two
  ways: `tb_core_map_decode` confirms the 0x800000-0x800fff share window vs the
  0x801000 register boundary, and `tb_core_boot` now writes 0x5A to 0x800000
  through the real V60 bus and reads `comm[0]=5a` back (`CORE BOOT PASS`).
- **V60-15 — down-direction character search (SCHC*D / SKPC*D).** The down form
  previously reused the up start (op1, count len1) and then *decremented*,
  walking below the buffer — the same corruption class as the MOVCD bug fixed in
  V60-14. It now scans descending from MAME's start index (byte: op1+len1 down to
  op1, len1+1 reads with the first one-past-the-buffer, per `opSEARCHDB`; half:
  op1+(len1-1)*2 down to op1, len1 reads, per `opSEARCHDH`), reports the element
  index in R27 and its address in R28, and follows MAME's post-loop Z test
  (i==len1): Z set only when a byte down-search matches its one-past-the-top
  read, cleared when the scan falls off to i=-1. Every change is gated on
  `subop[0]`, so the up-search / MOVC / CMPC / MOVCD paths (which ga2 exercises)
  are byte-identical. New tier `verif/v60/tb_v60_schd.sv` checks byte/half,
  SCHC/SKPC, mid-range hit, exhaustion, and the one-past-the-top Z=1 quirk;
  `V60 SCHD PASS` and the full V60 differential/directed tiers still pass.

Reverted:

- **TM-4 — pre-first-write zoom init (backed out).** R20 set the power-up zoom
  shadow to 0x0000 (to mirror MAME's zeroed videoram, where zoom 0 hits the
  0x80 dstep clamp = 4x). In isolation that is defensible, but it is invisible
  in practice (the display is blanked before the game programs the registers)
  and it broke `tb_tilemap_vram`, which renders NBG0 relying on the neutral
  0x0200 (1.0) power-up default. Given zero visible benefit against a real test
  regression, both init sites (`s32_vram` and `s32_core`) are restored to the
  neutral 0x0200 default. The audit had already rated TM-4 optional.

Running total: roughly **51 of 72** R20 findings implemented; the video
subsystem's provable-without-a-fit findings (TM-1/2/3/5), the s32comm share RAM
(IO-7, sim-verified), US-set coin routing (IO-11/12, additive, hardware
verification pending), and the V60 down-direction search (V60-15, sim-verified)
are now closed.

### Honest status of everything still open

IO-7 was the last finding both implementable and *verifiable in simulation*
this session; IO-11/12 is implemented but only hardware-verifiable. Everything
remaining has a concrete blocker — a paused build, a reference file we do not
have, or hardware we cannot run — not a lack of effort:

- **Blocked on the paused Quartus build (4):** CG-2, CG-3 — the Holosseum
  palette defect is proven to live below RTL in the dual-clock `altsyncram`
  primitive, which behavioural simulation does not model; both need a fitted /
  gate-level netlist. **PF-6** (surface the line-fetch overrun telemetry) needs
  a MiSTer OSD/status surface that only exists post-fit, and **AU-11** (audio
  NCO 14-58 ppm) is a PLL-synthesis limit — the MiSTer clock tree cannot hit the
  exact arcade crystal, the error is ~100x below the audible pitch JND, and it
  only changes with PLL coefficients applied at build time. CG-2/CG-3 remain the
  single highest-value next step for the original palette complaint.
- **Blocked on a missing MAME reference (5):** AU-3/4/5/6/10 — the MultiPCM
  envelope/LFO/TL/cross-route work derives from `gew_pcm_device` in `gew.cpp`
  (the MultiPCM base class), which is absent from the pinned MAME subset
  (`multipcm.cpp` is only the 185-line derived shell). Guessing the envelope/LFO
  math would be an unverifiable change; also Multi 32-only.
- **IO-11/IO-12 — US-set coin routing (implemented additively, unverified on
  hardware).** MAME wires the 4-player i8255 port C to EXTRA3
  (`ppi.in_pc_callback().set_ioport("EXTRA3")`); the US sets (ga2u, spidmanu,
  arabfgtu) `PORT_MODIFY` EXTRA3 so bit 3 (0x08) = COIN1 and bit 2 (0x04) =
  COIN2, while base sets leave those bits `IPT_UNUSED`. Per an explicit user
  decision, the top-level `ga2_ppi_pc` now additively drives EXTRA3 bits 3/2
  from the same P1/P2 coin buttons that feed SERVICE12, leaving Start3/Start4
  (bits 0/1) intact. Safe for every non-US set (they ignore those bits);
  Verible parses the top-level clean. It stays **unverified** until a US ROM
  runs on a build (the top-level wrapper is not in the ModelSim core
  regression), and carries a documented double-count caveat on US sets (the
  press also pulses SERVICE12 COIN3/4) that only a board-descriptor US flag
  would remove. The service-credit / PCB Push SW1/SW2 mapping remains a smaller
  separate gap.
- **Needs non-target ROMs + a MAME comparison to verify (1):** IO-17 — the
  index-2 factory EEPROM images are *likely* byte-swapped vs MAME's big-endian
  region, affecting jpark/radm/radr/scross/titlef/harddunk preloads (never
  holo/spidman/ga2). The direction is unconfirmed and cannot be verified without
  those factory images and MAME's expected NVRAM, so changing the loader blind
  would risk corrupting a currently-working preload path.
- **Deferred by explicit user decision (feasible, not blocked):** the V60 string
  fill/stop variants (CMPCF 0x01, CMPCS 0x02, MOVCFU 0x0a, MOVCFD 0x0b,
  MOVCSU 0x0c) and the exact MOVCD R27/R28 completion. These are directed-testable
  with the same methodology as V60-13/14/15, but implementing them means adding
  memory-writing fill phases, CY-flag handling and R26 into the shared string FSM
  that ga2 relies on (up-search/MOVC/CMPC) — real regression risk on a working
  critical path for instructions no shipping target uses. Asked, and the decision
  was to stop CPU-FSM work at V60-15 and leave these documented rather than churn
  the FSM. MAME reference: `opCMPSTRB/opMOVSTRUB(bFill,bStop)` in `op7a.hxx`.
- **Documented-accept / done (rest):** V60-22 (BAM signedness — matches the NEC
  manual, audit allows leaving), SP-5 (flip timing, accepted), SP-6 (bank mirror,
  nothing needed for shipping sets), SP-7 (line-fetch deadline telemetry present),
  PF-9 (needs a scandoubler module), CG-1 (already implemented as the SVA
  assertion).

## Round 23 addendum — full-core audit pass (sim-only)

A whole-core review (V60 / audio / video / core-integration / V25 reviewers)
run under an explicit "fix/improve where possible, no RBF build" directive.
Findings were few and low-severity because the shipping System-32 path was
already MAME-accurate; all fixes below are verified in ModelSim only.

Implemented:
- **V60 SHA left-shift overflow (Finding 1 + count==width sub-fix).** `sha_left_ov`
  now masks exactly `count` top bits per MAME `SHIFTLEFT_OV` (op12.hxx) instead of
  `count+1`, and the guard is `c > w` (not `>= w`) so `count == width` folds into
  the exact mask (matching MAME's `count==bitsize` case, e.g. `SHA.B #8,-1 ⇒ OV=0`);
  only the genuinely-UB `count > width` stays in the simplified branch. The 50-seed
  differential never modelled SHA's OV, so a new directed tier **`t07_v60_shaov`**
  (18 MAME-exact vectors incl. the cited `SHA.B #1,0x40 ⇒ OV=0`) locks it down.
- **V60 MULX/DIVX overflow.** Removed the spurious OV-clear on MULX/S_DIVX
  completion — MAME sets only S/Z and leaves OV unchanged.
- **Audio AU-N1 — Multi-32 MultiPCM cross-route.** On Multi 32 the MultiPCM now
  cross-routes exactly like the YM (both `add_route(1,"sleft")/add_route(0,"sright")`
  in segas32.cpp): system L takes each device's R channel and vice-versa. Fixed the
  mixer *and* the stale `tb_audio_mix` expectation that had crossed only the YM.
  (Multi-32-only; dead in the SYSTEM32_ONLY shipping build.)
- **Multi-32 io1 wiring (F1a/F1b).** io1 EEPROM/NVRAM `in_pf` and screen-B
  `display_en` now use io1's own signals (were reading constant 0xff / screen A).
  Multi-32-only; zero effect on the shipping build.
- **Dead-code / resource hygiene.** Removed the write-only 64 KiB `prg[]` array in
  the s32_v25 mailbox HLE (never read); the never-instantiated
  `s32_v25_program_rom` module; the dead `sx` reg and the vestigial `mode_416`
  input port in `s32_sprite` (the sprite latches ctl6 internally — B5's design
  evolved past the port; core + two sprite testbenches updated).
- **PF-1 completion (audit "F2").** Dropped the inert **"HQ2x"** option from the
  Scandoubler Fx menu (there is no hq2x scaler instance) and simplified the
  `scanline_level` map to `None=0, CRT 25/50/75 = 1/2/3`. (Top-level parses clean;
  its behavioural check is the Quartus build, deferred with the rest of the RBF.)
- **New coverage:** `t07_v60_incdecmem` — halfword INC/DEC **memory** RMW (15
  checks incl. the discriminating `dec.h 0x0701→0x0700 ⇒ Z=0`), added while ruling
  out a spidman camera-timer hypothesis; proves the halfword memory-RMW Z flag is
  width-correct (relevant to `dec.h 34[R25]`, spidman's page-advance timer).

Left as documented notes (not implemented): none outstanding from this pass — the
above closes the Round 23 findings. Pre-existing deferrals (V60 fill/stop string
variants, IO-17, PF-9) are unchanged.

## Round 24 addendum — full video subsystem audit (sim-only)

A one-module-per-reviewer audit of the entire video pipeline
(`s32_tilemap` / `s32_vram` / `s32_sprite` / `s32_mixer` / `s32_palette` /
`s32_linebuf` / `s32_big_dpram` / `s32_video`) against the pinned MAME
`segas32_v.cpp` / `segas32.cpp`, plus the CDC design of the whole video read
path. Every reported finding was re-verified against both the RTL and the MAME
source before any change. The shipping System-32 path was already MAME-accurate;
the one real bug below was a cross-clock pulse-width hazard that only appears on
hardware (all prior benches drove `vblank` as a single simulation pulse).

### Implemented and verified

- **SP-8 — sprite `vblank` double-fire (BUG-HIGH; the most plausible cause of the
  known mid-frame sprite tear).** The sprite engine runs on `clk_ram`
  (96.648 MHz) but its `vblank` input is `vbl_end`, a **one-`clk_sys` pulse**
  (`s32_video` `vb_end_r`), so it is sampled high on **two consecutive `clk_ram`
  edges**. The R20 SP-3 "vblank seen mid-render" latch
  (`if (vblank && rs != R_IDLE) vblank_pending <= 1`) re-caught the *same* pulse
  on its second sample — by then the FSM had advanced R_IDLE→R_DELAY — and on
  return to R_IDLE ran a **second full erase/swap/render pass mid-frame**. In
  MAME automatic mode (`!BIT(m_sprite_control[3],1)`, segas32_v.cpp:318-340) the
  command is forced to `2'b11`, so the spurious pass performs a second
  `disp_buf` swap partway down scanout (tear line whose height tracks render
  duration) and doubles sprite ROM/DDR bandwidth; in 30 Hz auto mode it rendered
  every frame instead of every other. **Fix (`s32_sprite`):** edge-detect the
  pulse — `vblank_rise = vblank & ~vblank_d` — and qualify both the pending
  latch and the R_IDLE launch on the rising edge, preserving the SP-3 overrun
  protection. **New directed tier `verif/common/tb_sprite_vblank.sv`** drives the
  realistic **2-`clk_ram`-wide** pulse and asserts exactly one render pass and one
  buffer swap per frame; it **PASSes on the fixed RTL and FAILs on the pre-fix
  RTL** ("2 buffer swaps, want 1"), and also checks the 1-cycle pulse still
  yields one pass (no single-sample regression). Wired into
  `run_regression.ps1`/`.sh` under tier 27. This is the fix to try on hardware
  **before** the planned triple-buffer rework — pass 1's swap sits at ~line 1
  (invisible), so it may close the tear outright.

- **Mixer dead pipeline logic removed (OPT/clarity).** `idx_first`,
  `idx_second`, `best2sel_hold`, and `spr_group_s` in `s32_mixer` were assigned
  every pixel but never read (the live paths are `idx_winner`→`pal_addr_r` and
  `idx_runner`→`idx2_hold`); the names actively misled (`idx_first` reads as "the
  first palette lookup"). Deleted. Zero hardware change (Quartus already pruned
  them); the 512-case mixer differential and directed tier still pass. Diagnostic
  `$display`s in `tb_mixer`, `tb_mixer_diff`, and `tb_core_soak` were repointed to
  the live `idx_winner`/`best2sel`.

- **CG-1 write-both warning refined (sim-only).** The `ifdef SIMULATION`
  "pend copy dropped" warning fired on *every* alias/blend palette write because
  the core bus holds `cpu_we` (the `m_req` level) high for several `clk_sys`
  edges, so `pend_we && cpu_we && write_both` was true on the held edges after
  `pend_we` set — masking any genuine drop. Now edge-qualified
  (`cpu_we && !cpu_we_d`): it fires only when a *new* write-both transaction
  lands while a prior pend copy is outstanding, which is the real second-master
  hazard it was meant to catch. No hardware/synthesis effect.

- **Comment rot.** Corrected the `s32_sprite` `vblank` port comment
  ("start-of-vblank" → end-of-vblank, which is the correct MAME anchor) and a
  stale `s32_mixer` pipeline comment describing a "2:1 palette-clock phase" that
  no longer exists (both palette sides are `clk_ram` since the 82d3635 CDC fix).

**Verification:** full native ModelSim regression **35/35 green** (all video
tiers 9-12/21-24/27/34, the new `tb_sprite_vblank`, the 512-case mixer
differential, and the WSL V25 firmware tier 35 after staging the git-ignored
`roms/sim/ga2/mcu.bin`). Verible lint clean on all eight video modules.

### Verified MAME-exact (no change needed)

The entire shipping-profile pipeline was confirmed bit-exact against MAME and is
recorded here so future rounds do not re-audit it:

- **Mixer** — sprite-group `$4C` table (all 16), priority/rank encoding and the
  balanced-max-tree ≡ MAME's bubble-sorted scan (unique keys), blend gating +
  `(first*(7-f)+second*(f+1))>>3` with per-operand pre-multiply offsets,
  `compute_sprite_blend` (4 modes), `compute_color_offsets` (mode map incl. the
  grayscale placeholder), 6-bit signed offsets, shadow-pen `& 0x7ffe` compare and
  RMW shadow, backdrop `(reg&0x1e00)+((reg+y)&0x1ff)`, and `<<3` RGB clamp/pack.
  The Python oracle (`s32_mixer_ref.py`) was checked against MAME independently —
  no shared misreading.
- **Tilemap** — tile attribute/flip/page/bank decode, NBG0/1 zoom (12.20 step,
  0x80 clamp, sext9/10 center rule, flip algebra), NBG2/3 rowscroll/rowselect
  table addressing and wraps, text nibble order, bitmap 4/8bpp, clip windows
  (inclusive edges, clip-out XOR, flip transform), and layer enables incl.
  `$1FF00[13:12]` for NBG2/3.
- **Palette** — `to_alt`/`from_alt` exhaustively equal over all 65536 values and
  exact inverses; alias-window byte-write RMW bit-identical to MAME
  read→convert→COMBINE_DATA→convert-back over 20000 random cases; write-both
  mirror condition/target/merge; and the post-82d3635 read path is fully
  `clk_ram`-coherent (single remaining `clk_sys` element is the RAM cell array
  itself, DONT_CARE collision, which MAME also races).
- **Sprite** — list walk (jump/clip/end, 0x20000 wrap, 8192 watchdog), full
  `draw_one_sprite` decode, truncating-divider zoom ≡ MAME's xacc/yacc loop,
  pen/end-code/transparency semantics, indirect tables, ROM/RAM fetch swizzle,
  control-reg latch timing, and the 16-bit framebuffer pixel tag.
- **Video timing** — 416/320×224 in 512/410×262, dot CE = MASTER/4 and /5,
  `vblank_start`/`vblank_end` IRQ anchors, display-enable black-fill.

### Documented, not implemented (edge cases no target game exercises)

Each is real but out of reach of ga2/spidman/arabfgt/holo, and the fix would add
logic/visible change to a hardware-validated path; recorded with the exact fix so
a future round can decide:

- **TM-6 — layer-enable / line-buffer content skew (BUG-LOW).** The mixer gates
  displayed line N with `tm_layer_off` derived from the tilemap's *render*
  snapshot (line N+1), but line N's pre-rendered pixels used the enables from the
  render of line N-1. A mid-frame enable toggle (`$1FF02`/`$1FF8E`/`$1FF00[13:12]`)
  therefore mis-gates exactly one scanline. No target game toggles enables
  mid-frame. Correct fix: parity-bank `layer_off` alongside the pixel data
  (write `layer_off_bank[render_line[0]]` at render, read by `vcnt[0]`), matching
  how the line buffer itself is parity-banked. Not applied — it touches the
  working display path for zero target-game benefit and an untestable win.
- **TM-7 — `$1FF00` pre-first-write readback (ACCURACY).** A CPU read of
  `$31FF00` before any write returns 0x0000 (BRAM power-up) vs MAME 0x8000; the
  *render* path is unaffected (`mode_416` uses the shadow, which inits 0x8000).
  Target games write `$1FF00` outright during init, so it is never observed. A
  sim-only BRAM init would make sim disagree with hardware (altsyncram is
  `power_up_uninitialized="FALSE"` → zeros); the honest fix is to mux
  register-region CPU readback from the shadow, which risks the rowscroll-table
  read path — deferred.
- **CG-4 — 5→8-bit color expansion (ACCURACY-LOW).** The mixer emits
  `{clamp5(v),3'b000}` (max 0xF8) where MAME `pal5bit` replicates `(v<<3)|(v>>2)`
  (max 0xFF) — a uniform ~3% full-scale compression, below the pitch/brightness
  JND and shared by the RTL and the Python oracle (so the differential does not
  flag it). One-line fix (`{v, v[4:2]}` per channel) but it shifts global
  brightness on a hardware-validated build and would require updating the oracle;
  deferred pending a decision. Relevant if pixel-exact CG-3 frame diffing is ever
  enabled.
- **Throughput OPTs (not bugs).** Bitmap loop refetches each VRAM word per pixel
  (3 cyc/px → ~1 with a held word); NBG zoom reciprocal divider reruns per line
  for static register values (cacheable); sprite pixel loop is 2 clk/px
  (overlappable to 1); sprite list-entry fetch is 10 cyc/entry (64-bit engine
  port ~2.5×); erase is 128 single-beat DDR writes/line (burstable). Each frees
  line/frame budget under SDRAM contention (reduces `tm_line_overrun` /
  `fb_rd_underrun` exposure) but is a self-contained state-machine change needing
  its own verification; left as recommended future work.

## Round 24 addendum — full `s32_core.sv` audit pass (sim-only)

A focused whole-file audit of `rtl/s32_core.sv` on top of the deployed
2026-07-22 baseline (real-V25 + sdram request-drop fix). Four parallel reviewers
(read-mux timing contract, MAME memory-map decode cross-check, clock-domain
crossings, build-config/protection consistency) plus a direct MAME `segas32.cpp`
map diff. Verified in Verilator lint (holo / universal / shipping `S32_REAL_V25`
profiles) and the native ModelSim regression (34/35 tiers pass; tier 35 V25
firmware passes once the gitignored `roms/sim/ga2/mcu.bin` is present — confirmed
by a direct run).

Implemented:
- **SP-8 — sprite `vblank` double-render (the significant find).** `vblank`
  (`vbl_end`) is a 1-`clk_sys` pulse consumed in the sprite's `clk_ram` domain,
  so it is high across TWO consecutive `clk_ram` edges (phase-aligned 2:1). The
  FSM consumed it as a bare level: edge 1 launched the pass from `R_IDLE`; edge 2
  (now `R_DELAY`) latched a spurious `vblank_pending`, arming a **complete second
  erase+swap+render pass every frame** — ~2x sprite SDRAM p2 traffic, a double
  `render_count` decrement in 30 Hz mode, and a **mid-frame `disp_buf` swap**.
  That mid-frame swap is a plausible contributor to the open "tearing line ~1/3
  down" symptom (spidman/ga2). Fixed with a rising-edge qualifier
  (`vblank_edge = vblank & ~vblank_d`) in `s32_sprite.sv`, matching every other
  `clk_sys`→`clk_ram` pulse consumer in the core (scheduler kick, fb-read kick).
  A 1-cycle TB pulse still yields exactly one edge, so the sprite tiers are
  unaffected (SPRITE + SPRITE FB tiers pass).
- **Config hardening — `is_multi32` under `GAME_ONLY`.** `is_multi32` was forced
  0 only by `SYSTEM32_ONLY`; a hypothetical `S32_GA2_ONLY`-alone build
  (GAME_ONLY=1, SYSTEM32_ONLY=0) would have followed a Multi 32 descriptor while
  its analog/trackball hardware was compiled out. Now `(SYSTEM32_ONLY ||
  GAME_ONLY)` forces the System 32 configuration — a dedicated single-screen
  build is System 32 by definition. No effect on the shipping profile (both set).
- **PF-6b — sprite line-fetch (`fb_rd_kick`) vblank-line suppression.** The DDR
  line-read prefetch was kicked on every scanline including the 37 vblank lines,
  fetching nonexistent buffer rows 224-255 and wasting ~14% of the p-read line
  bandwidth (same class as the TM-5 tilemap vblank suppression). Gated to
  `vcnt < 223 || vcnt == 261`, which still covers all 224 displayed lines.
- **Diagnostics correctness (no gameplay effect).** (a) ROM-icache lookup now
  qualifies on `!ack_r` so it does not re-arm/re-pulse `rom_ready` against an
  already-served address while the V60 holds `m_req` post-ack; (b)
  `debug_status[7]` ("PC left reset vector") compared the 32-bit PC against
  `0x00FFFFF0` and so was stuck-on from cycle 0 — now compares the bus-visible 24
  bits vs `0xFFFFF0`; (c) `debug_status[22]` (runaway-PC) now excludes the
  architectural reset window `0xFFFFFFF0-FF` instead of firing at every reset.

Verified-correct, no change needed (independent MAME cross-check):
- The full V60 address decode is a faithful match to `system32_map` **and**
  `multi32_map`: ROM, workram (0x0f0000 mirror), videoram/spriteram (0x0e0000),
  sprite-control (umask 0x00ff, 0x0ffff0 mirror), the A16 palette/mixer split
  with exact mirror masks (0x0e0000 / 0x0eff80; Multi 32 0x060000 / 0x06ff80 +
  bank1 at 0x680000/0x690000), shared RAM (8 KiB, 0x0fe000), s32comm, the io-chip
  A[6:5]==00 decode with 0x0fff80 mirror (Multi 32 dual chips split on A19), int
  control (!A19), random (A19), and the 0xF00000 first-megabyte ROM mirror.
- Unmapped-read fill value: MAME `map.unmap_value_high()` ⇒ 0xFFFF, exactly the
  RTL `rmux` default.
- INTC read returns 0xFF for all offsets (MAME `int_control_r` — timer readback
  unimplemented in MAME too), matching the RTL.
- Read-mux one-cycle timing contract holds for every source; all level-`cs`
  write paths are idempotent or self-latched (no per-clock side-effect double-fire).

Noted, not changed (out of shipping-profile scope): the universal-build
`s32_prot_brival` / `s32_prot_hle` ROM-copy path is a non-functional stub
(`rom_ack` tied 0, `pram_*` unconnected, no protection-RAM instantiated) — dead
under GAME_ONLY (brival/sonic/jleague are not shipping targets); revisit if a
universal build is ever targeted.

## Round 24 addendum — cpu/v60_v70 completeness audit (2026-07-22, sim-only)

A full re-audit of `rtl/cpu/v60/s32_v60.sv` + `s32_v60_bus.sv` against the pinned
MAME snapshot, driven by "complete, total implementation — improve/fix/optimize".
The shipping integer/system ISA re-verified clean against the newly vendored EA
bodies (`am1/am2/am3.hxx`, SHA-256 recorded in `docs/v60-mame-audit.md`); all
findings below either close a documented deferral or a genuine latent bug. No RBF
build (sim-only, per standing directive); verified in **both** Icarus and
ModelSim plus a 50-seed differential and a clean Verilator lint.

Implemented:
- **Single-precision FP group (0x5C/0x5F) — the last ISA-class exclusion.** New
  binary32 unit: CMPF, MOVFS, NEGFS, ABSFS, SCLFS, ADDFS, SUBFS, MULFS, DIVFS,
  CVTWS, CVTSW. Round-to-nearest-even, gradual underflow (subnormals), IEEE
  inf/NaN, matching MAME's host-`float`. FADD/FMUL/CVT combinational; FDIV a
  27-step restoring mantissa divide (`S_FP_DIV`). Operands decode through the
  existing EA engine (`S_FP_OP2`/`S_FP_LD`): op1 = ReadAM value, op2 = ReadAM
  (CMPF) / WriteAM (MOVFS/CVTWS/CVTSW) / ReadAMAddress-RMW (rest). Replaces the
  former reserved-op trap, so it cannot regress the shipping path. New tier
  **`t07_v60_fp`** checks 1,800+ vectors bit-exact vs `numpy.float32` (incl.
  subnormal/inf/NaN/tie cases); **`t07_v60_fpdecode`** runs real ADDFS/MULFS
  (register + memory forms) end to end. Bug found + fixed during bring-up: the
  subnormal-operand normalization shift in `fp_unpack` over-shifted by 3 and
  overflowed the 24-bit mantissa (all subnormal inputs mis-scaled) — corrected
  the leading-zero frame.
- **String fill/stop variants + exact MOVC/CMPC tail (closes the R23 deferral).**
  CMPCF (0x01), CMPCS (0x02), MOVCFU (0x0a), MOVCFD (0x0b), MOVCSU (0x0c) now
  implement the R26 fill phase (`S_STR_FILL`) and the R26 stop/CY break per
  `op7a.hxx opCMPSTRB/H` and `opMOVSTRU*/D*`. The MOVC completion registers
  (R27/R28) were **off by one element step** for both up and down forms, and the
  CMPC tail dropped the `*2` element scaling for the halfword (0x5A) family — a
  genuine latent bug on the shipping MOVCU/CMPC path (byte was correct, halfword
  and the exact tail were not). Both fixed via a shared `movc_finish` helper that
  computes MAME-exact `R28 = op1 + i*step`, `R27 = op2 + i*step` (up) and the
  `op1 + (len1-i-1)*step` down form, including the peculiar MOVCFD down-fill
  addressing. New tier **`t07_v60_strfs`** proves 21 cases (all variants, both
  widths, all length orderings) against a Python mirror of `op7a.hxx`.
- **Dead-code / hygiene.** Removed the unused `wire [1:0] dim`, the never-called
  `rotc_res` stub (ROTC is done iteratively in `S_ROTC`), and a redundant
  partial nonblocking assignment to `mdacc[63:32]` in the multiply step that the
  following full assignment always overwrote.

Left as documented notes (not implemented):
- **V70 32-bit external bus.** `s32_v60_bus` still issues 16-bit cycles even
  under `IS_V70=1`; System 32 is V60-only and `is_multi32` is forced 0 in the
  shipping profile, so the parameter is unused today. A System Multi 32 (V70)
  build would need the 1..2 aligned 32-bit-cycle path added and re-timed.
- **Genuinely-UNHANDLED FP sub-opcodes** stay on the reserved-instruction vector,
  exactly as MAME `fatalerror`s them.

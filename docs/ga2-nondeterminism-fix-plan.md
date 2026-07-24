# ga2 rendering-divergence / non-determinism fix plan

**Bugs in scope (all ga2):** (1) "PLAYER SELECT" renders as a white box, text
missing; (2) stage background doesn't appear for ~1 s when a map starts; (3) some
enemies disappear / deal & take no damage.

**Status:** investigation plan. Root is *narrowed but not nailed*, so this is
diagnostic-heavy; the fix itself is expected to be small once the divergence seed
is found. No RTL changes until a specific seed is identified and confirmed.

**Companion docs:** these are a *separate workstream* from `docs/v60-pipelining-plan.md`
(that fixes the waterfall *slowdown*, a throughput problem; this fixes the
*divergence* bugs). See also `docs/v60-authenticity-from-manual.md`.

---

## 0. What is already ruled OUT (don't re-chase these)

Prior investigation (Verilator full-core + MAME 0.285 diff, 2026-07-23) eliminated
the obvious suspects:

- **Not throughput/slowdown.** The char-select screen runs at **42 % work / 58 %
  idle** — nowhere near overrunning the frame budget. Pipelining/turbo will *not*
  fix these three.
- **Not the video render path.** Our sprite engine, palette, and tilemap render
  **pixel-identical to MAME** at the select screen. The "PLAYER SELECT" palette
  (0x450–0x45f = white) is byte-identical to MAME. The letters are *sprites* that
  fly in, land, then the tilemap text + palette load — our core **freezes the fly-in
  mid-animation**, leaving the white letter-sprites on screen. The renderer is
  drawing correctly; it's being *fed* a frozen/diverged display list.
- **Not the V25 mailbox/protection (for ga2).** MAME trace (verif/mame/ga2_v25_trace.lua):
  the V60 writes the mailbox **zero** times; the V25 writes **only at frame 0**
  (boot: wake string + sprite-expansion table `0a 00 c5 00 11 00 11 00 18 00 18 00
  1f 00 c6 00` + semaphores), then goes **idle** through the select screen. ga2's
  V25 is **boot-only**, and the HLE responder hardcodes the identical correct boot
  data — yet the sim STILL shows the bugs. So the bugs are **downstream of the V25**,
  in the V60 core / video / frame-timing.

**The surviving signature: build-sensitive non-determinism.** Identical
`+FRAMES` params, one Verilator binary reached vblank 195, a *rebuilt* binary did
not. Verilator is deterministic per-binary, so run-to-run differences **across
rebuilds** = dependence on **uninitialised state / X-propagation** — RTL registers
or RAM that should reset deterministically but don't, whose power-on value the game
logic (or the video/sprite address path) reads before writing.

---

## 1. Root-cause hypotheses (ranked)

- **H1 (leading): uninitialised RTL state (missing/incomplete reset).** Somewhere
  in the V60 core, work RAM, video, or the sprite/display-list path, a reg/RAM is
  read before it is written and lacks a deterministic reset. Its garbage value
  seeds a game-logic or display-list divergence → frozen select fly-in (→ white
  text), diverging sprite-list double-buffer (→ enemies vanish, cf.
  arabfgt floor-flicker), delayed init (→ background pop-in). *Evidence: the
  build-sensitivity is the textbook fingerprint of this.*
- **H2 (caveat to rule out): real-V25 boot table wrong.** The sim uses the HLE V25
  (correct boot table by construction); the **hardware** uses the real
  `s32_v25_cpu`. If the real V25 computes the boot **sprite-expansion table** wrong
  (≠ `0a00c500…1f00c600`), sprites corrupt on hardware while the correct-table HLE
  sim looks fine — a plausible hardware-only contributor to **#3 disappearing
  enemies**. Cheap to check directly; do it in parallel.
- **H3 (lower): a genuine V60 execution bug** that only manifests from certain
  state. Would surface as a differential-cosim mismatch (see §5) — if cosim stays
  50/50 through the divergence, H3 is unlikely and H1 dominates.

---

## 2. Diagnostic plan — find the exact divergence seed

The whole game is finding *which* piece of state diverges first, and *why*.

### Phase A — Deterministic repro + first-divergence frame
1. Lock a repeatable sim repro to the select screen:
   `+IMG=roms/sim/ga2 +B0=22 +COINAT=41 +COINLEN=4 +STARTAT=51 +STARTLEN=4`
   (harness/params from the ga2-select investigation).
2. Capture a MAME reference of the same run: per-frame **work-RAM** (0x200000–)
   and the **sprite display list** (0x400000) via `verif/mame/ga2_select.lua`.
3. Add/extend a per-frame work-RAM + sprite-list dump in `tb_core_romboot`
   (`+DUMPSPRAT`, work-RAM snapshot already exist) and **diff ours vs MAME frame by
   frame** to find the **FIRST frame and FIRST address** where our state departs.
   That address is the thread to pull — trace backward to the reg/logic that wrote
   (or failed to write) it.

### Phase B — X-propagation audit (H1, the main effort)
1. **Rand/X-reset sweep.** Re-run the sim with Verilator's randomised reset
   (`--x-initial unique` / `+verilator+rand+reset+2`) instead of the current
   zero-init, across several seeds. If the bug's onset frame *moves* with the seed
   → **confirms uninitialised-state dependence** and tells us the divergence rides
   on un-reset regs. (Also try all-ones and all-X inits.)
2. **Targeted X-tracing.** With X-init, watch for X reaching game-visible state
   (work-RAM writes, sprite-list addresses, the select fly-in counters). Verilator
   reports the first X-origin signal; that reg is a prime suspect.
3. **Systematic reset audit** of the hot paths, in priority order:
   - `rtl/cpu/v60/s32_v60.sv` — any reg read before write without a reset arm
     (esp. anything feeding PC/branch/loop counters, the fetch window, flags).
   - `rtl/video/*` and the sprite engine — display-list read pointers, double-buffer
     select, line-buffer/erase state, any counter the game's list-build reads back.
   - work-RAM / VRAM init — does the game clear it before first read, or does it
     rely on a power-on value we don't reproduce?
   For each un-reset reg, decide the *correct* deterministic value: what the real
   chip powers up to, or what the game's boot code establishes. Prefer matching
   MAME's initial state where known.

### Phase C — Real-V25 boot-table check (H2, parallel + cheap)
Extend `verif/common/tb_core_v25int.sv` (real V25, built via
`verif/v25/run_v25_integration.sh`, `+define+S32_REAL_V25 +define+S32_GA2_ONLY`)
to boot the real `s32_v25_cpu`, dump the DPRAM sprite-expansion table, and compare
to the known-good `0a 00 c5 00 11 00 11 00 18 00 18 00 1f 00 c6 00`.
- Match → real V25 exonerated for the boot table; enemies bug is H1.
- Mismatch → a real-V25 bug corrupting the sprite table; fix that (separate, in the
  V25 core) — likely explains #3 on hardware.
(Caveat: full-game real-V25 sim is infeasibly slow; this is boot-only, which *is*
feasible.)

### Phase D — Per-bug confirmation
Once a seed is fixed, confirm each symptom clears and trace the causal chain:
- #1: select fly-in animation *completes* → letters land → tilemap text + palette
  load → no white box.
- #2: map-start init sequence isn't delayed → background present from frame 1.
- #3: sprite-list double-buffer stays synced frame-to-frame → enemies persist;
  collision state consistent.

---

## 3. Fix approach

- For each un-reset reg/RAM proven to seed the divergence: add a **deterministic
  reset** to the hardware-correct / game-expected value. Keep the change minimal
  and local.
- **Do NOT** blanket-reset everything to zero — some state legitimately powers up
  non-zero, and a wrong reset value is itself a bug. Match MAME/real-hardware init.
- If H2 fires, fix the real-V25 boot computation in `rtl/cpu/v25/` separately.

---

## 4. The sim-vs-hardware wrinkle (read before trusting a sim result)

- **Sim runs the HLE V25; hardware runs the real V25.** For **H1** (uninitialised
  state in V60/video), this doesn't matter — ga2's V25 is boot-only and the HLE
  boot data is correct, so the sim reproduces the *same* divergence the hardware
  shows. The sim is therefore a **valid, fast harness for H1.**
- For **H2**, you *must* use the real-V25 integration tb (the HLE hides the bug).
- **Final proof is always hardware.** Reproduce all three bugs on the deployed
  MiSTer build (coin up → select → start a map), apply the fix, and re-test on
  hardware — the sim only gets us to the seed.

---

## 5. Verification gate (every change)

- **Differential co-sim vs the Python reference** (`verif/cosim/run_diff.sh`,
  50 seeds) — must stay 50/50. If a reset change alters architectural results, it
  shows here. This also adjudicates H3: a mismatch during the divergence window =
  a real V60 logic bug, not just uninitialised state.
- **V60 unit suite 27/27** + **full-core romboot render** (select screen must now
  show real "PLAYER SELECT" text, not the white box) + **exc=0**.
- **MAME frame-diff**: our work-RAM/sprite-list should now track MAME past the
  previous first-divergence frame.
- **Hardware:** the three bugs cleared on the MiSTer.

---

## 6. Existing tooling to reuse

- `verif/mame/ga2_select.lua` (MAME per-frame spr/vram/pal + snapshots),
  `ga2_v25_trace.lua` (mailbox tap).
- `tb_core_romboot` plusargs: `+PCHIST`, `+DUMPSPRAT`, work-RAM snapshots,
  `+DUMPAT` frame dumps.
- `scratch/flickdiff.py` (period-2 / per-row PPM diff), the sprite-list branch
  walker, `ppm2png.py`.
- `verif/v25/run_v25_integration.sh` + `tb_core_v25int` for the real-V25 check.

---

## 7. Risk, scope, and order

- This is an **investigation** (diagnostic-heavy); the eventual RTL fix is likely
  a handful of reset arms, low-risk, gated by the co-sim.
- **Order:** Phase A (find first-divergence frame) → Phase B (X-audit; the main
  effort, highest-probability root H1) → Phase C in parallel (cheap V25 boot check,
  rules out the hardware sprite-corruption path for #3) → fix → Phase D + §5 gate.
- **Watch:** a concurrent Claude session has historically shared this repo and
  touched `tb_core_romboot` / the V25 path — check current file state before
  editing, and re-confirm which V25 work already landed.

---

## 8. Expected outcome

The three bugs share one root (a diverging select/gameplay display list driven by
uninitialised state); finding and resetting the single seed should clear all three
at once — the white text (fly-in completes), the background pop-in (init not
delayed), and the disappearing enemies (list buffers stay synced), with a possible
separate real-V25 boot-table fix for the enemies if H2 fires. None of this depends
on pipelining or throughput; it's an orthogonal correctness fix.

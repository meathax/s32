# Core-issue differential debugging method

This is the reusable procedure for investigating behavioural defects reported in the Sega System 32 core. It distils the useful parts of [`../audit.md`](../audit.md) into an operational method that fits this repository's existing `verif/` tooling.

The goal is not to guess from a screenshot. The goal is to produce a small, reproducible statement such as:

> In the same scripted encounter, MAME and RTL match through V60 retirement N. At N+1, the instruction at PC X writes value A in MAME and value B in RTL to entity field Y. The mismatch is caused by RTL module Z, is covered by regression R, and is corrected by patch P.

## 1. Governing principles

1. **Reproduce before editing.** Run the same ROM, configuration, initialization, and frame-indexed inputs in MAME and the Verilated core.
2. **Use MAME as an architectural reference, not a V60 timing oracle.** Compare retired instructions, registers, flags, exceptions, and observable memory/I/O effects. Do not change V60 cycle timing merely to match MAME's interpreter.
3. **Find the first divergence.** Later differences are downstream noise. Report and solve one first mismatch at a time.
4. **Move down a comparison ladder.** Start with the cheapest observation that brackets the problem, then add only the detail needed to localize it.
5. **State one testable hypothesis before editing RTL.** The fix must explain the first divergence, not just hide the visible symptom.
6. **Keep the fix minimal and add a regression before declaring success.** Run focused, subsystem, and full-core gates afterward.
7. **Use real MiSTer hardware as the final validation layer.** Hardware testing does not replace MAME/RTL proof, and simulation does not replace timing-qualified hardware testing.

A game-behaviour symptom is not automatically a dedicated hardware-logic bug. Enemy AI, damage, hit-stun, death, scoring, and progression are normally game-ROM software executed by the V60. If MAME and the FPGA behave differently, first suspect architectural CPU state, flags, byte lanes, memory contents, interrupts, input delivery, or shared-resource timing.

## 2. Reuse the infrastructure already here

Do not create a parallel `sim/` framework unless the current harness cannot express a required comparison.

- `verif/common/tb_core_romboot.sv` — full-core ROM boot, deterministic frame input, frame capture, and accepted-write tracing through `+TRACELO` / `+TRACEHI`.
- `verif/verilator/run_romboot.sh` — Verilator full-core runner.
- `verif/mame/` — pinned-style Lua capture scripts, PowerShell wrappers, and semantic comparators. `ga2_select_trace.lua` and `compare_ga2_select_trace.py` are the reference pattern.
- `verif/cosim/` — existing V60 retirement co-simulation foundation. Extend or correct it rather than writing another incompatible retirement format.
- `verif/v60/` — directed CPU tests and differential seed tests.
- Verilator and GTKWave MCP tools — narrow waveform generation and inspection around a proven divergence.
- MiSTerClaw — launch, input, screenshot, and final real-hardware verification.
- `tools/report-quartus.ps1 -RequireReady` and `tools/deploy-mister.ps1` — mandatory release and deployment gates.

Scratch traces, screenshots, waveforms, and temporary binaries belong under `scratch/`. Permanent scenarios, comparators, and regressions belong under `verif/`.

## 3. Per-issue workflow

### Step 0 — Write the issue contract

Before tracing, record:

- game/set and exact MRA;
- visible symptoms and what correct MAME behaviour looks like;
- shortest known path to reproduce;
- whether the defect occurs in Verilator, MiSTer, or both;
- the pass/fail observation;
- anything not yet explained.

Keep distinct symptoms together only while evidence supports a shared cause. Split them if their first divergences differ.

### Step 1 — Make one deterministic scenario

One scenario must define both runners' inputs. Prefer a small YAML or JSON record under `verif/scenarios/` when a reusable scenario runner exists. Until then, keep the MAME and RTL schedules adjacent and mechanically checked.

Minimum scenario fields:

```yaml
id: ga2_stage1_enemy_contact
set: ga2
mra: Golden Axe The Revenge of Death Adder (World, Rev B).mra
rom_sha256: <verified manifest or set hash>
initialization:
  nvram: <known image or isolated empty directory>
  work_ram: <documented policy>
  rng_seed: <documented policy>
dip: <explicit values>
inputs:
  - {frame: 60, control: P1_COIN, value: 1}
  - {frame: 64, control: P1_COIN, value: 0}
  - {frame: 120, control: P1_START, value: 1}
  - {frame: 124, control: P1_START, value: 0}
  - {frame: 300, control: P1_RIGHT, value: 1}
stop: {frame: 900}
expected:
  mame: <observable correct result>
  rtl: <current failing result>
```

Requirements:

- Inputs are indexed by emulated frame or another shared architectural boundary, never wall-clock time.
- ROM identity, DIP settings, NVRAM, and initialization are explicit.
- MAME uses an isolated per-test NVRAM/config directory.
- Run each side twice before cross-comparison. Each side must reproduce its own hashes/events exactly.
- Run the RTL scenario under randomized initialization when practical. A zero-init-only pass is a reset defect, not a valid baseline.

### Step 2 — Establish the behavioural boundary

Capture MAME and RTL/MiSTer at the same scenario landmarks.

Use screenshots, frame CRCs, or short state summaries only to answer:

- What is the last matching frame or event?
- What is the first frame or event where behaviour differs?
- Which subsystem or game object becomes observably wrong first?

A visual match is supporting evidence, never the final proof of an RTL correction.

### Step 3 — Descend the comparison ladder

Use the smallest level that can expose the cause:

1. **Frame/state summary** — bracket the mismatch.
2. **Semantic memory writes** — trace the work-RAM, VRAM, palette, object-table, sound, or I/O range relevant to the symptom.
3. **CPU retirement** — align by `(cpu, retirement_sequence)`, not timestamps. Compare PC, opcode, changed registers, PSW/flags, exception/interrupt, and writes attributed to the instruction.
4. **Bus effects** — compare accepted transactions only after attributing them to an instruction or subsystem. Preserve ordered writes and side-effecting I/O reads. Pure-memory reads may be grouped according to an explicit policy. Split V60 32-bit accesses into their external 16-bit cycles with byte enables and endianness preserved.
5. **Subsystem semantics** — IRQ source/vector/ack, DMA descriptors and accepted transfers, sprite fields, palette indices, audio register writes, and so on.
6. **Narrow waveform** — capture roughly 2,000 relevant cycles before and 500 after the proven first divergence. Prefer FST; use VCD only for small focused tests.

Do not compare MAME and RTL V60 cycle counts. If the only apparent mismatch is V60 timing, mark it `TIMING_UNVERIFIABLE` until supported by the NEC manual, a real-board capture, or another hardware-grounded source.

### Step 4 — Trace efficiently

For a focused issue, range-gated text traces are acceptable and fast to build. For long scenarios, use three layers:

1. Per-frame rolling hashes for CPU, bus, and relevant memory regions.
2. A bounded in-memory ring of recent detailed events.
3. Full detailed tracing only for the narrowed mismatch window.

Do not emit unbounded JSON for every instruction or bus event. Use a fixed binary record for high-volume retirement tracing, with a schema/version header shared by MAME, RTL, and the comparator.

The comparator must:

- reject incompatible trace/schema/MAME versions;
- stop at the first unexplained divergence;
- distinguish missing, extra, reordered, and wrong-data events;
- include enough preceding context to reproduce the causal chain;
- never silently suppress a mismatch.

### Step 5 — Prove the root cause

Before changing RTL, write one hypothesis:

> Opcode/path X computes or writes field Y incorrectly because condition Z is wrong. This predicts the first divergent event E and the downstream symptom S.

Then test it:

- inspect the relevant MAME source/trace and RTL path;
- use the V60 manual or other hardware evidence when timing or undocumented semantics are involved;
- add a directed test or assertion that fails on the old RTL;
- demonstrate that the proposed correction changes the first divergence in the predicted way.

A domain-to-module map may suggest suspects, but it does not prove responsibility. The report should say `suspect` until the failing test or waveform proves the actual source.

### Step 6 — Apply the smallest justified correction

Do not patch game-specific RAM values, skip an instruction, weaken a comparison, regenerate a golden trace, or add a workaround that is not tied to documented hardware behaviour.

The correction should usually be one of:

- CPU instruction decode/width/flags/addressing semantics;
- byte-enable or bus-lane handling;
- interrupt or exception architectural behaviour;
- memory arbitration/accepted-transfer handling;
- reset/initialization state;
- subsystem semantics proven by the comparison.

### Step 7 — Verification gates

Run, in order:

1. New focused regression reproducing the exact first divergence.
2. Relevant subsystem suite, such as all V60 tests.
3. V60 differential/random-seed tests when the CPU changed.
4. Full repository regression/qualification.
5. Fresh MAME and Verilator scenario traces; comparator must pass.
6. Visual/frame evidence for the reported symptom.
7. Quartus build and `tools/report-quartus.ps1 -RequireReady`.
8. MiSTer deployment with hash verification and scripted real-hardware reproduction.

Never deploy a stale or timing-failing RBF.

### Step 8 — Report what was and was not proven

Every completed issue report should contain:

```text
Issue:
Deterministic scenario:
Last matching event:
First divergence:
Root-cause hypothesis:
Evidence tier:
RTL change:
Focused regression:
Subsystem/full regression:
Fresh MAME↔RTL result:
Quartus timing/result:
MiSTer result:
What this fix explains:
What this fix does not explain:
Artifacts:
```

## 4. Evidence tiers

Use these labels in reports and comments:

1. `CONFIRMED` — original-board logic-analyser capture or silicon-level evidence.
2. `DOCUMENTED` — schematics, service manual, or NEC/Yamaha/Ricoh documentation.
3. `OBSERVED` — repeatable behaviour on an original board or trusted hardware capture.
4. `MAME_ASSUMED` — MAME source/behaviour only.
5. `UNKNOWN` — insufficient evidence.

MAME is usually strong evidence for game-visible architectural CPU behaviour, mapped register effects, and the correct software path. It is weaker evidence for exact V60 instruction timing, arbitration, contention, DMA edge timing, protection HLE, and analog/output details.

When MAME and confirmed hardware differ, follow the hardware and record the intentional deviation explicitly.

## 5. Issue-specific comparison ladders

### CPU/game behaviour

Frame boundary → work-RAM/entity field → responsible update-function PC → V60 retirement/register/PSW → accepted memory write → focused opcode/addressing regression.

### Video

Frame CRC → first scanline → layer → sprite/tile/palette semantic state → source fetch/index stream → mixer/output pixel → narrow waveform.

### Audio

V60 sound command → Z80 IRQ/retirement → YM/RF5C68 register write → sample address/key state → block CRC → sample comparison.

### Interrupts and DMA

Assert source → pending/priority state → acknowledge/vector → descriptor → each accepted transfer → completion state.

## 6. Golden Axe enemy-behaviour example

For reports such as enemies wandering incorrectly, repeated hit-lock, or enemies not dying:

1. Script one short encounter in MAME with minimal player movement and attacks.
2. Confirm whether the three symptoms share a first divergence.
3. Identify the player and enemy entity records by tracing position, AI state, health, damage, hit-stun, invulnerability, active/dead flags, and animation state.
4. Trace writes to those records in MAME and RTL.
5. Find the first differing write and its V60 PC/opcode/flags/register inputs.
6. If entity writes match, move outward to input reads, collision-object lists, IRQ cadence, and memory delivery.
7. Add a focused CPU or full-core regression before modifying RTL.

Do not invent an FPGA "enemy AI" subsystem. The game ROM owns the AI; the differential trace identifies which emulated architectural facility made that software take the wrong path.

## 7. Guardrails

- Do not weaken a comparator to make a failure pass without a documented, human-approved architectural justification.
- Do not update a golden result as part of a normal build.
- Do not call frame-only evidence a conclusive pass when a deeper comparison was required.
- Do not infer causality from a long list of downstream differences.
- Do not fit V60 cycle timing to MAME.
- Do not modify unrelated user work in a dirty worktree.
- Preserve exact reproduction commands, versions, hashes, traces, and screenshots for every fix.

## 8. Definition of done for one reported issue

An issue is complete only when:

- the original failing behaviour has a deterministic reproduction;
- MAME and RTL have a documented last match and first divergence;
- a focused regression fails before and passes after the correction;
- the correction explains the divergence and reported symptom;
- relevant subsystem and full regressions pass;
- fresh MAME↔RTL comparison passes at the required depth;
- a current, timing-qualified RBF is deployed and verified on MiSTer when hardware is in scope;
- remaining unexplained symptoms are stated explicitly rather than folded into a success claim.

# Agent brief: build a MAME↔RTL differential test system for the Sega System 32 core

**Audience:** you, the coding agent, working autonomously over many sessions on this repository.
**Deliverable:** not a fixed core — a *machine* that finds and localises core bugs, plus the bugs it finds.

Read this whole document before touching anything. Then follow the phases in order. Do not skip ahead.

---

## 1. Why you are doing this

Right now, debugging this core means looking at a wrong-looking screenshot and guessing. That is a bad task shape for you and for a human. You will make plausible changes that fix the symptom and break something three subsystems away, and nobody will notice for weeks.

You are going to replace that with a **lockstep differential debugger**: MAME runs the game as a reference model, the Verilated RTL runs the same game with the same inputs, both emit a common machine-readable event stream, and a comparator reports the **single first point** where they disagree — with the responsible RTL module named.

The output you are aiming for is not "the sprite looks wrong." It is:

> At V60 retirement 8,941,220, MAME wrote `0x0038` to `0x405812` and the RTL wrote `0x0000`. The first preceding difference is that RTL sprite-list DMA completed four master cycles late. Suspect: `rtl/video/sprite_dma.sv:117-134`.

That is a bounded problem you can actually solve. Everything below exists to manufacture that sentence reliably.

**The core insight to internalise:** most of the work is *not* fixing RTL. It is building infrastructure that turns unbounded debugging into bounded debugging. Resist the urge to jump to fixing bugs. A half-built comparator produces confident nonsense.

---

## 2. The hardware you are targeting

Establish these facts from MAME source and datasheets — do not trust the summary below as final, it is orientation only. **Every number here must be verified against MAME's driver and recorded in `docs/hardware_facts.md` with a source and a confidence tag.**

**Sega System 32 (1990):**

| Block | Part | Clock |
|---|---|---|
| Main CPU | NEC V60 (µPD70616) | 16.10795 MHz |
| Sound CPU | Zilog Z80 | 8.053975 MHz |
| FM | 2 × Yamaha YM3438 | 8.053975 MHz |
| PCM | Ricoh RF5C68, 8 channels (Sega-remarked 315-*) | 12.5 MHz |
| Video RAM | 128 KB | |
| Sprite attribute RAM | 128 KB | |
| Palette RAM | 64 KB | |
| Mixer registers | 128 bytes | |

Video capability: 4 scrolling tile layers + 1 text layer + 1 sprite layer with **hardware sprite zooming** and translucent shadows. System 32 is the last of Sega's Super Scaler line — it combines the Y Board's pseudo-3D scaling with System 24's sprite system. **The zooming sprite path and the mixer are where the hard bugs live.** Budget accordingly.

**Multi 32** is a different machine: NEC V70 @ 20 MHz, MultiPCM (Yamaha YMW-258-F) instead of RF5C68, dual monitor, more RAM. **Scope decision required in Phase 0:** either declare Multi 32 out of scope for now (recommended) or plan for a second reference configuration. Do not let Multi 32 sets leak into your test suite by accident — `orunners`, `harddunk`, `titlef` are Multi 32.

### 2.1 The V60 problem — read this twice

The NEC V60 has a 16-bit external data bus with a 32-bit internal architecture and a 24-bit external address bus. Every 32-bit access the CPU makes becomes two bus cycles externally. Your bus-level traces must reflect that, and MAME's may or may not.

**More importantly: MAME's V60 core is an interpreter with approximate instruction cycle counts. It is not a cycle-accurate model of the V60.**

This has a hard consequence that governs the entire design:

- ✅ **MAME can validate your V60's architectural correctness** — which instructions execute, what registers and flags they produce, what memory they write, which exceptions they take. This is enormously valuable and is your primary comparison axis.
- ❌ **MAME cannot validate your V60's cycle timing.** Comparing your RTL's per-instruction cycle counts against MAME's is comparing against a guess. Any "timing fix" justified by matching MAME is not a fix; it is fitting your hardware to an emulator's approximation.

V60 timing evidence must come from, in order: the NEC V60/V70 (µPD70616) user's manual and datasheet instruction timing tables; logic-analyser capture from a real System 32 board; observed behaviour of games that are timing-sensitive. Record which tier every timing decision rests on.

Build the comparator so it **mechanically refuses** to run cycle-level V60 comparisons and reports `TIMING_UNVERIFIABLE` instead. This is not pedantry — without that guard you will spend weeks "fixing" the V60 to match an interpreter.

### 2.2 What else MAME will not tell you

A working emulator only has to be right enough to run games. Expect MAME's System 32 driver to be approximate or silent on:

- DMA setup edge cases and partial/aborted transfers
- interrupt acknowledge timing and IRQ priority resolution
- bus contention between V60, sprite engine, and tilemap fetches
- refresh cycles and wait states
- exact mixer/blend arithmetic at the LSB
- protection MCU behaviour (see below)

When a divergence lands in one of these areas, the correct first move is to ask *which side is wrong*, not to change the RTL.

### 2.3 Protection MCUs — pick your test titles carefully

Several System 32 titles use protection devices, and MAME may implement them at a high level or simulate them entirely. If MAME fakes protection and your RTL implements it (or vice versa), you get a permanent divergence that is nobody's bug.

**In Phase 2, choose initial test titles that have no protection device.** Enumerate the driver's sets and check each one's protection status in the MAME source before adopting it as a test:

```bash
mame -listsource | grep segas32     # all sets in the driver
```

Record the protection status of every candidate set in `tests/CANDIDATES.md` with `NONE | HLE_IN_MAME | SIMULATED | EMULATED` and only promote `NONE` sets to Phase 3 and 4 baselines.

---

## 3. Rules of engagement

These are not suggestions. CI will enforce the mechanical ones in Phase 6; until then, enforce them yourself.

**You may, without asking:**
- create and modify anything under `sim/`, `tools/`, `tests/`, `policies/`, `docs/`
- add trace instrumentation under `rtl/debug/` and `rtl/**/assertions/`
- make RTL fixes that a divergence report positively identifies, with the report ID in the commit message

**You must stop and ask a human before:**
- changing `deviations.yaml`, `policies/*.yaml`, golden hashes, or anything in `tools/compare_*`
- changing the MAME version pin
- restructuring the RTL architecture, or rewriting a subsystem rather than fixing it
- adding a workaround you cannot trace to a specific documented hardware behaviour
- anything that would make a currently-failing test pass without explaining *why* it was failing

**You may never:**
- resolve a failure by weakening, disabling, or narrowing a comparison
- regenerate a golden trace to make a test pass
- declare success on the basis of a screenshot or a frame CRC alone
- commit a change that fixes one test and breaks another without saying so explicitly and prominently

**The governing rule:**

> A failure may only be resolved by weakening the comparison if you *demonstrate* that the difference is architecturally non-observable, or that MAME is inaccurate — with evidence recorded in `deviations.yaml` and approved by a human.

If you find yourself reasoning toward "the comparator is too strict here," stop and write the case up in `docs/open_questions.md` instead of acting on it.

---

## 4. Phase 0 — Establish your environment and write it down

Before any code, discover what you actually have and record it. Do not assume; check.

**Enumerate your tools.** List every MCP server, tool, and command available to you. For each, note what it gives you. In particular determine whether you have:

| Capability | Needed for | If missing |
|---|---|---|
| Shell + persistent filesystem | everything | stop, ask the human |
| Git | commits, bisect, rebasable MAME patches | stop, ask the human |
| Long-running / background processes | Verilator and MAME runs take minutes | chunk work, checkpoint aggressively |
| Web fetch or search | MAME docs, Verilator docs, NEC V60 manual | ask the human to vendor the docs into `docs/vendor/` |
| A documentation MCP (Context7 or similar) | Verilator and MAME API reference | fall back to web fetch |
| A GitHub MCP | reading MAME source without cloning it | clone MAME locally instead |
| Filesystem access outside the repo | MAME source, ROMs, toolchains | ask for paths explicitly |

Write the result to `docs/agent_environment.md`. Include exact invocation commands for MAME, Verilator, and Quartus if present, with versions. Re-read and update this file at the start of every session.

**Establish the toolchain baseline.** Record and pin:

```
sim/mame/MAME_VERSION          # e.g. 0.278 — changing this is a reviewed commit
sim/verilator/VERILATOR_VERSION
docs/hardware_facts.md         # verified System 32 facts, each with source + confidence
docs/agent_environment.md
```

MAME's Lua API is explicitly **not declared stable** and can change between releases. An unpinned MAME will one day produce a flood of phantom divergences. Pin it, record the pin in every trace header, and have the comparator refuse traces from a different version.

**Set up the session protocol.** You will work across many sessions. Maintain:

- `AGENT_LOG.md` — append-only. One entry per session: what you did, what you learned, what broke, what you tried that didn't work. *Especially* what didn't work — you will otherwise retry it in three sessions' time.
- `STATE.md` — current phase, current acceptance gate, the single next action, and any blocking question for the human. Overwrite each session. Keep it under 40 lines.
- `docs/open_questions.md` — things you could not resolve, with what evidence would resolve them.

Start every session by reading `STATE.md`, `AGENT_LOG.md` (last three entries), and `docs/agent_environment.md`.

**Phase 0 gate:** those four files exist and are accurate, the Multi 32 scope decision is recorded, and you can invoke MAME and Verilator successfully from the shell.

---

## 5. Phase 1 — Determinism (no comparison yet)

**Nothing downstream works if this is not solid.** Non-determinism in the harness presents as thousands of RTL bugs, and you will spend a week debugging your own testbench believing you are debugging the core. This is the single most common way projects like this fail.

### 5.1 The scenario format

One file, consumed by both runners, is the source of truth:

```yaml
test: ga2_boot_to_attract
system: ga2                     # MAME set name
rom_manifest: roms/ga2.sha1
reset_cycles: 1024
dip:
  difficulty: normal
  lives: 3
init:
  work_ram: zero                # zero | pattern:AA55 | file:...
  vram: zero
  nvram: file:nvram/ga2.default
  rng_seed: 0
inputs:                         # frame-indexed. never real time.
  - {frame: 0,   port: 1, control: START,   value: 1}
  - {frame: 1,   port: 1, control: START,   value: 0}
  - {frame: 190, port: 1, control: RIGHT,   value: 1}
stop: {frame: 600}
compare:
  levels: [v60_retire, z80_retire, bus, irq, video_crc, audio_crc]
  timing_policy: policies/timing_default.yaml
```

Frame-indexed input is the only granularity both sides can agree on before they agree on cycles.

**Do not use MAME `.inp` recordings for automation.** They historically do not capture full machine configuration (DIP switch state has been a long-standing gap) and playback is sensitive to MAME version and driver changes. Inject inputs through Lua from the scenario file instead. `.inp` is still useful for capturing a human play session that you then *transcribe* into a scenario — that is a good authoring shortcut, not a runtime mechanism.

### 5.2 Nail down every source of nondeterminism

| Source | MAME side | RTL side |
|---|---|---|
| Power-on RAM | init from scenario, isolated `-nvram_directory` per test | testbench backdoor load, not `initial` blocks |
| Uninitialised registers | n/a | `--x-initial unique` + `+verilator+rand+reset+2` to *find* dependencies; `+0` for reproducible runs |
| NVRAM/EEPROM | per-test directory, never the user's | preloaded image |
| Host timing | `-nothrottle -video none -sound none -seconds_to_run N` | free-running sim clock |
| ROM identity | SHA-1 manifest verified before run | same manifest, same load order |
| Input | scenario replay | scenario replay |

Run the whole suite once under `+verilator+rand+reset+2`. Any test that only passes with zero-init has a real reset bug that will bite on hardware. Log those separately; they are genuine findings.

### 5.3 The MiSTer harness — the part that will actually bite you

Your RTL is not a bare System 32 board; it sits inside the MiSTer framework. Most early "divergences" will be harness artefacts. Build `sim/mister_harness/` properly before writing a single comparator:

**ROM delivery.** On hardware, ROMs arrive over `hps_io`'s `ioctl_download` / `ioctl_addr` / `ioctl_data` / `ioctl_index` handshake, driven from an MRA. Your testbench must reproduce that protocol exactly — index assignment, byte/word ordering, and the precise deassertion timing of `ioctl_download`. System 32 ROM sets are large and multi-region (program, sprite, tile, sound, PCM sample); the load order and index mapping must match the MRA the core actually ships with. **If simulation shortcuts ROM loading with `$readmemh` while hardware uses the ioctl path into SDRAM, you are testing two different machines.**

**SDRAM.** Use a behavioural SDRAM model with realistic CAS latency, bank/row semantics, refresh, and the same arbitration and burst behaviour as the real part. System 32 has heavy concurrent demand — V60 code fetch, sprite ROM streaming for the zoom engine, tile fetches, PCM sample fetches — and an idealised zero-latency RAM model hides exactly the class of bug (a read returning stale or late data under contention) this whole system exists to find. **A core that passes every test against an ideal SDRAM model and fails on hardware is the expected outcome of getting this wrong.**

**Clock enables.** The core almost certainly runs one fast `clk_sys` with clock enables standing in for 16.10795 MHz and 8.053975 MHz. Every trace timestamp must be recorded in a domain mappable to MAME's notion of time — master clock ticks — not raw `clk_sys` edges. Define the mapping once, in `docs/time_domains.md`, and use it everywhere.

**Reset sequencing.** Reproduce the framework's real reset sequence, including any DDR3/SDRAM initial reset requirements. Not a convenient one.

Treat harness bugs as a distinct category. If a divergence report implicates the harness, the fix goes in `sim/mister_harness/`, never in `rtl/`.

**Prior art worth reading before you write this:** JimmyStones' Verilator template (linked from the official MiSTer developer docs), the `vsim/` harness in `MiSTer-devel/Apple-IIgs_MiSTer` (scripted input injection, screenshot capture, golden-frame regression), and `Slamy/CDi_MiSTer`'s `sim2/` (Verilator loop where MAME was explicitly used to analyse boot program flow). Do not reinvent these.

**Phase 1 gate:** the same scenario, run twice on each side independently, produces byte-identical per-frame CRCs. Both sides. Every time. If this is flaky, fix it before proceeding — no exceptions.

---

## 6. Phase 2 — Frame CRC regression

Smallest thing that catches real bugs. Ship it before going deeper.

- Per-frame CRC on both sides, written alongside the rolling hash (§7.1)
- Golden storage, content-addressed (git-lfs or an object store), never regenerated as a build side effect
- `python tools/difftest.py --regression` runs everything and reports pass/fail

**Phase 2 gate:** a deliberately introduced one-bit RTL bug (inject one, verify, revert) is caught by the suite, and the suite runs unattended to completion.

---

## 7. Phase 3 — CPU retirement comparison

This is where the system starts paying for itself.

### 7.1 Trace volume — do not use JSON for the hot path

The naive design writes JSON Lines for every event. Do the arithmetic before you commit to it: a V60 retiring on the order of a million instructions per emulated second, at ~120 bytes per JSON record, is **~120 MB per emulated second per CPU**. A ten-minute test is tens of gigabytes before you count bus events, and you have two CPUs. You cannot write it, diff it, or read it.

Three layers instead:

**Layer 1 — rolling hash (always on, cheap).** Each side maintains a running 64-bit hash over the canonical retirement stream and the canonical bus stream:

```
h = h * PRIME xor mix(seq, pc, opcode, arch_state_delta, writes)
```

Emit `(checkpoint_id, retire_count, v60_hash, z80_hash, bus_hash, vram_crc, palette_crc, sprite_crc, audio_crc)` once per frame. A few hundred bytes per frame. **The fast comparison path reads only this.**

**Layer 2 — ring buffer (always on, bounded).** Both runners keep the last N events (N ≈ 200,000) in a fixed-size in-memory ring. On mismatch, dump the ring. You get full detail leading up to the failure without having written the preceding hours.

**Layer 3 — full trace (on demand only).** After bisection narrows the failure to an interval, re-run *only that interval* with full tracing. This window alone is converted to JSON for you to read.

Fixed-width binary record, one shared schema generating a C header, a Lua table, and the Python reader — so all three sides agree by construction:

```c
struct trace_rec {
    uint64_t t;        // master clock ticks (see docs/time_domains.md)
    uint32_t seq;      // per-domain sequence number
    uint8_t  domain;   // V60 / Z80 / BUS / IRQ / DMA / VIDEO / AUDIO / INPUT
    uint8_t  event;
    uint16_t flags;    // width, byte enables, r/w, initiator
    uint32_t addr;
    uint32_t data;
    uint32_t aux;      // pc, vector, channel, sprite index...
};
```

Schema version in the file header. The comparator refuses mismatched versions rather than silently misreading fields.

### 7.2 Instrumenting MAME — three tiers, start at tier 2

**Tier 1 — debugger script.** `mame ga2 -debug -debugscript scripts/trace.cmd`, using `source`, `trace`, and `tracelog`. Fine for a first look. Poor as infrastructure: human-readable output, thin non-CPU coverage, and a parsing maintenance tax. Prototype only.

**Tier 2 — Lua taps (start here).** MAME's Lua interface installs pass-through handlers on address ranges, run via `-autoboot_script`:

```lua
local space = manager.machine.devices[":maincpu"].spaces["program"]

space:install_write_tap(VRAM_BASE, VRAM_END, "vram_w", function(offset, data, mask)
  emit{t = now(), domain = "video", event = "vram_write",
       addr = offset, data = data, mask = mask}
end)

space:install_read_tap(SNDLATCH, SNDLATCH, "sndlatch_r", function(offset, data, mask)
  emit{t = now(), domain = "audio", event = "latch_read", addr = offset, data = data}
end)
```

Derive `VRAM_BASE` and every other address **from MAME's `segas32` memory maps**, not from this document or from your memory of the hardware. Locate the driver first (`src/mame/sega/segas32*.cpp` in recent MAME; older trees split it across `drivers/` and `video/`) and read the address map declarations.

This gives you mapped I/O, video registers, sprite attribute writes, mixer register writes, sound latch traffic, and input reads **without forking MAME**. Taps are not free — a tap on a hot range costs real wall-clock time. Tap deliberately.

**Tier 3 — C++ driver instrumentation (for retirement and hot paths).** Per-instruction V60 retirement tracing is the one thing Lua cannot do at acceptable speed. Add a thin emission layer to the V60 device and the segas32 driver. Rules: never change emulated behaviour; guard behind a build flag so an uninstrumented MAME is always available for cross-checking; emit through the single binary writer, never `printf`; and **maintain it as a series of rebasable patches against the pinned upstream tag in `sim/mame/patches/`, not as a fork you drift away from.**

For the V60 register set, enumerate it from MAME's state registration rather than hardcoding a list — the V60 has general registers plus a substantial set of system registers, and you want all of them or a documented subset.

### 7.3 Instrumenting the RTL

```systemverilog
`ifdef SIM_TRACE
  import trace_pkg::*;
  trace_rec_t trace_rec;
  logic       trace_valid;
`endif
```

Instrument **subsystem boundaries**, not every internal wire. Emit via **DPI-C** into the same binary writer the harness uses — `$sformatf` inside RTL is slow enough to turn a seconds-long iteration into a minutes-long one.

Use the same event names and field semantics as the MAME side. If the two schemas drift, your comparator becomes a schema-difference detector rather than a bug detector.

Also enable Verilator's `--assert` and write SVAs for protocol invariants: bus handshake legality, sprite DMA never running past its list, tilemap fetch addresses in range, mixer register writes only in legal windows. **An assertion that fires is a better bug report than any comparator output, because it names the module directly.**

### 7.4 Alignment — the trap that will eat a week if you get it wrong

**Align CPU comparison by `(cpu_id, retirement_sequence_number)`, never by timestamp.** MAME and your RTL will schedule internal operations completely differently while producing identical architecturally-correct results. Timestamp alignment produces a divergence on essentially every instruction and the output is unusable.

At each retirement compare: sequence number, PC, opcode, changed registers, flags, writes attributed to the instruction, exception/interrupt taken. Timing is a **separate axis**, assessed separately, and for the V60 it is `TIMING_UNVERIFIABLE` against MAME (§2.1).

For bus transactions, the same trap in a different costume: MAME's V60 core performs an instruction's memory accesses at instruction granularity in core-internal order, while your RTL issues real 16-bit bus cycles interleaved with prefetch and DMA. Strict ordered comparison false-positives constantly. Use an explicit policy:

```yaml
bus_policy:
  group_by: retirement
  writes:  ordered          # write order is architecturally visible
  reads:   set              # reads compared as a multiset within the instruction
  split_32bit_accesses: true   # V60 16-bit external bus: one 32-bit access = two cycles
  ignore:
    - speculative_prefetch
    - refresh_cycles
  require_match: [addr, width, byte_enables, data]
```

Every entry under `ignore` needs a justification in `deviations.yaml`. "It was noisy" is not a justification.

**Phase 3 gate:** a retirement-aligned divergence report is produced for a known-buggy scenario, names a plausible module, and the ring buffer dump contains the events leading up to it.

---

## 8. Phase 4 — Bisect and narrow waveforms

Checkpoint every frame, storing **hashes** rather than state: V60 registers, Z80 registers, work RAM, VRAM, sprite attribute RAM, palette RAM, mixer registers, DMA state, interrupt state, sound state.

When frame 900 differs: find the last matching checkpoint → binary-search the interval → re-run only that interval with full tracing → identify the first divergent retirement or transaction.

**Validate save states before relying on them.** MAME save/load makes bisection far faster than replaying from reset, but save state support varies by driver and MAME warns when it is incomplete. Test it: save at checkpoint N, restore, run to N+1, confirm the hash matches the uninterrupted run. If it does not, fall back to replay-from-reset — slower but correct. Record the result in `docs/hardware_facts.md`.

Then waveforms, **only around the failure**. Never a full VCD for ten minutes of gameplay. Re-run with tracing over roughly `divergence_cycle - 2000` to `divergence_cycle + 500`. Prefer FST — much smaller than equivalent VCD, and Verilator supports `--trace-fst` directly:

```bash
verilator --cc --exe --build \
  --trace-fst --trace-depth 8 --trace-threads 2 \
  --assert -DSIM_TRACE \
  rtl/emu.sv sim/main.cpp
```

The bundle produced for each failure:

```text
failure.json          # the report — read this first
rtl_context.jsonl     # ~2000 events before divergence, RTL side
mame_context.jsonl    # same window, MAME side
failure.fst           # narrow waveform
scenario.yaml         # exact reproduction input
reproduce.sh          # one command
```

Keep the context files to a few thousand events. **If the window needs to be wider to make sense of the bug, that is a signal to bisect further, not to widen the window.**

### 8.1 The report format

```json
{
  "test": "ga2_stage1_enemy_spawn",
  "schema_version": 3,
  "mame_version": "0.278",
  "rtl_commit": "a41f3c9",
  "checkpoint": {"frame": 418, "scanline": 92},
  "last_matching": {"cpu": "v60", "retirement": 8941220},
  "divergence": {
    "level": "B",
    "domain": "bus",
    "mame": {"pc": "0x00182C", "write": {"addr": "0x405812", "data": "0x0038"}},
    "rtl":  {"pc": "0x00182C", "write": {"addr": "0x405812", "data": "0x0000"}}
  },
  "first_preceding_difference": {
    "domain": "dma",
    "detail": "sprite list DMA completion 4 master cycles late",
    "confidence": "MAME_ASSUMED"
  },
  "suspect_modules": ["rtl/video/sprite_dma.sv", "rtl/bus/arbiter.sv"],
  "downstream_symptoms": ["enemy activation coordinate incorrect",
                          "sprite absent from frame 419"],
  "artifacts": {"waveform": "...", "reproduce": "..."}
}
```

`suspect_modules` comes from a maintained `CODEOWNERS_DOMAINS.yaml` mapping event domain → RTL path, not from guesswork. `first_preceding_difference.confidence` is load-bearing: `MAME_ASSUMED` means *check whether MAME is the one that's wrong before you change RTL.*

**Report the first divergence only.** After state diverges, everything downstream is noise. Two million differences is worse than none — you will confidently fix a symptom.

**Phase 4 gate:** a full bisect-to-FST run completes automatically from a single command and produces a bundle small enough to read in one sitting.

---

## 9. Phase 5 — Subsystem semantics

Now extend past the CPU, in this order. Each of these is a comparison ladder — descend it, never start at the bottom.

### 9.1 Video

Screenshot diffing tells you the result, never the cause. In order:

1. **Frame CRC** → 2. **Scanline CRC** (first mismatching scanline) → 3. **Layer CRC** (which of the 4 tile layers / text / sprite layer) → 4. **Semantic sprite comparison** (per-sprite code, x, y, zoom factors, priority, flip, palette) → 5. **Layer inputs, not just outputs** → 6. **Pixels and waveforms**, last resort.

Step 5 matters more here than on simpler hardware. Before blaming the mixer, compare what fed it: sprite attribute RAM contents, sprite ROM fetch addresses, the zoom accumulator sequence, tilemap fetch addresses, the palette index stream. Matching outputs with mismatched inputs means two bugs are cancelling — worth knowing.

This ladder distinguishes: sprite RAM wrong / sprite RAM read timing wrong / **zoom accumulator wrong** / priority wrong / mixer blend wrong / palette lookup wrong / output scaling wrong. All seven look identical in a screenshot.

**Expect the Super Scaler zoom path to be the hardest part of the whole project.** Give it its own trace domain with the zoom accumulator state exposed per sprite per scanline, and its own test scenarios chosen for heavy scaling. The mixer's 128 bytes of registers deserve a dedicated semantic comparison too — colour offset, blending, shadow/highlight and priority resolution all live there.

### 9.2 Audio

Direct PCM comparison is the **last** step, not the first. Order:

1. sound command written by V60 → 2. Z80 interrupt → 3. Z80 retirement trace → 4. YM3438 register writes (both chips, tracked separately) → 5. RF5C68 register writes → 6. PCM sample ROM address sequence → 7. channel key-on/key-off state → 8. PCM block CRC → 9. sample-by-sample with tolerance.

```text
MAME: RF5C68 channel 5 KEY_ON at audio tick 81233
RTL:  RF5C68 channel 5 never keyed on
First difference: Z80 read of sound latch returned 0x00, expected 0x80
```

That is a ticket. "The explosion sound is missing" is not.

### 9.3 Interrupts and DMA

These are genuinely ordered and can be compared strictly: interrupt assert/ack sequence with source and vector, DMA channel/source/destination/length/mode and each accepted transfer. This is also the area MAME is most likely to be approximate — tag findings accordingly.

**Phase 5 gate:** each subsystem has at least one scenario that exercises it and at least one comparison level below frame CRC.

---

## 10. Phase 6 — Guardrails in CI

Prose rules do not constrain an agent under pressure to make a test pass. Make them mechanical:

- **Hash-pin the comparator.** `tools/`, `policies/`, `deviations.yaml`, and golden hashes are checksummed. Any change fails CI unless the same commit adds a `deviations.yaml` entry with `approved_by: human`. This makes "fix the test instead of the bug" impossible rather than merely discouraged.
- **Frame-CRC-only passes report `INCONCLUSIVE`, not `PASS`,** if levels A–C were skipped.
- **Regression is mandatory.** A patch fixing one test and breaking two is rejected and reported as such.
- **Every fix states its evidence tier.** A fix justified only by "MAME does it this way" is tagged `MAME_ASSUMED` and flagged for human review.

### 10.1 The deviation registry

Every intentional difference from MAME lives in one machine-readable file that the comparator reads:

```yaml
- id: DEV-014
  field: sprite_dma.completion_latency
  scope: [tests/video/*, tests/gameplay/ga2_stage1.yaml]
  mame_behaviour: "completion asserted on the same cycle as final transfer"
  rtl_behaviour:  "completion asserted one cycle later"
  evidence: CONFIRMED
  evidence_ref: "logic analyser capture, docs/captures/sprite_dma_ack.md"
  rationale: "Real board shows one-cycle ack delay; MAME does not model it."
  approved_by: human
  approved_on: 2026-08-02
```

No entry, no suppression. The waiver ID is printed in every report it affects.

### 10.2 Confidence hierarchy

Tag every compared field `CONFIRMED | DOCUMENTED | OBSERVED | MAME_ASSUMED | UNKNOWN`:

```
decapped silicon / logic analyser capture
        ↓
schematics, service manuals, NEC V60 user's manual
        ↓
observations from an original System 32 board
        ↓
MAME source and behaviour
        ↓
other emulators
```

**When MAME and real hardware disagree, the FPGA follows the hardware.**

---

## 11. Your repair loop

Once the machine exists, this is your per-bug procedure. Follow it literally.

```
1.  Run the smallest failing deterministic test.
2.  Read failure.json.
3.  Inspect both context traces within the supplied window only.
4.  Map the divergence to the responsible RTL module.
5.  State ONE testable root-cause hypothesis explicitly, in writing, before editing.
6.  Check the confidence tag: is MAME trustworthy here? If MAME_ASSUMED or UNKNOWN,
    find independent evidence before changing RTL.
7.  Add or strengthen an SVA that reproduces the issue.
8.  Make the smallest justified RTL correction.
9.  Run the focused test.
10. Run the subsystem regression suite.
11. Run the full regression suite.
12. Report: hypothesis, evidence tier, change made, and what it does NOT explain.
```

Step 12's last clause matters. A fix that makes the test pass but does not explain every observed symptom is an incomplete fix, and saying so is more valuable than claiming victory.

---

## 12. Repository layout

```text
rtl/
├── cpu/v60/  bus/  dma/  video/  audio/  memory/
└── debug/
    ├── trace_pkg.sv           # generated from the shared schema
    ├── trace_v60.sv  trace_z80.sv  trace_bus.sv
    ├── trace_video.sv  trace_audio.sv
    └── assertions/
sim/
├── mister_harness/            # ioctl ROM load, SDRAM model, clocks, reset
├── verilator/                 # main.cpp, scenario_player.cpp, dpi_trace.c
└── mame/
    ├── lua/                   # tier-2 taps
    ├── patches/               # tier-3, rebasable vs pinned tag
    └── MAME_VERSION
tools/
├── trace_schema.py            # generates C header + Lua table + Python reader
├── normalize_mame.py  normalize_rtl.py
├── compare_cpu.py  compare_bus.py  compare_video.py  compare_audio.py
├── find_first_divergence.py  bisect.py  minimize_scenario.py
└── difftest.py                # THE entry point
policies/                      # timing tolerances, bus ordering policy
deviations.yaml                # human-approved deviations only
tests/{boot,cpu,dma,interrupts,video,audio,gameplay}/
tests/CANDIDATES.md            # per-set protection status
traces/{golden,failures}/
docs/{hardware_facts,agent_environment,time_domains,open_questions}.md
CODEOWNERS_DOMAINS.yaml
AGENT_LOG.md  STATE.md
```

One command, everything else an implementation detail:

```bash
python tools/difftest.py tests/gameplay/ga2_stage1.yaml
python tools/difftest.py --regression
python tools/difftest.py --minimize <test>
```

---

## 13. Failure modes — check this table before debugging anything

| Symptom | Usual cause |
|---|---|
| Divergence on nearly every instruction | Aligning by timestamp instead of retirement number (§7.4) |
| Divergence on nearly every bus cycle | Comparing bus *order* against MAME's V60 interpreter, or not splitting 32-bit accesses into two 16-bit cycles |
| Divergence at the same frame in every test | Harness bug — ROM load path, reset sequencing, or SDRAM model (§5.3) |
| Permanent divergence in one specific game | Protection MCU that MAME simulates and you emulate, or vice versa (§2.3) |
| Passes in sim, fails on hardware | Ideal SDRAM model, or X-init masking a reset bug — run `+verilator+rand+reset+2` |
| Timing "fixes" that never converge | Fitting the V60 to MAME's interpreter (§2.1). Stop; get the NEC manual |
| Comparator "fixed itself" overnight | Missing hash pin on `tools/` (§10) |
| Tests pass but a real bug ships | Level D only; levels A–C silently skipped |
| Trace generation dominates runtime | Full tracing on the fast path instead of rolling hash (§7.1) |
| Divergences appear after a MAME update | Unpinned MAME, or Lua API drift (§4) |
| Sound "bug" that isn't | Sample-level audio comparison run before register-level (§9.2) |

---

## 14. Definition of done

You are done with the infrastructure when a human can run one command, walk away, and come back to a ranked list of first-divergence reports each naming a specific RTL module — and when a deliberately injected one-bit bug anywhere in the CPU, bus, DMA, video, or audio path is caught and localised automatically.

You are never "done" with the core. That is fine. The machine is the deliverable; the bug fixes are the interest it pays.

---

## Appendix: kickoff message

Commit this file to the repo (as `AGENTS.md`, or `docs/DIFFTEST_BRIEF.md` referenced from `AGENTS.md`), then start with something like:

> Read `docs/DIFFTEST_BRIEF.md` in full before doing anything. Then execute Phase 0 only: enumerate your available tools and MCP servers, verify you can invoke MAME and Verilator, pin their versions, verify the System 32 hardware facts in §2 against MAME's `segas32` driver source, make the Multi 32 scope decision, and create `docs/agent_environment.md`, `docs/hardware_facts.md`, `AGENT_LOG.md`, and `STATE.md`. Do not write any simulation or comparator code yet. Stop at the Phase 0 gate and report what you found, including anything in §2 that turned out to be wrong.

Phase-gate it like that for at least the first three phases. Letting an agent run Phases 0–3 unsupervised in one go usually produces a comparator built on an assumption that was wrong in Phase 0.

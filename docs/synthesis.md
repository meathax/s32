# Synthesis results — yosys 0.33, Cyclone V target (`synth_intel_alm`)

First real synthesis data for the core, run with open-source tooling
(`yosys -p "read_verilog -sv <module>; synth_intel_alm -family cyclonev"`).
These figures validate the DESIGN.md §10.3 ALM budget; final numbers come
from Quartus (which packs ~2 ALUTs/ALM and maps MLAB/M10K differently).

| Module | ALUTs | FFs | DSP | Notes |
|---|---|---|---|---|
| `s32_v60` (CPU) | 12,288 | 2,107 | 0 | ≈ 6.1–7.5 K ALMs packed — matches the §10.3 estimate of 7,500. Register file currently in flops (yosys `-nobram`); Quartus maps it + microcode scratch to M10K, reducing further. |
| `s32_sprite` | 1,588 | 602 | 1 | + 16 MLAB. Under the 3,500 ALM budget. |
| `s32_mixer` | 2,514 | 1,048 | 0 | + 2,688 MLAB bits (line buffers → M10K in Quartus). Within the 3,000 ALM budget for two instances after BRAM extraction. |
| `s32_tilemap` | — | — | — | not yosys-parseable (unpacked-array ports, SV feature gap in yosys 0.33); Quartus handles these. Budget by analogy with sprite engine: ~3.5 K ALMs. |

## Method / caveats

- `-noiopad` (module-level runs), `-nobram` where yosys would otherwise
  flatten large memories into registers (V60 fetch buffer warning is
  expected — Quartus infers MLAB for it).
- A whole-`s32_core` yosys run does not complete: yosys 0.33 rejects
  SystemVerilog unpacked-array module ports (`input [15:0] scrollx [0:3]`),
  used on the video modules. Quartus accepts these; the whole-chip fit is a
  Quartus step. The per-module runs above prove synthesizability and budget.
- These are *module-level* sanity syntheses proving the RTL is
  synthesizable and the §10 budget is realistic — not a full-chip fit.
  Full-chip fit + timing closure runs in Quartus with `sys/` and the PLL IP
  (see `Arcade-SegaSystem32.qsf`).

## Quartus 17 integration status

The generated Cyclone V Qsys PLL is now included through
`rtl/pll/synthesis/pll.qip` and the top uses its actual exported interface.
Local and CI build scripts abort if that generated QIP is missing, so a
hardware build cannot silently use the 50 MHz simulation placeholder. The
requested 96.648/48.324 MHz clocks quantize to approximately
96.634615/48.317307 MHz in the generated IP.

Initial Quartus 17 mapping/elaboration blockers have also been removed:
declaration/source ordering, a V60 identifier collision, simulation-only
large memory initialization loops, hierarchical reach-through, and an
enum-returning helper that crashed the older frontend.

### Latest full-chip Analysis & Synthesis result (map only)

The ga2 release profile (`S32_SYSTEM32_ONLY` + `S32_GA2_ONLY`) completes
Quartus 17 Analysis & Synthesis. The current `.map.rpt` reports:

| Mapping metric | Result |
|---|---:|
| Estimated logic utilization | **40,434 / 41,910 ALMs** (96.5%) |
| Combinational ALUTs | 63,251 |
| Dedicated logic registers | 23,981 |
| Block-memory bits | 3,993,510 |
| DSP blocks | 52 |
| PLLs | 3 |

These are **map-only estimates**, not fitted resource utilization. The map
does not prove placement/routing or timing closure, and it does not produce a
release-qualified RBF. No successful fitter summary, timing-closure report,
release RBF, or hardware result is recorded here.

The profile keeps ga2's V25 and i8255 paths and removes hardware unreachable
by ga2: the ADC, three trackballs, generic protection HLE, Burning Rival HLE,
and Air Rescue DSP. Those blocks remain present in universal builds.

The EEPROM shadow is now an explicit 64×16 dual-port Cyclone V `altsyncram`
M10K. Data is stored inverted so the device's zero power-up state has the
93C46 erased value `0xFFFF`; serial writes and index-2/3 loads use one port,
and synchronous NVRAM upload reads use the other. WRAL/ERAL are serialized
over 64 core clocks so the single write port remains inferable. The focused
ModelSim test covers serial READ/WRITE/WRAL/ERAL, upload latency, dirty/ack
timing, and loader-baseline behavior. An isolated Quartus map reports 81
ALMs, 147 combinational ALUTs, 90 registers, and 1,024 block-memory bits.

## Verification status (see also `verif/run_regression.sh` and
`verif/run_regression.ps1`)

| Tier (DESIGN.md §11) | Status |
|---|---|
| Module lint/elaboration (all RTL) | ✅ green (iverilog) |
| V60 smoke test | ✅ PASS |
| V60 directed suite (memory operands, stack, JSR/RET, IRQ entry + RETIU, HALT) | ✅ PASS (8/8) |
| Full-core integration boot (CPU→bus→palette/VRAM writes, vblank IRQ→handler→HALT, CRT vsync) | ✅ PASS |
| **V60 differential co-simulation vs independent reference model** | ✅ PASS — 100/100 in the historical stress run; 50/50 in the latest complete Windows regression |
| Cyclone V synthesizability (yosys) | ✅ V60/sprite/mixer synthesized |
| Real-ROM full-core simulation | ✅ `holo`, `ga2`, and `svf` reach documented boot/render milestones; ga2 accepts scripted coin/Start and drives a populated sprite list through ROM fetch to mixer pixels; this is not hardware acceptance |
| MAME instruction-trace corpus (external golden model) | tooling in `verif/cosim/`; capture/replay against a suitably instrumented MAME build is still pending |
| **Full-core soak / §11.6 simulator-tier acceptance** | ✅ PASS — clean boot-to-HALT, vblank IRQ→handler, extended multi-frame run, 339K active video samples, **zero X on RGB and audio** |
| Focused DDR/ROM-loader integration | ✅ PASS |
| EEPROM index-3 load/save persistence | ✅ PASS — upload byte order, dirty state, soft-reset retention |
| V60 maximum-length F1 decode | ✅ PASS — 20-byte double-displacement MOVW and correct next PC |
| V60 `SKPCUH` search semantics | ✅ PASS — exact ga2 encoding plus found/exhausted/zero-length cases |
| EEPROM M10K implementation | ✅ PASS — serial operations, synchronous upload latency, dirty/ack ordering, isolated Quartus inference |
| Complete regression | ✅ PASS — native Windows ModelSim **25/25 tiers**, including **50/50 V60 differential seeds**; detailed transcript in `verif/modelsim-regression.log` |
| Per-game acceptance (§11.6 hardware tier) | no build of this core has launched a set on a DE10-Nano; tracked in `docs/compat.md` |

## §11.6 acceptance — simulator tier (run here)

§11.6 says "run on real hardware **or high-fidelity simulator**; verify
audio/video output, confirm no crashes over extended play." The **synthetic
simulator tier** runs here: `verif/common/tb_core_soak.sv` boots the assembled
`s32_core` from its reset vector with a synthetic
homebrew workload that drives the whole bus decode (video registers, palette,
VRAM, I/O display-enable, interrupt controller), takes a vblank interrupt into
a handler, and then soaks the CRT/render/mixer pipeline over an extended
multi-frame window. It verifies: no crash (clean HALT, no illegal-opcode
trap), the interrupt path delivers to the handler, the render pipeline runs
live, and **no X-propagation on the RGB or audio buses**. This surfaced and
fixed a real core bug (the p0 ROM-address handshake) during bring-up of the
test. Separate real-ROM runs now exercise `holo`, `ga2`, and `svf`, but the
harness idealizes external DDR/audio service. Pixel-exact colour, audio
equivalence, extended play, and a physical-board result remain per-game
bring-up items — see `docs/compat.md`.

The corrected ga2 scripted-input run samples coin at frames 41/42 and Start
at frames 51/52. After the Start transition, frame 63 reaches its first
populated sprite list (`spr_cmd=4`, `srom=5968`, `sprpx=52722`); frame 64
reports `spr_opq=42393` and real pixels at the mixer. Frames 64–69 continue
at about 5.9K sprite-ROM requests and 42K opaque sprite pixels per frame.
The 90-frame run (frames 0–89) completes with `ROMBOOT DONE`, zero errors,
and zero warnings. Four commands and roughly 5.8–6.0K sprite-ROM requests per
frame remain active through frame 89, where cumulative `sprpx=1374558`. The
frame-80 PPM/PNG visibly resolves the Golden Axe character-select scene with
skull/candle portraits, `STERN`, a player sprite, and `Credits 0`; the files
are retained in `verif/modelsim_romboot/dump80.png`. These results remain
simulation evidence and do not establish pixel equivalence or hardware
behavior.
The ROM harness supplies a one-time, testbench-only R0–R30 initialization to
match MAME's deterministic V60 device-start state and avoid four-state `X`
poisoning. Production soft-reset semantics are unchanged.

## Differential co-simulation (the §11.2 equivalence tier, run here)

§11.2 specifies instruction-level equivalence checking against a golden
model. MAME is one such model; an **independent
reimplementation** is an equally valid second implementation for differential
testing, and it runs fully in this environment. `verif/cosim/v60_ref.py` is a
from-scratch Python V60 (integer ISA + all addressing modes, sharing no code
with the RTL); `gen_diff_program.py` emits constrained-random straight-line
programs; `run_diff.sh` executes each on both the reference and the RTL and
diffs final architectural state.

**This tier immediately earned its keep:** it caught a real RTL bug the
directed suites missed — signed `DIVW/DIVH/DIVB` produced wrong results
because the signed/unsigned selector tested the wrong opcode bit (DIV/DIVU
differ in bit 4, not bit 0, which distinguishes REM/REMU) and the divider
lacked operand-magnitude/sign handling. Fixed; 100/100 random seeds now
match the reference. This is exactly the value §11.2 exists to provide.

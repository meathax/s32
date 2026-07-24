# V60 instruction-pipelining plan

**Status:** proposal / not started. No RTL changes until the design and risk are
approved. This is the sequel to `docs/v60-prefetch-plan.md` (fetch, done) and is
grounded in `docs/v60-authenticity-from-manual.md` plus the newly-found NEC
designers' paper (Komoto/Saito/Mine, *J. Info. Proc.* Vol.13 No.2, 1990) and the
measured work-loop CPI.

---

## 0. Why this exists — the measured gap

| Quantity | Value | Source |
|---|---|---|
| Our **work-loop** CPI (idle spin excluded) | **13.04 cyc/instr** | `tb_core_romboot +PCHIST`, ga2 |
| Authentic V60 peak | **4.57 cyc/instr** (3.5 MIPS @ 16 MHz) | IPSJ 1990, Table I |
| Authentic "typical" (memory/branch-heavy) | **~8** (MAME flat-8 sits here) | MAME `v60.cpp:626` |
| Authentic bus cycle | **3 clocks/access** — **we already match (÷3)** | IPSJ 1990, Table I |
| Real V60 microarchitecture | **6-unit, 6-stage pipeline, up to 4 instructions in flight** | IPSJ 1990, Table I |

We are **~1.6–2.8× slower than real hardware on work code**. The fetch fix took
overall CPI 22.70→13.89 by hiding the fetch; it did **not** close this, because
the remaining loss is that our core executes **one instruction at a time** while
the real V60 **overlaps four**. This plan is the only authentic lever left to
close it. Target: **~8 cyc/instr** (authentic-typical), not 4.57 (that needs the
full 6-stage machine and is out of scope — see §8).

---

## 1. What is already pipelined, and what is not

**Already done (the PFU stage):** instruction *fetch* is overlapped with
execution — the prefetch engine fills the 24-byte window on idle bus cycles while
the FSM executes, and the FAST_IFETCH port serves 8-byte icache lines at clk_sys.
So "Fetch" is effectively stage 1 of a pipeline already.

**Not overlapped (the gap):** decode, effective-address generation, operand
fetch, execute, and writeback run **strictly sequentially per instruction**. The
FSM is one instruction's whole lifecycle:

```
S_FILL → S_DECODE → S_IF2 → S_EA_MODE → S_EA_DONE → (S_OP2_LD | S_RMW_RD …) → S_EXEC → S_NEXT → (back to S_FILL)
```

Instruction N+1 does **not** begin S_DECODE until N reaches S_NEXT. That inter-
instruction handoff (`S_NEXT → S_FILL → S_DECODE`) is a 2–3-cycle bubble on
*every* instruction, on top of the per-instruction state chain.

**Measured state-cycle breakdown (ga2 work code, where the 13.04 goes):**

| State group | % of cycles | Nature |
|---|---|---|
| S_FILL (realign/dispatch) | 16–19 | inter-instruction bubble + window realign |
| S_DECODE | 7 | decode (1 cyc/instr) |
| S_IF2 | 3 | second-byte decode |
| S_EA_MODE + S_EA_DONE | ~14 | effective-address generation |
| **S_OP2_LD + S_RMW_RD** | **~38** | **operand memory access — genuine 3-clock bus cycles (authentic)** |
| S_EXEC + S_RMW_EX | ~10 | ALU/execute |
| S_NEXT | 3 | PC advance / handoff |

Key reading: **~38 % is real operand-memory time** the real V60 *also* pays (it
has no data cache; 3-clock bus). That is **not overhead to remove** — removing it
would make us *faster than real hardware*. The reclaimable part is the **~29 %**
in S_FILL/S_DECODE/S_IF2/S_NEXT — the decode+dispatch machinery that the real V60
**overlaps** with the previous instruction's execute/operand-access. That overlap
is what this plan buys.

---

## 2. Why CISC pipelining is hard (the hazards)

The V60 is CISC: variable-length (1–22 byte) instructions, memory-to-memory
operations, complex double-indirect addressing. Overlapping instruction N+1 with
N introduces three hazard classes that must be handled *without changing
architectural results*:

- **Data hazards (RAW).** N+1 reads a register or memory location N writes. If
  N+1's EA-gen or execute reads it before N's writeback commits, it gets a stale
  value. Registers *and* memory (memory-to-memory ops write RAM that a following
  instruction may read).
- **Structural hazards.** The single shared bus (our arbiter = the BCU): N's
  operand access and N+1's fetch/operand access contend. The prefetch arbiter
  already serialises these with data priority; overlapping operand accesses of two
  instructions needs the same discipline.
- **Control hazards.** If N is a taken branch/call/return/exception, the
  sequentially-decoded N+1 is wrong and must be discarded. We *already* flush the
  fetch window on control transfer (epoch bump); the pipeline must also squash any
  partially-decoded N+1.

The real V60 handles these with interlocks (the IDU/EAG/EXU stall each other via
the pipeline-control logic). We will use the **conservative equivalent**: detect a
hazard and *fall back to sequential* for that instruction pair (see §4).

---

## 3. Staged implementation (each stage independent, reversible, verifiable)

The guiding principle: **never regress correctness; each stage is a bounded
overlap whose worst case equals today's sequential behaviour.** Ship and verify
one stage before starting the next.

### Stage P0 — instrumentation (DONE)
The `work_cyc`/`work_instr` counter in `tb_core_romboot.sv` already reports work-
only CPI. Baseline = **13.04**. Re-run after each stage to prove the gain.

### Stage A — decode/dispatch overlap *(recommended first; best risk/reward)*
Begin decoding N+1's opcode during N's final states (S_EXEC/S_NEXT), so the
`S_NEXT → S_FILL → S_DECODE` bubble is hidden for the common sequential case.

- **Mechanism.** Add a small "predecode" latch that, once N+1's bytes are
  resident in the fetch window (the prefetch guarantees this for sequential flow)
  and N is in a late state, computes N+1's opcode/length/operand descriptors —
  *without reading register values or touching the bus*. When N hits S_NEXT, N+1
  jumps straight into EA/execute instead of re-walking S_FILL/S_DECODE.
- **Why it's the safe one.** Decode is *read-only* on architectural state and
  only *identifies* operands (which register, which addressing mode); it does not
  read register *values* or memory. So it cannot observe a stale value from N. The
  only ordering constraint is that N+1's window bytes are valid — already true.
- **Squash on control transfer.** If N turns out to be a taken branch, discard the
  predecode (the epoch/flush already invalidates the window; the predecode latch
  keys off the same epoch).
- **Expected gain.** Removes most of S_FILL+S_DECODE+S_NEXT (~25 % of cycles) for
  sequential pairs → **13.04 → ~10–11**.

### Stage B — EA-generation overlap
Compute N+1's effective address during N's operand-access/execute.

- **Hazard.** N+1's EA may use a base/index register N writes → RAW. Handle by a
  **register scoreboard**: mark the register(s) N will write as *pending*; if N+1's
  EA reads a pending register, **stall** N+1's EA until N's writeback commits (or
  forward the value if cheap). Independent pairs overlap; dependent pairs fall back
  to sequential.
- **Expected gain.** Hides S_EA_MODE+S_EA_DONE (~14 %) for independent pairs →
  **~10–11 → ~8–9**.

### Stage C — operand-prefetch overlap *(optional; likely not worth it)*
Speculatively start N+1's operand load during N's execute when there is no memory
dependency and the bus is free. Highest complexity (memory RAW detection,
speculative bus cycles that may need cancelling on a branch). Recommend deferring
unless B leaves us above target.

**Realistic end state: Stages A+B → ~8–9 cyc/instr = authentic-typical.** That is
the whole point; stop there.

---

## 4. Hazard-handling design (the safety principle)

Use a **1-instruction-deep overlap with conservative stall-on-dependency**:

1. A tiny **scoreboard** records the destination register(s) and, for memory-write
   instructions, the write range of the *in-flight* instruction N.
2. Before N+1 advances into a stage that would *use* a value (EA read of a
   register, operand read of memory), check it against N's scoreboard.
3. **Hit → stall** N+1 at the stage boundary until N's writeback commits (fall
   back to exactly today's sequential timing for that pair). **Miss → overlap.**

Worst case (every pair dependent) = today's behaviour, no speedup, still correct.
Best case (independent pairs, the common case) = full overlap. This **bounds the
risk**: the change can only make things *faster or equal*, never wrong — provided
the hazard check is complete. The hazard check's completeness is the one thing to
get exactly right and to test adversarially.

---

## 5. Correctness & verification (non-negotiable gate per stage)

Pipelining must change **timing only**, never architectural results. Gate every
stage on all of:

- **V60 unit suite 27/27** (Verilator + Icarus), including the new hazard tests
  below.
- **Differential co-sim vs the Python reference** (`verif/cosim/run_diff.sh`,
  50 seeds) — the primary safety net: it compares PC, instruction bytes,
  registers, PSW and memory ops. Any pipelining bug that changes results shows
  here immediately. Must stay 50/50.
- **Full-core romboot render pixel-identical** + `exc=0` (ga2, and spot-check
  arabfgt/spidman).
- **New hazard unit tests** (add to the suite):
  - RAW register: `MOV R1←…; ADD …,R1` (N+1 reads N's dest).
  - RAW memory: memory-to-memory write followed by a read of the same address.
  - Branch shadow: taken branch immediately followed by an instruction that must
    be squashed, not executed.
  - EA base hazard: `MOV R2←…; MOV …,[R2+disp]`.
- **Work-CPI measured** after each stage (target trend 13→~10→~8).

---

## 6. Timing-closure impact (must re-sweep)

- Pipeline **latches between stages shorten** combinational paths → can *help*
  Fmax. But the **hazard-detection logic adds combinational depth** and the design
  activates more logic per cycle.
- The core currently closes at **+0.141 ns (seed 3)**. Every pipelining stage
  **must** be followed by a Quartus rebuild + `seed_sweep.sh` and must not go
  negative on the slow-100 °C corner. Budget a seed re-sweep per stage.
- Keep each stage's added logic shallow (register the hazard check where possible)
  precisely because of this thin margin.

---

## 7. The non-authentic alternative — a "turbo" option (low-risk, complementary)

The user's stated goal is *"the waterfall needs to run much faster"* and that the
slowdown is *not* authentic. Two ways to deliver that:

- **Pipelining (this plan):** reaches **authentic** speed (~8 CPI). Real System 32
  hardware still slowed down *somewhat* at heavy scenes, so this makes the
  waterfall *authentically* sluggish — better than now, but not slowdown-free.
- **Turbo / V60 ce multiplier (OSD option):** run the V60 clock-enable at 2×/3×.
  **Trivial, near-zero risk** (a divider change + an OSD menu item), eliminates the
  slowdown entirely, but is **not authentic** (faster than the real board).

**Recommendation:** treat these as *complementary*, not either/or. Ship a **turbo
OSD option** regardless — it is a few lines, common in MiSTer cores, and directly
satisfies "run much faster" for users who want no slowdown. Pursue **pipelining**
separately for users/purists who want authentic behaviour. The turbo option also
lets us A/B the *cause*: if turbo removes the waterfall slowdown, that confirms the
V60 throughput is the bottleneck (validating this whole plan on hardware).

---

## 8. What is explicitly out of scope

- **Full 6-stage / 4-way superscalar V60.** Reaching the 4.57-CPI *peak* needs the
  real machine's depth and out-of-order-ish interlocks — an from-scratch rewrite,
  enormous risk, far past the point of diminishing returns for game speed. Not
  worth it; ~8 CPI (A+B) is the goal.
- **Making operand-memory access faster.** Authentic at 3-clock bus; speeding it
  up would be *less* accurate.
- **MMU/TLB pipelining.** System 32 runs the V60 in physical mode (no paging), so
  the MMU path is unused — nothing to pipeline there.

---

## 9. Effort / risk summary and decision points

| Stage | Effort | Risk | Est. CPI | Recommend |
|---|---|---|---|---|
| A — decode/dispatch overlap | Medium | Low–Med | 13 → ~10–11 | **Yes, first** |
| B — EA overlap + scoreboard | Med–High | Medium | ~10–11 → ~8–9 | Yes, after A verifies |
| C — operand-prefetch overlap | High | High | ~8–9 → ~7–8 | Defer / probably no |
| Full superscalar | Very high | Very high | → ~4.6 | No |
| Turbo OSD option | Trivial | Very low | n/a (removes slowdown) | **Yes, in parallel** |

**Decisions needed from the user before any RTL work:**
1. **Authentic vs fast:** pipelining (authentic ~8 CPI), turbo (fast, non-authentic),
   or both? (Recommendation: both — turbo now, pipelining staged.)
2. **How far to pipeline:** Stage A only, A+B, or beyond?
3. **Risk tolerance:** each stage rebuilds + re-sweeps timing on a working,
   deployed core; the differential co-sim is the correctness net.

**Suggested path:** ship the **turbo OSD option** first (immediate, safe, satisfies
"much faster"), then implement **Stage A**, verify against the full gate (§5) +
re-sweep timing (§6), measure the CPI, and reassess whether **Stage B** is worth
it. Stop at A+B (~8 CPI). This keeps every step reversible and correctness-gated.

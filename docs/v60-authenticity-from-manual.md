# V60 authenticity audit vs the NEC µPD70616 Programmer's Reference Manual

Source: NEC µPD70616 (V60) Programmer's Reference Manual, "Preliminary Information"
rev 1.0 (archive.org NEC_V60pgmRef, 308 pp). Read 2026-07-23 to ground the
fetch/prefetch redesign (docs/v60-prefetch-plan.md) in the real part's
architecture. The µPD70616 IS our target part (System 32 = D70616R-16, 16.108 MHz).

## The decisive finding: the real V60 HAS a prefetch queue — our redesign is authentic

Manual §1 "Pipeline Operation" (p.1-18) and Figure 1-13 "µPD70616 Functional
Blocks and Pipeline" (p.1-19) describe six concurrent functional units with
interlocks: **PFU, IDU, EAG, MMU, BCU, EXU**.

**PFU (Pre-fetch Unit)** — verbatim (p.1-18):
> "The pre-fetch unit is designed to load the **16 byte instruction queue** from
> external memory **during idle bus periods**. Since instruction execution is
> generally a sequential process, the **latency to fetch an instruction from
> memory can be reduced to zero** if the instruction is found in the pre-fetch
> queue."

**BCU (Bus Control Unit)** — verbatim (p.1-18):
> "The bus control unit acts the interface for **each internal bus requester**.
> Additional logic allows the BCU to re-run faulty bus cycles ... and to use a
> short cycle bus mode for accessing fast cache memories."

Figure 1-13: the **Prefetch Queue (PFU)** and the EXU's data path both connect to
the **BCU's Data Bus Interface** — i.e. instruction prefetch and operand data
accesses share one bus, arbitrated by the BCU.

**This is exactly the redesign.** Mapping:
| Real V60 (manual) | Our implementation |
|---|---|
| PFU 16-byte prefetch queue, fills during idle bus periods | prefetch engine + `fb[]` window, fills via the idle bus |
| Fetch latency → 0 on queue hit | goal: hide fetch behind execution (S_FILLW → ~0%) |
| BCU arbitrates each internal bus requester (prefetch + data) | data/prefetch arbiter (data priority) — the BCU |
| BCU "short cycle bus mode for fast cache" | s32_core ROM icache 2-clk hit path |

So the concurrent-prefetch + data-priority-arbiter approach is **not an
approximation of MAME — it is the real µPD70616 microarchitecture.** Before this
manual, our own DESIGN.md §5.4 only *asserted* a "2×16-byte-line" prefetch queue
without a cited source; the manual confirms the queue exists and is 16 bytes.

## What the manual does NOT provide: per-instruction cycle counts

This is a *programmer's* reference (semantics, formats, addressing modes,
exceptions), not a hardware/timing manual. Confirmed by:
- Table of Contents: no timing/execution-time/cycles section anywhere (Sections
  1-9: Intro, Data Types, Register Set, Address Spaces, Task Mgmt, Instruction
  Formats & Addressing Modes, Instruction Set, Interrupts & Exceptions, Debug).
- Instruction reference pages (Section 7, e.g. CLRTLB p.7-20) list Syntax /
  Operation / Description / Condition Codes / Instruction Format / Addressing
  Modes / Exceptions / Opcode — **no clocks/cycles field.**

⟹ The timing-calibration reference stays MAME's flat "8 clocks/instruction
average" (v60.cpp:626, its own "fix me"), exactly as docs/v60-prefetch-plan.md
§0 assumed. The manual does not change the P4 calibration target; it validates
the *architecture* that produces the target behavior (fetch hidden → the game
runs at ~MAME/real speed instead of fetch-bound).

## Reassessment of the plan (docs/v60-prefetch-plan.md)

**No change of direction — the manual upgrades the plan from "inferred authentic"
to "confirmed authentic."** Specific refinements:

1. **Queue geometry.** Real PFU queue = **16 bytes**; ours is 24. Keep 24: it is
   a safe superset that holds the 20-byte worst-case instruction without an
   on-demand tail fetch (a 16-byte queue would stall on 17-20-byte instructions —
   rare double-displacement EAs). The extra 8 bytes cost negligible authenticity
   (those instructions are uncommon) and avoid a corner case. Documented deviation.
2. **Prefetch fills during idle bus periods** = data has bus priority, prefetch
   steals idle cycles. Our data-priority arbiter matches this exactly. Keep.
3. **BCU = our arbiter.** Confirmed single shared bus with the prefetch as one
   requester. Our CPU-internal arbiter (dbus_* data + pf_* prefetch, data
   priority, one owner per transaction) is the faithful model. Keep.
4. **Pipelining scope.** The real V60 also overlaps IDU/EAG/EXU across
   instructions (a deeper pipeline). We keep the single sequential microstate FSM
   for decode/EA/execute and only add the PFU-equivalent prefetch. Justification:
   fetch was 56% of our cycles (the dominant loss); MAME — the game-validated
   reference — does not pipeline decode/EA/exec either (flat 8), so matching its
   throughput needs only fetch hidden. Full IDU/EAG/EXU pipelining is a much
   larger change, unnecessary to hit game speed, and out of scope. Noted as a
   possible future enhancement.
5. **BCU ECC re-run / short-cycle mode** are System-32-irrelevant (no ECC; the
   icache already models the fast-cache path). No action.

**Conclusion:** proceed with the prefetch implementation as planned (P0/P1 done,
P2 in progress). The manual removes the biggest uncertainty in the plan — whether
a prefetch queue is authentic — and answers it definitively: yes, 16-byte PFU
filling on idle bus cycles, arbitrated by the BCU. Calibration remains vs MAME.

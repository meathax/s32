# Plan: Authentic V60 fetch-timing fix (instruction prefetch)

Status: PLAN (no code yet). Author: investigation 2026-07-23.
Goal: eliminate the ga2 waterfall slowdown (and the downstream stage-1 background
pop-in and frozen "PLAYER SELECT" fly-in) by making the V60 core execute game
code at roughly its authentic per-frame rate, via an instruction prefetch queue.

---

## 0. What "authentic" means here — the ground truth we have

Established by an exhaustive read-only audit (V60 core, bus adapter, s32_core ack
paths, all 27 V60 testbenches, MAME v60 source, repo design docs):

| Fact | Source | Status |
|---|---|---|
| Real part is uPD70616: **16-bit external data bus**, 24-bit address, 16.10795 MHz on System 32 (32.2159 MHz XTAL / 2) | NEC Selection Guide quoted in MAME v60.cpp:35-53; PCB photo "D70616R-16"; segas32.cpp:2251 | **Confirmed** |
| Real per-instruction cycle counts | nowhere — MAME: *"Actual cycles / instruction is unknown"*, charges flat 8 ("fix me — just an average"); no NEC manual exists anywhere on this machine | **Unknown** |
| Real V60 has an instruction prefetch queue | Implied by physics (16-bit bus at 16 MHz cannot feed ~4.5-byte instructions at 8 CPI without one) and asserted by our own `DESIGN.md §5.4` ("prefetch queue, 2x16-byte lines, flushed on branches") — which was **designed but never implemented** | **Safe inference** |
| The de-facto behavioral reference is MAME's ~8 CPI at 16.108 MHz — games validated against it for 30 years | MAME v60.cpp:626 | Confirmed |
| Repo acceptance policy | `DESIGN.md §5.6`: base cycles where known else MAME's average, plus **real memory wait states from our bus**, cycle-count within **+/-20%** of budget on macro benchmarks (per-frame instruction counts of running games) | Already written — we follow it |

**The authentic fix:** implement the prefetch queue the real part must have (and
our own DESIGN.md already specifies), keep the **16-bit external bus** and
**16.108 MHz ce-gated timing** exactly as they are, give **data accesses
priority** over prefetch on the single bus, and **calibrate against MAME-derived
macro benchmarks (+/-20%)**. Not a turbo, not a clk_sys-domain cheat.

## 1. Where the 22.7 cycles/instruction actually go (measured + audited)

- Measured (ga2 attract, `+PCHIST`): **S_FILLW (fetch bus-wait) = 40%**,
  **S_FILL = 16%** -> 56% of all V60 time is fetch; ~12.7 of 22.7 cyc/instr.
- Audited cost of one 4-byte fetch today: **6 ce ticks**, of which **5 are pure
  adapter-FSM hops** (I_IDLE accept + 2x I_CYC + 2x I_WAIT) — the core's ROM
  icache answers in 2 clk_sys, *fully hidden* under the 3:1 clock ratio. Memory
  is not the problem; **serialization is**: the CPU stops dead and single-threads
  every 4-byte top-up (sustained 7 ticks per 32-bit word; a post-branch refill of
  20 bytes ~= 35 ticks).
- Everything else (decode, EA, execute, data access) ~= 10 cyc/instr — reasonable
  for a multi-cycle CISC and close to authentic.

**Target arithmetic:** hide fetch behind execution -> fetch residue ~1-3
cyc/instr -> **~10-12 CPI** on memory-heavy game code (Phase 3 trims to ~9-11).
Effect on the measured scenes: select work 42% -> **~18-22%** (MAME: 15%);
attract idle 23% -> **~55-65%** (MAME-derived ~70%). Within the +/-20% policy
band, and enough to eliminate the waterfall overrun, the background pop-in, and
the frozen white "PLAYER SELECT" fly-in (all downstream of V60 speed).

## 2. Design

### 2.1 Architecture choice (driven by the audit's hazard list)

The audit found ~45 data-access bus sites in `s32_v60.sv` all using the idiom
`if(!bus_req) issue; else if(bus_ack) complete` — a prefetcher sharing that
channel would have its acks consumed by data states. Therefore:

**The arbitration lives in `s32_v60_bus`, not in the CPU FSM.** The adapter gains
a second, read-only, 32-bit **instruction port** (`i_req/i_addr/i_rdata/i_ack`):

- Strict priority: **data port wins**. An i-transaction starts only when the
  d-port is idle; a d-request arriving mid-i-transaction waits only for the
  *current 16-bit m-cycle* to finish (<= ~2 ticks — exactly how a real single-bus
  prefetcher steals idle cycles).
- The d-port's semantics, beat sequencing, and timing are **byte-for-byte
  untouched** — `tb_v60_bus_lanes` (asserts exact 1/2/3 external-cycle counts)
  must pass unmodified. All 45 data sites in the CPU are untouched.
- The core side (`s32_core`) still sees **one m-stream** — the icache
  single-transaction invariant, `wr_stb` one-shots, side-effect-on-read
  peripherals, and the SDRAM p0 fill FSM are all preserved. Zero changes to
  `s32_core`.

### 2.2 Prefetch engine (inside `s32_v60.sv`, merged into the single always block)

A small ce-gated engine (PF_IDLE -> PF_WAIT) running concurrently with the main FSM:

- **Launch condition:** queue has room (`fb_wr <= 20`), no realign in progress, no
  flush pending -> issue a 32-bit fetch at `fb_base + fb_wr` on the i-port.
- **Separate commit pointer:** `fb_wr` (where fetched bytes land) is decoupled
  from `fb_valid` (what decode may read) — audit hazard #4 (fb_valid is both
  commit pointer and fetch address today; any concurrent change desyncs them).
  Fetch address is latched at issue.
- **Commit rules** (hazards #2, #3): bytes append **only above `fb_valid`**, never
  shift/rebase (readers do combinational `fb[k]` many cycles after fill —
  append-only is provably safe); commit is **deferred one cycle** if the main FSM
  is in a realign-shift or fb_prev-snapshot cycle; `fb_valid` is published
  atomically after commit.
- **Flush/redirect via epoch counter:** every non-sequential pc write (all 13+
  sites — branches, JSR/RET/RETI/RSR, JMP, exceptions at S_EXC_VEC, HALT-wake)
  already funnels through window invalidation; each flush bumps `pf_epoch`;
  in-flight i-port acks tagged with a stale epoch are **discarded**. Covers
  IRQ/NMI entry (can fire between any two instructions).
- **SMC guard extended:** the existing guard (a completing data write overlapping
  the live/retained window kills it — audit V60-19) additionally bumps
  `pf_epoch`, so a write can never race a prefetch already on the bus and leave
  stale bytes.
- **Address clamp:** prefetch never crosses out of ROM/RAM decode space into the
  I/O region — a cheap comparator, so code ending near 0xC00000 can't make the
  prefetcher strobe the ADC/EEPROM side-effect reads the audit flagged.
- **Queue geometry:** the existing 24-byte `fb` window *is* the queue (DESIGN.md
  wanted 2x16B lines; we keep 24B because every reader indexes `fb[k]` relative
  to instruction start — restructuring to a ring buffer breaks ~30 read sites and
  the documented Icarus variable-index fragility). Deviation documented.
- The `fb_prev` loop cache, `fb_need` early decode, and the DBcc fetch-through
  trick are **kept intact** — proven (R11-1: 12,310->3,130 cycles) and orthogonal.

`S_FILL` then degenerates to: realign (unchanged) -> check `fb_valid >= fb_need`
-> usually **already satisfied** by the background engine -> dispatch. `S_FILLW`
leaves the common path entirely (kept only as the cold-start/miss wait).

### 2.3 Sequential-path bubble cut (second-order, after 2.2 is proven)

For the common retire path (`S_NEXT`, `total_len <= 4`): fold the <=4-byte
realign shift into S_NEXT itself and dispatch **directly to S_DECODE** when
post-shift bytes suffice — skipping S_FILL entirely. Same for the one-byte-advance
decodes (NOP/BRK-skip/etc.). Saves 1-2 cyc/instr. The S_HALT-wake path (the
audit's one S_DECODE entry that bypasses S_FILL) gets an explicit
prefetcher-consistency flush.

## 3. Phasing — each phase lands separately, fully green before the next

| Phase | Content | Gate |
|---|---|---|
| **P0 — Safety net** (no RTL change) | Record baselines: tb_v60_fetch (3,130 cyc/10 reads), +PCHIST CPI ga2 select/attract, full 38-tier regression, 50-seed differential, spidman trigger trio, orphaned tb_v60_xch. **Write the missing directed tests the audit exposed** *before* changing anything: (a) SMC store-ahead-of-PC sweep (0..20 bytes ahead, asserts new bytes execute), (b) IRQ arriving on the exact refill cycle, (c) branch-to-window-edge sweep (last byte, first-past, base-1, odd targets), (d) fb_base-parity x alignment sweep, (e) a **ce-gated** unit run (all 27 tbs run ce=1 today — a prefetcher that mis-samples acks on gated ce would pass the whole unit tier and only die in-game) | Everything green pre-change; new tests lock current behavior |
| **P1 — Mechanical decouple** | Introduce `fb_wr` + latched fetch address; zero behavior change | Full regression **bit-identical** (50/50 differential seeds) |
| **P2 — Prefetch engine + adapter i-port** | 2.1 + 2.2 | Full matrix + new P0 tests + tb_v60_bus_lanes untouched-pass; +PCHIST shows S_FILLW < 10% |
| **P3 — Bubble cut** | 2.3 | tb_v60_audit's exact-PC asserts; CPI ~9-11 |
| **P4 — Calibration** | Macro benchmarks vs MAME (select work <=~20%, attract idle >=~60%, waterfall scene via +PLAYMAGIC autopilot); tighten tb_v60_fetch budgets to lock gains (~<=2,200 cyc); add budgeted loop variants (loop > 24B, call/return loop, computed jump). If we *overshoot* MAME meaningfully, apply DESIGN.md's compat-throttle lever — authenticity cuts both ways | Within +/-20% policy band |
| **P5 — Full validation + hardware** | 38-tier ModelSim + Icarus + Verilator lint (the v25_holo_real_lint path lints s32_v60); update the 5 white-box-coupled tbs the audit inventoried (movcd/strfs poke `cpu.fb[3]`, long_ea reads `total_len`, romboot FBDBG probes) and tb_sdram_edge stimulus if the p0 pattern changed; X-prop/reset audit of all new state (ties to the earlier non-determinism finding); Quartus timing closure + ALUT check; **deploy to MiSTer, verify: waterfall speed, stage-1 background fade-in, PLAYER SELECT text** — the three symptoms are the acceptance tests | Hardware evidence |

## 4. Risk register (top items, mitigations built into the design)

1. **Data states consuming prefetch acks** -> eliminated structurally (separate
   adapter port; d-port untouched).
2. **Commit during realign-shift/snapshot smears bytes** -> defer-commit rule +
   simulation assertion.
3. **Stale bytes after SMC or redirect** -> epoch-tagged acks + extended guard +
   new directed test (a gap today: *no existing test covers it*).
4. **ce-gating mistakes** (double-sampled acks) -> prefetcher fully ce-gated; new
   gated-ce unit tier.
5. **V70/Multi 32 fractional CE** (2-3 clk gaps, ack-miss-by-one-tick ~58% of
   reads) -> i-port tolerates by construction (latency only); V70 stays on 16-bit
   cycles (existing documented open item, not worsened).
6. **Quartus timing/ALUT** at 48 MHz -> new logic is small (one comparator set,
   epoch counter, port mux) but the fb write-mux widens; monitored at P5.
7. **Simulator fragility** (Icarus variable-index corruption, Verilator NBA-RHS —
   both documented in-file) -> follow the existing explicit-loop idioms; run all
   three simulators.
8. **Concurrent session in this repo** — it edited the testbench and deleted build
   dirs mid-run earlier. Prefer it paused, or work knowing collisions are possible.

## 5. What this predicts for the visible bugs

- **Waterfall slowdown**: gone or reduced to MAME-comparable (frame budget no
  longer overrun).
- **Stage-1 background pop-in** and **white PLAYER SELECT box**: both expected to
  resolve — the V60 failing to finish setup/animation work in time, not video
  bugs (the select screen already renders pixel-identical to MAME when the V60
  keeps up).
- **arabfgt select swirl/slowdown**: same root class; re-verify separately after P4.

Per repo git rules: no commits/pushes at any phase without explicit go-ahead;
report each phase with evidence.

---

## Appendix A. Key audit facts to carry into implementation (so we don't re-derive)

### A.1 Fetch buffer — writers (all in the single `always @(posedge clk) ... else if (ce)` block, L580/591)
- Decls L92-98: `fb[0:23]` (24B; worst instr 20B), `fb_base`, `fb_valid` (0..24),
  `fb_prev[0:23]`/`fb_prev_base`/`fb_prev_valid`, `fb_realigning`.
- L622-626 S_RESET init.
- L647-651 S_FILL realign first-shift cycle: snapshot whole window into fb_prev.
- L652-656 S_FILL realign: shift down s=min(delta,4)/cycle; fb_base+=s; fb_valid-=s.
- L658-664 S_FILL miss: loop-cache restore when `fb_prev_valid!=0 && pc==fb_prev_base`.
- L665-669 S_FILL miss no-restore: full invalidate.
- L672-673 S_FILL enough: clear realign, dispatch.
- L684-690 S_FILLW ack: top-up 4 bytes at fb[fb_valid..+3]; fb_valid clamps to 24.
- L2909-2920 SMC guard (OUTSIDE case, runs every ce a data write completes):
  write overlapping live window -> fb_valid<=0; overlapping retained -> fb_prev_valid<=0.
  Relies on "writes and fetches occupy mutually exclusive states" + textual-last NBA.
  **This invariant is what the epoch counter must replace for a concurrent prefetcher.**

### A.2 Fetch buffer — readers (combinational, many cycles AFTER S_FILL)
- `opcode=fb[0]` L100; `fb_need` early-decode reads fb[0],fb[1][7:5],fb[2] L106-129;
  `fb32/fb16` L131-136; EA mode taps `modval=fb[ea_ofs]` L458-461; RF read-addr mux
  reads fb bytes in S_DECODE/S_STR_OP1/S_STR_OP2/S_DEC_OP2/S_BF_*/S_BS_* L512-547;
  `disp_of` L552-558; plus late length/ext byte reads at L1859/1900/2123/2327/2335/
  2424/2472/2511/2573. **=> Append-only above fb_valid is safe; shift/rebase/restore
  mid-instruction corrupts in-flight ea_ofs/len1/len2-relative reads.**

### A.3 Non-sequential PC writers (each must bump pf_epoch / redirect prefetch)
Bcc L766/774/808/814; BSR/JSR S_JSR1 L1673; CALL S_CALL1b L1694; RET L1702;
RETIU/S L1741; RSR L1757; exception/IRQ/NMI vector S_EXC_VEC L2861 (fires between
any two instrs from S_DECODE sampling L707-725); JMP L3538; **S_HALT wake L2895
(re-enters S_DECODE WITHOUT S_FILL — special-case it).** st_after_fill is ONLY
ever S_DECODE.

### A.4 Bus adapter cost (s32_v60_bus, fully ce-gated, L50 `else if (ce)`)
- 4-byte aligned read: 5 ce ticks c_req->c_ack (1 accept + 2x(I_CYC+I_WAIT)),
  6 ticks to data-consumed; **5 of 6 are FSM hops, core ack (N<=2 clk_sys) hidden
  by 3:1 ratio.** 16-bit write = 3 ticks c_req->c_ack. Adapter starts on c_req
  RISING edge (needs 1-tick idle gap between transactions — the CPU provides it).
- ROM path: 32-line x 8-byte direct-mapped icache in s32_core (shared I/D,
  fill-on-demand, no prefetch); hit N=2 clk_sys; miss = 4 chained p0 words.

### A.5 Clocking
- ce_cpu = clk_sys(48.324MHz) * 21845/65536 ~= 16.108 MHz (V60); V70 = 27122/65536
  ~= 20 MHz with alternating 2/3 clk_sys spacing (ack-miss-by-one ~58% of reads).
- tb ce = exact /3 (cdiv 0..2). All 27 unit tbs run **ce=1** (no gated-ce coverage).

### A.6 Validation assets
- Perf gate: `tb_v60_fetch.sv` (cycles<=4000, reads<=32; measured 3,130/10).
- Bus timing: `tb_v60_bus_lanes.sv` (exact 1/2/3 external-cycle asserts) — must
  pass unchanged.
- Differential: `tb_v60_diff.sv` + verif/cosim (50 seeds; STRAIGHT-LINE only — no
  branch/interrupt coverage).
- Runners: `verif/run_regression.ps1` (38 tiers, ModelSim, authoritative);
  `verif/run_regression.sh` (35 tiers, Icarus); `verif/verilator/run_romboot.sh`
  (full-core real ROM at gated ce — where a fetch change is validated on game
  code); `verif/verilator/run_spidman_trigger_regression.sh` (Verilator-only, NOT
  in main regression — run explicitly); `tb_v60_xch.sv` orphaned (manual).
- White-box couplings to update on any fb rename: tb_v60_movcd:79 & tb_v60_strfs:70
  poke `cpu.fb[3]`; tb_v60_long_ea:110 reads `cpu.total_len`; tb_core_romboot reads
  `core.v60.fb[0..7]/fb_base/fb_valid/ea_ofs` (FBDBG) + `core.ic_hit/rom_ready/rom_filling`.
- Verification GAPS (write these in P0): SMC store-ahead-of-PC; IRQ during refill;
  branch-to-window-edge; RAM-executed + self-modify through core data path;
  hostile fetch-port wait-state jitter; gated-ce unit run; odd-PC/alignment sweep.

### A.7 Prior fetch work (do not re-derive)
- R11-1 (audit.md:115): incremental fb + fb_prev loop cache + fb_need early decode
  took the directed branch loop from 12,310 cyc/2,305 reads to 3,130/10.
- V60-19 / Round 21 (audit.md:460, cc68a25): the SMC window-invalidation guard.
- DESIGN.md 5.4/5.6: prefetch queue was specified (2x16B lines) but never built;
  timing policy is MAME-average +/- real bus waits, +/-20% on macro benchmarks.

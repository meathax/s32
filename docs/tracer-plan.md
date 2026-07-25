# MiSTer On-Core Differential Tracer — Plan (v2, post-review)

**Status: PLAN ONLY — no RTL, no device writes yet.**
v2 incorporates a 4-lens adversarial review (30 findings, 2 blockers) verified
against the actual repo; the corrected claims below cite real file evidence.

Goal: a light, **removable**, **portable** trace IP installed inside the running core
(FPGA hardware, not sim) that records real-time execution events into a DDR3 ring
buffer, freezes on a button, and is pulled off the MiSTer as a text log in the same
line format the existing sim/MAME diff loop uses (`frame=… pc=… wa=… data=… be=…`),
**one line per accepted write** (see Tap policy — the legacy `sim_obj8_writes.txt`
triplication is a TB sampling artifact that v1 of this plan wrongly treated as the
reference).

Why hardware capture matters: every open bug class (ga2 slowdown, arabfgt
swirl/floor-flicker, ga2 select) is **real-hardware V60/V25 timing divergence** the
Verilator sim cannot reach (sim runs the HLE V25; real-V25 sim too slow for
full-game). The FPGA is the only place the true behaviour exists and today has no
trace output. What already exists vs. what is new work:

| Piece | Status | Where / correction |
|---|---|---|
| Log line format + offline diff habit | exists | `sim_obj8_writes.txt` (but: 3× duplicated — TB tap is level-sampled; fixed as part of Phase C) |
| MAME-side technique (write taps) | proven, **emitter is new work** | `verif/mame/*.lua` prove taps; none emits this line format — `trace_obj8.lua` must be written (spec in §4) |
| Tap signals | exist as **internal nets** of `s32_core` | `rtl/s32_core.sv` `m_req/m_we/m_ack/sel_wram/wram_a/m_wdata/m_be`; NOT ports — capture logic must live inside `s32_core` (§1) |
| Frame counter | **does not exist in RTL** | sim log's `frame=` is the TB variable `sprdump_cur`; the adapter synthesizes one from `vbl_start` |
| Host access to running MiSTer | exists | misterclaw `mister_shell` (root ssh per docs/misterclaw.md), scp for file transfer |
| On-hardware trace emitter | **new — this plan** | |

---

## 1. Architecture: two layers (removable + portable)

### Layer 1 — portable IP (`mister_tracer/`, schema-agnostic)

```
mister_tracer/
  rtl/
    tracer_pkg.sv          // params, header/record layout constants
    tracer_core.sv         // async capture FIFO + ring sequencer + freeze drain FSM
    tracer_ddr_writer.sv   // DDRAM-style WRITE-ONLY burst master (records + header)
    tracer_ddr_arbiter.sv  // 2:1 DDRAM mux: host absolute priority (contract below)
  tracer.qip
  host/
    trace_pull.sh          // on the MiSTer: dd /dev/mem region -> /tmp/trace.bin
    trace_decode.py        // bin + schema JSON -> "frame=… pc=… …" text log
    trace_diff.py          // two logs -> first divergence (alignment rules in §4)
  adapters/
    s32_adapter.example.sv // template: tap+pack capture module (lives IN the core)
    s32_obj8.schema.json   // field offsets/widths for trace_decode.py
  README.md
  INTERFACE.md             // versioned contract (checklist in §1.4)
```

Layer 1 treats each record as an **opaque parameterized-width blob** (default 128
bits; width is a parameter and is mirrored into the header). It never interprets
fields; per-core meaning lives only in the adapter + schema JSON. Header magic is
neutral (`"MTRC"`); core identity goes in `schema_id`.

### Layer 2 — per-core integration (the honest surface)

Review finding: the tap nets are internal wires of `s32_core`
(`rtl/s32_core.sv:170-173,223,261`) and Quartus cannot hierarchically reference
across modules — so integration is **not** "one file at the emu top". The real,
still-small surface for s32, every edit inside `` `ifdef S32_TRACE ``:

1. **`rtl/debug/s32_tracer_adapter.sv`** (new) — capture side, **instantiated inside
   `s32_core`**: tap condition, record packing, seq/frame counters, async-FIFO write
   side. Exports one narrow bundle (FIFO read side or rec+valid) up through an
   ifdef'd port on `s32_core`.
2. **`rtl/s32_core.sv`** — ifdef'd adapter instantiation + the one ifdef'd port.
3. **`Arcade-SegaSystem32.sv`** — ifdef'd: tracer core/writer + arbiter between
   `s32_fb_if` and the DDRAM pins; `status[17]` trigger wire; CONF_STR OSD entry.
4. **`files.qip` + qsf** — `tracer.qip` line and the `S32_TRACE=1` macro.

Tap policy (review blocker, resolved): the V60 bus **holds** `m_req` until `m_ack`
(`rtl/cpu/v60/s32_v60_bus.sv:70,109-110`), so the v1 level-sampled condition records
each write ~3× — exactly why `sim_obj8_writes.txt` has every line triplicated, and
why the TB's own paltrace tap ack-qualifies ("Log only acknowledged writes",
`tb_core_romboot.sv:569-578`). **The adapter emits ONE record per accepted write:
`m_req && m_we && sel_wram && in_range && m_ack && !ack_d`** (mirrors the existing
`wr_stb` one-shot idiom, `s32_core.sv:1268`). Duplication is prevented at the tap,
never in the decoder. Real obj8 rate: ~8 writes/frame (24/3).

Record (s32 obj8 schema, 128 bits):
`{seq[16], frame[16], pc[32], wa[16], data[16], be[8], flags[8], seq_hi_echo[16]}`
- `seq` increments **per qualifying tap event** (not per FIFO push) — a FIFO-full
  drop consumes a seq, so drops appear as gaps; header also counts them.
- `seq_hi_echo` = seq[31:16] of a 32-bit internal sequence: widens the effective
  sequence AND lets the decoder reject torn records on live pulls (§2).
- `frame` = adapter counter incremented on `vbl_start`, reset with the core.

Trigger: `status[17]` (verified free; CONF_STR uses O[0]..O[16]). Because MiSTer
status bits persist across OSD/core reload, freeze is **edge-interpreted after 2FF
sync**, not level — the tracer must not boot frozen after a reload (§1.4 reset table).

### 1.3 Removability (corrected mechanics)

- Quartus 17 cannot macro-gate a QIP inclusion (documented in this repo:
  `rtl/cpu/v25/v25.qip` header), so `tracer.qip` listed in `files.qip` is
  **analyzed on every build even with the macro off**. Consequences:
  - Layer-1 RTL must stay within the Quartus 17.1-clean SV subset already used in
    `rtl/` at all times.
  - Full removal = comment/delete **both** the qsf macro and the `files.qip` line
    (two switches, same as the `S32_REAL_V25` pattern — currently a commented
    precedent at qsf:87, mechanism valid).
- Macro off → no tracer/arbiter instantiated anywhere; `s32_fb_if` wired directly
  to the DDRAM pins exactly as today. All trace edits sit inside `` `ifdef ``.
- Rot guard (lesson from the never-compiled real-V25 path carrying a latent bug,
  docs/ga2-readiness.md): CI/sim step Verilator-lints/elaborates the `S32_TRACE=1`
  configuration on every change.

### 1.4 INTERFACE.md checklist (review-mandated contract items)

- clk/rst per port group; **all DDR-side ports synchronous to the host core's
  `DDRAM_CLK`** (clk_ram here); capture port in the adapter's tap clock (clk_sys
  here) — async FIFO always instantiated (portability to unrelated-clock cores).
- Reset behavior table: warm core reset invalidates an unfrozen ring; a **frozen**
  ring survives (header stays frozen=1) so a capture can be pulled after reset.
- `arm`/`freeze` edge-detected after 2FF sync in the writer domain; boot-frozen
  case explicitly excluded.
- Tracer DDR master is **write-only by contract** (`DDRAM_RD` tied 0).
- Normative byte layout: record beat 0 = `rec[63:0]` at the lower byte address,
  little-endian lanes matching `DDRAM_BE` bit i = byte i (decoder depends on this).
- `RECORD_WIDTH` parameter mirrored into the header; header magic `"MTRC"`,
  `schema_id` identifies the core/schema.
- Header torn-read protocol (§2) and the freeze drain sequence (§3).

### Portability spectrum (honest costs)

- Core with no DDR use → tracer owns the DDRAM port; pure drop-in.
- Core whose emu DDRAM port has a single leaf master (s32 today: `s32_fb_if`) →
  insert the arbiter at the emu top; small integration (§ Layer 2 list).
- Core with a multi-channel core-local DDR helper (ao486/PSX-class `ddram.sv`) →
  **preferred integration is adding a write-only channel inside that helper**, not
  stacking a second arbiter under it (those helpers pipeline outstanding reads; the
  write-only-slave rule is what keeps either option tractable).

---

## 2. DDR region, ring layout, and pull coherency

Facts verified by review against this repo:

- `DDRAM_ADDR[28:0]` is a 64-bit-word address, byte = `addr << 3`
  ([rtl/mem/s32_fb_if.sv:105-111](rtl/mem/s32_fb_if.sv), `FB_BASE=32'h3000_0000`
  default taken by the emu instantiation; passes unscaled through `sys_top.v`
  `ram1_*` → f2h_sdram1).
- Our FB claims **0x3000_0000–0x300F_FFFF** (4 × 512×256×2 B = 1 MiB).
- Contention model (corrected): the emu DDRAM port has **exactly one master today**
  (`s32_fb_if`), so the tracer arbiter is 2:1 by construction. The framework's other
  DDR users ride *separate* bridge ports and only share raw controller bandwidth:
  ascal vbuf (RAMBASE hardcoded `32'h2000_0000`, 8 MiB, sys_top.v:714-724), the
  always-instantiated `ddr_svc` (ALSA channel compiled out via
  `MISTER_DISABLE_ALSA=1`; the LFB **palette reader remains live regardless of
  MISTER_FB** and targets `LFB_BASE`, which Main sets at runtime over SPI,
  sys_top.v:454-455,1029-1043). So the candidate region must be validated against
  Main's runtime choices, not just compile-time RTL.

**Candidate tracer region: byte 0x3010_0000, 16 MiB (0x3010_0000–0x310F_FFFF)** —
1 MiB-aligned (`= 769 MiB`), directly above the FB claim, inside the core-reserved
window. 16 MiB = 1 M records.

### Phase A verification (all read-only, gates everything)

1. **Local:** read `sys/sysmem.sv` end-to-end (confirm ram1 address passes unscaled;
   no other emu-port master); re-inventory every DDR consumer live under this qsf's
   macro set.
2. **On device (misterclaw `mister_shell`):**
   - `id`; `dd if=/dev/mem bs=1M skip=769 count=1 | xxd | head` → proves root,
     /dev/mem readability, and the dd variant in one shot. **Portable dd form only**
     (busybox may lack `iflag=skip_bytes`): `bs=1M skip=769 count=16`.
   - `cat /proc/cmdline` + `/proc/iomem` → candidate must be **outside kernel System
     RAM** — required not just for safety but for **read coherency** (outside System
     RAM /dev/mem reads are uncached/coherent with f2h writes; inside, reads can be
     stale — if it ever lands in System RAM the pull method changes to mmap O_SYNC,
     not just the base).
   - `MiSTer.ini` fb/vbuf settings + LFB state → confirm Main isn't pointing any
     buffer into the range.
   - Idle-write check: read the region twice **across an OSD open/close and a core
     reload** (the moments Main is most likely to touch DDR), not just two quiet
     samples.
3. Outcome pins `DDR_BASE_BYTE`/`DDR_SIZE_BYTES` (qsf-set parameters) with evidence
   recorded here before Phase B.

### Ring + header layout with torn-read protection

At `DDR_BASE_BYTE`: 64-byte header, then the record ring.

```
header: magic "MTRC", version, record_width, schema_id,
        gen_ctr_a, wr_index, wrap_count, drop_count, frozen, seq_at_freeze, gen_ctr_b
```

- Every mutable field is 32-bit-atomic (HPS A9 is 32-bit).
- **Seqlock**: writer bumps `gen_ctr_a` before and `gen_ctr_b` after each header
  update; host re-reads until `a == b`.
- **Ordering rule**: a header claiming `wr_index=N` is issued on the same DDRAM
  master strictly **after** the record bursts covering [0,N) were accepted —
  same-port Avalon ordering then guarantees the pointer never leads the data.
- **Live pulls are best-effort** (a dd racing a ring wrap can pair a record's two
  64-bit words across generations — the `seq_hi_echo` in word1 lets the decoder
  reject such torn records); **frozen pulls are authoritative**.

---

## 3. Dataflow, CDC, freeze, and the arbiter contract

```
clk_sys (taps)                     clk_ram (96.648 MHz)            HPS/Linux
┌─────────────────────┐  async   ┌──────────┐  ┌─────────┐  ┌──────────────────┐
│ adapter IN s32_core │ FIFO(64) │ ring seq │→ │ arbiter │→ │ DDR3 ring region │
│ ack-edge tap, pack, │─────────▶│ + writer │  │ fb wins │  │ header + records │
│ seq++/frame(vbl)    │          │ + drain  │  └─────────┘  └──────────────────┘
└─────────────────────┘          └──────────┘   ▲ s32_fb_if (unchanged, priority)
        ▲ status[17] freeze (2FF-synced, edge)
```

- clk_sys/clk_ram are same-PLL 1:2 here, but the FIFO is a true dual-clock FIFO
  (portability). Overflow policy: **drop-with-count**, never back-pressure the
  tapped bus; drops = seq gaps + header count. Drop counter crosses clk_sys→clk_ram
  via gray-code/handshake (it is published in the clk_ram-written header).
- **Freeze sequence** (review-mandated, unit-TB-asserted): (1) freeze edge 2FF-synced
  into both domains; (2) clk_sys side stops accepting tap events, latches final seq;
  (3) writer drains the FIFO to empty and completes any burst in flight; (4) final
  seq crosses by handshake; (5) writer emits the terminal header (frozen=1,
  seq_at_freeze, wr_index) as its **last** DDR write. TB asserts ring contents ==
  seq range minus counted drops, exactly.

### Arbiter contract (rewritten per review — the fb path is hard-deadline)

`s32_fb_if` traffic is not neat bursts: erase/flush = up to 128 **pipelined
BURSTCNT=1 single-beat writes**; line read = one **BURSTCNT=128** command whose 128
`DDRAM_DOUT_READY` beats return long after acceptance; shadow RMW = up to 128
read-modify-write iterations with request-idle gaps between words
([rtl/mem/s32_fb_if.sv:207-305](rtl/mem/s32_fb_if.sv)). The line fetch has a real
per-scanline deadline (`fb_rd_kick`/deadline + `debug_fb_underrun` telemetry,
s32_core.sv:589-609 — R19-4 class). Therefore:

- **Grant-hold** = host request present (WE/RD asserted) **or host read data still
  outstanding** (all 128 readdatavalid beats returned before regrant counts as
  complete).
- `DDRAM_DOUT`/`DOUT_READY` route **unconditionally to the host** (tracer is
  write-only), so an in-flight fb read is unaffected by a granted tracer write.
- **Tracer grant requires host idle ≥ M cycles** (parameter) — prevents stealing the
  shadow-RMW inter-word gaps; optionally gated by a host-busy hint input (wired to
  `wr_busy | erase-pending | read-pending`) making the line-fetch window
  tracer-transparent.
- Honest invariant: fb waits at most one ≤8-beat tracer burst **per host-idle
  window** (cycle cost subject to `DDRAM_BUSY`), not "one per operation".
  **Acceptance gate stays empirical: `debug_fb_underrun` unchanged before/after,
  on-device, in the heaviest known scene (ga2 waterfall).**
- Bandwidth: obj8 ≈ 8 records/frame ≈ kB/s. Documented extreme (future broad tap,
  ~5–6 M writes/s × 16 B ≈ 90 MB/s): 16 MiB ring ≈ **0.2 s** (v1 said 0.7 s —
  arithmetic corrected); broad mode would need a bigger ring or filtered taps.
  Narrow taps remain the intended "last N seconds" mode.

---

## 4. Host pull + decode + diff

1. During play, toggle the OSD trigger (or I do it via `mister_osd_navigate`).
2. `trace_pull.sh` via `mister_shell`:
   `dd if=/dev/mem of=/tmp/trace.bin bs=1M skip=769 count=16` (header first, then
   only the valid span); fetch to the PC over the established root ssh (scp) —
   misterclaw has no file-transfer tool of its own.
3. `trace_decode.py trace.bin s32_obj8.schema.json > hw_obj8_writes.txt` — one line
   per accepted write; rejects torn records (seq echo) on live pulls.
4. **MAME emitter `verif/mame/trace_obj8.lua` (new work, spec'd):** one line per
   access; `wa = (offset - 0x200000) >> 1`; `be` from mem_mask
   (0x00ff/0xff00/0xffff → 01/10/11, lane polarity documented once in the shared
   field-mapping table both emitters are written against); `pc` as `%08x`; frame
   source = screen frame_number, stated in the log header.
5. **Diff alignment (review-mandated):** absolute frame numbers are NOT comparable
   (MAME counts from Lua attach + scripted coin-in; hardware arms mid-game).
   `trace_diff.py` keys on the **ordered (pc, wa, data, be) event sequence anchored
   at a semantic event** (e.g. first spawn-write signature); `frame` is carried as
   annotation and reported as a frame-delta/skew profile, never as part of the
   divergence key. The bug class is literal non-determinism — the tool locates
   *where* sequences part ways, it never expects identical streams.

---

## 5. Verification plan (gates on evidence)

- **Unit sim (portable folder, Verilator):** randomized records against a behavioral
  DDRAM slave with busy/backpressure fuzzing — assert: no loss except counted drops
  (seq-exact), no reorder, correct wrap, seqlock header always coherent at any pull
  point, freeze drain exact. **Arbiter TB replays the three real fb patterns by
  name: 128×BURSTCNT=1 erase, BURSTCNT=128 line read (data return spread), and the
  shadow-RMW request-gap loop** — assert fb beats never split/reordered and the
  deadline model (DEADLINE_CYCLES, as in `s32_fb_ddr_model`) never trips.
- **Integration sim (restructured — v1's gate was unexecutable):**
  `tb_core_romboot` instantiates `s32_core`, not the emu top, and its DDR model
  covers only the 1 MiB FB (`s32_fb_ddr_model.sv`, FB_BASE=0). Phase C therefore
  includes TB-harness work: (a) the arbiter + fb_if + tracer DDR side get a shared
  wrapper module instantiable by both emu and TB; (b) run under
  `+define+S32_REAL_FB_SIM` with the model's array widened to also cover a
  sim-scaled `DDR_BASE`; (c) TB drives arm/freeze and dumps the ring
  (`$writememh`) for `trace_decode.py`. **Gate: decoded ring == the TB obj8 log
  after the TB tap is fixed to the same ack-edge qualification** (the TB fix and
  reference regeneration are part of this phase; "byte-identical to the legacy
  triplicated log" is dropped as self-contradictory). The hps_io `status[17]` path
  remains hardware-only-tested — stated, not hidden.
- **On-device self-test:** `TRACE_SELFTEST` emits a counting pattern; pull + decode
  must reproduce it exactly (validates address mapping + pull coherency in
  isolation) before any game capture.
- **First real capture:** ga2, obj8 window, freeze at the character-select window;
  diff vs a fresh MAME `trace_obj8.lua` run → first-divergence report.
- **Quartus:** timing closes at the same corners; macro-off build's DDR-path
  critical-path report unchanged; `debug_fb_underrun` before/after on device.

---

## 6. Phases

| Phase | Deliverable | Gate |
|---|---|---|
| **A** | DDR safe-region evidence (local sysmem audit + on-device read-only checks incl. dd/root/coherency probe, OSD/reload idle checks); `DDR_BASE/SIZE` pinned here | region confirmed free, outside System RAM, dd form verified |
| **B** | `mister_tracer/` IP + unit TBs (incl. named fb-pattern arbiter replays) green | all unit assertions pass under fuzzing |
| **C** | s32 integration (4 ifdef'd touch points) + TB harness work + ack-edge TB tap fix; integration sim parity | decoded ring == corrected TB log |
| **D** | Quartus build (`S32_TRACE=1`), on-device self-test, first ga2 obj8 capture + MAME diff report | self-test exact; underrun telemetry unchanged; a real hw-vs-MAME divergence report produced |
| **E** (later) | OSD-selectable tap windows; V25-side tap; port to a second core to prove the contract | — |

Out of scope (keeping it light): no MCP server, no MiSTer-Main/Linux daemon changes,
no continuous streaming, no V25 taps in v1.

## 7. Risks

| Risk | Mitigation |
|---|---|
| DDR region touched by Main at runtime (LFB_BASE is runtime-set) | Phase A checks across OSD/reload events; self-test pattern; header magic + seqlock detect clobbering |
| Arbiter perturbs the hard-deadline fb line fetch | write-only tracer, host-idle-≥M grant rule, host-busy hint; empirical gate = `debug_fb_underrun` unchanged in ga2 waterfall |
| Torn header/records on live pulls | seqlock header, per-record seq echo, frozen-pull-authoritative rule |
| Observation perturbs the (timing) bug | pure-listener taps, FIFO never back-pressures, drops counted |
| Ifdef'd path rots (real-V25 precedent) | CI lint/elab of `S32_TRACE=1` on every change |
| Quartus timing regression on DDR mux | registered arbiter outputs; macro-off netlist path identical; usual multicorner run |
| Per-window recompile cost | v1 window is a qsf parameter; Phase E moves it to OSD bits |

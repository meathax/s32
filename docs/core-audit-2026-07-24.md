# Sega System 32 MiSTer core audit — 2026-07-24

## Executive verdict

The current source has substantial directed and differential verification and
no source-level parse errors were found in the high-risk RTL blocks.  The
focused V60 suite passes 28/28, including the new Golden Axe II boss-health
division regression, and the latest ModelSim run passed tiers 1–7 before it
encountered a release-profile contract mismatch.

The current build is **not release-qualified or deployable**:

1. Quartus seed 6 misses setup timing by **-0.519 ns**, with a second core clock
   domain at **-0.306 ns** and design-wide setup TNS of **-9.768 ns**.
2. The active JPARK-only fit uses **37,631 / 41,910 ALMs (90%)** and
   **519 / 553 RAM blocks (94%)**, leaving little routing and memory margin.
3. The nominal 38-tier regression is blocked at tier 8 because it
   unconditionally demands the Holosseum release profile while the QSF is
   JPARK-only.
4. TimeQuest reports 91 unconstrained external-port paths.  All internal clocks
   are constrained, so this is not the cause of the core-clock setup failure,
   but it prevents clean interface-level timing sign-off.
5. The fitted database was produced by Quartus Lite 17.1, while the local
   `D:\Q` helper points to Quartus Standard 17.0.  That executable refuses to
   open the 17.1 database, preventing reproducible path-level STA locally.

No new production RTL was changed during this audit.  The correct immediate
work is to restore a profile-aware full regression and close timing before
deploying another RBF.

## Audited snapshot

- Repository: `D:\Arcade\AI\s32`
- Git HEAD: `62257c17f6789d4cb9e399c50e6722f5f065ff9a`
- HEAD subject: `Add CPU Turbo OSD option (x1-x4 V60/V70 clock-enable) ...`
- Worktree: dirty before this audit; all pre-existing user changes were
  preserved.
- Active QSF:
  - `S32_SYSTEM32_ONLY=1`
  - `S32_JPARK_ONLY=1`
  - no active `S32_REAL_V25`
  - fitter seed 6
  - high-performance optimization, physical combo optimization, duplication,
    retiming, and asynchronous-signal pipelining enabled
- Target: Cyclone V `5CSEBA6U23I7`
- QSF-recorded tool: Quartus Lite 17.1
- Actual seed-6 reports: Quartus Lite 17.1 build 590
- Local `D:\Q` executable: Quartus Standard 17.0 build 595
- MiSTer state observed through MisterClaw:
  - loaded core: `SSV_20260724`
  - game: `Dyna Gear.mra`
  - therefore no System 32 hardware claim was made during this audit

## Tool coverage and limitations

| Tool/service | Result | Audit use |
|---|---|---|
| PySlang MCP | High-risk blocks parsed and elaborated in an isolated read-only mirror. No semantic errors in V60, sprite, tilemap, mixer, palette, framebuffer, loader, or I/O groups. | Width, signedness, incomplete-case, hierarchy, and unresolved-reference audit. |
| Standalone Verible MCP | Default lint on 11 high-risk files returned zero violations. | Independent syntax/style check. |
| MCP4EDA Verible | Same 11-file lint set returned zero violations. | Second Verible endpoint; result agrees with standalone service. |
| Verilator MCP | Focused V60/boss-bar design compiled successfully with `-Wno-fatal`; the warning-fatal pass counted 76 warnings. | Independent elaboration of the CPU regression design. |
| Local Verilator regression | 28/28 V60 tests pass. | Strongest focused functional CPU evidence. |
| MCP4EDA Yosys | `yosys_analyze` failed twice and the natural-language endpoint also failed with `Transport closed`. | No valid Yosys synthesis result is claimed. |
| Standalone Yosys MCP | Not registered in the available MCP inventory. | The only registered Yosys service is MCP4EDA Yosys. |
| Local/WSL Yosys | No `yosys` executable found. | No fallback synthesis result is claimed. |
| MCP4EDA OpenLane | A self-contained palette synthesis attempt failed because the Docker Desktop Linux engine is unavailable. | No ASIC synthesis result is claimed. |
| MCP4EDA KLayout | No GDS/OASIS or foundry rule deck exists for this FPGA project. | Physical-layout DRC is not applicable to the RBF. |
| MCP4EDA AnySilicon | Endpoint proposed fabricated die/wafer defaults rather than FPGA-relevant evidence. | Die-per-wafer/yield calculations are not applicable to a pre-existing Cyclone V. |
| MCP4EDA supply-chain | Endpoint could not classify the FPGA/provenance query. | Local manifests and licenses were audited instead. |
| Standalone GTKWave MCP | Could not enumerate a valid textual VCD and its timing request hung. | Service result is unusable, not a clean waveform result. |
| MCP4EDA GTKWave | Returned `{}` for the same valid VCD. | Same limitation as standalone endpoint. |
| MisterClaw | Status worked; shell listing returned an unexpected response type. | Current loaded core/game established, but no remote file/hash audit. |
| Git MCP | Bound to a different repository (`Zombie Annihilation`) and rejected this path. | Native read-only Git commands were used instead. |
| Quartus reports | Map, fit, STA, resource, routing, and freshness reports are current for seed 6. | Authoritative FPGA implementation evidence. |

The MCP inventory also contains browser, asset, game-engine, audio, database,
and web tools.  They do not provide meaningful HDL, timing, CDC, or FPGA
implementation evidence and were intentionally not used to manufacture audit
coverage.

## Evidence from source analysis

### PySlang

Segmented analysis was required because the MCP cannot read the workspace ACL
directly and its combined 20-file project-summary call fails internally with
`AttributeError`.  The audited mirror contains the same RTL bytes.

| Block | Errors | Warnings | Main warning classes |
|---|---:|---:|---|
| V60 + bus | 0 | 70 | explicit truncation, expression width, signed shifts, exhaustive cases without `default` |
| Sprite | 0 | 8 | address-expression width and explicit zero-extension opportunities |
| Tilemap | 0 | 11 | array-index sizing and arithmetic truncation |
| Mixer | 0 | 15 | priority/group truncation and signed blend arithmetic |
| Palette | 0 | 0 | clean |
| Framebuffer interface | 0 | 1 | width conversion |
| ROM loader + package | 0 | 0 | clean |
| I/O design units | 0 | 12 | timer/address arithmetic widths |

Several incomplete-case warnings are false positives: the V60 condition-code
case covers all 16 values, stack-bank cases cover all four 2-bit values, and
the mixer cases cover all values of their selectors.  The most visible width
warnings are also range-safe by construction, for example:

- `modtop - 3'd4` is passed to a 2-bit displacement selector only when
  `modtop` is 4–6, yielding 0–2.
- double-displacement encoded lengths are six-bit expressions assigned to a
  five-bit length, but their legal maximum is far below 31.
- the sprite indirect-palette OR zero-extends a 12-bit expression into a
  16-bit table entry.
- mixer blend intermediates are wider than the mathematically reachable color
  range.

These should be made explicit for warning cleanliness, but this audit did not
find evidence that those specific conversions currently alter game behavior.

### Verible and Quartus synthesis warnings

Both Verible endpoints report zero default-rule violations on the selected
high-risk files.  Quartus still reports synthesis-specific warnings that
Verible does not model:

- explicit width truncations in top-level analog filtering, V60, tilemap,
  sprite, mixer, and JT12;
- array-index width warnings in V60 fetch-window, VRAM, tilemap, and mixer
  logic;
- conservative “may have unintended latch behavior” warnings for local
  variables in `automatic` V60 floating-point tasks;
- dual-clock read-during-write ambiguity in MiSTer framework scaler/shadow-mask
  memories;
- framework connectivity, unused-signal, and constant-propagation warnings.

The V60 task locals were checked manually.  The tasks are explicitly
`automatic`, outputs receive defaults, and each local is assigned before use
on its reachable branch.  The map report does not list a corresponding
inferred V60 storage latch.  This is warning debt, not a confirmed stale-state
defect.

## Functional verification

### Focused V60 suite

`scratch/v60_bossfix_suite.log` records:

- **28 passed, 0 failed**
- includes smoke, directed, fetch, self-modifying code, long EA, bus lanes,
  DIVX, flags, rotate, decimal, string, FP, Spider-Man XCH/window/gate, and
  `tb_v60_ga2_bossbar`
- includes the `/3` clock-enable smoke profile

### Full ModelSim regression

The latest run proves the following before stopping:

1. universal + System32-profile full-core lint: pass
2. V60 smoke: pass
3. V60 directed: pass
4. universal + System32-profile core boot: pass
5. independent V60 differential co-sim: **50/50 seeds pass**
6. extended multi-frame full-core soak: pass
7. audit-directed V60 groups, including boss-bar: pass

Tier 8 then executes `check_holo_release.py` unconditionally.  That script
requires `S32_HOLO_ONLY=1` and `S32_REAL_V25=1`, but the active QSF is
JPARK-only, so the runner stops before framebuffer, mixer, sprite, SDRAM,
interrupt, audio, MultiPCM, bus-decode, and production-V25 tiers.

The runner contains tiers 1–38 and emits `PASS (38/38 tiers)` at completion,
but `Write-Tier` still formats every heading as `/35`.  This is reporting drift,
not an RTL defect.

## Quartus implementation audit

### Seed 6 — current

- map: successful and current
- estimated map area: 38,133 ALMs; 57,603 combinational ALUTs
- fit: successful and current
- fitted area: 37,631 / 41,910 ALMs (90%)
- RAM: 519 / 553 blocks (94%)
- routing: 35% average, 63% peak
- worst setup slack: **-0.519 ns**
- second failing core clock: **-0.306 ns**
- design-wide setup TNS: **-9.768 ns**
- worst hold slack: positive, at least **+0.116 ns**
- RBF: current relative to the build reports
- repository classifier: **Deployable: False**

### Seed sweep

| Seed | Result |
|---:|---|
| 7 | Fit and assembler succeed; worst setup slack **-0.329 ns** |
| 5 | Quartus 17.1 crashes with an access violation during physical synthesis |
| 6 | Fit and assembler succeed; worst setup slack **-0.519 ns** |

Changing seeds changes placement/routing and therefore slack, but none of the
successful seeds closes timing.  More random seeds are not a substitute for
finding and reducing the actual failing logic/routing paths.

### Constraints

TimeQuest reports:

- 0 illegal clocks
- 0 unconstrained clocks
- 4 unconstrained input ports / 14 input paths
- 50 unconstrained output ports / 77 output paths

The unconstrained ports are principally MiSTer framework interfaces such as
HDMI I2C, HDMI parallel outputs, SDIO, user I/O, and LEDs.  They should receive
explicit board delays or deliberate false-path declarations.  Their presence
does not explain the negative register-to-register core-clock slack, but it
means “fully constrained” sign-off is currently false.

Several `sys_top.sdc` filters are stale for this fitted profile (`spi_sck`,
legacy composite-video signals, and absent scaler signals).  Quartus ignores
those filters and reports 14 STA warnings.  Profile-aware SDC guards would make
the intended omissions explicit.

## Findings

### AUD-001 — Critical: current RBF fails timing

The current RBF is fresh but non-deployable because two setup domains fail.
At 90% ALM and 94% RAM use, the fitter has limited freedom.  A mistimed FPGA can
fail intermittently with temperature, voltage, device variation, or different
placement even when a particular game appears to work.

Required action:

1. run path-level `report_timing` in the same Quartus Lite 17.1 environment
   that produced the fit;
2. group failing endpoints by hierarchy;
3. pipeline, duplicate, narrow, or floorplan the dominant path;
4. rerun at least three seeds only after the RTL/path fix;
5. require non-negative setup/hold at every corner before staging/deploying.

### AUD-002 — Critical: full regression is not runnable for the active profile

The regression’s unconditional Holo release contract stops a valid JPARK audit
at tier 8.  Only 7 of 38 tiers were reached in the latest run.  The already
proven earlier tiers are valuable, but they do not qualify the current
production profile.

Required action: make the release-contract tier accept an explicit profile
(`holo`, `ga2`, `jpark`, or universal), run the matching static MRA/QSF contract,
then continue all common tiers.  Keep profile-specific V25/gun/analog tests
conditional rather than terminating the entire common suite.

### AUD-003 — High: implementation is close to device limits

The JPARK-only profile consumes 90% of ALMs and 94% of RAM blocks.  The RAM
headroom is only 34 blocks.  This increases seed sensitivity and makes future
debug features, authentic peripherals, or timing pipelines harder to add.

Required action: generate hierarchy resource reports for V60, sprite, tilemap,
audio, framebuffer, and framework blocks.  Optimize the largest duplicated
mux/register networks and verify inferred memories before adding features.

### AUD-004 — High: Quartus environment is not reproducible locally

The current database is 17.1 Lite, the QSF records 17.1 Lite, but
`tools/build.bat` defaults to `D:\Q`, which contains 17.0 Standard.  TimeQuest
17.0 refuses to open the 17.1 database.  The audit therefore could not obtain
exact source/destination nodes for the -0.519 ns paths without risking a
database overwrite.

Required action: pin one supported Quartus 17.1 Lite Docker image or install
path, record its image digest/version, and have every build/report script
verify it before touching the database.

### AUD-005 — High: external interfaces are not fully constrained

TimeQuest’s 91 unconstrained external paths prevent interface-level sign-off.
Add board-appropriate delays where signals are synchronous and explicit
false-paths where they are truly asynchronous or framework-controlled.  Remove
or guard stale SDC object filters.

### AUD-006 — Medium: residual compatibility gaps are explicit in production RTL

These do not presently explain Golden Axe behavior, but they bound claims of
complete System 32/Multi 32 compatibility:

- V60 memory-to-memory `XCH` is marked rare and enters the one-register/
  one-memory `S_XCH2` write state without first performing the two reads
  described by the comment.  Register/register and register/memory forms are
  covered; memory/memory needs a directed regression and a real two-read/
  two-write sequence.
- i8255 mode-set writes are implemented, but bit-set/reset control words
  (`bit7=0`) are ignored.  Current targets treat port C as input, so impact is
  presently universal-build compatibility.
- interrupt-controller reads always return `0xFF`; readable timer counts remain
  a TODO.
- MultiPCM envelope, interpolation, and LFO behavior are documented bounded
  approximations, and its slot scheduler can droop under SDRAM latency.  This is
  Multi 32 accuracy risk, not JPARK/GA2 System 32 risk.
- Kokoroj SCSI/CXD support is explicitly a stub.
- US-set coin routing carries a documented possible double-count path until a
  board-descriptor region flag separates SERVICE12 from i8255 EXTRA3 routing.

### AUD-007 — Medium: synthesis-warning debt masks future defects

PySlang, Verilator, and Quartus all report width/sign/index warnings, although
the reviewed high-frequency examples are currently range-safe.  Leaving dozens
of warnings makes a newly introduced harmful truncation difficult to spot.

Required action: add explicit slices/casts and safe defaults, then maintain a
small reviewed waiver file for intentional tool-specific warnings.  Promote
new unwaived width, array-index, latch, multiple-driver, and CDC warnings to CI
failures.

### AUD-008 — Medium: no hardware acceptance was possible in this session

MisterClaw reports a different core (`SSV_20260724`) and game (`Dyna Gear`).
The shell endpoint failed, so the installed System 32 RBF name/hash could not
be re-established.  No gameplay, video, audio, thermal, or long-soak statement
is made for this audited source.

### AUD-009 — Low: waveform/tooling artifacts can mislead debugging

`scratch/tb_v60_flags.vcd` is 33,245 bytes of zeros.  A different capture,
`scratch/tb_v60_setf_wave.vcd`, is a valid textual VCD with full hierarchy.
Both GTKWave MCP services failed on the valid file, so their empty responses
must not be interpreted as “no transitions.”  Delete or clearly mark corrupt
captures and validate `$enddefinitions` before waveform analysis.

## Subsystem confidence

| Subsystem | Confidence | Basis / remaining risk |
|---|---|---|
| V60 integer core | High for covered System 32 paths | 28/28 focused tests, 50/50 differential seeds, long-EA/bus/string/division coverage. Rare memory-memory XCH remains suspect. |
| V60 floating point | Medium-high | Extensive directed tests and reviewed helpers; warning debt and documented host-dependent NaN/large-scale edge behavior remain. |
| V25/protection | Medium | Earlier production firmware/integration tiers exist, but the latest run did not reach them and active JPARK profile does not build real V25. |
| Sprite/tile/mixer/palette | Medium-high in simulation | Strong directed/differential history and clean parsing; latest run stopped before these tiers and current fit fails timing. |
| SDRAM/DDR/framebuffer | Medium | Directed protocol tests exist; latest common run stopped before them, and implementation is timing-sensitive. |
| System 32 audio | Medium-high | JT12/RF5C68/reset/mixer coverage exists; latest run stopped before audio tiers. |
| Multi 32 audio/video | Medium-low | MultiPCM is approximate and current QSF explicitly compiles a System32-only game profile. |
| I/O/peripherals | Medium | Major lane/timer/ADC/trackball fixes are covered historically; timer reads, i8255 BSR, US coin routing, and CD hardware remain incomplete. |
| FPGA release implementation | Low until timing closes | Fit succeeds, but setup fails and external ports are not fully constrained. |

## Recommended closure order

1. Make `run_regression.ps1` profile-aware and correct `/35` to `/38`.
2. Run and retain a complete 38/38 regression for the exact JPARK QSF defines.
3. Recreate the fit/report in pinned Quartus Lite 17.1 and emit the worst 25
   setup paths with hierarchy, source, destination, logic depth, and routing
   delay.
4. Fix the dominant timing path structurally; do not deploy a negative-slack
   RBF.
5. Add/waive every external-port constraint intentionally and reach a fully
   constrained TimeQuest report.
6. Repeat at least seeds 5–7 (or three stable seeds if one exposes a Quartus
   crash) and require all release gates to pass.
7. Add a directed memory-memory XCH test, timer-read tests, and i8255 BSR test
   before expanding compatibility claims.
8. Load the hash-qualified System 32 RBF on MiSTer, verify the reported core
   name/hash, then run cold-boot, attract, gameplay, audio, pause/resume, and
   multi-hour soak acceptance.

## Audit artifacts

- Quartus classifier: `tools/report-quartus.ps1`
- Current reports: `output_files/Arcade-SegaSystem32.{map,fit,sta}.rpt`
- Focused V60 evidence: `scratch/v60_bossfix_suite.log`
- Latest common regression evidence: `scratch/bossfix_full_regression.log`
- Seed logs:
  - `scratch/bossfix_quartus.log`
  - `scratch/bossfix_seed5_quartus.log`
  - `scratch/bossfix_seed6_quartus.log`
- Temporary TimeQuest script:
  `scratch/report_worst_paths.tcl` (cannot open the 17.1 database with local
  Quartus 17.0)

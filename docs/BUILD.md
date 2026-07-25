# Building the RBF

The core ships as source. Producing `SegaS32.rbf` requires Intel/Altera
Quartus — it cannot be built without the FPGA toolchain. The recommended path
is a local Docker build; native Quartus and CI remain available as fallbacks.

---

## Option A — Local Docker build on Windows (recommended)

Install Docker Desktop with its WSL2 backend, start it, then run from the repo
root:

```powershell
pwsh -File tools/build-docker.ps1
```

The script pulls the MiSTer-compatible Quartus Lite 17.0.2 container,
regenerates the PLL, compiles the project, qualifies the fitter/timing reports,
and only then stages `releases/SegaS32.rbf`. Docker and Quartus use all
processors available to the container; the project does not impose a processor
limit. After the first successful pull, use `-SkipPull` to start subsequent
builds immediately:

```powershell
pwsh -File tools/build-docker.ps1 -SkipPull
```

This path also avoids the TBB routing crash observed with the older native
Windows Quartus 17.0.0 build while keeping compilation on the local PC.

Summarize a completed build and reject anything that is not fit, timing-clean,
and backed by a current RBF with:

```powershell
pwsh -File tools/report-quartus.ps1
pwsh -File tools/report-quartus.ps1 -RequireReady
```

The checker deliberately ignores static-timing numbers from a failed fit and
also rejects a stale RBF left by an earlier run.

---

## Option B — CI (no local Quartus install)

A GitHub Actions workflow (`.github/workflows/build.yml`) compiles the core on
every push and uploads the `.rbf` as a build artifact.

1. Push to the branch (or open the Actions tab and run the workflow manually).
2. When the job finishes, download the **`SegaS32-rbf`** artifact from the run.
3. It contains `SegaS32.rbf`, already named for the MRAs.

The workflow reclaims unused SDK space on the disposable runner, then runs the
build in the community `raetro/quartus:17.0` container. The cleanup must happen
before Docker pulls the image because the image is larger than the free space
left on an unmodified hosted runner.

---

## Option C — Native Windows Quartus build

Set `QUARTUS_ROOT` to your Quartus installation, then run from the repository root:

```powershell
$env:QUARTUS_ROOT = 'C:\intelFPGA_lite\17.0'
.\tools\build.bat
```

`build.bat` regenerates the PLL, checks that Qsys emitted
`rtl\pll\synthesis\pll.qip`, compiles, and stages
`releases\SegaS32.rbf`. It fails instead of silently falling back if the
generated PLL is absent.

The checked-in `tools/make_pll.tcl` is the authoritative PLL definition:

- Cyclone V, 50 MHz reference, three outputs.
- requested `outclk0` = 96.648 MHz, `outclk1` = 48.324 MHz, and `outclk2` =
  96.648 MHz at -90 degrees for the SDRAM clock;
- Quartus 17 quantizes the generated clocks to approximately **96.634615 MHz**
  and **48.317307 MHz**, which is within the fractional-CE design tolerance;
- the generated Qsys wrapper ports are `refclk_clk`, `reset_reset`,
  `outclk0_clk`, `outclk1_clk`, `outclk2_clk`, and `locked_export`, matching
  `Arcade-SegaSystem32.sv`;
- `rtl/pll/pll.qip` includes the generated `synthesis/pll.qip`. The nearby
  `rtl/pll/pll.v` is a simulation placeholder only and must not be used for a
  hardware release.

If Qsys generation fails, run the two commands printed in
`tools/make_pll.tcl` directly and confirm that
`rtl/pll/synthesis/pll.qip` exists before starting compilation. A hand-made
GUI PLL is no longer the preferred path because wrapper export names differ
between generation modes.

---

## Option D — Local build (manual / other platforms)

### Prerequisites

- **Quartus Prime 17.0.2** with Cyclone V device support (the MiSTer-standard
  tool version). The checked-in CI path uses the community Lite image.
- ~8 GB RAM; a full compile is 20–60 minutes.

### Steps

1. Clone the repo and check out this branch.

2. **Regenerate the PLL IP** with the same scripted flow as CI:

   ```sh
   qsys-script --script=tools/make_pll.tcl
   qsys-generate rtl/pll/pll.qsys --synthesis=VERILOG \
     --output-directory=rtl/pll
   test -f rtl/pll/synthesis/pll.qip
   ```

   `files.qip` references `rtl/pll/pll.qip`, which in turn includes the
   generated synthesis QIP.

3. Open `Arcade-SegaSystem32.qpf`.

4. Processing → **Start Compilation** (`Ctrl+L`).

5. Output is `output_files/Arcade-SegaSystem32.rbf`. **Rename to `SegaS32.rbf`**
   (the MRAs reference `<rbf>SegaS32</rbf>`).

### Command line (headless)

```sh
# from the repo root after the Qsys commands above, with quartus_sh on PATH:
quartus_sh --flow compile Arcade-SegaSystem32
mkdir -p releases
cp output_files/Arcade-SegaSystem32.rbf releases/SegaS32.rbf
```

---

## Installing on the MiSTer

- `SegaS32.rbf` → `/media/fat/_Arcade/cores/`
- everything in `mra/` → `/media/fat/_Arcade/`
- game ROM zips → `/media/fat/games/mame/` (standard MAME set names:
  `ga2.zip`, `spidman.zip`, `svf.zip`, …). The MRA references each zip by name
  and validates the individual ROM CRCs.

Launch from the MiSTer `_Arcade` menu.

On Windows, a passwordless-SSH MiSTer can be updated with:

```powershell
pwsh -File tools/deploy-mister.ps1 -MisterHost root@<MISTER-IP>
```

The deployment script defaults to the Holosseum MRA. It first requires a
successful fit, non-negative reported timing slack, and a current matching
RBF, then uploads both files under temporary names. It checks SHA-256 hashes
on the MiSTer and only
atomically moves verified files into place. It never copies or modifies ROM
files. For a qualified build retained in an isolated directory, pass that
directory with `-ReportRoot` and its RBF with `-RbfPath`.

---

## Current build expectations

Quartus 17 compatibility and PLL-elaboration blockers found during the first
mapping passes have been fixed, including generated Qsys port names, source
ordering, a V60 identifier collision, simulation-only memory initialization,
hierarchical signal reach-through, and an enum-returning helper that crashed
the older Quartus frontend. The earlier ga2-only profile completed Analysis &
Synthesis at a **map-only estimate of 26,851 / 41,910 ALMs**. The checked-in
Holosseum profile must establish its own fit/timing report before deployment.

Before the V60 write-port refactor, seeds 5–7 all reached successful placement
but failed routing with 70–77% peak interconnect use. Seed 5 reported 39,851 /
41,910 fitted ALMs and 514 / 553 RAM blocks before failure. Consolidating every
architectural-register update into two masked write ports then reduced the map
estimate by 13,227 ALMs to 26,851 while retaining simultaneous writes and
byte/bit masks. The refactor passes all 25 regression tiers and 50/50
differential seeds. A new fit and timing result are still required.

The following release gates remain **open**:

- a complete Cyclone V fit with a generated `.rbf`;
- non-negative timing slack, especially in the approximately 96.635 MHz
  `clk_ram` domain;
- resource use from the Quartus fitter rather than module-level estimates;
- installation and gameplay validation on a DE10-Nano, including DDR3
  framebuffer backpressure and audio.

After any compile, run `tools/report-quartus.ps1 -RequireReady` and inspect
`output_files/*.fit.rpt` and `output_files/*.sta.rpt`; the mere presence of
an RBF is not a timing-closure claim. The current hardware target is
Holosseum; use the Round 19 evidence and open release gates in
`docs/audit.md` rather than inferring readiness from the map estimate.

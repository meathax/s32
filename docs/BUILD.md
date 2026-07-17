# Building the RBF

The core ships as source. Producing `SegaS32.rbf` requires Intel/Altera
Quartus — it cannot be built without the FPGA toolchain. There are two paths:
build locally, or let CI build it for you.

---

## Option A — CI (no local install)

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

## Option B — Local build on Windows (one command)

If Quartus is at `D:\Q` (set `QUARTUS_ROOT` otherwise):

```bat
cd <repo root>
tools\build.bat
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

## Option C — Local build (manual / other platforms)

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

---

## Current build expectations

Quartus 17 compatibility and PLL-elaboration blockers found during the first
mapping passes have been fixed, including generated Qsys port names, source
ordering, a V60 identifier collision, simulation-only memory initialization,
hierarchical signal reach-through, and an enum-returning helper that crashed
the older Quartus frontend. The ga2-only profile now completes Analysis &
Synthesis at a **map-only estimate of 40,434 / 41,910 ALMs**. This is not
evidence of a successful fit or timing closure.

The following release gates remain **open**:

- a complete Cyclone V fit with a generated `.rbf`;
- non-negative timing slack, especially in the approximately 96.635 MHz
  `clk_ram` domain;
- resource use from the Quartus fitter rather than module-level estimates;
- installation and gameplay validation on a DE10-Nano, including DDR3
  framebuffer backpressure and audio.

After any compile, inspect `output_files/*.fit.rpt` and
`output_files/*.sta.rpt`; the mere presence of an RBF is not a timing-closure
claim. The current first hardware target is ga2; use the evidence and open
release gates in `docs/ga2-readiness.md` rather than inferring readiness from
the map estimate.

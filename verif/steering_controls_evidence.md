# Driving steering input evidence record

This record covers the single-screen steering-input change for Slip Stream,
Rad Mobile, and Rad Rally.

## Decision record

Observation:

The target adapter accepted only left-stick X and D-pad fallback steering.
HPS paddle, dedicated spinner, and mouse-relative reports were not connected,
and new OSD controls had to remain hidden for unrelated games.

Evidence:

- KNOWN: sys/hps_io.sv defines paddle_0 as an 8-bit absolute value, spinner_0
  as an 8-bit delta plus event toggle, and ps2_mouse as an event-toggle packet.
- KNOWN: s32_core.sv exposes wheel_load_ch0 on the accepted MSM6253 channel-0
  load write.
- KNOWN: the shipped descriptor bytes select Slip Stream with
  digital_steering, Rad Mobile with DIGITAL_RADM, and Rad Rally with
  comm_link_hle; the current MRA inventory contains no other matching set.
- KNOWN: the donor adapter is the GPLv3 s32multi implementation at commit
  1e89f67005ae0eb11ae0622cb52e8214c78ed76e.
- INFERRED: those descriptor combinations are a stable gate for the current
  three driving MRA families.
- HYPOTHESIS: Low/Normal/High sensitivity should be half-scale, unity-scale,
  and double-scale around neutral, with saturation.

Hypotheses:

1. OSD-only changes cannot route a new input because the HPS ports are
   currently unconnected.
2. Spinner reports must be edge-detected from their toggles; level sampling
   would repeat or lose deltas.
3. Rad Mobile wheel state must advance on wheel_load_ch0, not on video timing,
   to preserve the firmware's signed sample-step window.
4. An unmasked OSD option would be visible for every title; the new options
   therefore use the h3 menu mask driven by the descriptor gate.

Selected explanation:

The missing functionality is at the HPS-to-driving-adapter boundary. The
adapter now selects analog stick, absolute paddle, or relative spinner/mouse
input, while the existing MSM6253-paced wheel slew remains the causal
Rad Mobile protection. The top-level status values are forced back to the
analog source and normal sensitivity whenever the descriptor is not one of
the three driving profiles.

Smallest change:

Only the driving adapter, single-screen HPS/OSD wiring, focused regressions,
README provenance/features, donor ledger, and this evidence record changed. No
framework, core decode, PLL, constraint, generated output, or MRA descriptor
byte changed.

Verification:

The focused adapter bench covers reset, paddle, analog-stick, spinner-toggle,
mouse-relative, reverse, low/normal/high sensitivity, sample pacing, and
digital fallbacks. Static contract coverage checks the HPS ports, menu mask,
and all shipped driving descriptors.

Observed results on 2026-08-28:

- PASS: verif/common/tb_driving_controls.sv with Icarus, including all new
  source, sensitivity, toggle, reverse, and sample-pacing checks.
- PASS: verif/tb_s32_driving_controls.sv with Icarus.
- PASS: verif/common/tb_radm_msm6253.sv with Icarus; the existing Rad Mobile
  MSM6253 channel and MSB-first read regression remains green.
- PASS: verif.test_driving_input_contract, 2 tests.
- PASS: strict headless Verilator adapter build and run with one runtime
  thread, timing, assertions, unique X handling, and no display backend.
- Remaining diagnostics are classified as benign: unused fields in the
  retained PS/2 packet register, unused testbench button bits, and the
  toolchain's STDOUT_FILENO/STDERR_FILENO macro redefinitions.
- NOT ACCEPTED as new failures: the existing driving profile contract still
  expects removed wheel_pending_valid/adc0_load symbols, and the existing MRA
  descriptor test still reports the pre-existing slipstrm descriptor-length
  failure. The MRA files were not changed.
- The broader verif.test_gen_mra suite was also run and returned 37 tests with
  10 failures and 1 error in existing metadata/regeneration checks. No MRA or
  generator file changed, so those worktree gaps are outside this steering
  change and are not used as its acceptance verdict.
- The optional FST-enabled Verilator build was unavailable because the
  installed UCRT64 environment lacks lz4.h; the acceptance run did not need
  runtime waveform output.

Regression scope:

Run the driving adapter bench, the duplicate focused bench, descriptor/profile
contract tests, MRA descriptor tests, and the existing ADC/MSM6253 regression.
No Quartus/RBF build is part of this request.

Known unknowns:

PCB wheel polarity, host report gain, preferred mouse axis, and real-MiSTer
hardware behavior remain unmeasured. The sensitivity transfer is an explicit
host-side implementation choice pending hardware validation.

## Provenance

The paddle/spinner/mouse event-handling structure is adapted from
meathax/s32multi commit
1e89f67005ae0eb11ae0622cb52e8214c78ed76e
([source file](https://github.com/meathax/s32multi/blob/1e89f67005ae0eb11ae0622cb52e8214c78ed76e/rtl/io/s32_driving_controls.sv)).
The donor project and this core are GPLv3; the target implementation remains
inside the project-owned adapter boundary.

## Source identities

- Target pre-change commit: `01fc184f7ea537707d3d87892d550a72e3b2c1f7`.
- Donor commit: `1e89f67005ae0eb11ae0622cb52e8214c78ed76e`.
- Working-tree SHA-256: `Arcade-SegaSystem32.sv`
  `E460AA06A941D9F75091A3CDDC00CBE444288E6BBE829A0EEB46656C2D872185`;
  `rtl/io/s32_driving_controls.sv`
  `0EB795C852A3D10D76F18BFB03F87A8C177BBED31776A1F452BE7707169A84B2`.

# releases/

Drop target for the built core, **`SegaS32.rbf`**.

This directory does **not** contain a prebuilt bitstream — an RBF is a
synthesized FPGA image and must be produced by Quartus (see
[../docs/BUILD.md](../docs/BUILD.md)). It is intentionally not committed as a
binary blob.

How an RBF gets here / to the Releases page:

- **CI (recommended):** `.github/workflows/build.yml` compiles the core and
  uploads `SegaS32.rbf` as a build artifact on every run. Pushing a version
  tag (`git tag v0.1.0 && git push --tags`) additionally publishes it as a
  **GitHub Release asset**.
- **Local build:** `quartus_sh --flow compile Arcade-SegaSystem32`, then
  `cp output_files/Arcade-SegaSystem32.rbf releases/SegaS32.rbf`.

`SegaS32.rbf` is git-ignored so local builds don't accidentally commit a
multi-megabyte binary; distribute it through Releases instead.

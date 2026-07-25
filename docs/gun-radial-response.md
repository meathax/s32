# Gun radial-response archive

The Alien3 / Jurassic Park gun radial-response experiment was removed from the live
core on 2026-07-25 at the user's request. The live implementation is back to the
stable per-axis inversion, deadzone, and IIR filter.

The removed implementation—including the Quartus-friendly reciprocal approximation
used during the resource-fit investigation—is preserved at:

- `scratch/alien3-jurassic-park-gun-radial-response.backup.sv`

It is not referenced by `Arcade-SegaSystem32.qsf` and is not synthesized. To
restore it later, replace the live analog-aim block in
`Arcade-SegaSystem32.sv` with the archived block and reintroduce the gun-profile
target/filter branches shown in the backup.

No RBF was built after this removal; rebuilding remains intentionally deferred
until explicitly requested.

# Donor compatibility record

This directory contains only verification references. Nothing here is
instantiated by the production `segas32` profile.

| ID | Source and pinned revision | License | Use in this repository | Verdict |
|---|---|---|---|---|
| D001 | [jotego/jt8255](https://github.com/jotego/jt8255/tree/3bb5f7ea461fc7d72b847ec55ce997e5d5bc1754), `3bb5f7ea461fc7d72b847ec55ce997e5d5bc1754` | MIT | `jt8255.v` is retained verbatim as the Intel 8255 comparison model; `LICENSE.jt8255` is retained | Structurally shared; reverified by `tb_i8255_conformance` |
| D002 | [jotego/jtcores](https://github.com/jotego/jtcores/tree/1268a90e365c2520b412f224ae30d20c61aa0031), `1268a90e365c2520b412f224ae30d20c61aa0031` | GPL-3.0-or-later | `jts18_io` was inspected as a 315-5296 reference only | Rejected for copying: System 18 register map is not System 32 |
| D003 | [MiSTer-devel/Arcade-IremM92_MiSTer](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer/tree/68a4683e237eafca02e3df56dd84bacc255fba55), `68a4683e237eafca02e3df56dd84bacc255fba55` | GPL-2.0 | MiSTer integration/reference patterns only | No System 32 chip RTL imported |
| D004 | [rmonic79/MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust/tree/c682de9f4acc61d8f4c7779efb48149d3baa3a8e), `c682de9f4acc61d8f4c7779efb48149d3baa3a8e` | GPL-3.0-or-later | `rtl/crt_adjust.sv`, core-side analog geometry stage; project glue in `Arcade-SegaSystem32.sv` | Imported and integrated; HDMI/scandoubler safety gates are core-specific |
| D005 | [jotego/jtcores](https://github.com/jotego/jtcores/tree/c990f843c7bd8eaf26179a0632bac1436cc05b52), `c990f843c7bd8eaf26179a0632bac1436cc05b52`; [jlrh/taito-fpga](https://github.com/jlrh/taito-fpga/tree/405a68eac741918e627cda563cc1a0c219ed18fd), `405a68eac741918e627cda563cc1a0c219ed18fd` | GPL-3.0-or-later | JTFRAME-compatible host contract and Operation Wolf core-side gun wiring were inspected; `s32_lightgun.sv` and `s32_lightgun_overlay.sv` are project-owned implementations | Adapted interface semantics only; no upstream RTL copied |

The upstream JT8255 source hash is
`208f61e0e39ad8c468b2bba69fd04b26e6ad6bdc047b811af7cf64107d883b67`.
The local file hash is
`451e71e8a4863218ed318669372d131bb21b37838729529aa0cabdbab415e08a`; the
only difference is a final newline added by the repository patch workflow.

No compatible open RTL was found for Jurassic Park's drive board, EPR-14084,
or the remaining System 32 protection devices. Those remain evidence-led
implementation tasks; no excluded Multi 32, Air Rescue, F1 Exhaust Note, CD,
or AS-1 hardware is introduced here.

## D004 import details

The upstream `rtl/crt_adjust.sv` SHA-256 is
`E66C4BAE75CA86606C134FA82E57F63274331422A2C8931188495DFEAC5AFC21`.
The retained project file SHA-256 is
`9B4D2832F3F4DF932063C87D7CD920A97940F4DB85AC4F7F9D7D822ED9E07A44`.
The local difference is limited to exposing the existing AW=10 storage width
as a parameter and documenting the measured Cyclone V memory cost; the default
hardware behavior remains AW=10. The upstream source header and GPL-3 notice
remain in the file. The project uses only the core-side module; the upstream
sys-side and experimental V-Size variants are not compiled or imported.

## Evidence-gated gaps

- Jurassic Park's MAME `init_jpark` patch is retained at main-ROM offset
  `0xC15A8` (`70 CD CD D8`). MAME includes an unused `cpu2`/`epr-13908`
  movement ROM, but does not define its clock, reset, memory map, I/O, sensor,
  or piston-output contract. A guessed second Z80 would therefore be a new
  hardware design, not donor reuse.
- EPR-14084 is retained as an isolated firmware/bus laboratory. The verified
  first firmware transaction is `OUT (60h),00h`; ports `00-2F`, `40`, and `60`
  have no proven device semantics or timing. The production Rad Rally path
  consequently keeps the MAME communication HLE authoritative.
- Sonic, Dark Edge, and Burning Rival HLEs have focused MAME-contract tests
  and are software-visible behavioral matches. Native replacement of V25,
  315-5296/uPD4701, palette DAC, or analogue behaviour remains blocked until
  accepted/completed bus events and PCB-level timing are captured. No
  test-only trace is treated as hardware equivalence.

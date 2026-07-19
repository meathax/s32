# MAME System 32 reference snapshot

The authoritative behavioral reference for this core is the official MAME
repository at commit `a8c5e5346af728a35269a6ecd50c8e4a8df59b0b` (master HEAD
recorded 2026-07-19).

The source snapshot is stored under ignored
`scratch/upstream/mame-master-20260719/`, preserving the upstream directory
layout and BSD-3-Clause source headers. The user-supplied
`D:/Downloads/segas32.cpp` is byte-identical to the downloaded official file:
SHA-256 `DB9E1752BF512AB3040CF4AC58F40A89E5BF159ABCFBA95CD4598D3FA11E89AF`.

| Upstream file | SHA-256 | Core use |
| --- | --- | --- |
| `src/mame/sega/segas32.cpp` | `DB9E1752BF512AB3040CF4AC58F40A89E5BF159ABCFBA95CD4598D3FA11E89AF` | board maps, clocks, ROM layouts, initialization |
| `src/mame/sega/segas32.h` | `0426255C590FBA756D9C1F49812E7AF6AD39DA9A47EA5A3A435BD9B8814B7D09` | device state and video/protection interfaces |
| `src/mame/sega/segas32_v.cpp` | `A16798DC281DC12460DBF32FF1E513AFB0BE897B473D9EBB820297388B939E6F` | tile, sprite, mixer, clipping, zoom, priority, shadow |
| `src/mame/sega/segas32_m.cpp` | `8F36D091F564F337C6F9C5EAAFD2A69F9B33EEC49DB7445BAB30106E66D4DC6C` | V25 opcode tables and protection behavior |
| `src/devices/cpu/v60/v60.cpp` | `1B37FFD25C36478CCFB95F4AB80F814B9E75B8BF671793FAEDAEE218193BB087` | V60 architectural and interrupt behavior |
| `src/devices/cpu/v60/v60.h` | `D043902C9E15F223901322EEE302DB6E47FC3587F1D7E2B9751D952377EA2B0D` | V60 public configuration/state contract |
| `src/devices/sound/multipcm.cpp` | `62C322D8CB97B7970D7E0E2F99CA36B9D034089B97DF3DCDD79C05FD4B204990` | MultiPCM register, envelope, pitch, loop, pan behavior |
| `src/devices/sound/multipcm.h` | `73738F097E6A775847679DF5131162385D8DB9279214A4B36CF89B3718688968` | MultiPCM state and interface contract |

MAME is used as the observable behavior contract. Emulator scheduling and
software-rendering structures are not copied blindly into FPGA RTL. For each
adopted correction, the workflow is:

1. identify the exact MAME behavior and board address/bit meaning;
2. reproduce a mismatch in a focused RTL test;
3. implement the hardware-equivalent bounded behavior;
4. retain the test as a regression; and
5. record any intentional approximation, especially timing or analog audio.

The first correction from this snapshot was the V25 address descramble. MAME
defines `descrambled[dst] = raw[bitswap(dst)]`; the streaming loader therefore
must write `inverse_bitswap(source)`. The old forward mapping placed `00` at
the MCU reset vector. The corrected mapping sends Golden Axe raw source
`0xFDDC` (`0x02`, encrypted far-jump opcode) to destination `0xFFF0`, and the
real firmware now passes wake-string, response-table, and stack-state tests.

# V25-compatible CPU core evaluation

## Outcome

The preferred execution-core prototype for Golden Axe is Jamie Iles'
**s80x86** (`jamieiles/80x86`), audited at commit
`a12778b40ae905f82eb2c23ea4ac037f98099fae`.

It is a complete synthesizable 80186-compatible SystemVerilog CPU, has been
implemented on Intel Cyclone V, and reports a footprint of about 1,800 ALMs.
The source is GPL-3.0. The ignored research checkout is
`scratch/upstream/s80x86`; no GPL RTL has been copied into tracked source.

## Why the real MCU is now required

The current `s32_v25` HLE supplies a wake-up string and static result table.
That is enough for Golden Axe to boot and enter gameplay, but hardware testing
shows missing character-select sprites, malformed fragments, broken
enemy/damage state, and repeatable loss of ordinary sprites after the magic
attack while the V60, scrolling, controls, music, and sound continue.

The same malformed character-select output occurs in full-core simulation,
where the game emits only four sprite commands. MAME emits 23 valid commands
for the equivalent screen, and the production sprite walker processes that
correct list comfortably within one frame. This locates the defect upstream of
sprite-rendering throughput and is consistent with missing dynamic protection
MCU processing.

## Golden Axe firmware compatibility

The local 64 KB MCU image was address-descrambled with MAME's documented
permutation:

`bitswap<16>(i, 14,11,15,12,13,4,3,7,5,10,2,8,9,6,1,0)`

After applying MAME's Golden Axe opcode table, the reset vector decodes to
`EA 0000 0000`, a standard far jump to `0000:0000`. Every populated entry in
the published Golden Axe table is a standard 8086/80186 opcode. No NEC-only
V20/V25 instruction has been found in the known opcode set, so an
80186-compatible execution engine is a credible fit.

## Required integration changes

Golden Axe decrypts only bytes consumed as opcodes. ModRM, displacement, and
immediate bytes remain raw. A prefetch bus contains all of these byte types, so
applying the table to every instruction-bus read would be incorrect.

The s80x86 `InsnDecoder` has an explicit `STATE_OPCODE`. The smallest correct
port inserts the selected `ga2`/`arf` translation at that decoder boundary and
uses the translated byte for prefix recognition, instruction lookup, and the
latched opcode. Other decoder states continue consuming unmodified FIFO data.

The System 32 wrapper must also provide:

- the 10 MHz MCU clock enable;
- 64 KB ROM mirrored at physical `0x00000` and `0xf0000`;
- raw ROM data reads but opcode-only translation in the decoder;
- MB8421 DPRAM at physical `0x10000-0x1ffff`, mirrored onto 2 KB;
- 8-bit accesses adapted to the CPU's 16-bit byte-enable bus;
- safe inactive responses for unused I/O/internal peripherals unless firmware
  tracing proves that a specific V25 register is required.

The first acceptance test is firmware-driven: without any HLE mailbox writes,
the MCU must boot from `0xffff0`, write the genuine Golden Axe wake-up string
to DPRAM, and then respond to captured command sequences with MAME-equivalent
mailbox contents.

## Other candidates

### WonderSwan MiSTer V30MZ

`MiSTer-devel/WonderSwan_MiSTer`, audited at
`8f7a4d670b4635eda0e518e7fd9a17ef8610db79`, is GPL-2.0 and proven on MiSTer.
Its VHDL CPU is tightly coupled to WonderSwan packages, register buses, DMA,
timing, and save-state infrastructure. Its combined bus also makes
opcode-only decryption more invasive. It remains the fallback behavioral
reference rather than the preferred port.

### z8086

`nand2mario/z8086` is Apache-2.0 and therefore easier to redistribute, but it
is an 8086 implementation rather than a complete 80186 core. That ISA gap is
an unnecessary firmware-compatibility risk for this project.

## Licensing decision

GPL-3.0 adoption for the combined System 32 core was explicitly approved on
2026-07-19. The repository now carries the GPL-3.0 license and the audited
s80x86 source, generator inputs, generated instruction/microcode artifacts,
and attribution are vendored under `rtl/cpu/v25/s80x86/`.

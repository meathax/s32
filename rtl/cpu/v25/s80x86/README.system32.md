# s80x86 in the Sega System 32 core

This directory vendors the synthesizable portion of Jamie Iles' **s80x86**
CPU core for use as the instruction engine behind the NEC V25 compatibility
wrapper.

## Provenance and license

- Upstream: <https://github.com/jamieiles/80x86>
- Upstream commit: `a12778b40ae905f82eb2c23ea4ac037f98099fae`
- Upstream name: S80186 / s80x86
- License: GNU General Public License v3.0 or later
- License text: `COPYING` in this directory

The selected upstream RTL, generator sources, templates, microprogram source,
and instruction-description source are included.  This is enough corresponding
source to modify and regenerate the CPU artifacts used by this project.  The
upstream simulation framework, reference PC/FPGA systems, software tests, BIOS,
and documentation build are not used by the System 32 integration and are not
vendored here.

All selected upstream source files were byte-identical to the commit above when
first imported.  System 32-specific changes made after import remain covered by
the same GPL license and are recorded by this repository's history.

## Directory layout

- `rtl/`: upstream synthesizable CPU RTL and generator templates
- `rtl/alu/`: upstream ALU RTL
- `rtl/microcode/`: preferred-source microprograms and templates
- `documentation/instructions.yaml`: preferred-source instruction table
- `scripts/`: the instruction-definition generator and microassembler
- `generated/`: checked-in artifacts consumed by synthesis and simulation

Only the RTL listed by `s80x86_files.qip` is required to instantiate `Core`.
The upstream `MemArbiter.sv` and `rtl/cdc/` files belong to upstream reference
systems and are intentionally omitted because the System 32 V25 wrapper supplies
its own bus adaptation and clocking.

## Generated artifacts

The checked-in artifacts were regenerated at the pinned commit and compared
byte-for-byte with the upstream build output:

| File | SHA-256 |
| --- | --- |
| `InstructionDefinitions.sv` | `642a3bd0d16287cd646283a565611efe57501b02881a8bae860397bc16927683` |
| `Microcode.sv` | `e555d84fdb7c80268b0f08b5e95e7b18cd745653828e1d73f31a65d60c0761b3` |
| `MicrocodeTypes.sv` | `bd962600c15f5b94e248cae19a7700118f1614e39bb3d036c08c900edc421fc4` |
| `microcode.bin` | `243e3c78e0390153e5b0a6dd36c5a941a91038992b6fd09b1182c5df9c6dc7d7` |
| `microcode.mif` | `6df29dfb8a230620ac76924140a6acbecdec343c5de5442db13f4789967c2613` |

`microcode.bin` and `microcode.mif` contain the same 1,196-entry microprogram
in formats used by simulation and Quartus respectively.  They are source-build
outputs, not ROMs from the arcade game.

## Regenerating in WSL/Linux

The original generators require Python 3, the C preprocessor executable `cpp`,
PyYAML, Pystache, and textX 1.6.1.  The pinned upstream output was made with
Pystache 0.6.8 and textX 1.6.1.  Newer textX releases are not assumed compatible
with the old grammar API.

Run the following from this directory.  Keep the microprogram ordering exactly
as listed in upstream `rtl/microcode/CMakeLists.txt`; ordering changes generated
microcode addresses.

```sh
python3 -m venv .gen-venv
. .gen-venv/bin/activate
python -m pip install 'pystache==0.6.8' 'textX==1.6.1' PyYAML

tmpdir="$(mktemp -d)"
printf '%s\n' \
  '#pragma once' \
  '#define S80X86_TRAP_ESCAPE 0' \
  '#define S80X86_PSEUDO_286 0' > "$tmpdir/config.h"

python scripts/gen-instructions-functions \
  "$tmpdir/InstructionDefinitions.sv"

python scripts/microassembler/uasm -I"$tmpdir" \
  "$tmpdir/microcode.bin" \
  "$tmpdir/microcode.mif" \
  "$tmpdir/Microcode.sv" \
  "$tmpdir/MicrocodeTypes.sv" \
  "$tmpdir/MicrocodeTypes.h" \
  rtl/microcode/{aaa,aad,aas,adc,add,and,bound,daa,das,arithmetic,call,comparison,cmp,cmps,div,enter,esc,extend,flags,hlt,inc,int,io,jmp,lds,lea,leave,les,lods,loop,mov,movs,mul,neg,not,or,pop,push,rcl,rcr,ret,rol,ror,sar,sbb,scas,shift,shl,shr,stos,sub,test,xchg,xlat,xor,wait,microcode,debug}.us

cmp generated/InstructionDefinitions.sv "$tmpdir/InstructionDefinitions.sv"
cmp generated/Microcode.sv "$tmpdir/Microcode.sv"
cmp generated/MicrocodeTypes.sv "$tmpdir/MicrocodeTypes.sv"
cmp generated/microcode.bin "$tmpdir/microcode.bin"
cmp generated/microcode.mif "$tmpdir/microcode.mif"
```

Copy the five compared outputs into `generated/` only after reviewing an
intentional source change.  `MicrocodeTypes.h` is emitted for upstream's C++
simulator and is not used or checked into this RTL-only integration.

There is currently an unnecessary duplicate copy of
`scripts/gen-instructions-functions` under `scripts/microassembler/`.  It is not
referenced by the regeneration procedure or build manifest.

## Quartus and simulator path requirements

Include `s80x86_files.qip` from the top-level Quartus file list.  It preserves
the compilation order required by compilation-unit typedefs and adds both the
microcode MIF and its containing directory to Quartus.  Quartus must report the
MIF as used; a build warning that `microcode.mif` cannot be found is fatal to CPU
correctness even if analysis and synthesis otherwise succeed.

`generated/Microcode.sv` initializes simulation with:

```systemverilog
$readmemb({{`MICROCODE_ROM_PATH, "/microcode.bin"}}, mem);
```

Therefore ModelSim, Icarus, and Verilator runs must either:

1. run with `generated/` as their working directory, or
2. define `MICROCODE_ROM_PATH` at compilation to the absolute or working-
   directory-relative `generated` path.

For example, from the repository root with Icarus:

```sh
iverilog -g2012 \
  '-DMICROCODE_ROM_PATH="rtl/cpu/v25/s80x86/generated"' \
  ...
```

The macro affects simulation only.  Quartus uses the `ram_init_file` attribute
and the MIF assignment/search path in the QIP.

## Integration cautions

- The System 32 port adds a synchronous `ce` input to every stateful module and
  to both the Microcode template and generated artifact. The wrapper uses the
  fractional ratio 5001/12081 for a 10.000614 MHz average rate from the
  generated 24.158653 MHz V25 compute clock. No enable pulse is connected to a clock pin, and bus ACKs remain
  asserted across skipped cycles until a CE edge consumes them.
- The upstream core exposes a unified data/I/O transaction interface with
  `d_io` indicating I/O space, plus a separate instruction bus.  The separate
  instruction bus is useful for V25 opcode decryption, but opcode decryption
  must occur at the instruction decoder boundary so immediate/displacement
  bytes remain raw.
- The generated SystemVerilog uses compilation-unit typedefs rather than a
  package.  Preserve the QIP order in standalone simulator command lines.
- Module names such as `Core`, `ALU`, and `Microcode` are generic.  Confirm they
  do not collide with another core in any monolithic verification build.
- The CPU is 80186-compatible, not a complete NEC V25 peripheral model.  The
  System 32 wrapper remains responsible for V25 memory mirroring, internal I/O
  behavior required by the firmware, interrupts, clock rate, and dual-port RAM.


#!/usr/bin/env python3
"""
MRA generator for the Sega System 32 / Multi 32 MiSTer core.

Parses MAME's segas32.cpp (ROM_START blocks + GAME macros) and emits one
.mra per supported set, laying out the ioctl stream per DESIGN.md §9.3:

  index 0: [64B board descriptor][maincpu 2MB][soundcpu 4MB][tiles 4MB]
           [multipcm 4MB][mcu 64KB][sprites 16MB]
  index 2: eeprom default image (128B), when the set provides one

Region padding/interleave is derived from the ROM_LOAD macros:
  ROM_LOAD                → linear
  ROM_LOAD16_BYTE         → interleave 2, map 01/10
  ROM_LOAD32_WORD         → interleave 4, two words
  ROM_LOAD32_BYTE         → interleave 4, map per offset&3
  ROM_LOAD_x2/_x4         → repeat each byte group (handled as repeats)
  ROM_LOAD16_WORD         → linear 16-bit

Usage: gen_mra.py <path-to-segas32.cpp> <outdir>
"""

import re, sys, os, textwrap
from html import escape

REGION_SIZES = {
    "maincpu":  0x200000,
    "soundcpu": 0x400000,
    "tiles":    0x400000,
    "sega":     0x400000,   # multipcm
    "mcu":      0x010000,
    "sprites":  0x1000000,
}
STREAM_ORDER = ["maincpu", "soundcpu", "tiles", "sega", "mcu", "sprites"]

# board descriptor per parent (DESIGN.md §3.4):
#   b0: flags {multi32,v25,v25table,adc,track,ppi,dsp_hle,cd_stub}
#   b1: {dual_pcb}
#   b2: prot_sel
PROT = dict(NONE=0, SONIC=1, BRIVAL=2, DARKEDGE=3, F1LAP=4, DBZVRVS=5, JLEAGUE=6)
def desc(multi32=0, v25=0, v25table=0, adc=0, track=0, ppi=0, dsp=0, cd=0,
         dual=0, prot=0):
    b0 = (multi32 | v25 << 1 | v25table << 2 | adc << 3 | track << 4 |
          ppi << 5 | dsp << 6 | cd << 7)
    d = bytes([b0, dual, prot]) + bytes(61)
    return d

GAMES = {
    # parent: (descriptor, per-set list built from clones automatically)
    "arescue":  desc(adc=1, dsp=1, dual=1),
    "alien3":   desc(adc=1),
    "arabfgt":  desc(v25=1, v25table=1, ppi=1),
    "brival":   desc(ppi=1, prot=PROT["BRIVAL"]),
    "darkedge": desc(ppi=1, prot=PROT["DARKEDGE"]),
    "dbzvrvs":  desc(adc=1, prot=PROT["DBZVRVS"]),
    "f1en":     desc(adc=1, dual=1),
    "f1lap":    desc(adc=1, prot=PROT["F1LAP"]),
    "ga2":      desc(v25=1, v25table=0, ppi=1),
    "holo":     desc(),
    "jpark":    desc(adc=1),
    "kokoroj":  desc(cd=1),
    "kokoroj2": desc(cd=1),
    "radm":     desc(adc=1),
    "radr":     desc(adc=1),
    "slipstrm": desc(adc=1),
    "sonic":    desc(track=1, prot=PROT["SONIC"]),
    "sonicp":   desc(track=1),
    "spidman":  desc(ppi=1),
    "svf":      desc(),
    "jleague":  desc(prot=PROT["JLEAGUE"]),
    "harddunk": desc(multi32=1, ppi=1),
    "orunners": desc(multi32=1, adc=1),
    "scross":   desc(multi32=1, adc=1),
    "titlef":   desc(multi32=1),
}
UNSUPPORTED = {"as1", "as1a", "as1b", "as1c"}

def parse(src):
    """Return {setname: {'regions': [(region, size, loads)], 'title', 'parent'}}"""
    sets = {}
    # ROM_START blocks
    for m in re.finditer(r"ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END", src, re.S):
        name, body = m.group(1), m.group(2)
        regions = []
        cur = None
        for line in body.splitlines():
            rm = re.search(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([\w:]+)"', line)
            if rm:
                # strip the mainpcb: prefix; keep other prefixes (subpcb:) as
                # distinct names so their loads never leak into the previous
                # region (they are intentionally not part of the stream — the
                # dual-PCB sub board is an HLE responder in the RTL)
                rname = rm.group(2)
                rname = rname[8:] if rname.startswith("mainpcb:") else rname.replace(":", "_")
                cur = {"region": rname, "size": int(rm.group(1), 16), "loads": []}
                regions.append(cur)
                continue
            lm = re.search(
                r'(ROM_LOAD(?:16_BYTE(?:_x2|_x4)?|16_WORD|32_WORD(?:_x2|_x4)?|32_BYTE|64_BYTE|64_WORD|_x2|_x4|_x8|_x16)?)\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)\s*SHA1\(([0-9a-fA-F]+)\)',
                line)
            if lm and cur is not None:
                cur["loads"].append(dict(
                    macro=lm.group(1), file=lm.group(2),
                    offset=int(lm.group(3), 16), size=int(lm.group(4), 16),
                    crc=lm.group(5)))
        sets[name] = {"regions": regions}
    # GAME macros for titles/parents
    for m in re.finditer(
            r'^GAMEL?\(\s*(\d+),\s*(\w+),\s*(\w+),\s*[\w]+,\s*\w+,\s*\w+,\s*init_\w+,\s*[\w_]+,\s*"([^"]*)",\s*"([^"]*)"',
            src, re.M):
        year, name, parent, manu, title = m.groups()
        if name in sets:
            sets[name].update(year=year, parent=parent if parent != "0" else "",
                              manu=manu, title=title)
    return sets

def macro_base_rep(mac):
    """Split a ROM_LOAD macro into its base form and repeat count."""
    m = re.match(r"(.*?)(_x(2|4|8|16))?$", mac)
    base = m.group(1)
    rep = int(m.group(3)) if m.group(3) else 1
    # plain ROM_LOAD_xN parses as base "ROM_LOAD"
    return base, rep

def interleave_parts(loads, region_size, ctx=""):
    """Emit MRA <part> XML for a region's loads, padded to region_size.
    Every load must be consumed and the emitted bytes tracked by a cursor —
    silent drops previously left ga2 without its second program megabyte,
    its Z80 program, and all sprite data."""
    out = []
    cursor = 0
    i = 0
    loads = sorted(loads, key=lambda l: l["offset"])

    def pad_to(off):
        nonlocal cursor
        assert off >= cursor, f"{ctx}: overlapping loads at 0x{off:x}"
        if off > cursor:
            out.append(f'    <part repeat="{off - cursor}">FF</part>')
            cursor = off

    while i < len(loads):
        l = loads[i]
        base, rep = macro_base_rep(l["macro"])
        if base == "ROM_LOAD16_BYTE":
            pair = loads[i:i+2]
            assert len(pair) == 2 and pair[1]["offset"] == pair[0]["offset"] + 1, \
                f"{ctx}: unpaired ROM_LOAD16_BYTE {l['file']}"
            pad_to(pair[0]["offset"])
            block = ['    <interleave output="16">',
                     f'      <part name="{escape(pair[0]["file"])}" crc="{pair[0]["crc"]}" map="01"/>',
                     f'      <part name="{escape(pair[1]["file"])}" crc="{pair[1]["crc"]}" map="10"/>',
                     '    </interleave>']
            for _ in range(rep):
                out.extend(block)
            cursor += rep * (pair[0]["size"] + pair[1]["size"])
            i += 2
            continue
        if base == "ROM_LOAD32_WORD":
            pair = loads[i:i+2]
            assert len(pair) == 2 and pair[1]["offset"] == pair[0]["offset"] + 2, \
                f"{ctx}: unpaired ROM_LOAD32_WORD {l['file']}"
            pad_to(pair[0]["offset"])
            # each part is a 16-bit word per 32-bit group: map digits name the
            # part's 1st/2nd byte, lanes read right-to-left
            block = ['    <interleave output="32">',
                     f'      <part name="{escape(pair[0]["file"])}" crc="{pair[0]["crc"]}" map="0021"/>',
                     f'      <part name="{escape(pair[1]["file"])}" crc="{pair[1]["crc"]}" map="2100"/>',
                     '    </interleave>']
            for _ in range(rep):
                out.extend(block)
            cursor += rep * (pair[0]["size"] + pair[1]["size"])
            i += 2
            continue
        if base == "ROM_LOAD64_WORD":
            grp = loads[i:i+4]
            assert len(grp) == 4 and all(
                grp[k]["offset"] == grp[0]["offset"] + 2*k for k in range(4)), \
                f"{ctx}: bad ROM_LOAD64_WORD group at {l['file']}"
            pad_to(grp[0]["offset"])
            out.append('    <interleave output="64">')
            for k, g in enumerate(grp):
                lanes = ["00"] * 4
                lanes[k] = "21"
                out.append(f'      <part name="{escape(g["file"])}" crc="{g["crc"]}" map="{"".join(reversed(lanes))}"/>')
            out.append('    </interleave>')
            cursor += sum(g["size"] for g in grp)
            i += 4
            continue
        if base in ("ROM_LOAD32_BYTE", "ROM_LOAD64_BYTE"):
            n = 4 if base == "ROM_LOAD32_BYTE" else 8
            grp = loads[i:i+n]
            assert len(grp) == n, f"{ctx}: short {base} group at {l['file']}"
            pad_to(grp[0]["offset"])
            out.append(f'    <interleave output="{n*8}">')
            for k, g in enumerate(grp):
                mp = "".join("1" if j == k else "0" for j in range(n))[::-1]
                out.append(f'      <part name="{escape(g["file"])}" crc="{g["crc"]}" map="{mp}"/>')
            out.append('    </interleave>')
            cursor += sum(g["size"] for g in grp)
            i += n
            continue
        # plain ROM_LOAD / ROM_LOAD16_WORD, with optional _xN repeats
        pad_to(l["offset"])
        for _ in range(rep):
            out.append(f'    <part name="{escape(l["file"])}" crc="{l["crc"]}"/>')
        cursor += l["size"] * rep
        i += 1
    assert cursor <= region_size, f"{ctx}: loads overflow region (0x{cursor:x} > 0x{region_size:x})"
    if cursor < region_size:
        out.append(f'    <part repeat="{region_size - cursor}">FF</part>')
    return out, cursor

def gen(setname, data, outdir):
    parent = data.get("parent") or setname
    d = GAMES.get(parent) or GAMES.get(setname)
    if d is None or setname in UNSUPPORTED:
        return False
    regions = {r["region"]: r for r in data["regions"]}
    # D1: no region may exceed its declared SDRAM slot size.
    for reg, size in REGION_SIZES.items():
        r = regions.get(reg)
        if r:
            loaded = sum(l["size"] for l in r["loads"])
            assert loaded <= size, (
                f"{setname}: region {reg} loads {loaded:#x} > slot {size:#x}")
    lines = []
    lines.append('<misterromdescription>')
    lines.append(f'  <name>{escape(data.get("title", setname))}</name>')
    lines.append(f'  <setname>{setname}</setname>')
    if parent != setname:
        lines.append(f'  <parent>{parent}</parent>')
    lines.append(f'  <year>{data.get("year", "")}</year>')
    lines.append(f'  <manufacturer>{escape(data.get("manu", "Sega"))}</manufacturer>')
    lines.append('  <rbf>SegaS32</rbf>')
    lines.append('  <rom index="0" zip="%s.zip" md5="none">' % setname)
    # descriptor
    hexd = d.hex().upper()
    lines.append(f'    <part>{hexd}</part>')
    for reg in STREAM_ORDER:
        size = REGION_SIZES[reg]
        r = regions.get(reg)
        if r and r["loads"]:
            parts, _ = interleave_parts(r["loads"], size, ctx=f"{setname}/{reg}")
            lines += parts
        else:
            lines.append(f'    <part repeat="{size}">FF</part>')
    lines.append('  </rom>')
    # eeprom default
    ee = regions.get("eeprom")
    if ee and ee["loads"]:
        lines.append('  <rom index="2">')
        lines.append(f'    <part name="{escape(ee["loads"][0]["file"])}" crc="{ee["loads"][0]["crc"]}"/>')
        lines.append('  </rom>')
    lines.append('  <nvram index="3" size="128"/>')
    lines.append('</misterromdescription>')
    title = data.get("title", setname).replace("/", "-").replace(":", "")
    with open(os.path.join(outdir, f"{title}.mra"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return True

def main():
    src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    outdir = sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    # D2: the emitted stream layout must match the RTL loader's OFF_* stream
    # boundaries (rtl/mem/s32_rom_loader.sv) — descriptor(0x40) then each
    # region padded to REGION_SIZES in STREAM_ORDER. This is the real
    # generator<->loader contract (the loader's map_addr then translates
    # each stream offset to its SDRAM region base, DESIGN.md §4.2/§9.3).
    LOADER_OFF = {"maincpu": 0x40}
    acc = 0x40
    for reg in STREAM_ORDER:
        LOADER_OFF.setdefault(reg, acc)
        acc += REGION_SIZES[reg]
    assert LOADER_OFF["soundcpu"] == 0x40 + 0x200000
    assert LOADER_OFF["sprites"] == 0x40 + 0x200000 + 0x400000*3 + 0x10000, \
        "stream layout drifted from s32_rom_loader OFF_SPRITES"
    sets = parse(src)
    n = 0
    for name, data in sorted(sets.items()):
        if "title" not in data:
            continue
        if gen(name, data, outdir):
            n += 1
        else:
            print(f"skip {name} (unsupported)")
    print(f"generated {n} MRAs")

if __name__ == "__main__":
    main()

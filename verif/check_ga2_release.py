#!/usr/bin/env python3
"""Static release-contract check for the sole supported hardware target: GA2."""

from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
qsf = (ROOT / "Arcade-SegaSystem32.qsf").read_text(encoding="utf-8")
assert 'VERILOG_MACRO "S32_SYSTEM32_ONLY=1"' in qsf, "release build is not System 32-only"
assert 'VERILOG_MACRO "S32_GA2_ONLY=1"' in qsf, "release build is not GA2-only"
assert 'VERILOG_MACRO "S32_REAL_V25=1"' in qsf, "release build does not enable the real V25"
assert 'VERILOG_MACRO "S80X86_PSEUDO_286_INT=0"' in qsf, "s80x86 interrupt mode is not fixed"

matches = []
for path in (ROOT / "mra").glob("*.mra"):
    tree = ET.parse(path)
    if tree.findtext("setname") == "ga2":
        matches.append((path, tree))

assert len(matches) == 1, f"expected exactly one GA2 MRA, found {len(matches)}"
path, tree = matches[0]
root = tree.getroot()

assert root.findtext("name") == "Golden Axe: The Revenge of Death Adder (World, Rev B)"
rom = root.find("rom[@index='0']")
assert rom is not None and rom.get("zip") == "ga2.zip"

# The first anonymous part is the fixed 64-byte board descriptor.  GA2 must be
# single-screen System 32 with the V25 and PPI flags set (0x02 | 0x20), while
# all other feature flags remain clear for this set.
descriptor_part = rom.find("part")
assert descriptor_part is not None and descriptor_part.text is not None
descriptor = bytes.fromhex(descriptor_part.text.strip())
assert len(descriptor) == 64, f"GA2 descriptor is {len(descriptor)} bytes, expected 64"
assert descriptor[0] == 0x22, f"GA2 feature byte is 0x{descriptor[0]:02x}, expected V25+PPI (0x22)"
assert descriptor[1:3] == bytes(2), "unexpected GA2 descriptor options"
assert descriptor[3] == 0x83, f"GA2 sprite-bank byte is 0x{descriptor[3]:02x}, expected 0x83"
assert descriptor[4:] == bytes(60), "unexpected GA2 descriptor options"

mcu = [part for part in rom.findall("part") if part.get("name") == "epr-14468-02.u3"]
assert len(mcu) == 1 and mcu[0].get("crc") == "77634daa", "GA2 V25 MCU program is missing or wrong"

nvram = root.find("nvram[@index='3']")
assert nvram is not None and nvram.get("size") == "128", "GA2 EEPROM contract changed"

print(f"GA2 RELEASE MRA PASS: {path.name}")

#!/usr/bin/env python3
"""Static checks for the dedicated Alien 3 profile and its regional MRAs."""

from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
qsf = (ROOT / "s32Alien3.qsf").read_text(encoding="utf-8")

for assignment in (
    "SAVE_DISK_SPACE OFF",
    "SMART_RECOMPILE ON",
    'FITTER_EFFORT "FAST FIT"',
    "ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL",
    "PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF",
    "PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF",
    "NUM_PARALLEL_PROCESSORS 6",
):
    assert assignment in qsf, f"missing Alien 3 Quartus policy assignment: {assignment}"

for macro in (
    "S32_ALIEN3_ONLY=1",
    "S32_V60_NO_FP=1",
    "S32_RELEASE_MINIMAL=1",
    "S32_JT12_MLAB_SHIFTS=1",
):
    assert f'VERILOG_MACRO "{macro}"' in qsf, f"missing Alien 3 macro: {macro}"

for forbidden in ("S32_REAL_V25=1", "S32_V25_GAME_ONLY=1", "S32_JPARK_ONLY=1"):
    assert forbidden not in qsf, f"Alien 3 profile contains unrelated macro: {forbidden}"

mras = sorted((ROOT / "mra").glob("Alien3 The Gun (*.mra"))
assert len(mras) == 3, f"expected three Alien 3 MRAs, found {len(mras)}"
for path in mras:
    root = ET.parse(path).getroot()
    assert root.findtext("rbf") == "s32Alien3", f"{path.name} must load s32Alien3.rbf"
    descriptor = root.find("./rom[@index='0']/part")
    assert descriptor is not None and descriptor.text is not None
    assert descriptor.text.strip().upper().startswith("080C0083"), \
        f"{path.name} has the wrong Alien 3 board descriptor"
    assert root.find("./rom[@index='2']") is None, \
        f"{path.name} must not require the optional 93c45 factory EEPROM dump"
    nvram = root.find("./nvram[@index='3']")
    assert nvram is not None and nvram.get("size") == "128", \
        f"{path.name} has the wrong writable EEPROM/NVRAM contract"

print("ALIEN3 RELEASE PASS: dedicated profile and three regional MRAs")

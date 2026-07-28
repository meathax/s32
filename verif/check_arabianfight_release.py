#!/usr/bin/env python3
"""Static contract for the dedicated Arabian Fight release profile."""

from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
common_qsf = (ROOT / "Arcade-SegaSystem32.qsf").read_text(encoding="utf-8")
arabian_qsf = (ROOT / "s32ArabianFight.qsf").read_text(encoding="utf-8")
assert 'VERILOG_MACRO "S32_JPARK_ONLY=1"' not in arabian_qsf, \
    "Arabian Fight revision inherited the unrelated gun-game profile"
for assignment in (
    "SAVE_DISK_SPACE OFF",
    "SMART_RECOMPILE ON",
    'FITTER_EFFORT "FAST FIT"',
    "SEED 1",
    "ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL",
    "PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF",
    "PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA OFF",
    "PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF",
    "NUM_PARALLEL_PROCESSORS 6",
):
    assert f"set_global_assignment -name {assignment}" in arabian_qsf, \
        f"Arabian Fight revision is missing required Quartus setting {assignment}"
for macro in (
    "S32_ARABFIGHT_ONLY=1",
    "S32_V25_GAME_ONLY=1",
    "S32_REAL_V25=1",
    "S32_V60_NO_FP=1",
    "S32_RELEASE_MINIMAL=1",
    "S32_JT12_MLAB_SHIFTS=1",
    "S32_V25_MLAB_FIFO=1",
    "MISTER_DISABLE_SHADOWMASK=1",
):
    assert f'VERILOG_MACRO "{macro}"' in arabian_qsf, \
        f"Arabian Fight revision is missing {macro}"
    assert f'VERILOG_MACRO "{macro}"' not in common_qsf, \
        f"shared QSF unexpectedly forces {macro}"

top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
assert "wire [15:0] cpu_ce_inc = 16'd32768;" in top, \
    "Arabian Fight fixed clk_sys/2 V60 cadence is missing"

matches = []
for path in (ROOT / "mra").glob("Arabian Fight (*.mra"):
    tree = ET.parse(path)
    matches.append((path, tree.getroot()))

assert len(matches) == 3, f"expected three Arabian Fight MRAs, found {len(matches)}"
for path, root in matches:
    assert root.findtext("rbf") == "s32ArabianFight", \
        f"{path.name} must load s32ArabianFight.rbf"

    rom = root.find("rom[@index='0']")
    assert rom is not None and rom.get("zip") is None
    descriptor_part = rom.find("part")
    assert descriptor_part is not None and descriptor_part.text is not None
    descriptor = bytes.fromhex(descriptor_part.text.strip())
    assert len(descriptor) == 64, f"{path.name}: descriptor length changed"
    assert descriptor[0] == 0x26, \
        f"{path.name}: expected V25+Arabian table+PPI feature byte"
    assert descriptor[1:3] == bytes(2), f"{path.name}: unexpected options"
    assert descriptor[3] == 0x83, f"{path.name}: sprite-bank contract changed"
    assert descriptor[4:] == bytes(60), f"{path.name}: unexpected options"

    mcu_rom = root.find("rom[@index='8']")
    mcu = [] if mcu_rom is None else [
        part for part in mcu_rom.findall("part")
        if part.get("name") == "epr-14468-01.u3"
    ]
    assert len(mcu) == 1 and mcu[0].get("crc") == "c3c591e4", \
        f"{path.name}: Arabian V25 MCU program is missing or wrong"

    nvram = root.find("nvram[@index='3']")
    assert nvram is not None and nvram.get("size") == "128", \
        f"{path.name}: EEPROM contract changed"

print("ARABIAN FIGHT RELEASE PASS: profile and three regional MRAs")

#!/usr/bin/env python3
"""Static contract for Arabian Fight in the universal segas32 profile."""

from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
standard_qsf = (ROOT / "Arcade-SegaSystem32.qsf").read_text(encoding="utf-8")
for assignment in (
    "SAVE_DISK_SPACE OFF",
    "SMART_RECOMPILE ON",
    'FITTER_EFFORT "STANDARD FIT"',
    # 2026-08-18: the current universal-profile netlist closes the clean full
    # fit at seed 5; seed 2 and seed 6 both missed slow-corner setup.
    "SEED 5",
    "ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL",
    "PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF",
    "PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA OFF",
    "PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF",
    "NUM_PARALLEL_PROCESSORS 2",
):
    assert f"set_global_assignment -name {assignment}" in standard_qsf, \
        f"Arcade-SegaSystem32.qsf is missing required Quartus setting {assignment}"
for macro in ("S32_PROFILE_STANDARD=1", "S32_UNIVERSAL=1", "S32_V25_HW=1",
              "S32_GAME_ONLY_STD=1", "S32_V60_NO_FP=1"):
    assert f'VERILOG_MACRO "{macro}"' in standard_qsf, \
        f"Arcade-SegaSystem32.qsf is missing {macro}"
for macro in ("S32_V25_MLAB_FIFO=1", "S32_V25_MLAB_EEPROM=1",
              "S32_JT12_MLAB_SHIFTS=1"):
    assert f'VERILOG_MACRO "{macro}"' not in standard_qsf, \
        f"Arcade-SegaSystem32.qsf must not force {macro}"
for macro in ("S32_PROFILE_V25=1", "S32_REAL_V25=1"):
    assert f'VERILOG_MACRO "{macro}"' not in standard_qsf, \
        f"Arcade-SegaSystem32.qsf unexpectedly defines obsolete {macro}"
assert 'VERILOG_MACRO "MISTER_DISABLE_SHADOWMASK=1"' in standard_qsf, \
    "Arcade-SegaSystem32.qsf must compile out the optional HDMI shadow-mask stage"
assert 'VERILOG_MACRO "S32_RELEASE_MINIMAL=1"' not in standard_qsf, \
    "Arcade-SegaSystem32.qsf must not retain the retired debug/release macro"

top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
# Arabian Fight keeps the clk_sys/2 bus cadence that fixes its attract-loop
# overrun, but every other board runs the PCB's literal 16.108 MHz bus rate.
# The uniform clk_sys/2 cadence asserted here previously black-screened ga2,
# spidman and radr on real hardware; see the rationale on cpu_ce_inc.
assert "active_board.v25_table ? 16'd32768 : 16'd21848" in top, \
    "Arabian Fight's clk_sys/2 cadence, and the PCB rate for other boards, is missing"
assert "is_multi32 ? 16'd27127 : 16'd21848" in top, \
    "non-V25 System 32 boards must run the PCB's literal 16.108 MHz bus cadence"
assert '"O[16:15],CPU Turbo' not in top, \
    "CPU Turbo must not be offered in the merged profile (V60 timing relies on fixed CE)"

matches = []
for path in (ROOT / "releases").rglob("Arabian Fight (*.mra"):
    tree = ET.parse(path)
    matches.append((path, tree.getroot()))

assert len(matches) == 3, f"expected three Arabian Fight MRAs, found {len(matches)}"
for path, root in matches:
    assert root.findtext("rbf") == "Arcade-SegaSystem32", \
        f"{path.name} must load Arcade-SegaSystem32.rbf"

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

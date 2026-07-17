#!/bin/sh
# System 32 core regression (DESIGN.md §11): grows with each milestone.
set -e
cd "$(dirname "$0")/.."
echo "[1/25] full-core lint compile (universal + System32-only profile)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_lint \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_lint.sv
vvp /tmp/s32_lint | grep -q "CORE UNIVERSAL LINT PASS" || { echo "CORE UNIVERSAL LINT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_GA2_ONLY -o /tmp/s32_lint_s32 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_lint.sv
vvp /tmp/s32_lint_s32 | grep -q "CORE S32-ONLY LINT PASS" && echo "CORE BUILD PROFILES: PASS" || { echo "CORE S32-ONLY LINT: FAIL"; exit 1; }
echo "[2/25] V60 smoke test"
iverilog -g2012 -o /tmp/s32_v60_smoke \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_smoke.sv
vvp /tmp/s32_v60_smoke | grep -q "SMOKE PASS" && echo "V60 SMOKE: PASS" || { echo "V60 SMOKE: FAIL"; exit 1; }
echo "[3/25] V60 directed suite"
iverilog -g2012 -o /tmp/s32_v60_dir \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_directed.sv
vvp /tmp/s32_v60_dir | grep -q "DIRECTED PASS" && echo "V60 DIRECTED: PASS" || { echo "V60 DIRECTED: FAIL"; exit 1; }
echo "[4/25] full-core integration boot (universal + System32-only profile)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_boot \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_boot.sv
vvp /tmp/s32_boot | grep -q "CORE BOOT PASS" || { echo "CORE UNIVERSAL BOOT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_GA2_ONLY -o /tmp/s32_boot_s32 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_boot.sv
vvp /tmp/s32_boot_s32 | grep -q "CORE BOOT PASS" && echo "CORE BUILD-PROFILE BOOTS: PASS" || { echo "CORE S32-ONLY BOOT: FAIL"; exit 1; }
echo "[5/25] V60 differential co-sim vs independent reference (50 seeds)"
sh verif/cosim/run_diff.sh 50
echo "[6/25] full-core soak / simulator-tier acceptance (extended multi-frame)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_soak \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_soak.sv
vvp /tmp/s32_soak | grep -q "CORE SOAK PASS" && echo "CORE SOAK: PASS" || { echo "CORE SOAK: FAIL"; exit 1; }
echo "[7/25] V60 audit-fix directed test (string/CALL/RET/RSR — audit.md)"
iverilog -g2012 -o /tmp/s32_v60_audit \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_audit.sv
vvp /tmp/s32_v60_audit | grep -q "AUDIT PASS" && echo "V60 AUDIT: PASS" || { echo "V60 AUDIT: FAIL"; exit 1; }
iverilog -g2012 -o /tmp/s32_v60_search \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_search.sv
vvp /tmp/s32_v60_search | grep -q "V60 SEARCH PASS" && echo "V60 SEARCH: PASS" || { echo "V60 SEARCH: FAIL"; exit 1; }
echo "[8/25] GA2 release-profile boot path (V25 wakeup / VRAM+palette / sprite list / vblank IRQ)"
python3 verif/check_ga2_release.py | grep -q "GA2 RELEASE MRA PASS" || { echo "GA2 RELEASE MRA: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_GA2_ONLY -o /tmp/s32_ga2 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_ga2path.sv
vvp /tmp/s32_ga2 | grep -q "GA2 PATH PASS" && echo "GA2 PATH: PASS" || { echo "GA2 PATH: FAIL"; exit 1; }
echo "[9/25] framebuffer interface directed test (runs / shadow RMW / erase / read)"
iverilog -g2012 -o /tmp/s32_fbif rtl/mem/s32_fb_if.sv verif/common/tb_fb_if.sv
vvp /tmp/s32_fbif | grep -q "FB IF PASS" && echo "FB IF: PASS" || { echo "FB IF: FAIL"; exit 1; }
echo "[10/25] mixer directed test (priority / palette index / blend / shadow)"
iverilog -g2012 -o /tmp/s32_mix rtl/video/s32_linebuf.sv rtl/video/s32_mixer.sv \
  rtl/video/s32_palette.sv verif/common/tb_mixer.sv
vvp /tmp/s32_mix | grep -q "MIXER PASS" && echo "MIXER: PASS" || { echo "MIXER: FAIL"; exit 1; }
echo "[11/25] sprite pixel-path directed test (pen rules / end codes / flip / zoom / indirect)"
iverilog -g2012 -o /tmp/s32_spr rtl/video/s32_sprite.sv verif/common/tb_sprite.sv
vvp /tmp/s32_spr | grep -q "SPRITE PASS" && echo "SPRITE: PASS" || { echo "SPRITE: FAIL"; exit 1; }
echo "[12/25] sprite scale divider exactness / fixed-latency test"
iverilog -g2012 -s tb_sprite_div -o /tmp/s32_sprdiv rtl/video/s32_sprite.sv verif/common/tb_sprite_div.sv
vvp /tmp/s32_sprdiv | grep -q "SPRITE DIV PASS" && echo "SPRITE DIV: PASS" || { echo "SPRITE DIV: FAIL"; exit 1; }
echo "[13/25] V60 DIVX/DIVUX iterative 64/32 exactness / latency test"
iverilog -g2012 -o /tmp/s32_v60_divx rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_divx.sv
vvp /tmp/s32_v60_divx | grep -q "DIVX PASS" && echo "V60 DIVX: PASS" || { echo "V60 DIVX: FAIL"; exit 1; }
echo "[14/25] V60 decimal group directed test (ADDDC/SUBDC/SUBRDC/CVTDPZ/CVTDZP)"
iverilog -g2012 -o /tmp/s32_v60dec rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_decimal.sv
vvp /tmp/s32_v60dec | grep -q "DECIMAL PASS" && echo "V60 DECIMAL: PASS" || { echo "V60 DECIMAL: FAIL"; exit 1; }
echo "[15/25] V60 bit string/field directed test (EXTBF/INSBF/SCHBS/MOVBS)"
iverilog -g2012 -o /tmp/s32_v60bits rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_bits.sv
vvp /tmp/s32_v60bits | grep -q "BITS PASS" && echo "V60 BITS: PASS" || { echo "V60 BITS: FAIL"; exit 1; }
echo "[16/25] V60 short backward-branch fetch performance"
iverilog -g2012 -o /tmp/s32_v60_fetch \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_fetch.sv
vvp /tmp/s32_v60_fetch | grep -q "FETCH PERF PASS" && echo "V60 FETCH PERF: PASS" || { echo "V60 FETCH PERF: FAIL"; exit 1; }
echo "[17/25] ROM loader reset / mapping / completion gating"
iverilog -g2012 -o /tmp/s32_rom_loader \
  rtl/s32_pkg.sv rtl/mem/s32_rom_loader.sv verif/common/tb_rom_loader.sv
vvp /tmp/s32_rom_loader | grep -q "ROM LOADER PASS" && echo "ROM LOADER: PASS" || { echo "ROM LOADER: FAIL"; exit 1; }
echo "[18/25] EEPROM NVRAM upload byte order / dirty-state persistence"
iverilog -g2012 -o /tmp/s32_eeprom_nvram \
  rtl/s32_pkg.sv rtl/io/s32_io.sv verif/common/tb_eeprom_nvram.sv
vvp /tmp/s32_eeprom_nvram | grep -q "EEPROM NVRAM PASS" && echo "EEPROM NVRAM: PASS" || { echo "EEPROM NVRAM: FAIL"; exit 1; }
echo "[19/25] V60 20-byte F1 / high fetch-buffer offset regression"
iverilog -g2012 -o /tmp/s32_v60_long_ea \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_long_ea.sv
vvp /tmp/s32_v60_long_ea | grep -q "LONG EA PASS" && echo "V60 LONG EA: PASS" || { echo "V60 LONG EA: FAIL"; exit 1; }
echo "[20/25] RF5C68 dual-port wave RAM / loop-fetch / channel cadence"
iverilog -g2012 -o /tmp/s32_rf5c68 \
  rtl/audio/s32_rf5c68.sv verif/common/tb_rf5c68.sv
vvp /tmp/s32_rf5c68 | grep -q "RF5C68 PASS" && echo "RF5C68: PASS" || { echo "RF5C68: FAIL"; exit 1; }
echo "[21/25] palette RAM alias / byte-enable / write-both / dual-port timing"
iverilog -g2012 -o /tmp/s32_palette \
  rtl/video/s32_palette.sv verif/common/tb_palette.sv
vvp /tmp/s32_palette | grep -q "PALETTE PASS" && echo "PALETTE: PASS" || { echo "PALETTE: FAIL"; exit 1; }
echo "[22/25] shared tile/bitmap line-buffer latency / layer / parity isolation"
iverilog -g2012 -o /tmp/s32_linebuf \
  rtl/video/s32_linebuf.sv verif/common/tb_linebuf.sv
vvp /tmp/s32_linebuf | grep -q "LINEBUF PASS" && echo "LINEBUF: PASS" || { echo "LINEBUF: FAIL"; exit 1; }
echo "[23/25] tilemap synchronous VRAM fetch latency / NBG / TEXT / BITMAP"
iverilog -g2012 -DSIMULATION -o /tmp/s32_tilemap_vram \
  rtl/video/s32_big_dpram.sv rtl/video/s32_vram.sv \
  rtl/video/s32_tilemap.sv verif/common/tb_tilemap_vram.sv
vvp /tmp/s32_tilemap_vram | grep -q "TILEMAP VRAM PASS" && echo "TILEMAP VRAM: PASS" || { echo "TILEMAP VRAM: FAIL"; exit 1; }
echo "[24/25] byte-wide true-dual-port BRAM timing / hold / collision semantics"
iverilog -g2012 -s tb_byte_dpram -o /tmp/s32_byte_dpram \
  rtl/video/s32_big_dpram.sv verif/common/tb_byte_dpram.sv
vvp /tmp/s32_byte_dpram | grep -q "BYTE DPRAM PASS" && echo "BYTE DPRAM: PASS" || { echo "BYTE DPRAM: FAIL"; exit 1; }
echo "[25/25] V25 HLE mailbox BRAM timing / wakeup / protection overlays"
iverilog -g2012 -s tb_v25_dpram -o /tmp/s32_v25_dpram \
  rtl/s32_pkg.sv rtl/video/s32_big_dpram.sv rtl/prot/s32_prot.sv \
  verif/common/tb_v25_dpram.sv
vvp /tmp/s32_v25_dpram | grep -q "V25 DPRAM PASS" && echo "V25 DPRAM: PASS" || { echo "V25 DPRAM: FAIL"; exit 1; }

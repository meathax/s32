#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
cd "$repo_root"

for required in \
    roms/sim/ga2/mcu.bin \
    rtl/cpu/v25/s32_v25_rom_cache.sv \
    rtl/cpu/v25/s32_v25_cpu.sv \
    rtl/cpu/v25/s80x86/generated/microcode.bin \
    verif/common/tb_v25_rom_cache.sv \
    verif/common/tb_v25_firmware.sv; do
    if [[ ! -f "$required" ]]; then
        echo "V25_FIRMWARE RUNNER FAIL: missing $required" >&2
        exit 2
    fi
done

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/s32-v25-firmware.XXXXXX")"
cleanup() {
    if [[ "${KEEP_BUILD:-0}" == "1" ]]; then
        echo "V25_FIRMWARE build retained at $build_dir"
    else
        rm -rf -- "$build_dir"
    fi
}
trap cleanup EXIT

start_seconds=$SECONDS
iverilog \
    -g2012 \
    -s tb_v25_rom_cache \
    -o "$build_dir/tb_v25_rom_cache" \
    rtl/cpu/v25/s32_v25_rom_cache.sv \
    verif/common/tb_v25_rom_cache.sv
"$build_dir/tb_v25_rom_cache" 2>&1 | tee "$build_dir/cache.log"
if ! grep -Fq "V25 ROM CACHE PASS" "$build_dir/cache.log"; then
    echo "V25_ROM_CACHE RUNNER FAIL: success marker missing" >&2
    exit 1
fi

verilator \
    --binary \
    --timing \
    -Wall \
    -Wno-fatal \
    -DS80X86_PSEUDO_286_INT=0 \
    "-DMICROCODE_ROM_PATH=\"$repo_root/rtl/cpu/v25/s80x86/generated\"" \
    --top-module tb_v25_firmware \
    --Mdir "$build_dir/obj_dir" \
    -o Vtb_v25_firmware \
    -f verif/v25/s80x86.f \
    rtl/cpu/v25/s32_v25_rom_cache.sv \
    rtl/cpu/v25/s32_v25_cpu.sv \
    verif/common/tb_v25_firmware.sv \
    2>&1 | tee "$build_dir/compile.log"

"$build_dir/obj_dir/Vtb_v25_firmware" 2>&1 | tee "$build_dir/run.log"

pass_marker='V25_FIRMWARE PASS: genuine GA2 firmware wrote wake-up, table, and stack state'
if ! grep -Fq "$pass_marker" "$build_dir/run.log"; then
    echo "V25_FIRMWARE RUNNER FAIL: firmware completion marker missing" >&2
    exit 1
fi

# The test emits one atomic success marker only after independently checking
# the complete 48-byte wake-up and 16-byte protection table (plus stack state).
echo "V25_ROM_CACHE RUNNER: PASS"
echo "V25_FIRMWARE WAKE: PASS"
echo "V25_FIRMWARE TABLE: PASS"
echo "V25_FIRMWARE RUNNER: PASS ($((SECONDS - start_seconds))s)"


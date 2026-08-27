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
    verif/common/tb_v25_internal_data.sv \
    verif/common/tb_v25_firmware.sv; do
    if [[ ! -f "$required" ]]; then
        echo "V25_FIRMWARE RUNNER FAIL: missing $required" >&2
        exit 2
    fi
done

start_seconds=$SECONDS
safe_verilator="${S32_VERILATOR_SAFE:-verilator-safe}"
safe_sim="${S32_VERILATOR_SIM_SAFE:-verilator-sim-safe}"
command -v "$safe_verilator" >/dev/null 2>&1 || { echo "missing $safe_verilator" >&2; exit 127; }
command -v "$safe_sim" >/dev/null 2>&1 || { echo "missing $safe_sim" >&2; exit 127; }
source "$repo_root/verif/verilator/workspace.sh"
s32_verilator_workspace "$safe_verilator"
build_dir="$S32_VERILATOR_WORKSPACE"
mkdir -p -- "$build_dir/temp"
export TMP="$build_dir/temp" TEMP="$build_dir/temp" TMPDIR="$build_dir/temp"
cleanup() {
    if [[ "${KEEP_BUILD:-0}" == "1" ]]; then
        echo "V25_FIRMWARE build retained at $build_dir"
    else
        case "$build_dir" in
            /r/Verilator/*|/mnt/r/Verilator/*) rm -rf -- "$build_dir" ;;
            *) echo "refusing unsafe V25 firmware cleanup: $build_dir" >&2 ;;
        esac
    fi
}
trap cleanup EXIT
"$safe_verilator" status
modelsim_bin="${MODELSIM_BIN:-}"
if command -v iverilog >/dev/null 2>&1; then
    iverilog \
        -g2012 \
        -s tb_v25_rom_cache \
        -o "$build_dir/tb_v25_rom_cache" \
        rtl/cpu/v25/s32_v25_rom_cache.sv \
        verif/common/tb_v25_rom_cache.sv
    "$build_dir/tb_v25_rom_cache" 2>&1 | tee "$build_dir/cache.log"
elif [[ -x "$modelsim_bin/vlib.exe" && -x "$modelsim_bin/vlog.exe" &&
        -x "$modelsim_bin/vsim.exe" ]]; then
    "$modelsim_bin/vlib.exe" "$build_dir/cache_work"
    "$modelsim_bin/vlog.exe" -sv -work "$build_dir/cache_work" \
        rtl/cpu/v25/s32_v25_rom_cache.sv verif/common/tb_v25_rom_cache.sv
    "$modelsim_bin/vsim.exe" -c -lib "$build_dir/cache_work" \
        tb_v25_rom_cache -do 'run -all; quit -f' 2>&1 | tee "$build_dir/cache.log"
else
    echo "V25_FIRMWARE RUNNER FAIL: neither iverilog nor ModelSim is available" >&2
    exit 127
fi
if ! grep -Fq "V25 ROM CACHE PASS" "$build_dir/cache.log"; then
    echo "V25_ROM_CACHE RUNNER FAIL: success marker missing" >&2
    exit 1
fi

if command -v iverilog >/dev/null 2>&1; then
    iverilog \
        -g2012 \
        -s tb_v25_internal_data \
        -o "$build_dir/tb_v25_internal_data" \
        rtl/cpu/v25/s32_v25_rom_cache.sv \
        rtl/cpu/v25/s32_v25_cpu.sv \
        verif/common/tb_v25_internal_data.sv
    "$build_dir/tb_v25_internal_data" 2>&1 | tee "$build_dir/internal-data.log"
else
    "$modelsim_bin/vlib.exe" "$build_dir/internal_work"
    "$modelsim_bin/vlog.exe" -sv -work "$build_dir/internal_work" \
        rtl/cpu/v25/s32_v25_rom_cache.sv rtl/cpu/v25/s32_v25_cpu.sv \
        verif/common/tb_v25_internal_data.sv
    "$modelsim_bin/vsim.exe" -c -lib "$build_dir/internal_work" \
        tb_v25_internal_data -do 'run -all; quit -f' 2>&1 | tee "$build_dir/internal-data.log"
fi
if ! grep -Fq "V25 INTERNAL DATA PASS" "$build_dir/internal-data.log"; then
    echo "V25_INTERNAL_DATA RUNNER FAIL: success marker missing" >&2
    exit 1
fi

"$safe_verilator" \
    --binary \
    --timing \
    --threads 1 \
    --verilate-jobs 4 \
    --build-jobs 4 \
    -CFLAGS -D_GLIBCXX_USE_CXX11_ABI=0 \
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

firmware_exe="$build_dir/obj_dir/Vtb_v25_firmware"
if [[ -f "$firmware_exe.exe" ]]; then
    firmware_exe="$firmware_exe.exe"
fi
firmware_host="$firmware_exe"
if command -v cygpath >/dev/null 2>&1; then
    firmware_host="$(cygpath -w "$firmware_exe")"
fi

# Native Windows safe-simulator wrappers cannot be launched reliably from an
# MSYS child shell.  The PowerShell entry point therefore asks this script to
# stop after the build and hands the exact generated executable back to the
# native host.  KEEP_BUILD keeps the model alive until that host run finishes.
if [[ "${S32_V25_BUILD_ONLY:-0}" == "1" ]]; then
    build_host="$build_dir"
    if command -v cygpath >/dev/null 2>&1; then
        build_host="$(cygpath -w "$build_dir")"
    fi
    echo "V25_FIRMWARE EXE: $firmware_host"
    echo "V25_FIRMWARE BUILD DIR: $build_host"
    echo "V25_FIRMWARE BUILD: PASS ($((SECONDS - start_seconds))s)"
    exit 0
fi

"$safe_sim" -- \
    "$firmware_host" \
    2>&1 | tee "$build_dir/run.log"

pass_marker='V25_FIRMWARE PASS: genuine GA2 firmware wrote wake-up, table, and stack state'
if ! grep -Fq "$pass_marker" "$build_dir/run.log"; then
    echo "V25_FIRMWARE RUNNER FAIL: firmware completion marker missing" >&2
    exit 1
fi

# The test emits one atomic success marker only after independently checking
# the complete 48-byte wake-up and 16-byte protection table (plus stack state).
echo "V25_ROM_CACHE RUNNER: PASS"
echo "V25_INTERNAL_DATA RUNNER: PASS"
echo "V25_FIRMWARE WAKE: PASS"
echo "V25_FIRMWARE TABLE: PASS"
echo "V25_FIRMWARE RUNNER: PASS ($((SECONDS - start_seconds))s)"

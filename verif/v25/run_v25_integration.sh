#!/usr/bin/env bash
# Real-V25 INTEGRATION test: the genuine V25 core inside the full s32_core,
# fetching its encrypted program through SDRAM port 5 and round-tripping the
# wake-up mailbox to the V60 over the real core bus (S32_REAL_V25).  Verilator,
# because ModelSim ASE cannot compile the s80x86 sources.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
cd "$repo_root"

for required in \
    roms/sim/ga2/mcu.bin \
    rtl/cpu/v25/s32_v25_cpu.sv \
    rtl/cpu/v25/s80x86/generated/microcode.bin \
    rtl/s32_core.sv \
    verif/common/tb_core_v25int.sv \
    verif/v25/s80x86.f; do
    if [[ ! -f "$required" ]]; then
        echo "V25_INTEGRATION RUNNER FAIL: missing $required" >&2
        exit 2
    fi
done

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/s32-v25int.XXXXXX")"
cleanup() {
    if [[ "${KEEP_BUILD:-0}" == "1" ]]; then
        echo "V25_INTEGRATION build retained at $build_dir"
    else
        rm -rf -- "$build_dir"
    fi
}
trap cleanup EXIT

start_seconds=$SECONDS
mc="$repo_root/rtl/cpu/v25/s80x86/generated"
video=$(ls rtl/video/*.sv | sort)

verilator \
    --binary --timing -Wall -Wno-fatal \
    -Wno-WIDTH -Wno-UNSIGNED -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNDRIVEN \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
    -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-CASEOVERLAP \
    -Wno-LATCH -Wno-COMBDLY \
    +define+SIMULATION +define+S32_SYSTEM32_ONLY +define+S32_GA2_ONLY \
    +define+S32_GOLDENAXE_ONLY +define+S32_RELEASE_MINIMAL \
    +define+S32_REAL_V25 +define+S80X86_PSEUDO_286_INT=0 \
    "-DMICROCODE_ROM_PATH=\"$mc\"" \
    --top-module tb_core_v25int --Mdir "$build_dir/obj_dir" -o Vtb_core_v25int \
    rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
    $video \
    rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv \
    rtl/io/s32_io.sv rtl/prot/s32_prot.sv verif/common/jt12_stub.v \
    -f verif/v25/s80x86.f \
    rtl/cpu/v25/s32_v25_rom_cache.sv rtl/cpu/v25/s32_v25_cpu.sv \
    rtl/s32_core.sv verif/common/tb_core_v25int.sv \
    2>&1 | tee "$build_dir/compile.log"

"$build_dir/obj_dir/Vtb_core_v25int" 2>&1 | tee "$build_dir/run.log"

if ! grep -Fq "V25 INTEGRATION PASS" "$build_dir/run.log"; then
    echo "V25_INTEGRATION RUNNER FAIL: integration marker missing" >&2
    exit 1
fi
echo "V25_INTEGRATION RUNNER: PASS ($((SECONDS - start_seconds))s)"

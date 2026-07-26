#!/usr/bin/env bash
# Long-form Golden Axe framebuffer run using the production real-V25 profile.
# Unlike run_romboot.sh, this includes the encrypted MCU, its external p5 ROM
# path, internal data RAM, CDC bridge, and Golden Axe-only synthesis choices.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
cd "$repo_root"

frames="${1:-650}"
shift 2>/dev/null || true
build_dir="${REAL_V25_BUILD:-scratch/verilator-real-v25-go}"
output_dir="${REAL_V25_OUT:-scratch/vromboot_real_out}"
microcode="$repo_root/rtl/cpu/v25/s80x86/generated"
warnings=(
  -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
  -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN
  -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-SYNCASYNCNET
)

verilator --binary --timing -j 0 "${warnings[@]}" \
  +define+SIMULATION +define+S32_REAL_FB_SIM \
  +define+S32_SYSTEM32_ONLY +define+S32_GA2_ONLY \
  +define+S32_GOLDENAXE_ONLY +define+S32_RELEASE_MINIMAL \
  +define+S32_REAL_V25 +define+S80X86_PSEUDO_286_INT=0 \
  "-DMICROCODE_ROM_PATH=\"$microcode\"" \
  --top-module tb_core_romboot --Mdir "$build_dir" -o romboot \
  -f verif/v25/s80x86.f \
  rtl/cpu/v25/s32_v25_rom_cache.sv rtl/cpu/v25/s32_v25_cpu.sv \
  -f scratch/romboot.f

mkdir -p "$output_dir"
cd "$output_dir"
"$repo_root/$build_dir/romboot" \
  +IMG="$repo_root/roms/sim/ga2" +B0=22 +B2=0 +SBM=3 \
  +FRAMES="$frames" "$@"

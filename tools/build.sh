#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
revision=Arcade-SegaSystem32
fit_retries="${S32_FIT_RETRIES:-3}"
fit_seeds="${S32_FIT_SEEDS:-6 1 2 3 4 5}"

for tool in qsys-script qsys-generate quartus_map quartus_fit quartus_asm quartus_sta; do
    command -v "$tool" >/dev/null || { echo "ERROR: missing $tool" >&2; exit 1; }
done
if command -v python3 >/dev/null; then
    python_bin=python3
elif command -v python >/dev/null; then
    python_bin=python
else
    echo "ERROR: Python is required for build qualification" >&2; exit 1
fi

rm -rf -- db incremental_db output_files
qsys-script --script=tools/make_pll.tcl
qsys-generate rtl/pll/pll.qsys --synthesis=VERILOG --output-directory=rtl/pll
test -f rtl/pll/synthesis/pll.qip
quartus_map --read_settings_files=on --write_settings_files=off "$revision" -c "$revision"

for seed in $fit_seeds; do
    echo "Trying fitter seed $seed"
    fit_ok=0
    for ((attempt=1; attempt<=fit_retries; attempt++)); do
        if quartus_fit --read_settings_files=off --write_settings_files=off --seed="$seed" "$revision" -c "$revision"; then
            fit_ok=1
            break
        fi
        echo "Fitter seed $seed attempt $attempt/$fit_retries failed"
    done
    ((fit_ok)) || continue
    quartus_asm --read_settings_files=off --write_settings_files=off "$revision" -c "$revision"
    quartus_sta "$revision" -c "$revision"
    if "$python_bin" tools/qualify_build.py; then
        mkdir -p releases
        cp output_files/Arcade-SegaSystem32.rbf releases/SegaS32.rbf
        echo "DONE: releases/SegaS32.rbf (seed $seed)"
        exit 0
    fi
done

echo "BUILD FAILED: no fitter seed produced a timing-qualified RBF" >&2
exit 1

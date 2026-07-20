from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path

from verif.mixer_diff.generate_vectors import write_vectors


ROOT = Path(__file__).resolve().parents[2]


def run_modelsim(modelsim_bin: Path, seed: int, count: int) -> str:
    with tempfile.TemporaryDirectory(prefix="s32-mixer-diff-") as directory:
        work = Path(directory)
        vectors = work / "vectors.hex"
        write_vectors(vectors, seed, count)
        commands = (
            ([modelsim_bin / "vlib.exe", "work"], "vlib"),
            ([modelsim_bin / "vlog.exe", "-sv",
              str(ROOT / "rtl/video/s32_mixer.sv"),
              str(ROOT / "verif/mixer_diff/tb_mixer_diff.sv")], "vlog"),
            ([modelsim_bin / "vsim.exe", "-c", "tb_mixer_diff",
              f"+VECTORS={vectors.as_posix()}",
              "-do", "run -all; quit -f"], "vsim"),
        )
        transcript = ""
        for command, name in commands:
            result = subprocess.run(
                [str(item) for item in command], cwd=work,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                check=False,
            )
            transcript += result.stdout
            if result.returncode:
                raise RuntimeError(f"{name} failed ({result.returncode})\n{transcript}")
        marker = f"MIXER DIFF PASS cases={count}"
        if marker not in transcript:
            raise RuntimeError(f"missing {marker!r}\n{transcript}")
        return transcript


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--modelsim-bin", type=Path, required=True)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=5387)
    parser.add_argument("--count", type=int, default=512)
    args = parser.parse_args()
    transcript = run_modelsim(args.modelsim_bin, args.seed, args.count)
    for line in transcript.splitlines():
        if "MIXER DIFF" in line:
            print(line)


if __name__ == "__main__":
    main()

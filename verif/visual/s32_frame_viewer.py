#!/usr/bin/env python3
"""Native live viewer for PPM frames produced by the S32 Verilator model.

The simulator remains the source of pixels; this window supplies the native
event loop, frame/checksum diagnostics, and a small keyboard bridge consumed at
the next simulated frame boundary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import tkinter as tk
from pathlib import Path


def frame_number(path: Path) -> int:
    try:
        return int(path.stem.removeprefix("dump").removeprefix("frame_"))
    except ValueError:
        return -1


parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--title", default="Sega System 32 - Verilator")
parser.add_argument("--status", type=Path)
parser.add_argument("--input", type=Path, help="atomic live input word written for the simulator")
parser.add_argument("--live-file", type=Path, help="single PPM overwritten at each simulated frame")
args = parser.parse_args()
output = args.output.resolve()
started = time.time() - 2.0

root = tk.Tk()
root.title(args.title)
root.configure(bg="#111111")
image_label = tk.Label(root, bg="#111111")
image_label.pack(padx=8, pady=(8, 4))
status_text = tk.StringVar(value="Waiting for completed Verilator frames...")
tk.Label(root, textvariable=status_text, bg="#111111", fg="#eeeeee", font=("Segoe UI", 10)).pack(padx=8, pady=(0, 8))
last_path: Path | None = None
last_size = -1
last_mtime = -1.0
observed_size = -1
observed_mtime = -1.0
observed_path: Path | None = None
stable_polls = 0
change_count = 0
last_checksum: str | None = None
display_frame = 0
live_frame = -1
input_mask = 0


def write_input() -> None:
    if not args.input:
        return
    args.input.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.input.with_suffix(args.input.suffix + ".tmp")
    temporary.write_text(f"{input_mask:04x}\n", encoding="ascii")
    temporary.replace(args.input)


def publish(state: str, frame: int = -1, checksum: str | None = None) -> None:
    if args.status:
        args.status.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.status.with_suffix(args.status.suffix + ".tmp")
        temporary.write_text(json.dumps({"state": state, "frame": frame, "checksum": checksum, "changes": change_count, "input": f"{input_mask:04x}"}) + "\n", encoding="utf-8")
        temporary.replace(args.status)


def poll() -> None:
    global last_path, last_size, last_mtime, observed_size, observed_mtime, observed_path
    global stable_polls, change_count, last_checksum, display_frame, live_frame
    candidates = []
    if args.live_file:
        ready = Path(str(args.live_file) + ".ready")
        if ready.exists():
            try:
                fields = ready.read_text(encoding="ascii").split()
                live_frame = int(fields[0])
                slot = int(fields[1])
                candidates.append(Path(f"{args.live_file}.{slot}"))
            except (OSError, ValueError, IndexError):
                pass
    candidates.extend(path for path in output.glob("dump*.ppm") if path.stat().st_mtime >= started)
    if candidates:
        newest = max(candidates, key=frame_number)
        size = newest.stat().st_size
        mtime = newest.stat().st_mtime
        if newest == observed_path and size == observed_size and mtime == observed_mtime:
            stable_polls += 1
        else:
            observed_path = newest
            observed_size = size
            observed_mtime = mtime
            stable_polls = 0
        # A live PPM is rewritten in place by the simulator. Wait for one
        # unchanged poll so the parser never consumes the file mid-frame.
        if stable_polls >= 1 and (newest != last_path or mtime != last_mtime) and size > 0:
            try:
                payload = newest.read_bytes()
                fields = payload.split()
                if fields[:1] != [b"P3"]:
                    raise ValueError("expected ASCII P3 PPM")
                width, height, maximum = map(int, fields[1:4])
                if maximum != 255:
                    raise ValueError("expected 8-bit samples")
                pixels = bytes(map(int, fields[4:]))
                checksum = hashlib.sha256(pixels).hexdigest()
                if last_checksum is not None and checksum != last_checksum:
                    change_count += 1
                last_checksum = checksum
                display_frame += 1
                source = tk.PhotoImage(data=f"P6\n{width} {height}\n255\n".encode() + pixels, format="PPM")
                scaled = source.zoom(2, 2)
                image_label.configure(image=scaled)
                image_label.image = scaled
                last_path = newest
                token = frame_number(newest)
                if token < 0:
                    token = live_frame if live_frame >= 0 else display_frame
                root.title(f"{args.title} | frame {token} | changes {change_count}")
                status_text.set(f"Native frame {token} | SHA-256 {checksum[:12]} | framebuffer changes {change_count}")
                publish("displaying", token, checksum)
            except (OSError, ValueError, tk.TclError):
                pass
            else:
                last_size = size
                last_mtime = mtime
    root.after(200, poll)


def close() -> None:
    global input_mask
    input_mask = 0
    write_input()
    publish("closed", frame_number(last_path) if last_path else -1, last_checksum)
    root.destroy()


def key_bit(event: tk.Event) -> int | None:
    return {
        "Left": 0x80, "Right": 0x40, "Up": 0x20, "Down": 0x10,
        "z": 0x01, "x": 0x02, "c": 0x04,
        "a": 0x01, "s": 0x02, "d": 0x04,
        "q": 0x400, "e": 0x800,
    }.get(event.keysym)


def key_press(event: tk.Event) -> None:
    global input_mask
    if event.keysym in ("Escape",):
        close()
        return
    bit = key_bit(event)
    if bit is not None:
        input_mask |= bit
        write_input()
    elif event.keysym in ("5", "6"):
        input_mask |= 0x100 if event.keysym == "5" else 0x200
        write_input()


def key_release(event: tk.Event) -> None:
    global input_mask
    bit = key_bit(event)
    if bit is not None:
        input_mask &= ~bit
    elif event.keysym in ("5", "6"):
        input_mask &= ~(0x100 if event.keysym == "5" else 0x200)
    write_input()


root.protocol("WM_DELETE_WINDOW", close)
root.bind_all("<KeyPress>", key_press)
root.bind_all("<KeyRelease>", key_release)
write_input()
publish("open")
root.after(100, poll)
root.mainloop()

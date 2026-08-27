#!/usr/bin/env python3
"""Validate a user-supplied EPR-14084 and emit an untracked readmemh image."""
import argparse, hashlib
from pathlib import Path

SIZE = 32768
SHA1 = "e1bb23eac85e3236046527c5c7688f6f23d43aef"

def main():
	parser = argparse.ArgumentParser()
	parser.add_argument("input", type=Path)
	parser.add_argument("output", type=Path)
	args = parser.parse_args()
	data = args.input.read_bytes()
	actual = hashlib.sha1(data).hexdigest()
	if len(data) != SIZE or actual != SHA1:
		raise SystemExit(f"EPR-14084 identity mismatch: size={len(data)} sha1={actual}")
	args.output.parent.mkdir(parents=True, exist_ok=True)
	args.output.write_text("".join(f"{byte:02x}\n" for byte in data), encoding="ascii")
	print(f"validated EPR-14084 size={SIZE} sha1={SHA1}; wrote {args.output}")
if __name__ == "__main__": main()

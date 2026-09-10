#!/usr/bin/env python3
"""Reject missing shared libraries and non-AArch64 ELF payloads."""
import argparse
import struct
import subprocess
from pathlib import Path


def check(directory):
    failures = []
    count = 0
    for path in sorted(Path(directory).rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            header = stream.read(20)
        if not header.startswith(b"\x7fELF"):
            continue
        count += 1
        endian = "<" if header[5] == 1 else ">"
        if struct.unpack(endian + "H", header[18:20])[0] != 183:
            failures.append(f"{path}: not an AArch64 ELF")
        result = subprocess.run(["ldd", str(path)], capture_output=True, text=True, check=False)
        output = result.stdout + result.stderr
        if "not found" in output:
            failures.append(f"{path}: {output}")
        elif result.returncode and not any(
            text in output for text in ("not a dynamic executable", "statically linked")
        ):
            failures.append(f"{path}: ldd failed: {output}")
    if count == 0:
        failures.append("No ELF payload found")
    if failures:
        raise RuntimeError("\n".join(failures))
    print(f"Validated {count} AArch64 ELF files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    check(parser.parse_args().directory)

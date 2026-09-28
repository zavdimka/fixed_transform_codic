#!/usr/bin/env python3
"""Copy an HDZRXT1 capture while retaining only one codec layer."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--layer", choices=("base", "enhancement"),
                        default="base")
    args = parser.parse_args()
    data = args.input.read_bytes()
    if data[:8] != b"HDZRXT1\0":
        raise ValueError("input is not HDZRXT1")
    cursor = 16
    records: list[bytes] = []
    wanted = 0x10 if args.layer == "base" else 0x11
    while cursor < len(data):
        size = struct.unpack_from("<H", data, cursor)[0]
        cursor += 2
        record = data[cursor:cursor + size]
        cursor += size
        if record[3] == wanted:
            records.append(record)
    body = b"".join(struct.pack("<H", len(record)) + record
                    for record in records)
    header = struct.pack("<8sHHI", b"HDZRXT1\0", len(records),
                         max(map(len, records)), 0)
    args.output.write_bytes(header + body)
    print(f"wrote {args.output}: layer={args.layer} records={len(records)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Print record layout and consistency information for an HDZ RXT stream."""

from __future__ import annotations

import argparse
import collections
import struct
from pathlib import Path


def le16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def inspect(path: Path, limit: int) -> None:
    data = path.read_bytes()
    if len(data) < 16 or data[:8] != b"HDZRXT1\0":
        raise ValueError(f"{path}: invalid RXT header")

    record_count = le16(data, 8)
    maximum_size = le16(data, 10)
    offset = 16
    records: list[tuple[int, ...]] = []
    for index in range(record_count):
        if offset + 2 > len(data):
            raise ValueError(f"{path}: truncated size at record {index}")
        size = le16(data, offset)
        offset += 2
        if offset + size > len(data) or size < 20:
            raise ValueError(f"{path}: invalid size {size} at record {index}")
        record = data[offset : offset + size]
        offset += size
        records.append(
            (
                record[3],
                le16(record, 4),
                le16(record, 6),
                le16(record, 8),
                record[10],
                record[11],
                record[12],
                record[13],
                le16(record, 16),
                size,
            )
        )

    fields = "type seq display source stripe q frag fragments payload bytes"
    print(f"{path}: records={record_count} maximum={maximum_size} bytes={len(data)}")
    print("types:", dict(sorted(collections.Counter(row[0] for row in records).items())))
    print(fields)
    shown = records if limit <= 0 or len(records) <= limit else records[:limit]
    for row in shown:
        print(" ".join(f"{value:5d}" for value in row))
    if len(shown) != len(records):
        print(f"... {len(records) - len(shown)} records omitted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--limit", type=int, default=16)
    args = parser.parse_args()
    for path in args.paths:
        inspect(path, args.limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

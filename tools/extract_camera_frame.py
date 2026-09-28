#!/usr/bin/env python3
"""Extract one display frame from HDZCAP1 into an HDZRXT1 decoder file."""

from __future__ import annotations

import argparse
import binascii
from pathlib import Path
import struct


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("frame_id", type=int)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = args.capture.read_bytes()
    magic, version, count, payload_size, payload_crc = struct.unpack_from(
        "<8sIIII", data)
    payload = data[24:]
    if (magic, version, len(payload), binascii.crc32(payload) & 0xFFFFFFFF) != (
            b"HDZCAP1\0", 1, payload_size, payload_crc):
        raise ValueError("invalid HDZCAP1 file")

    selected: list[bytes] = []
    cursor = 0
    parsed = 0
    while cursor < len(payload):
        size = struct.unpack_from("<H", payload, cursor)[0]
        cursor += 2
        record = payload[cursor:cursor + size]
        cursor += size
        parsed += 1
        if struct.unpack_from("<H", record, 6)[0] == args.frame_id:
            selected.append(record)
    if parsed != count or not selected:
        raise ValueError("record count mismatch or requested frame absent")

    by_stripe: dict[int, dict[int, list[bytes]]] = {}
    for record in selected:
        stripe = record[10]
        by_stripe.setdefault(stripe, {}).setdefault(record[3], []).append(record)
    for stripe in sorted(by_stripe):
        fields = []
        for record_type, name in ((0x10, "base"), (0x11, "enh")):
            records = by_stripe[stripe].get(record_type, [])
            if records:
                records.sort(key=lambda item: item[12])
                total_bytes = sum(struct.unpack_from("<H", item, 16)[0]
                                  for item in records)
                valid = (records[-1][14] & 7) + 1
                fields.append(
                    f"{name}={total_bytes * 8 - (8 - valid)}b/"
                    f"{len(records)}rec")
        print(f"stripe={stripe:02d} " + " ".join(fields))

    body = b"".join(struct.pack("<H", len(record)) + record
                    for record in selected)
    header = struct.pack("<8sHHI", b"HDZRXT1\0", len(selected),
                         max(map(len, selected)), 0)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(header + body)
    print(f"wrote {args.output}: frame={args.frame_id} records={len(selected)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Decode an HDZRXT1 frame with the Python model and compare C++ YUV bytes."""

from __future__ import annotations

import argparse
import struct
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import custom_codec_experiment as codec  # noqa: E402
import jpeg_radio_codec as core  # noqa: E402


def read_layers(path: Path):
    data = path.read_bytes()
    if data[:8] != b"HDZRXT1\0":
        raise ValueError("input is not HDZRXT1")
    count = struct.unpack_from("<H", data, 8)[0]
    cursor = 16
    groups: dict[tuple[int, int], list[tuple[int, bytes, int, int]]] = defaultdict(list)
    quality: dict[int, int] = {}
    for _ in range(count):
        size = struct.unpack_from("<H", data, cursor)[0]
        cursor += 2
        record = data[cursor:cursor + size]
        cursor += size
        payload_size = struct.unpack_from("<H", record, 16)[0]
        payload = record[18:18 + payload_size]
        layer = record[3]
        stripe = record[10]
        fragment = record[12]
        fragment_count = record[13]
        final_bits = (record[14] & 7) + 1 if fragment + 1 == fragment_count else 8
        groups[(stripe, layer)].append((fragment, payload, final_bits, fragment_count))
        quality[stripe] = record[11]
    if cursor != len(data):
        raise ValueError("trailing capture bytes")
    return groups, quality


def finish(parts):
    parts = sorted(parts)
    if len(parts) != parts[0][3] or [p[0] for p in parts] != list(range(len(parts))):
        raise ValueError("incomplete layer")
    payload = b"".join(part[1] for part in parts)
    return payload, (len(payload) - 1) * 8 + parts[-1][2]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("cpp_yuv", type=Path)
    parser.add_argument("--python-yuv", type=Path)
    args = parser.parse_args()
    groups, qualities = read_layers(args.capture)
    y = np.full((720, 1280), 128, dtype=np.uint8)
    cb = np.full((360, 640), 128, dtype=np.uint8)
    cr = np.full((360, 640), 128, dtype=np.uint8)
    stats = core.ArithmeticStats()
    for stripe in range(45):
        base_data, base_bits = finish(groups[(stripe, 0x10)])
        enh_data, enh_bits = finish(groups[(stripe, 0x11)])
        record = codec.LayeredStripeRecord(
            stripe, 1280, base_data, base_bits, enh_data, enh_bits,
            b"", False, False, False,
        )
        _, full = codec.decode_stripe(record, qualities[stripe], stats, True)
        y[stripe * 16:(stripe + 1) * 16] = full[0].astype(np.uint8)
        cb[stripe * 8:(stripe + 1) * 8] = full[1].astype(np.uint8)
        cr[stripe * 8:(stripe + 1) * 8] = full[2].astype(np.uint8)
    python_bytes = y.tobytes() + cb.tobytes() + cr.tobytes()
    cpp_bytes = args.cpp_yuv.read_bytes()
    if args.python_yuv:
        args.python_yuv.write_bytes(python_bytes)
    if len(cpp_bytes) != len(python_bytes):
        raise ValueError("YUV lengths differ")
    a = np.frombuffer(python_bytes, dtype=np.uint8).astype(np.int16)
    b = np.frombuffer(cpp_bytes, dtype=np.uint8).astype(np.int16)
    delta = np.abs(a - b)
    mismatches = int(np.count_nonzero(delta))
    print(f"bytes={len(a)} mismatches={mismatches} max_abs={int(delta.max())} "
          f"mean_abs={float(delta.mean()):.6f} python_saturations={stats.saturations}")
    return 0 if mismatches == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
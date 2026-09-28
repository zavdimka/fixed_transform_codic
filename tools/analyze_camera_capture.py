#!/usr/bin/env python3
"""Validate HDZCAP1 transport and report completeness of camera frames."""

from __future__ import annotations

import argparse
import binascii
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
import struct


CAPTURE_HEADER = struct.Struct("<8sIIII")
CAPTURE_MAGIC = b"HDZCAP1\0"
RECORD_MAGIC = b"\xc5\x3a\x01"
EXPECTED_STRIPES = set(range(45))


def crc16_ccitt(data: bytes) -> int:
    value = 0xFFFF
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ 0x1021) & 0xFFFF \
                if value & 0x8000 else (value << 1) & 0xFFFF
    return value


@dataclass
class Layer:
    count: int | None = None
    fragments: set[int] = field(default_factory=set)


@dataclass
class Stripe:
    base: Layer = field(default_factory=Layer)
    enhancement: Layer = field(default_factory=Layer)


@dataclass
class Frame:
    source_ids: set[int] = field(default_factory=set)
    stripes: dict[int, Stripe] = field(default_factory=lambda: defaultdict(Stripe))
    records: int = 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    args = parser.parse_args()

    data = args.capture.read_bytes()
    if len(data) < CAPTURE_HEADER.size:
        raise ValueError("truncated capture header")
    magic, version, record_count, payload_size, payload_crc = \
        CAPTURE_HEADER.unpack_from(data)
    payload = data[CAPTURE_HEADER.size:]
    if magic != CAPTURE_MAGIC or version != 1:
        raise ValueError("unsupported capture header")
    if len(payload) != payload_size:
        raise ValueError("capture payload size mismatch")
    if binascii.crc32(payload) & 0xFFFFFFFF != payload_crc:
        raise ValueError("capture payload CRC32 mismatch")

    frames: dict[int, Frame] = defaultdict(Frame)
    cursor = 0
    parsed = 0
    previous_sequence: int | None = None
    sequence_gaps: list[tuple[int, int]] = []
    while cursor < len(payload):
        if cursor + 2 > len(payload):
            raise ValueError("truncated record length")
        size = struct.unpack_from("<H", payload, cursor)[0]
        cursor += 2
        if size < 20 or cursor + size > len(payload):
            raise ValueError(f"invalid record size {size}")
        record = payload[cursor:cursor + size]
        cursor += size
        parsed += 1
        if record[:3] != RECORD_MAGIC or record[3] not in (0x10, 0x11):
            raise ValueError(f"record {parsed - 1}: invalid signature/type")
        encoded_size = struct.unpack_from("<H", record, 16)[0]
        if encoded_size + 20 != len(record):
            raise ValueError(f"record {parsed - 1}: payload length mismatch")
        if crc16_ccitt(record[:-2]) != struct.unpack_from("<H", record, len(record) - 2)[0]:
            raise ValueError(f"record {parsed - 1}: CRC16 mismatch")

        sequence, frame_id, source_id = struct.unpack_from("<HHH", record, 4)
        if previous_sequence is not None and sequence != (previous_sequence + 1) & 0xFFFF:
            sequence_gaps.append((previous_sequence, sequence))
        previous_sequence = sequence
        stripe_index = record[10]
        fragment_index = record[12]
        fragment_count = record[13]
        if fragment_count == 0 or fragment_index >= fragment_count:
            raise ValueError(f"record {parsed - 1}: invalid fragment index/count")

        frame = frames[frame_id]
        frame.source_ids.add(source_id)
        frame.records += 1
        stripe = frame.stripes[stripe_index]
        layer = stripe.base if record[3] == 0x10 else stripe.enhancement
        if layer.count is not None and layer.count != fragment_count:
            raise ValueError(f"frame {frame_id} stripe {stripe_index}: fragment count changed")
        layer.count = fragment_count
        if fragment_index in layer.fragments:
            raise ValueError(f"frame {frame_id} stripe {stripe_index}: duplicate fragment")
        layer.fragments.add(fragment_index)

    if parsed != record_count:
        raise ValueError(f"parsed {parsed} records, header says {record_count}")

    complete_frames = 0
    print(f"capture records={parsed} sequence_gaps={len(sequence_gaps)} frames={len(frames)}")
    for frame_id in sorted(frames):
        frame = frames[frame_id]
        stripe_ids = set(frame.stripes)
        incomplete_layers = []
        for stripe_id, stripe in frame.stripes.items():
            for name, layer in (("base", stripe.base), ("enh", stripe.enhancement)):
                if layer.count is not None and layer.fragments != set(range(layer.count)):
                    incomplete_layers.append(f"{stripe_id}:{name}")
        complete = (frame.source_ids == {frame_id}
                    and stripe_ids == EXPECTED_STRIPES
                    and not incomplete_layers
                    and all(frame.stripes[index].base.count is not None
                            for index in EXPECTED_STRIPES))
        complete_frames += int(complete)
        missing = sorted(EXPECTED_STRIPES - stripe_ids)
        extra = sorted(stripe_ids - EXPECTED_STRIPES)
        print(
            f"frame={frame_id} source={sorted(frame.source_ids)} records={frame.records} "
            f"stripes={len(stripe_ids)}/45 complete={int(complete)} "
            f"missing={missing} extra={extra} incomplete={incomplete_layers}")
    if sequence_gaps:
        print(f"sequence gaps: {sequence_gaps[:16]}")
    print(f"complete_frames={complete_frames}")
    return 0 if complete_frames else 2


if __name__ == "__main__":
    raise SystemExit(main())

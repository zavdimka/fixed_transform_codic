#!/usr/bin/env python3
"""Verify every byte of an FPGA deterministic PARLIO link capture."""

from __future__ import annotations

import argparse
import binascii
from pathlib import Path
import struct


CAPTURE_HEADER = struct.Struct("<8sIIII")
CAPTURE_MAGIC = b"HDZCAP1\0"
PAYLOAD_LENGTHS = (1, 7, 31, 127, 257, 511, 899, 900)


def crc16_ccitt(data: bytes) -> int:
    value = 0xFFFF
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ 0x1021) & 0xFFFF if value & 0x8000 \
                else (value << 1) & 0xFFFF
    return value


def expected_payload_byte(record_index: int, offset: int) -> int:
    offset_byte = offset & 0xFF
    rotated = ((offset_byte & 0x0F) << 4) | (offset_byte >> 4)
    return 0xA5 ^ (record_index & 0xFF) ^ offset_byte ^ rotated


def iter_records(payload: bytes):
    offset = 0
    while offset < len(payload):
        if offset + 2 > len(payload):
            raise ValueError(f"truncated record length at capture offset {offset}")
        size = struct.unpack_from("<H", payload, offset)[0]
        offset += 2
        if size < 20 or offset + size > len(payload):
            raise ValueError(f"invalid record size {size} at capture offset {offset - 2}")
        yield payload[offset:offset + size]
        offset += size


def verify(path: Path, expected_count: int | None, expected_start: int) -> int:
    data = path.read_bytes()
    if len(data) < CAPTURE_HEADER.size:
        raise ValueError("truncated capture header")
    magic, version, packet_count, payload_size, payload_crc = \
        CAPTURE_HEADER.unpack_from(data)
    payload = data[CAPTURE_HEADER.size:]
    if magic != CAPTURE_MAGIC or version != 1:
        raise ValueError(f"unsupported capture magic={magic!r} version={version}")
    if len(payload) != payload_size:
        raise ValueError(f"payload size {len(payload)} != header {payload_size}")
    actual_crc = binascii.crc32(payload) & 0xFFFFFFFF
    if actual_crc != payload_crc:
        raise ValueError(f"capture CRC32 {actual_crc:08x} != {payload_crc:08x}")

    records = list(iter_records(payload))
    if len(records) != packet_count:
        raise ValueError(f"parsed {len(records)} records != header {packet_count}")
    if expected_count is not None and len(records) != expected_count:
        raise ValueError(f"captured {len(records)} records != expected {expected_count}")

    for offset, record in enumerate(records):
        number = (expected_start + offset) & 0xFFFF
        payload_length = PAYLOAD_LENGTHS[number & 7]
        if len(record) != payload_length + 20:
            raise ValueError(
                f"record {number}: size {len(record)} != {payload_length + 20}")
        sequence, frame_id, source_id = struct.unpack_from("<HHH", record, 4)
        encoded_length = struct.unpack_from("<H", record, 16)[0]
        expected_header = (
            record[0:4] == b"\xc5\x3a\x01\x10"
            and sequence == (number & 0xFFFF)
            and frame_id == (number & 0xFFFF)
            and source_id == (number & 0xFFFF)
            and record[10] == (number & 0x3F)
            and record[11:16] == b"\xa5\x00\x01\x07\x00"
            and encoded_length == payload_length
        )
        if not expected_header:
            raise ValueError(f"record {number}: header mismatch {record[:18].hex(' ')}")
        encoded_payload = record[18:-2]
        for offset, actual in enumerate(encoded_payload):
            expected = expected_payload_byte(number, offset)
            if actual != expected:
                raise ValueError(
                    f"record {number}: payload[{offset}]={actual:02x}, "
                    f"expected {expected:02x}")
        expected_crc = crc16_ccitt(record[:-2])
        actual_record_crc = struct.unpack_from("<H", record, len(record) - 2)[0]
        if actual_record_crc != expected_crc:
            raise ValueError(
                f"record {number}: CRC16 {actual_record_crc:04x} != "
                f"{expected_crc:04x}")

    print(
        f"PASS deterministic PARLIO capture: records={len(records)}, "
        f"payload_bytes={payload_size}, sequence={expected_start}.."
        f"{expected_start + len(records) - 1}")
    return len(records)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--records", type=int, help="required record count")
    parser.add_argument("--start", type=int, default=0,
                        help="expected first deterministic record index")
    args = parser.parse_args()
    verify(args.capture, args.records, args.start)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

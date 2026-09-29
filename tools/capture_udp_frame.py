#!/usr/bin/env python3
"""Capture one complete layered video frame from the live UDP stream."""

from __future__ import annotations

import argparse
import socket
import struct
import time
from pathlib import Path

FILE_MAGIC = b"HDZRXT1\0"
RECORD_MAGIC = b"\xC5\x3A\x01"
BASE_RECORD = 0x10
ENHANCEMENT_RECORD = 0x11


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = (((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1) & 0xFFFF
    return crc


def unpack_datagram(data: bytes) -> list[bytes]:
    if not data.startswith(b"HZU\x01"):
        return [data]
    records: list[bytes] = []
    cursor = 4
    while cursor + 2 <= len(data):
        size = struct.unpack_from("<H", data, cursor)[0]
        cursor += 2
        if size < 20 or cursor + size > len(data):
            raise ValueError("invalid HZU1 record length")
        records.append(data[cursor:cursor + size])
        cursor += size
    if cursor != len(data):
        raise ValueError("trailing bytes in HZU1 datagram")
    return records


def record_key(record: bytes) -> tuple[int, int, int]:
    if len(record) < 20 or record[:3] != RECORD_MAGIC:
        raise ValueError("invalid link-record signature")
    if record[3] not in (BASE_RECORD, ENHANCEMENT_RECORD):
        raise ValueError("invalid link-record type")
    payload_size = struct.unpack_from("<H", record, 16)[0]
    if len(record) != 20 + payload_size:
        raise ValueError("invalid link-record payload length")
    expected_crc = struct.unpack_from("<H", record, 18 + payload_size)[0]
    if crc16_ccitt(record[:18 + payload_size]) != expected_crc:
        raise ValueError("link-record CRC mismatch")
    return record[3], record[10], record[12]


def complete(records: dict[tuple[int, int, int], bytes], stripes: int) -> bool:
    for stripe in range(stripes):
        for layer in (BASE_RECORD, ENHANCEMENT_RECORD):
            first = records.get((layer, stripe, 0))
            if first is None:
                return False
            fragment_count = first[13]
            if fragment_count == 0:
                return False
            for fragment in range(fragment_count):
                current = records.get((layer, stripe, fragment))
                if current is None or current[13] != fragment_count:
                    return False
    return True


def write_rxt(path: Path, records: dict[tuple[int, int, int], bytes]) -> None:
    ordered = [records[key] for key in sorted(records, key=lambda k: (k[1], k[0], k[2]))]
    body = b"".join(struct.pack("<H", len(record)) + record for record in ordered)
    header = struct.pack("<8sHHI", FILE_MAGIC, len(ordered),
                         max(map(len, ordered)), 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + body)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5600)
    parser.add_argument("--stripes", type=int, default=45)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    sock.bind((args.bind, args.port))
    sock.settimeout(0.25)
    deadline = time.monotonic() + args.timeout
    frames: dict[int, dict[tuple[int, int, int], bytes]] = {}
    invalid = 0

    while time.monotonic() < deadline:
        try:
            datagram = sock.recv(65535)
        except TimeoutError:
            continue
        try:
            incoming = unpack_datagram(datagram)
        except ValueError:
            invalid += 1
            continue
        for record in incoming:
            try:
                key = record_key(record)
            except ValueError:
                invalid += 1
                continue
            frame_id = struct.unpack_from("<H", record, 6)[0]
            records = frames.setdefault(frame_id, {})
            previous = records.get(key)
            if previous is not None and previous != record:
                raise RuntimeError(f"conflicting duplicate record {key}")
            records[key] = record
            if complete(records, args.stripes):
                write_rxt(args.output, records)
                print(f"captured frame={frame_id} records={len(records)} "
                      f"bytes={sum(map(len, records.values()))} invalid={invalid}")
                return 0
            while len(frames) > 16:
                del frames[next(iter(frames))]
    best = sorted(
        ((len(records), frame_id) for frame_id, records in frames.items()),
        reverse=True,
    )[:4]
    raise TimeoutError(f"no complete frame before timeout; best={best}")


if __name__ == "__main__":
    raise SystemExit(main())
#!/usr/bin/env python3
"""Verify that hdzero_live displays incomplete UDP frames with gray stripes."""

from __future__ import annotations

import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def read_records(path: Path) -> list[bytearray]:
    data = path.read_bytes()
    if data[:8] != b"HDZRXT1\0":
        raise RuntimeError("reference input is not HDZRXT1")
    record_count = struct.unpack_from("<H", data, 8)[0]
    records: list[bytearray] = []
    cursor = 16
    for _ in range(record_count):
        if cursor + 2 > len(data):
            raise RuntimeError("truncated reference record length")
        size = struct.unpack_from("<H", data, cursor)[0]
        cursor += 2
        if size < 20 or cursor + size > len(data):
            raise RuntimeError("invalid reference record size")
        records.append(bytearray(data[cursor:cursor + size]))
        cursor += size
    if cursor != len(data):
        raise RuntimeError("trailing bytes in reference capture")
    return records


def reserve_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    first = data.find(b"\n")
    second = data.find(b"\n", first + 1)
    third = data.find(b"\n", second + 1)
    if first < 0 or second < 0 or third < 0 or data[:first] != b"P6":
        raise RuntimeError("invalid PPM output")
    width, height = map(int, data[first + 1:second].split())
    if data[second + 1:third] != b"255":
        raise RuntimeError("unexpected PPM depth")
    pixels = data[third + 1:]
    if len(pixels) != width * height * 3:
        raise RuntimeError("truncated PPM pixels")
    return width, height, pixels


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: test_live_packet_loss.py HDZERO_LIVE REFERENCE.rxt")
    executable = Path(sys.argv[1]).resolve()
    records = read_records(Path(sys.argv[2]))
    missing_stripe = 22
    transmitted = [record for record in records if record[10] != missing_stripe]
    if not transmitted or len(transmitted) == len(records):
        raise RuntimeError("reference does not contain the selected stripe")

    trigger = bytearray(records[0])
    frame_id = struct.unpack_from("<H", trigger, 6)[0]
    struct.pack_into("<H", trigger, 6, (frame_id + 1) & 0xFFFF)
    payload_size = struct.unpack_from("<H", trigger, 16)[0]
    crc_offset = 18 + payload_size
    struct.pack_into("<H", trigger, crc_offset, crc16_ccitt(trigger[:crc_offset]))

    port = reserve_udp_port()
    with tempfile.TemporaryDirectory(prefix="hdzero-loss-") as temp_dir:
        output = Path(temp_dir) / "partial.ppm"
        process = subprocess.Popen(
            [str(executable), "--bind", "127.0.0.1", "--port", str(port),
             "--headless", "--frames", "1", "--output-ppm", str(output)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            time.sleep(0.2)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                destination = ("127.0.0.1", port)
                for record in transmitted:
                    sock.sendto(record, destination)
                sock.sendto(trigger, destination)
            log, _ = process.communicate(timeout=10)
        except Exception:
            process.kill()
            process.wait()
            raise

        if process.returncode != 0:
            raise RuntimeError(f"hdzero_live failed ({process.returncode}):\n{log}")
        if "frames=1" not in log or "incomplete=1" not in log:
            raise RuntimeError(f"partial frame was not reported:\n{log}")
        width, height, pixels = read_ppm(output)
        if (width, height) != (1280, 720):
            raise RuntimeError("unexpected output dimensions")

        first_row = missing_stripe * 16
        gray = bytes((128, 128, 128))
        for row in range(first_row, first_row + 16):
            start = row * width * 3
            line = pixels[start:start + width * 3]
            if any(line[offset:offset + 3] != gray for offset in range(0, len(line), 3)):
                raise RuntimeError(f"missing stripe row {row} is not neutral gray")

        adjacent_start = (first_row - 1) * width * 3
        adjacent = pixels[adjacent_start:adjacent_start + width * 3]
        if all(adjacent[offset:offset + 3] == gray for offset in range(0, len(adjacent), 3)):
            raise RuntimeError("decoded neighbor is unexpectedly all gray")

    print(f"partial frame displayed; stripe {missing_stripe} replaced with gray")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
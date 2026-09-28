#!/usr/bin/env python3
"""Capture FPGA PARLIO packets from ESP32-C5 PSRAM over USB Serial/JTAG."""

from __future__ import annotations

import argparse
import binascii
from pathlib import Path
import re
import struct
import time

import serial

READY_RE = re.compile(rb"CAPTURE READY size=(\d+) crc=([0-9a-fA-F]{8})")
STATUS_RE = re.compile(
    rb"tx capture packets=(\d+) bytes=(\d+) capacity=(\d+) "
    rb"dropped=(\d+) rotated=(\d+) header=(\d+) crc=(\d+) queue=(\d+) size=(\d+) "
    rb"result=(\S+)")
HEADER = struct.Struct("<8sIIII")
MAGIC = b"HDZCAP1\0"


def read_line(port: serial.Serial, deadline: float) -> bytes:
    while time.monotonic() < deadline:
        line = port.readline()
        if line:
            return line.strip()
    raise TimeoutError("device did not answer before timeout")


def read_exact(port: serial.Serial, size: int, timeout: float) -> bytes:
    data = bytearray(size)
    view = memoryview(data)
    offset = 0
    deadline = time.monotonic() + timeout
    while offset < size:
        count = port.readinto(view[offset:])
        if count:
            offset += count
            deadline = time.monotonic() + timeout
        elif time.monotonic() >= deadline:
            raise TimeoutError(
                f"capture stalled after {offset}/{size} bytes")
    return bytes(data)


def validate_capture(data: bytes) -> tuple[int, int]:
    if len(data) < HEADER.size:
        raise ValueError("truncated capture header")
    magic, version, packet_count, payload_size, payload_crc = (
        HEADER.unpack_from(data))
    if magic != MAGIC or version != 1:
        raise ValueError(
            f"unsupported capture header magic={magic!r} version={version}")
    payload = data[HEADER.size:]
    if len(payload) != payload_size:
        raise ValueError(
            f"payload size mismatch: {len(payload)} != {payload_size}")
    actual_payload_crc = binascii.crc32(payload) & 0xFFFFFFFF
    if actual_payload_crc != payload_crc:
        raise ValueError(
            f"payload CRC mismatch: {actual_payload_crc:08x} != "
            f"{payload_crc:08x}")

    offset = 0
    records = 0
    maximum = 0
    while offset < len(payload):
        if offset + 2 > len(payload):
            raise ValueError("truncated packet length")
        packet_size = struct.unpack_from("<H", payload, offset)[0]
        offset += 2
        if packet_size == 0 or offset + packet_size > len(payload):
            raise ValueError(
                f"invalid packet {records} size={packet_size}")
        maximum = max(maximum, packet_size)
        offset += packet_size
        records += 1
    if records != packet_count:
        raise ValueError(
            f"packet count mismatch: parsed={records} header={packet_count}")
    return records, maximum


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="USB Serial/JTAG port, for example COM7")
    parser.add_argument("output", type=Path, help="output .hcap file")
    parser.add_argument(
        "--packets", type=int, default=0,
        help="capture this many FPGA transactions first; 0 dumps the stored capture")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--capture-timeout", type=float, default=180.0)
    parser.add_argument(
        "--allow-partial", action="store_true",
        help="dump records retained when the device capture times out")
    parser.add_argument(
        "--camera-pattern", action="store_true",
        help="enable the OV5640 color bars before capture")
    parser.add_argument(
        "--camera-order", type=int, choices=range(4), default=None,
        help="set OV5640 YUV422 byte order before capture")
    parser.add_argument(
        "--camera-settle", type=float, default=0.0,
        help="wait this many seconds after camera setup before capture")
    parser.add_argument(
        "--require-zero-dropped", action="store_true",
        help="fail unless ESP32 reports zero header/CRC/queue/size errors")
    args = parser.parse_args()
    if args.packets < 0 or args.packets > 20000:
        parser.error("--packets must be between 0 and 20000")

    port = serial.Serial()
    port.port = args.port
    port.baudrate = args.baud
    port.timeout = 0.25
    port.write_timeout = args.timeout
    port.dtr = False
    port.rts = False
    port.open()

    with port:
        port.reset_input_buffer()
        if args.camera_pattern:
            port.write(b"camera pattern 1\n")
            port.flush()
            pattern_deadline = time.monotonic() + args.timeout
            while True:
                line = read_line(port, pattern_deadline)
                print(line.decode("ascii", "replace"))
                if b"camera pattern 1:" in line:
                    if b"ESP_OK" not in line:
                        raise RuntimeError(line.decode("ascii", "replace"))
                    break
        if args.camera_order is not None:
            command = f"camera order {args.camera_order}\n".encode("ascii")
            port.write(command)
            port.flush()
            order_deadline = time.monotonic() + args.timeout
            while True:
                line = read_line(port, order_deadline)
                print(line.decode("ascii", "replace"))
                if command.strip() + b":" in line:
                    if b"ESP_OK" not in line:
                        raise RuntimeError(line.decode("ascii", "replace"))
                    break
        if args.camera_settle < 0.0:
            parser.error("--camera-settle must be non-negative")
        if args.camera_settle:
            time.sleep(args.camera_settle)
        if args.packets:
            port.write(f"tx capture {args.packets}\n".encode("ascii"))
            port.flush()
            deadline = time.monotonic() + args.capture_timeout
            capture_error = None
            while True:
                line = read_line(port, deadline)
                print(line.decode("ascii", "replace"))
                if b"tx capture:" in line:
                    if b"ESP_OK" not in line:
                        capture_error = (
                            "device capture failed: "
                            + line.decode("ascii", "replace"))
                    break

            port.write(b"tx capture status\n")
            port.flush()
            status_deadline = time.monotonic() + args.timeout
            status_match = None
            while True:
                line = read_line(port, status_deadline)
                print(line.decode("ascii", "replace"))
                if b"tx capture packets=" in line:
                    status_match = STATUS_RE.search(line)
                    break
            if capture_error is not None and not args.allow_partial:
                raise RuntimeError(capture_error)
            if args.require_zero_dropped:
                if status_match is None:
                    raise RuntimeError("device did not return extended capture status")
                fields = status_match.groups()
                dropped, header_errors, crc_errors, queue_errors, size_errors = (
                    int(fields[index]) for index in (3, 5, 6, 7, 8))
                if any((dropped, header_errors, crc_errors,
                        queue_errors, size_errors)):
                    raise RuntimeError(
                        "transport errors: "
                        f"dropped={dropped} header={header_errors} "
                        f"crc={crc_errors} queue={queue_errors} "
                        f"size={size_errors}")

        port.reset_input_buffer()
        port.write(b"tx capture dump\n")
        port.flush()
        deadline = time.monotonic() + args.timeout
        while True:
            line = read_line(port, deadline)
            match = READY_RE.search(line)
            if match:
                size = int(match.group(1))
                expected_crc = int(match.group(2), 16)
                print(f"receiving {size} bytes, crc32={expected_crc:08x}")
                break
            if b"tx capture dump:" in line:
                raise RuntimeError(line.decode("ascii", "replace"))

        data = read_exact(port, size, args.timeout)
        actual_crc = binascii.crc32(data) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise RuntimeError(
                f"transfer CRC mismatch: {actual_crc:08x} != "
                f"{expected_crc:08x}")
        packet_count, maximum = validate_capture(data)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
        print(
            f"wrote {args.output}: packets={packet_count}, "
            f"maximum={maximum}, bytes={len(data)}, crc32={actual_crc:08x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

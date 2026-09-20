#!/usr/bin/env python3
"""Upload an ESP-IDF application image through the firmware USB console."""

from __future__ import annotations

import argparse
import binascii
from pathlib import Path
import re
import sys
import time

import serial

SEND_RE = re.compile(rb"OTA SEND offset=(\d+) size=(\d+)")


def read_device_line(port: serial.Serial, deadline: float) -> bytes:
    while time.monotonic() < deadline:
        line = port.readline()
        if line:
            return line.strip()
    raise TimeoutError("device did not answer before timeout")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="USB Serial/JTAG port, for example COM7")
    parser.add_argument("image", type=Path, help="ESP-IDF app .bin")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()

    image = args.image.read_bytes()
    crc = binascii.crc32(image) & 0xFFFFFFFF
    print(f"image={args.image} size={len(image)} crc32={crc:08x}")

    port = serial.Serial()
    port.port = args.port
    port.baudrate = args.baud
    port.timeout = 0.25
    port.write_timeout = args.timeout
    # USB Serial/JTAG uses DTR/RTS as reset/boot controls. Keep both inactive
    # so an in-application update never accidentally enters the ROM loader.
    port.dtr = False
    port.rts = False
    port.open()
    with port:
        port.reset_input_buffer()
        command = f"update receive {len(image)} {crc:08x}\n".encode("ascii")
        port.write(command)
        port.flush()

        deadline = time.monotonic() + args.timeout
        while True:
            line = read_device_line(port, deadline)
            if b"OTA READY" in line:
                print(line.decode("ascii", "replace"))
                break
            if b"OTA FAILED" in line or b"update:" in line:
                raise RuntimeError(line.decode("ascii", "replace"))

        sent = 0
        while True:
            line = read_device_line(port, time.monotonic() + args.timeout)
            match = SEND_RE.search(line)
            if match:
                offset, count = map(int, match.groups())
                if offset != sent or offset + count > len(image):
                    raise RuntimeError(f"invalid device request: {line!r}")
                port.write(image[offset:offset + count])
                port.flush()
                sent += count
                if sent == len(image) or sent % (64 * 1024) == 0:
                    print(f"sent {sent}/{len(image)} bytes")
                continue
            if b"OTA COMPLETE" in line:
                print(line.decode("ascii", "replace"))
                print(f"uploaded {sent} bytes; send 'reboot' to boot the new slot")
                return 0
            if b"OTA FAILED" in line:
                raise RuntimeError(line.decode("ascii", "replace"))


if __name__ == "__main__":
    raise SystemExit(main())
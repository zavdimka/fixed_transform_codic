#!/usr/bin/env python3
"""Capture repeated raw FPGA DVP prefixes and report unstable byte positions."""

from __future__ import annotations

import argparse
import hashlib
import re
import time

import serial


WORD_PREFIX_RE = re.compile(rb"\[[0-9a-fA-F]{10}:[0-9a-fA-F]{2}\]")
LOG_LINE_RE = re.compile(rb"[IWE] \([^\r\n]*\) [^\r\n]*\r?\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--boot-wait", type=float, default=6.0)
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    captures: list[bytes] = []
    port = serial.Serial()
    port.port = args.port
    port.baudrate = 115200
    port.timeout = 0.1
    port.dtr = False
    port.rts = False
    with port:
        time.sleep(args.boot_wait)
        port.reset_input_buffer()
        port.write(b"camera pattern 1\n")
        port.flush()
        time.sleep(0.25)
        port.reset_input_buffer()
        for _ in range(args.count):
            port.write(b"camera capture\n")
            port.flush()
            deadline = time.monotonic() + args.timeout
            pending = bytearray()
            while time.monotonic() < deadline:
                chunk = port.read(4096)
                if chunk:
                    pending.extend(chunk)
                    start = pending.find(b"camera samples=")
                    end = pending.find(b"camera capture lines=", start + 1)
                    if start >= 0 and end >= 0:
                        text = pending[start + len(b"camera samples="):end]
                        text = LOG_LINE_RE.sub(b"", text)
                        text = WORD_PREFIX_RE.sub(b"", text)
                        text = b"".join(text.split())
                        sample = bytes.fromhex(text.decode("ascii"))
                        captures.append(sample)
                        break
            else:
                raise TimeoutError("camera capture response timed out")

    lengths = sorted({len(capture) for capture in captures})
    unique = {capture for capture in captures}
    print(f"captures={len(captures)} lengths={lengths} unique={len(unique)}")
    for index, capture in enumerate(captures):
        print(f"capture[{index}] sha256={hashlib.sha256(capture).hexdigest()[:16]}")
    if len(unique) == 1:
        print("PASS: every raw DVP prefix is bit-identical")
        return 0

    width = min(map(len, captures))
    unstable = []
    for offset in range(width):
        values = sorted({capture[offset] for capture in captures})
        if len(values) > 1:
            unstable.append((offset, values))
    print(f"FAIL: unstable_offsets={len(unstable)}")
    for offset, values in unstable[:64]:
        print(f"  offset={offset:03d} values=" + ",".join(f"{v:02x}" for v in values))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

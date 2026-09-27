#!/usr/bin/env python3
"""Capture a bounded interval of raw UART output to stdout."""

import argparse
import sys
import time

import serial


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="/dev/ttyACM0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--reset", action="store_true")
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.2) as uart:
        if args.reset:
            uart.dtr = False
            uart.rts = True
            time.sleep(0.15)
            uart.rts = False

        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            chunk = uart.read(4096)
            if chunk:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Send commands to an ESP USB console and capture its response."""

import argparse
import sys
import time

import serial


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("commands", nargs="+")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--seconds", type=float, default=5.0)
    parser.add_argument("--settle", type=float, default=0.25)
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.1) as console:
        console.reset_input_buffer()
        for command in args.commands:
            console.write(command.encode("utf-8") + b"\r")
            console.flush()
            time.sleep(args.settle)

        deadline = time.monotonic() + args.seconds
        output = bytearray()
        quiet_deadline = deadline
        while time.monotonic() < deadline:
            chunk = console.read(4096)
            if chunk:
                output.extend(chunk)
                quiet_deadline = min(deadline, time.monotonic() + 0.75)
            elif output and time.monotonic() >= quiet_deadline:
                break

    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

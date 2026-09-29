#!/usr/bin/env python3
"""Send one command to the ESP32 console and print its response."""

from __future__ import annotations

import argparse
import time

import serial


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("command", nargs="+")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--settle", type=float, default=0.3)
    parser.add_argument("--wait", type=float, default=1.0)
    parser.add_argument(
        "--between", type=float, default=0.0,
        help="delay between commands while keeping the serial port open",
    )
    parser.add_argument(
        "--max-wait", type=float, default=8.0,
        help="absolute response timeout per command",
    )
    parser.add_argument(
        "--then", action="append", default=[], metavar="COMMAND",
        help="send another command on the same serial connection after the prior response",
    )
    args = parser.parse_args()

    port = serial.Serial()
    port.port = args.port
    port.baudrate = args.baud
    port.timeout = 0.1
    port.dtr = False
    port.rts = False
    with port:
        time.sleep(args.settle)
        port.reset_input_buffer()
        commands = [" ".join(args.command), *args.then]
        for command_index, command in enumerate(commands):
            if command_index != 0 and args.between > 0:
                time.sleep(args.between)
            if command.startswith("@wait "):
                time.sleep(float(command[6:]))
                continue
            port.write((command + "\n").encode("ascii"))
            port.flush()
            deadline = time.monotonic() + args.wait
            hard_deadline = time.monotonic() + args.max_wait
            while time.monotonic() < min(deadline, hard_deadline):
                data = port.read(4096)
                if data:
                    print(data.decode("ascii", "replace"), end="")
                    deadline = time.monotonic() + args.wait
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import argparse
import time

import serial


def read_until_quiet(port: serial.Serial, quiet: float, limit: float) -> str:
    chunks: list[bytes] = []
    deadline = time.monotonic() + limit
    quiet_deadline = time.monotonic() + quiet
    while time.monotonic() < deadline:
        data = port.read(port.in_waiting or 1)
        if data:
            chunks.append(data)
            quiet_deadline = time.monotonic() + quiet
        elif chunks and time.monotonic() >= quiet_deadline:
            break
    return b"".join(chunks).decode("utf-8", errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("commands", nargs="+")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--settle", type=float, default=2.0)
    parser.add_argument("--quiet", type=float, default=0.6)
    parser.add_argument("--limit", type=float, default=8.0)
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.1) as uart:
        uart.dtr = False
        uart.rts = False
        time.sleep(args.settle)
        initial = read_until_quiet(uart, args.quiet, args.limit)
        if initial:
            print(initial, end="")
        for command in args.commands:
            uart.write(command.encode("ascii") + b"\r\n")
            uart.flush()
            print(read_until_quiet(uart, args.quiet, args.limit), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
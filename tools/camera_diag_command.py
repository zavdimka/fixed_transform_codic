#!/usr/bin/env python3
import argparse
import time

import serial


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("command", nargs="?", default="camera capture")
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--interval", type=float, default=0.1)
    parser.add_argument("--setup", action="append", default=[])
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")

    with serial.Serial(args.port, 115200, timeout=0.25) as port:
        port.dtr = False
        port.rts = False
        port.reset_input_buffer()
        for setup in args.setup:
            port.write((setup + "\n").encode("ascii"))
            port.flush()
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                line = port.readline()
                if line:
                    print(line.decode("ascii", "replace"), end="")
                    if setup.encode("ascii") + b":" in line:
                        break
        for capture_index in range(args.repeat):
            port.write((args.command + "\n").encode("ascii"))
            port.flush()
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                line = port.readline()
                if line:
                    print(line.decode("ascii", "replace"), end="")
                    if (b"camera capture" in line
                            and (b"lines=" in line or b":" in line)):
                        break
            if capture_index + 1 < args.repeat:
                time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

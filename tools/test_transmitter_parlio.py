#!/usr/bin/env python3
"""Capture and strictly verify the deterministic FPGA-to-ESP32 link test."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="ESP32 USB serial port, e.g. /dev/ttyACM0")
    parser.add_argument("--records", type=int, default=1000)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--capture-timeout", type=float, default=180.0)
    parser.add_argument("--io-timeout", type=float, default=30.0)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    output = args.output or (
        root / "artifacts" / f"parlio_selftest_{args.records}.hcap"
    )
    output.parent.mkdir(parents=True, exist_ok=True)

    subprocess.run(
        [
            sys.executable,
            str(root / "tools" / "capture_download.py"),
            args.port,
            str(output),
            "--packets",
            str(args.records),
            "--capture-timeout",
            str(args.capture_timeout),
            "--timeout",
            str(args.io_timeout),
            "--require-zero-dropped",
        ],
        check=True,
    )
    subprocess.run(
        [
            sys.executable,
            str(root / "tools" / "verify_parlio_link_capture.py"),
            str(output),
            "--records",
            str(args.records),
            "--start",
            "1",
        ],
        check=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Decode a 64-byte FPGA debug snapshot captured by ESP32 over SPI."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import json
from pathlib import Path

from hevc_reference.debug_interface import DebugSnapshot


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    snapshot = DebugSnapshot.from_bytes(args.snapshot.read_bytes())
    print(json.dumps(asdict(snapshot), indent=2))


if __name__ == "__main__":
    main()

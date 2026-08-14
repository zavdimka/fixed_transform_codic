#!/usr/bin/env python3
"""Generate the compile-time HEVC VPS/SPS/PPS RBSP ROM image."""

from __future__ import annotations

import argparse
from pathlib import Path

from hevc_reference.parameter_sets import parameter_set_rbsps


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=768)
    parser.add_argument("--fps", type=int, default=60)
    args = parser.parse_args()

    parameter_sets = parameter_set_rbsps(args.width, args.height, args.fps)
    lengths = tuple(map(len, parameter_sets))
    if lengths != (19, 35, 5):
        raise RuntimeError(f"ROM layout changed unexpectedly: {lengths}")
    image = b"".join(parameter_sets)
    args.output.write_text(" ".join(f"{value:02x}" for value in image) + "\n")
    print("lengths=" + ",".join(map(str, lengths)))
    print(f"total={len(image)}")


if __name__ == "__main__":
    main()

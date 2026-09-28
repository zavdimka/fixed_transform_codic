#!/usr/bin/env python3
"""Report clipping and coarse spatial statistics for planar YUV420 frames."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np


def summarize(name: str, plane: np.ndarray) -> None:
    percentiles = np.percentile(plane, [0, 1, 10, 50, 90, 99, 100])
    clipping = 100.0 * np.count_nonzero((plane == 0) | (plane == 255)) / plane.size
    fields = " ".join(f"p{p}={value:.1f}" for p, value in zip(
        (0, 1, 10, 50, 90, 99, 100), percentiles))
    print(f"{name}: mean={plane.mean():.1f} {fields} clipped={clipping:.2f}%")


def band_medians(plane: np.ndarray, bands: int) -> str:
    height, width = plane.shape
    y0, y1 = height // 3, 2 * height // 3
    values = []
    for band in range(bands):
        x0 = width * band // bands
        x1 = width * (band + 1) // bands
        values.append(int(np.median(plane[y0:y1, x0:x1])))
    return " ".join(str(value) for value in values)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("frame", type=Path)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--bands", type=int, default=16)
    args = parser.parse_args()

    raw = np.fromfile(args.frame, dtype=np.uint8)
    y_size = args.width * args.height
    c_size = y_size // 4
    if raw.size != y_size + 2 * c_size:
        raise ValueError(f"expected {y_size + 2 * c_size} bytes, got {raw.size}")
    y = raw[:y_size].reshape(args.height, args.width)
    cb = raw[y_size:y_size + c_size].reshape(args.height // 2, args.width // 2)
    cr = raw[y_size + c_size:].reshape(args.height // 2, args.width // 2)

    for name, plane in (("Y", y), ("Cb", cb), ("Cr", cr)):
        summarize(name, plane)
        print(f"{name} band medians: {band_medians(plane, args.bands)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Render YUV420 planes captured from the receiver RTL simulation."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import jpeg_radio_codec as codec  # noqa: E402


def read_plane(path: Path, shape: tuple[int, int]) -> np.ndarray:
    data = np.fromfile(path, dtype=np.uint8)
    expected = shape[0] * shape[1]
    if data.size != expected:
        raise ValueError(f"{path} contains {data.size} bytes, expected {expected}")
    return data.reshape(shape)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_dir", type=Path)
    parser.add_argument("--expected", type=Path)
    args = parser.parse_args()

    capture_dir = args.capture_dir.resolve()
    y = read_plane(capture_dir / "rtl_y.raw", (720, 1280))
    cb = read_plane(capture_dir / "rtl_cb.raw", (360, 640))
    cr = read_plane(capture_dir / "rtl_cr.raw", (360, 640))
    rgb = codec.ycbcr420_to_rgb(y, cb, cr)
    output = capture_dir / "rtl_frame.png"
    Image.fromarray(rgb).save(output)

    report: dict[str, object] = {"image": str(output)}
    if args.expected:
        expected = np.asarray(Image.open(args.expected).convert("RGB"), dtype=np.uint8)
        if expected.shape != rgb.shape:
            raise ValueError(
                f"expected image shape {expected.shape}, captured {rgb.shape}"
            )
        signed_delta = rgb.astype(np.int16) - expected.astype(np.int16)
        absolute_delta = np.abs(signed_delta)
        mse = float(np.mean(signed_delta.astype(np.float64) ** 2))
        report.update({
            "expected": str(args.expected.resolve()),
            "mae": float(np.mean(absolute_delta)),
            "max_error": int(np.max(absolute_delta)),
            "different_channel_values": int(np.count_nonzero(absolute_delta)),
            "different_pixels": int(np.count_nonzero(np.any(absolute_delta, axis=2))),
            "psnr_db": math.inf if mse == 0.0 else 10.0 * math.log10(255.0**2 / mse),
        })
        Image.fromarray(np.clip(absolute_delta * 4, 0, 255).astype(np.uint8)).save(
            capture_dir / "difference_x4.png"
        )

    (capture_dir / "render_report.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

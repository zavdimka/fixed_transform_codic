#!/usr/bin/env python3
"""Export real quantized blocks for RTL scheduler throughput measurements."""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import custom_codec_experiment as codec
import jpeg_radio_codec as core


BLOCKS_PER_CTU = 6


def parse_size(value: str) -> tuple[int, int]:
    try:
        width_text, height_text = value.lower().split("x", 1)
        width, height = int(width_text), int(height_text)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError("size must be WIDTHxHEIGHT") from error
    if width <= 0 or height <= 0 or width % 16 or height % 16:
        raise argparse.ArgumentTypeError("trace size must be positive and CTU16 aligned")
    return width, height


def parse_qualities(value: str) -> tuple[int, ...]:
    try:
        qualities = tuple(int(item) for item in value.split(","))
    except ValueError as error:
        raise argparse.ArgumentTypeError("qualities must be comma-separated integers") from error
    if not qualities or any(not 1 <= quality <= 100 for quality in qualities):
        raise argparse.ArgumentTypeError("qualities must be in [1, 100]")
    return qualities


def fit_rgb(image_path: Path, size: tuple[int, int]) -> np.ndarray:
    with Image.open(image_path) as source:
        fitted = ImageOps.fit(
            source.convert("RGB"), size, method=Image.Resampling.LANCZOS
        )
        return np.asarray(fitted, dtype=np.uint8)


def export_stripe(
    task: tuple[int, int, np.ndarray, np.ndarray, np.ndarray],
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    quality, stripe_y, y_source, cb_source, cr_source = task
    stats = core.ArithmeticStats()
    blocks: list[codec.QuantizedBlockTrace] = []
    modes: list[int] = []
    codec.encode_stripe(
        y_source, cb_source, cr_source, quality, stripe_y, stats,
        trace_blocks=blocks, trace_modes=modes,
    )
    ctu_columns = y_source.shape[1] // 16
    expected_blocks = ctu_columns * BLOCKS_PER_CTU
    if len(blocks) != expected_blocks:
        raise AssertionError(
            f"stripe {stripe_y} produced {len(blocks)}, expected {expected_blocks} blocks"
        )
    if len(modes) != ctu_columns:
        raise AssertionError(
            f"stripe {stripe_y} produced {len(modes)}, expected {ctu_columns} modes"
        )
    coefficients = np.asarray(
        [block.coefficients for block in blocks], dtype=np.int16
    ).reshape(ctu_columns, BLOCKS_PER_CTU, 64)
    table_ids = np.asarray(
        [block.table_id for block in blocks], dtype=np.uint8
    ).reshape(ctu_columns, BLOCKS_PER_CTU)
    base_counts = np.asarray(
        [block.base_count for block in blocks], dtype=np.uint8
    ).reshape(ctu_columns, BLOCKS_PER_CTU)
    return coefficients, table_ids, base_counts, np.asarray(modes, dtype=np.uint8)


def export_quality(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    quality: int,
    jobs: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    tasks = [
        (
            quality,
            stripe_y,
            y[y0:y0 + 16],
            cb[y0 // 2:y0 // 2 + 8],
            cr[y0 // 2:y0 // 2 + 8],
        )
        for stripe_y, y0 in enumerate(range(0, y.shape[0], 16))
    ]
    if jobs == 1:
        stripes = list(map(export_stripe, tasks))
    else:
        with ProcessPoolExecutor(max_workers=jobs) as executor:
            stripes = list(executor.map(export_stripe, tasks))

    coefficients = np.stack([stripe[0] for stripe in stripes])
    table_ids = np.stack([stripe[1] for stripe in stripes])
    base_counts = np.stack([stripe[2] for stripe in stripes])
    modes = np.stack([stripe[3] for stripe in stripes])
    if np.any(coefficients < -2048) or np.any(coefficients > 2047):
        raise ValueError(
            f"Q{quality} trace exceeds the signed 12-bit coefficient interface"
        )
    return coefficients, table_ids, base_counts, modes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--size", type=parse_size, default=(1280, 720))
    parser.add_argument("--qualities", type=parse_qualities, default=(20, 24))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs <= 0:
        raise SystemExit("--jobs must be positive")

    rgb = fit_rgb(args.image, args.size)
    y, cb, cr = core.rgb_to_ycbcr420(rgb)
    y, cb, cr = codec.pad_stripe_planes(y, cb, cr)
    payload: dict[str, np.ndarray] = {
        "width": np.asarray(args.size[0], dtype=np.uint16),
        "height": np.asarray(args.size[1], dtype=np.uint16),
        "qualities": np.asarray(args.qualities, dtype=np.uint8),
    }
    for quality in args.qualities:
        coefficients, table_ids, base_counts, modes = export_quality(
            y, cb, cr, quality, args.jobs
        )
        prefix = f"q{quality}"
        payload[f"{prefix}_coefficients"] = coefficients
        payload[f"{prefix}_table_ids"] = table_ids
        payload[f"{prefix}_base_counts"] = base_counts
        payload[f"{prefix}_modes"] = modes
        nonzero = np.count_nonzero(coefficients)
        print(
            f"Q{quality}: shape={coefficients.shape}, "
            f"nonzero={nonzero}/{coefficients.size} "
            f"({100.0 * nonzero / coefficients.size:.2f}%)"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.output, **payload)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()

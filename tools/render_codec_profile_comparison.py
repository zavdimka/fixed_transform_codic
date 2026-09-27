#!/usr/bin/env python3
"""Render visual comparisons for bounded single-layer codec profiles.

Each 16-line stripe is independent in the production format, so the slow
Python reference can be evaluated in parallel without changing codec state.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
import os
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import custom_codec_experiment as codec  # noqa: E402
import jpeg_radio_codec as core  # noqa: E402


WIDTH = 1280
HEIGHT = 720


@dataclass(frozen=True)
class Profile:
    name: str
    luma_coefficients: int
    chroma_coefficients: int
    enhancement: bool = False


PROFILES = (
    Profile("base_06_03", 6, 3),
    Profile("single_10_05", 10, 5),
    Profile("single_14_07", 14, 7),
    Profile("single_18_09", 18, 9),
    Profile("single_22_11", 22, 11),
    Profile("full_enhancement", 6, 3, True),
)


def _decode_task(task: tuple) -> tuple[str, int, np.ndarray, np.ndarray, np.ndarray, int]:
    (
        profile,
        quality,
        stripe_index,
        y_source,
        cb_source,
        cr_source,
    ) = task
    codec.LUMA_BASE_COEFFICIENTS = profile.luma_coefficients
    codec.CHROMA_BASE_COEFFICIENTS = profile.chroma_coefficients
    record = codec.encode_stripe(
        y_source,
        cb_source,
        cr_source,
        quality,
        stripe_index,
        core.ArithmeticStats(),
    )
    base, full = codec.decode_stripe(
        record,
        quality,
        core.ArithmeticStats(),
        enhancement=profile.enhancement,
    )
    decoded = full if profile.enhancement else base
    bits = record.base_bits + (record.enhancement_bits if profile.enhancement else 0)
    return profile.name, stripe_index, decoded[0], decoded[1], decoded[2], bits


def _font(size: int) -> ImageFont.ImageFont:
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def _contact_sheet(
    images: list[tuple[str, Image.Image]],
    columns: int,
    scale: float,
) -> Image.Image:
    label_height = 36
    sample = images[0][1]
    tile_width = round(sample.width * scale)
    tile_height = round(sample.height * scale)
    rows = (len(images) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * tile_width, rows * (tile_height + label_height)), "white")
    draw = ImageDraw.Draw(sheet)
    font = _font(18)
    for index, (label, image) in enumerate(images):
        left = (index % columns) * tile_width
        top = (index // columns) * (tile_height + label_height)
        resized = image.resize((tile_width, tile_height), Image.Resampling.LANCZOS)
        sheet.paste(resized, (left, top + label_height))
        draw.text((left + 8, top + 7), label, fill="black", font=font)
    return sheet


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--quality", type=int, default=24)
    parser.add_argument("--workers", type=int, default=min(12, os.cpu_count() or 1))
    args = parser.parse_args()

    with Image.open(args.image) as source_file:
        source_image = source_file.convert("RGB").resize(
            (WIDTH, HEIGHT), Image.Resampling.LANCZOS
        )
    source_rgb = np.asarray(source_image, dtype=np.uint8)
    y, cb, cr = core.rgb_to_ycbcr420(source_rgb)

    decoded = {
        profile.name: (
            np.empty_like(y),
            np.empty_like(cb),
            np.empty_like(cr),
        )
        for profile in PROFILES
    }
    profile_bits = {profile.name: 0 for profile in PROFILES}
    tasks = []
    for profile in PROFILES:
        for stripe_index, y0 in enumerate(range(0, HEIGHT, 16)):
            tasks.append((
                profile,
                args.quality,
                stripe_index,
                y[y0:y0 + 16],
                cb[y0 // 2:y0 // 2 + 8],
                cr[y0 // 2:y0 // 2 + 8],
            ))

    completed = 0
    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        futures = [executor.submit(_decode_task, task) for task in tasks]
        for future in as_completed(futures):
            name, stripe_index, stripe_y, stripe_cb, stripe_cr, bits = future.result()
            y0 = stripe_index * 16
            decoded[name][0][y0:y0 + 16] = stripe_y
            decoded[name][1][y0 // 2:y0 // 2 + 8] = stripe_cb
            decoded[name][2][y0 // 2:y0 // 2 + 8] = stripe_cr
            profile_bits[name] += bits
            completed += 1
            if completed % 45 == 0:
                print(f"completed {completed}/{len(tasks)} stripes", flush=True)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    source_image.save(args.output_dir / "source.png")
    rendered: list[tuple[str, Image.Image]] = [("Original", source_image)]
    pixels = WIDTH * HEIGHT
    for profile in PROFILES:
        rgb = core.ycbcr420_to_rgb(*decoded[profile.name])
        image = Image.fromarray(rgb.astype(np.uint8), "RGB")
        bpp = profile_bits[profile.name] / pixels
        label = profile.name.replace("_", " ") + f" ({bpp:.3f} bpp)"
        image.save(args.output_dir / f"{profile.name}.png")
        rendered.append((label, image))
        print(f"{profile.name}: {bpp:.5f} bpp", flush=True)

    _contact_sheet(rendered, columns=2, scale=0.5).save(
        args.output_dir / "comparison_full.png"
    )

    # Central symbols and the fine writing at the right are the most useful
    # regions for seeing transform blur and ringing on this reference image.
    crop_box = (360, 70, 1240, 650)
    crops = [(label, image.crop(crop_box)) for label, image in rendered]
    _contact_sheet(crops, columns=2, scale=1.0).save(
        args.output_dir / "comparison_detail.png"
    )


if __name__ == "__main__":
    main()

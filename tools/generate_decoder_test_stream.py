#!/usr/bin/env python3
"""Generate a repeatable base-layer hardware decoder test stream."""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import custom_codec_experiment as codec  # noqa: E402
import jpeg_radio_codec as core  # noqa: E402


WIDTH = 1280
HEIGHT = 720
QUALITY = 24
FRAGMENT_BYTES = 900
FILE_MAGIC = b"HDZRXT1\0"


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = (((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1) & 0xFFFF
    return crc


def make_source_image() -> np.ndarray:
    bars = (
        (235, 235, 235), (235, 215, 35), (35, 215, 215), (35, 200, 55),
        (215, 45, 205), (215, 45, 45), (45, 55, 215), (20, 20, 20),
    )
    image = Image.new("RGB", (WIDTH, HEIGHT), "black")
    draw = ImageDraw.Draw(image)
    bar_width = WIDTH // len(bars)
    for index, color in enumerate(bars):
        draw.rectangle((index * bar_width, 0,
                        (index + 1) * bar_width - 1, HEIGHT - 1), fill=color)

    draw.rectangle((64, 72, WIDTH - 65, 218), fill=(18, 18, 18),
                   outline=(255, 255, 255), width=6)
    draw.rectangle((64, 502, WIDTH - 65, 648), fill=(18, 18, 18),
                   outline=(255, 255, 255), width=6)
    font = ImageFont.load_default(size=54)
    small = ImageFont.load_default(size=34)
    draw.text((112, 108), "FPGA BASE DECODER", fill=(255, 255, 255), font=font)
    draw.text((112, 538), "PRECOMPUTED FILE / 1280x720", fill=(255, 255, 255),
              font=small)

    for y in range(256, 466, 32):
        draw.line((0, y, WIDTH - 1, y), fill=(255, 255, 255), width=2)
    for x in range(0, WIDTH, 80):
        draw.line((x, 240, x, 480), fill=(0, 0, 0), width=2)
    return np.asarray(image, dtype=np.uint8)


def make_link_record(payload: bytes, *, sequence: int, stripe: int,
                     fragment_index: int, fragment_count: int,
                     final_valid_bits: int) -> bytes:
    flags = final_valid_bits - 1 if fragment_index == fragment_count - 1 else 0
    header = bytes((0xC5, 0x3A, 0x01, 0x10))
    header += struct.pack("<HHH", sequence, 1, 1)
    header += bytes((stripe, QUALITY, fragment_index, fragment_count, flags, 0))
    header += struct.pack("<H", len(payload))
    body = header + payload
    return body + struct.pack("<H", crc16_ccitt(body))


def generate(output: Path, preview_dir: Path) -> None:
    source = make_source_image()
    y, cb, cr = core.rgb_to_ycbcr420(source)
    records: list[bytes] = []
    decoded_y = np.empty_like(y)
    decoded_cb = np.empty_like(cb)
    decoded_cr = np.empty_like(cr)
    sequence = 0
    maximum_base = 0

    for stripe in range(HEIGHT // 16):
        y0 = stripe * 16
        encoded = codec.encode_stripe(
            y[y0:y0 + 16], cb[y0 // 2:y0 // 2 + 8],
            cr[y0 // 2:y0 // 2 + 8], QUALITY, stripe,
            core.ArithmeticStats(), base_max_bytes=2048,
            enhancement_max_bytes=1536,
        )
        base_planes, _ = codec.decode_stripe(
            encoded, QUALITY, core.ArithmeticStats(), enhancement=False
        )
        decoded_y[y0:y0 + 16] = base_planes[0]
        decoded_cb[y0 // 2:y0 // 2 + 8] = base_planes[1]
        decoded_cr[y0 // 2:y0 // 2 + 8] = base_planes[2]

        maximum_base = max(maximum_base, len(encoded.base_data))
        chunks = [encoded.base_data[offset:offset + FRAGMENT_BYTES]
                  for offset in range(0, len(encoded.base_data), FRAGMENT_BYTES)]
        valid_bits = (encoded.base_bits - 1) % 8 + 1
        for fragment_index, chunk in enumerate(chunks):
            records.append(make_link_record(
                chunk, sequence=sequence, stripe=stripe,
                fragment_index=fragment_index, fragment_count=len(chunks),
                final_valid_bits=valid_bits,
            ))
            sequence = (sequence + 1) & 0xFFFF

    maximum_record = max(map(len, records))
    if maximum_record > 1024:
        raise RuntimeError(f"record exceeds parser limit: {maximum_record}")
    frame_crc = zlib.crc32(decoded_y.astype(np.uint8).tobytes())
    frame_crc = zlib.crc32(decoded_cb.astype(np.uint8).tobytes(), frame_crc)
    frame_crc = zlib.crc32(decoded_cr.astype(np.uint8).tobytes(), frame_crc)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stream:
        stream.write(FILE_MAGIC)
        stream.write(struct.pack("<HHI", len(records), maximum_record, frame_crc))
        for record in records:
            stream.write(struct.pack("<H", len(record)))
            stream.write(record)

    preview_dir.mkdir(parents=True, exist_ok=True)
    Image.fromarray(source).save(preview_dir / "source.png")
    decoded = core.ycbcr420_to_rgb(decoded_y, decoded_cb, decoded_cr)
    Image.fromarray(decoded).save(preview_dir / "expected_base.png")
    print(f"wrote {output}: {len(records)} records, {output.stat().st_size} bytes")
    print(f"maximum base stripe {maximum_base} bytes, record {maximum_record} bytes")
    print(f"decoded YUV CRC32 {frame_crc:08x}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=ROOT / "esp32/fs/test/decoder_base.rxt")
    parser.add_argument("--preview-dir", type=Path,
                        default=ROOT / "test_vectors/decoder_base")
    args = parser.parse_args()
    generate(args.output, args.preview_dir)


if __name__ == "__main__":
    main()

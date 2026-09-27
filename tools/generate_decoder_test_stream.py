#!/usr/bin/env python3
"""Generate a repeatable base-layer hardware decoder test stream."""

from __future__ import annotations

import argparse
import os
import struct
import sys
import zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import bounded_iht_codec as bounded  # noqa: E402
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


def make_source_image(source_image: Path | None = None) -> np.ndarray:
    if source_image is not None:
        with Image.open(source_image) as input_image:
            image = input_image.convert("RGB")
            if image.size != (WIDTH, HEIGHT):
                image = image.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)
            return np.asarray(image, dtype=np.uint8)

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
    try:
        font = ImageFont.load_default(size=54)
        small = ImageFont.load_default(size=34)
    except TypeError:  # Pillow < 10.1
        font = ImageFont.load_default()
        small = font
    draw.text((112, 108), "FPGA BASE DECODER", fill=(255, 255, 255), font=font)
    draw.text((112, 538), "PRECOMPUTED FILE / 1280x720", fill=(255, 255, 255),
              font=small)

    for y in range(256, 466, 32):
        draw.line((0, y, WIDTH - 1, y), fill=(255, 255, 255), width=2)
    for x in range(0, WIDTH, 80):
        draw.line((x, 240, x, 480), fill=(0, 0, 0), width=2)
    return np.asarray(image, dtype=np.uint8)


def make_link_record(payload: bytes, *, record_type: int, sequence: int, stripe: int,
                     fragment_index: int, fragment_count: int,
                     final_valid_bits: int) -> bytes:
    flags = final_valid_bits - 1 if fragment_index == fragment_count - 1 else 0
    header = bytes((0xC5, 0x3A, 0x01, record_type))
    header += struct.pack("<HHH", sequence, 1, 1)
    header += bytes((stripe, QUALITY, fragment_index, fragment_count, flags, 0))
    header += struct.pack("<H", len(payload))
    body = header + payload
    return body + struct.pack("<H", crc16_ccitt(body))


def encode_bounded_block(
    guard: codec.DualBudgetWriter,
    residual: np.ndarray,
    *,
    table_id: int,
    base_count: int,
    maximum_ac: int,
    quant_shift: int,
    selection_strategy: str = "energy",
) -> tuple[np.ndarray, np.ndarray, bool, bool]:
    """Encode one block exactly as receiver_bounded_sparse_iht8 consumes it."""
    quantized = bounded.quantize_sparse_block(
        residual.astype(int).tolist(), quant_shift, max_ac=63
    ).coefficients()
    zigzag_addresses = [row * 8 + column for row, column in core.ZIGZAG]
    base_values = [quantized.get(address, 0)
                   for address in zigzag_addresses[:base_count]]

    dc = min(2047, max(-2047, int(base_values[0])))
    dc_size = core.magnitude_category(dc)
    result = guard.submit(codec._vlc_budget_token(
        codec.Layer.BASE, codec.VlcClass.DC, table_id, dc_size,
        core.amplitude_bits(dc, dc_size), dc_size,
        mandatory=True, reserve_release=codec.DC_MAX_TOKEN_BITS[table_id],
    ))
    if result is not codec.Admission.ACCEPTED:
        raise RuntimeError("reserved bounded DC token did not fit")

    transmitted_base_ac, base_truncated = codec._submit_ac_segment(
        guard, codec.Layer.BASE, base_values[1:], table_id, table_id == 0
    )
    transmitted_base = [dc] + transmitted_base_ac

    # The transform counts every fixed base AC address even when its value is
    # zero. Reserve those slots, then spend the remaining limit on the most
    # visually useful full-band coefficients outside the base prefix.
    enhancement_slots = maximum_ac - (base_count - 1)
    candidates = [
        (scan_index, address, quantized.get(address, 0))
        for scan_index, address in enumerate(
            zigzag_addresses[base_count:], start=base_count
        )
        if quantized.get(address, 0)
    ]
    candidates.sort(key=lambda item: (
        bounded.coefficient_priority(item[1], item[2], quant_shift),
        -item[0],
    ), reverse=True)
    if selection_strategy == "energy":
        selected = {
            scan_index: value
            for scan_index, _address, value in candidates[:enhancement_slots]
        }
    elif selection_strategy == "low-frequency":
        selected = {
            scan_index: value
            for scan_index, _address, value in candidates
            if scan_index <= maximum_ac
        }
    elif selection_strategy == "hybrid":
        guaranteed_ac = 9 if table_id == 0 else 4
        fixed_indices = tuple(range(base_count, guaranteed_ac + 1))
        adaptive_slots = enhancement_slots - len(fixed_indices)
        adaptive = [
            item for item in candidates if item[0] > guaranteed_ac
        ][:adaptive_slots]
        selected = {
            **{
                scan_index: quantized.get(zigzag_addresses[scan_index], 0)
                for scan_index in fixed_indices
            },
            **{
                scan_index: value
                for scan_index, _address, value in adaptive
            },
        }
    else:
        raise ValueError(
            f"unknown coefficient selection strategy: {selection_strategy}"
        )
    enhancement_input = [
        selected.get(scan_index, 0)
        for scan_index in range(base_count, 64)
    ]
    transmitted_enhancement, enhancement_truncated = codec._submit_ac_segment(
        guard, codec.Layer.ENHANCEMENT, enhancement_input,
        table_id, table_id == 0,
    )
    enhancement_truncated |= any(
        value and scan_index not in selected
        for scan_index, _address, value in candidates
    )

    base_events = {
        zigzag_addresses[index]: value
        for index, value in enumerate(transmitted_base)
        if value
    }
    full_events = dict(base_events)
    for offset, value in enumerate(transmitted_enhancement,
                                   start=base_count):
        if value:
            full_events[zigzag_addresses[offset]] = value
    base_residual = np.asarray(
        bounded.inverse_block(base_events, quant_shift), dtype=np.int16
    )
    full_residual = np.asarray(
        bounded.inverse_block(full_events, quant_shift), dtype=np.int16
    )
    return (base_residual, full_residual,
            base_truncated, enhancement_truncated)


def encode_bounded_stripe(
    y_source: np.ndarray,
    cb_source: np.ndarray,
    cr_source: np.ndarray,
    *,
    quality: int,
    include_enhancement: bool,
    selection_strategy: str = "energy",
) -> tuple[bytes, int, bytes, int, tuple[np.ndarray, np.ndarray, np.ndarray]]:
    """Build one hardware stream stripe and its bit-exact reconstructed YUV."""
    width = y_source.shape[1]
    reconstructed_y = np.zeros_like(y_source, dtype=np.int16)
    reconstructed_cb = np.zeros_like(cb_source, dtype=np.int16)
    reconstructed_cr = np.zeros_like(cr_source, dtype=np.int16)
    base_reserve, enhancement_reserve = codec._stripe_mandatory_reserve(
        width // 16, local_prediction=False, adaptive_quant=False
    )
    guard = codec.DualBudgetWriter(
        2048 * 8, 1536 * 8, base_reserve, enhancement_reserve
    )
    quant_shift = quality & 7

    for lx in range(0, width, 16):
        cx = lx // 2
        y_predictors = codec._predictors(reconstructed_y, 0, lx, 16)
        cb_predictors = codec._predictors(reconstructed_cb, 0, cx, 8)
        cr_predictors = codec._predictors(reconstructed_cr, 0, cx, 8)
        mode = min(
            y_predictors,
            key=lambda candidate: (
                core.residual_satd(
                    y_source[:, lx:lx + 16] - y_predictors[candidate]
                )
                + core.residual_satd(
                    cb_source[:, cx:cx + 8] - cb_predictors[candidate]
                )
                + core.residual_satd(
                    cr_source[:, cx:cx + 8] - cr_predictors[candidate]
                ),
                candidate,
            ),
        )
        result = guard.submit(codec._raw_budget_token(
            codec.Layer.BASE, mode, core.INTRA_MODE_BITS,
            mandatory=True, reserve_release=core.INTRA_MODE_BITS,
        ))
        if result is not codec.Admission.ACCEPTED:
            raise RuntimeError("reserved bounded intra mode did not fit")

        for sub_row in range(2):
            for sub_column in range(2):
                by, bx = sub_row * 8, lx + sub_column * 8
                predictor = y_predictors[mode][
                    by:by + 8, sub_column * 8:(sub_column + 1) * 8
                ]
                base_residual, full_residual, _, _ = encode_bounded_block(
                    guard,
                    y_source[by:by + 8, bx:bx + 8].astype(np.int16)
                    - predictor,
                    table_id=0, base_count=6, maximum_ac=12,
                    quant_shift=quant_shift,
                    selection_strategy=selection_strategy,
                )
                chosen = full_residual if include_enhancement else base_residual
                reconstructed_y[by:by + 8, bx:bx + 8] = np.clip(
                    predictor.astype(np.int64) + chosen, 0, 255
                )

        for source_plane, reconstructed_plane, predictors in (
            (cb_source, reconstructed_cb, cb_predictors),
            (cr_source, reconstructed_cr, cr_predictors),
        ):
            predictor = predictors[mode]
            base_residual, full_residual, _, _ = encode_bounded_block(
                guard,
                source_plane[:, cx:cx + 8].astype(np.int16) - predictor,
                table_id=1, base_count=3, maximum_ac=6,
                quant_shift=quant_shift,
                selection_strategy=selection_strategy,
            )
            chosen = full_residual if include_enhancement else base_residual
            reconstructed_plane[:, cx:cx + 8] = np.clip(
                predictor.astype(np.int64) + chosen, 0, 255
            )

    base_data, enhancement_data, base_bits, enhancement_bits = \
        codec._finish_bounded_streams(guard)
    return (
        base_data, base_bits, enhancement_data, enhancement_bits,
        (reconstructed_y, reconstructed_cb, reconstructed_cr),
    )

def _encode_stripe_job(
    job: tuple[int, np.ndarray, np.ndarray, np.ndarray, bool, str],
) -> tuple[int, bytes, int, bytes, int,
           tuple[np.ndarray, np.ndarray, np.ndarray]]:
    (stripe, y_source, cb_source, cr_source, include_enhancement,
     selection_strategy) = job
    encoded = encode_bounded_stripe(
        y_source, cb_source, cr_source, quality=QUALITY,
        include_enhancement=include_enhancement,
        selection_strategy=selection_strategy,
    )
    return (stripe, *encoded)


def _encode_jpeg_stripe_job(
    job: tuple[int, np.ndarray, np.ndarray, np.ndarray, bool],
) -> tuple[int, bytes, int, bytes, int,
           tuple[np.ndarray, np.ndarray, np.ndarray]]:
    """Encode one stripe for the full JPEG-compatible 8x8 DCT datapath."""
    stripe, y_source, cb_source, cr_source, include_enhancement = job
    encoded = codec.encode_stripe(
        y_source, cb_source, cr_source, QUALITY, stripe,
        core.ArithmeticStats(), base_max_bytes=2048,
        enhancement_max_bytes=1536,
    )
    base_decoded, full_decoded = codec.decode_stripe(
        encoded, QUALITY, core.ArithmeticStats(),
        enhancement=include_enhancement,
    )
    decoded = full_decoded if include_enhancement else base_decoded
    return (
        stripe, encoded.base_data, encoded.base_bits,
        encoded.enhancement_data, encoded.enhancement_bits, decoded,
    )


def generate(output: Path, preview_dir: Path, include_enhancement: bool,
             source_image: Path | None = None, jobs: int = 1,
             selection_strategy: str = "energy",
             transform_profile: str = "bounded-iht") -> None:
    source = make_source_image(source_image)
    y, cb, cr = core.rgb_to_ycbcr420(source)
    records: list[bytes] = []
    decoded_y = np.empty_like(y)
    decoded_cb = np.empty_like(cb)
    decoded_cr = np.empty_like(cr)
    sequence = 0
    maximum_base = 0

    stripe_jobs = []
    for stripe in range(HEIGHT // 16):
        y0 = stripe * 16
        common_job = (
            stripe, y[y0:y0 + 16], cb[y0 // 2:y0 // 2 + 8],
            cr[y0 // 2:y0 // 2 + 8], include_enhancement,
        )
        stripe_jobs.append(
            (*common_job, selection_strategy)
            if transform_profile == "bounded-iht" else common_job
        )

    encode_job = (_encode_stripe_job if transform_profile == "bounded-iht"
                  else _encode_jpeg_stripe_job)
    if jobs > 1:
        with ProcessPoolExecutor(max_workers=jobs) as executor:
            encoded_stripes = list(executor.map(encode_job, stripe_jobs))
    else:
        encoded_stripes = list(map(encode_job, stripe_jobs))

    for (stripe, base_data, base_bits, enhancement_data, enhancement_bits,
         decoded_planes) in encoded_stripes:
        y0 = stripe * 16
        decoded_y[y0:y0 + 16] = decoded_planes[0]
        decoded_cb[y0 // 2:y0 // 2 + 8] = decoded_planes[1]
        decoded_cr[y0 // 2:y0 // 2 + 8] = decoded_planes[2]

        if include_enhancement:
            enhancement_chunks = [
                enhancement_data[offset:offset + FRAGMENT_BYTES]
                for offset in range(0, len(enhancement_data), FRAGMENT_BYTES)
            ]
            enhancement_valid_bits = (enhancement_bits - 1) % 8 + 1
            for fragment_index, chunk in enumerate(enhancement_chunks):
                records.append(make_link_record(
                    chunk, record_type=0x11, sequence=sequence,
                    stripe=stripe, fragment_index=fragment_index,
                    fragment_count=len(enhancement_chunks),
                    final_valid_bits=enhancement_valid_bits,
                ))
                sequence = (sequence + 1) & 0xFFFF

        maximum_base = max(maximum_base, len(base_data))
        chunks = [base_data[offset:offset + FRAGMENT_BYTES]
                  for offset in range(0, len(base_data), FRAGMENT_BYTES)]
        valid_bits = (base_bits - 1) % 8 + 1
        for fragment_index, chunk in enumerate(chunks):
            records.append(make_link_record(
                chunk, record_type=0x10, sequence=sequence, stripe=stripe,
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
    parser.add_argument(
        "--source-image", type=Path,
        default=ROOT / "test_vectors/decoder_base/input.png",
        help="RGB image resized to the 1280x720 decoder frame",
    )
    parser.add_argument("--include-enhancement", action="store_true")
    parser.add_argument(
        "--selection-strategy",
        choices=("energy", "low-frequency", "hybrid"),
        default="energy",
    )
    parser.add_argument(
        "--transform-profile",
        choices=("bounded-iht", "jpeg-dct"),
        default="bounded-iht",
        help="coefficient/transform format expected by the FPGA decoder",
    )
    parser.add_argument(
        "--jobs", type=int,
        default=max(1, min(8, os.cpu_count() or 1)),
        help="parallel stripe encoders (default: up to 8)",
    )
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    generate(args.output, args.preview_dir, args.include_enhancement,
             args.source_image, args.jobs, args.selection_strategy,
             args.transform_profile)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""FPGA-oriented layered intra codec reference model.

The codec ends at independently tagged base/enhancement tile records.  Radio
packet packing, interleaving and low-frequency duplication deliberately belong
to the ESP32 transport layer and are not modelled here.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
from pathlib import Path

import numpy as np
from PIL import Image

import jpeg_radio_codec as core


TILE_SIZE = 64
LUMA_BASE_COEFFICIENTS = 6
CHROMA_BASE_COEFFICIENTS = 3
BASE_QUALITY_OFFSET = 2


@dataclass(frozen=True)
class LayeredTileRecord:
    tile_x: int
    tile_y: int
    base_data: bytes
    base_bits: int
    enhancement_data: bytes
    enhancement_bits: int


@dataclass
class CodecResult:
    full_rgb: np.ndarray
    base_rgb: np.ndarray
    records: list[LayeredTileRecord]
    base_bits: int
    enhancement_bits: int
    full_psnr: float
    base_psnr: float
    saturations: int

    @property
    def total_bits(self) -> int:
        return self.base_bits + self.enhancement_bits


def encode_ac_segment(
    writer: core.BitWriter,
    values: list[int],
    table_id: int,
    presence_prefix: bool = False,
) -> list[int]:
    """Encode one known-length zigzag segment with JPEG-style static VLC."""
    transmitted = [0] * len(values)
    last_nonzero = max((i for i, value in enumerate(values) if value), default=-1)
    if presence_prefix:
        writer.write(int(last_nonzero >= 0), 1)
        if last_nonzero < 0:
            return transmitted
    run = 0
    for index, raw_value in enumerate(values):
        if not raw_value:
            run += 1
            continue
        value = min(1023, max(-1023, int(raw_value)))
        while run >= 16:
            core.huffman_write(writer, 1, table_id, 0xF0)
            run -= 16
        size = core.magnitude_category(value)
        core.huffman_write(writer, 1, table_id, (run << 4) | size)
        writer.write(core.amplitude_bits(value, size), size)
        transmitted[index] = value
        run = 0
    if last_nonzero < len(values) - 1:
        core.huffman_write(writer, 1, table_id, 0x00)
    return transmitted


def decode_ac_segment(
    reader: core.BitReader,
    length: int,
    table_id: int,
    presence_prefix: bool = False,
) -> list[int]:
    values = [0] * length
    if presence_prefix and not reader.read(1):
        return values
    index = 0
    while index < length:
        symbol = core.huffman_read(reader, 1, table_id)
        if symbol == 0x00:
            break
        if symbol == 0xF0:
            index += 16
            if index > length:
                raise ValueError("ZRL crosses layered coefficient segment")
            continue
        run, size = symbol >> 4, symbol & 15
        index += run
        if not size or index >= length:
            raise ValueError("invalid layered AC symbol")
        values[index] = core.amplitude_value(reader.read(size), size)
        index += 1
    return values


def encode_layered_block(
    base_writer: core.BitWriter,
    enhancement_writer: core.BitWriter,
    residual: np.ndarray,
    quant_table: np.ndarray,
    table_id: int,
    base_count: int,
    stats: core.ArithmeticStats,
) -> tuple[np.ndarray, np.ndarray]:
    coefficients = core.forward_residual_dct(residual, stats)
    quantized = core.quantize_block(coefficients, quant_table)
    values = [int(quantized[row, column]) for row, column in core.ZIGZAG]

    dc = min(2047, max(-2047, values[0]))
    dc_size = core.magnitude_category(dc)
    core.huffman_write(base_writer, 0, table_id, dc_size)
    base_writer.write(core.amplitude_bits(dc, dc_size), dc_size)
    base_values = [dc] + encode_ac_segment(
        base_writer, values[1:base_count], table_id, table_id == 0
    )
    enhancement_values = encode_ac_segment(
        enhancement_writer, values[base_count:], table_id, table_id == 0
    )

    base_quantized = np.zeros((8, 8), dtype=np.int64)
    full_quantized = np.zeros((8, 8), dtype=np.int64)
    for index, value in enumerate(base_values):
        row, column = core.ZIGZAG[index]
        base_quantized[row, column] = value
        full_quantized[row, column] = value
    for offset, value in enumerate(enhancement_values, start=base_count):
        row, column = core.ZIGZAG[offset]
        full_quantized[row, column] = value
    return base_quantized, full_quantized


def decode_layered_block(
    base_reader: core.BitReader,
    enhancement_reader: core.BitReader | None,
    quant_table: np.ndarray,
    table_id: int,
    base_count: int,
    stats: core.ArithmeticStats,
) -> tuple[np.ndarray, np.ndarray]:
    dc_size = core.huffman_read(base_reader, 0, table_id)
    dc = core.amplitude_value(base_reader.read(dc_size), dc_size)
    base_values = [dc] + decode_ac_segment(
        base_reader, base_count - 1, table_id, table_id == 0
    )
    enhancement_values = (
        decode_ac_segment(
            enhancement_reader, 64 - base_count, table_id, table_id == 0
        )
        if enhancement_reader is not None
        else [0] * (64 - base_count)
    )
    base_quantized = np.zeros((8, 8), dtype=np.int64)
    full_quantized = np.zeros((8, 8), dtype=np.int64)
    for index, value in enumerate(base_values + enhancement_values):
        row, column = core.ZIGZAG[index]
        full_quantized[row, column] = value
        if index < base_count:
            base_quantized[row, column] = value
    return (
        core.inverse_residual_dct(base_quantized * quant_table, stats),
        core.inverse_residual_dct(full_quantized * quant_table, stats),
    )


def layered_quant_tables(quality: int) -> tuple[np.ndarray, np.ndarray]:
    """Give the base layer one finer preset step without a second transform."""
    y_table, c_table = core.quant_tables(quality)
    fine_y, fine_c = core.quant_tables(min(100, quality + BASE_QUALITY_OFFSET))
    y_table = y_table.copy()
    c_table = c_table.copy()
    for index in range(LUMA_BASE_COEFFICIENTS):
        row, column = core.ZIGZAG[index]
        y_table[row, column] = fine_y[row, column]
    for index in range(CHROMA_BASE_COEFFICIENTS):
        row, column = core.ZIGZAG[index]
        c_table[row, column] = fine_c[row, column]
    return y_table, c_table


def _predictors(
    plane: np.ndarray,
    y: int,
    x: int,
    size: int,
) -> dict[int, np.ndarray]:
    top = plane[y - 1, x:x + size] if y else None
    left = plane[y:y + size, x - 1] if x else None
    return core.intra_predictors(top, left, size)


def encode_tile(
    y_source: np.ndarray,
    cb_source: np.ndarray,
    cr_source: np.ndarray,
    quality: int,
    tile_x: int,
    tile_y: int,
    stats: core.ArithmeticStats,
) -> LayeredTileRecord:
    qy, qc = layered_quant_tables(quality)
    base_writer = core.BitWriter()
    enhancement_writer = core.BitWriter()
    base_y = np.zeros((64, 64), dtype=np.int16)
    base_cb = np.zeros((32, 32), dtype=np.int16)
    base_cr = np.zeros((32, 32), dtype=np.int16)

    for macroblock_row in range(4):
        for macroblock_column in range(4):
            ly, lx = macroblock_row * 16, macroblock_column * 16
            cy, cx = macroblock_row * 8, macroblock_column * 8
            y_predictors = _predictors(base_y, ly, lx, 16)
            cb_predictors = _predictors(base_cb, cy, cx, 8)
            cr_predictors = _predictors(base_cr, cy, cx, 8)
            mode = min(
                y_predictors,
                key=lambda candidate: (
                    core.residual_satd(y_source[ly:ly + 16, lx:lx + 16] - y_predictors[candidate])
                    + core.residual_satd(cb_source[cy:cy + 8, cx:cx + 8] - cb_predictors[candidate])
                    + core.residual_satd(cr_source[cy:cy + 8, cx:cx + 8] - cr_predictors[candidate]),
                    candidate,
                ),
            )
            base_writer.write(mode, core.INTRA_MODE_BITS)

            for sub_row in range(2):
                for sub_column in range(2):
                    by, bx = ly + sub_row * 8, lx + sub_column * 8
                    predictor = y_predictors[mode][sub_row * 8:(sub_row + 1) * 8,
                                                   sub_column * 8:(sub_column + 1) * 8]
                    base_q, _ = encode_layered_block(
                        base_writer, enhancement_writer,
                        y_source[by:by + 8, bx:bx + 8].astype(np.int16) - predictor,
                        qy, 0, LUMA_BASE_COEFFICIENTS, stats,
                    )
                    base_residual = core.inverse_residual_dct(base_q * qy, stats)
                    base_y[by:by + 8, bx:bx + 8] = np.clip(
                        predictor.astype(np.int64) + base_residual, 0, 255
                    )

            for plane_id, plane_source, base_plane, predictors in (
                (1, cb_source, base_cb, cb_predictors),
                (2, cr_source, base_cr, cr_predictors),
            ):
                predictor = predictors[mode]
                base_q, _ = encode_layered_block(
                    base_writer, enhancement_writer,
                    plane_source[cy:cy + 8, cx:cx + 8].astype(np.int16) - predictor,
                    qc, 1, CHROMA_BASE_COEFFICIENTS, stats,
                )
                base_residual = core.inverse_residual_dct(base_q * qc, stats)
                base_plane[cy:cy + 8, cx:cx + 8] = np.clip(
                    predictor.astype(np.int64) + base_residual, 0, 255
                )

    return LayeredTileRecord(
        tile_x, tile_y,
        base_writer.finish(), base_writer.bit_length,
        enhancement_writer.finish(), enhancement_writer.bit_length,
    )


def decode_tile(
    record: LayeredTileRecord,
    quality: int,
    stats: core.ArithmeticStats,
    enhancement: bool,
) -> tuple[tuple[np.ndarray, np.ndarray, np.ndarray], tuple[np.ndarray, np.ndarray, np.ndarray]]:
    qy, qc = layered_quant_tables(quality)
    base_reader = core.BitReader(record.base_data, record.base_bits)
    enhancement_reader = (
        core.BitReader(record.enhancement_data, record.enhancement_bits)
        if enhancement else None
    )
    base_planes = [np.zeros((64, 64), dtype=np.int16),
                   np.zeros((32, 32), dtype=np.int16),
                   np.zeros((32, 32), dtype=np.int16)]
    full_planes = [np.zeros_like(plane) for plane in base_planes]

    for macroblock_row in range(4):
        for macroblock_column in range(4):
            mode = base_reader.read(core.INTRA_MODE_BITS)
            ly, lx = macroblock_row * 16, macroblock_column * 16
            cy, cx = macroblock_row * 8, macroblock_column * 8
            y_predictor = _predictors(base_planes[0], ly, lx, 16)[mode]
            chroma_predictors = [
                _predictors(base_planes[index], cy, cx, 8)[mode]
                for index in (1, 2)
            ]
            for sub_row in range(2):
                for sub_column in range(2):
                    by, bx = ly + sub_row * 8, lx + sub_column * 8
                    predictor = y_predictor[sub_row * 8:(sub_row + 1) * 8,
                                            sub_column * 8:(sub_column + 1) * 8]
                    base_residual, full_residual = decode_layered_block(
                        base_reader, enhancement_reader, qy, 0,
                        LUMA_BASE_COEFFICIENTS, stats,
                    )
                    base_planes[0][by:by + 8, bx:bx + 8] = np.clip(
                        predictor.astype(np.int64) + base_residual, 0, 255
                    )
                    full_planes[0][by:by + 8, bx:bx + 8] = np.clip(
                        predictor.astype(np.int64) + full_residual, 0, 255
                    )
            for plane_index, predictor in zip((1, 2), chroma_predictors):
                base_residual, full_residual = decode_layered_block(
                    base_reader, enhancement_reader, qc, 1,
                    CHROMA_BASE_COEFFICIENTS, stats,
                )
                base_planes[plane_index][cy:cy + 8, cx:cx + 8] = np.clip(
                    predictor.astype(np.int64) + base_residual, 0, 255
                )
                full_planes[plane_index][cy:cy + 8, cx:cx + 8] = np.clip(
                    predictor.astype(np.int64) + full_residual, 0, 255
                )

    if base_reader.position != record.base_bits:
        raise ValueError("unused base-layer bits")
    if enhancement_reader is not None and enhancement_reader.position != record.enhancement_bits:
        raise ValueError("unused enhancement-layer bits")
    return tuple(base_planes), tuple(full_planes)


def simulate(rgb: np.ndarray, quality: int = 24) -> CodecResult:
    height, width = rgb.shape[:2]
    y, cb, cr = core.rgb_to_ycbcr420(rgb)
    y, cb, cr = core.pad_planes(y, cb, cr)
    tile_rows, tile_columns = y.shape[0] // 64, y.shape[1] // 64
    encode_stats = core.ArithmeticStats()
    records: list[LayeredTileRecord] = []
    for tile_y in range(tile_rows):
        for tile_x in range(tile_columns):
            records.append(encode_tile(
                y[tile_y * 64:(tile_y + 1) * 64, tile_x * 64:(tile_x + 1) * 64],
                cb[tile_y * 32:(tile_y + 1) * 32, tile_x * 32:(tile_x + 1) * 32],
                cr[tile_y * 32:(tile_y + 1) * 32, tile_x * 32:(tile_x + 1) * 32],
                quality, tile_x, tile_y, encode_stats,
            ))

    decoded_base = [np.zeros_like(y), np.zeros_like(cb), np.zeros_like(cr)]
    decoded_full = [np.zeros_like(y), np.zeros_like(cb), np.zeros_like(cr)]
    decode_stats = core.ArithmeticStats()
    for record in records:
        base_planes, full_planes = decode_tile(record, quality, decode_stats, True)
        for plane_index, scale in ((0, 64), (1, 32), (2, 32)):
            yy, xx = record.tile_y * scale, record.tile_x * scale
            decoded_base[plane_index][yy:yy + scale, xx:xx + scale] = base_planes[plane_index]
            decoded_full[plane_index][yy:yy + scale, xx:xx + scale] = full_planes[plane_index]
    base_rgb = core.ycbcr420_to_rgb(*decoded_base)[:height, :width]
    full_rgb = core.ycbcr420_to_rgb(*decoded_full)[:height, :width]
    return CodecResult(
        full_rgb, base_rgb, records,
        sum(record.base_bits for record in records),
        sum(record.enhancement_bits for record in records),
        core.calculate_psnr(rgb, full_rgb), core.calculate_psnr(rgb, base_rgb),
        encode_stats.saturations + decode_stats.saturations,
    )


def main() -> None:
    global BASE_QUALITY_OFFSET
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--quality", type=int, default=24)
    parser.add_argument("--base-quality-offset", type=int, default=2)
    parser.add_argument("--output-dir", type=Path, default=Path("custom_codec_results"))
    args = parser.parse_args()
    if not 1 <= args.quality <= 100:
        raise SystemExit("--quality must be in [1, 100]")
    if not 0 <= args.base_quality_offset <= 20:
        raise SystemExit("--base-quality-offset must be in [0, 20]")
    BASE_QUALITY_OFFSET = args.base_quality_offset
    rgb = np.asarray(Image.open(args.image).convert("RGB"), dtype=np.uint8)
    result = simulate(rgb, args.quality)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    Image.fromarray(result.full_rgb).save(args.output_dir / f"decoded_full_q{args.quality}.png")
    Image.fromarray(result.base_rgb).save(args.output_dir / f"decoded_base_q{args.quality}.png")
    pixels = rgb.shape[0] * rgb.shape[1]
    print(f"frame: {rgb.shape[1]}x{rgb.shape[0]}, tiles: {len(result.records)}")
    print(f"quality: {args.quality}, full PSNR: {result.full_psnr:.3f} dB, base PSNR: {result.base_psnr:.3f} dB")
    print(f"base: {result.base_bits/pixels:.4f} bpp, enhancement: {result.enhancement_bits/pixels:.4f} bpp, total: {result.total_bits/pixels:.4f} bpp")
    print(f"arithmetic saturations: {result.saturations}")
    print("transport: not included; ESP32 owns packing, interleaving and LF duplication")


if __name__ == "__main__":
    main()

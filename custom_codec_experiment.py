#!/usr/bin/env python3
"""FPGA-oriented layered intra codec reference model.

The codec ends at independently tagged base/enhancement tile records.  Radio
packet packing, interleaving and low-frequency duplication deliberately belong
to the ESP32 transport layer and are not modelled here.
"""

from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
import math
from pathlib import Path
import zlib

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import jpeg_radio_codec as core
from custom_budget_writer import Admission, BudgetToken, DualBudgetWriter, Layer
from custom_fixed_vlc import VlcClass, encode_vlc_token
from custom_token_byte_packer import TokenBytePacker, left_align_token


TILE_SIZE = 64
LUMA_BASE_COEFFICIENTS = 6
CHROMA_BASE_COEFFICIENTS = 3
BASE_QUALITY_OFFSET = 2
DIAGONAL_SCAN = tuple(core.ZIGZAG)
HORIZONTAL_SCAN = tuple((row, column) for row in range(8) for column in range(8))
VERTICAL_SCAN = tuple((row, column) for column in range(8) for row in range(8))
QUALITY_OFFSETS = (-4, -2, 0, 2)
BASE_MAX_BYTES = 2048
ENHANCEMENT_MAX_BYTES = 1536


@dataclass(frozen=True)
class LayeredTileRecord:
    tile_x: int
    tile_y: int
    base_data: bytes
    base_bits: int
    enhancement_data: bytes
    enhancement_bits: int


@dataclass(frozen=True)
class LayeredStripeRecord:
    stripe_y: int
    width: int
    base_data: bytes
    base_bits: int
    enhancement_data: bytes
    enhancement_bits: int
    coarse_data: bytes
    local_prediction: bool
    mode_dependent_scan: bool
    adaptive_quant: bool
    base_truncated_blocks: int = 0
    enhancement_truncated_blocks: int = 0
    base_reference_crc32: int = 0


@dataclass(frozen=True)
class EspStripePacket:
    sequence: int
    primary: LayeredStripeRecord
    backup_stripe_y: int | None
    backup_coarse_data: bytes

    @property
    def payload_bytes(self) -> int:
        return (
            (self.primary.base_bits + 7) // 8
            + (self.primary.enhancement_bits + 7) // 8
            + len(self.backup_coarse_data)
        )


@dataclass(frozen=True)
class QuantizedBlockTrace:
    """One raster-order block presented to the RTL coefficient scanner."""

    coefficients: tuple[int, ...]
    table_id: int
    base_count: int


@dataclass(frozen=True)
class ResidualBlockTrace:
    """One signed pre-DCT 8x8 block presented to the RTL transform."""

    samples: tuple[int, ...]
    table_id: int
    base_count: int


@dataclass
class CodecResult:
    full_rgb: np.ndarray
    base_rgb: np.ndarray
    records: list[LayeredStripeRecord]
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


@dataclass(frozen=True)
class _AcToken:
    bits: int
    bit_length: int
    coefficient_index: int | None
    coefficient_value: int = 0


def _raw_budget_token(
    layer: Layer,
    value: int,
    bit_length: int,
    mandatory: bool = False,
    reserve_release: int = 0,
) -> BudgetToken:
    bits = left_align_token(value, bit_length) if bit_length else 0
    return BudgetToken(layer, bits, bit_length, mandatory, reserve_release)


def _vlc_budget_token(
    layer: Layer,
    table_class: VlcClass,
    table_id: int,
    symbol: int,
    amplitude: int = 0,
    amplitude_length: int = 0,
    mandatory: bool = False,
    reserve_release: int = 0,
) -> BudgetToken:
    token = encode_vlc_token(
        table_class, table_id, symbol, amplitude, amplitude_length
    )
    return BudgetToken(
        layer, token.bits, token.bit_length, mandatory, reserve_release
    )


DC_MAX_TOKEN_BITS = tuple(
    max(
        encode_vlc_token(VlcClass.DC, table_id, category, 0, category).bit_length
        for category in range(12)
    )
    for table_id in (0, 1)
)
EOB_TOKEN_BITS = tuple(
    encode_vlc_token(VlcClass.AC, table_id, 0x00).bit_length
    for table_id in (0, 1)
)


def _ac_tokens(values: list[int], table_id: int) -> tuple[list[_AcToken], bool]:
    events: list[_AcToken] = []
    last_nonzero = max((index for index, value in enumerate(values) if value), default=-1)
    run = 0
    for index, raw_value in enumerate(values):
        if not raw_value:
            run += 1
            continue
        value = min(1023, max(-1023, int(raw_value)))
        while run >= 16:
            token = encode_vlc_token(VlcClass.AC, table_id, 0xF0)
            events.append(_AcToken(token.bits, token.bit_length, None))
            run -= 16
        size = core.magnitude_category(value)
        symbol = (run << 4) | size
        token = encode_vlc_token(
            VlcClass.AC, table_id, symbol,
            core.amplitude_bits(value, size), size,
        )
        events.append(_AcToken(token.bits, token.bit_length, index, value))
        run = 0
    return events, last_nonzero < len(values) - 1


def _submit_ac_segment(
    guard: DualBudgetWriter,
    layer: Layer,
    values: list[int],
    table_id: int,
    presence_prefix: bool,
) -> tuple[list[int], bool]:
    events, natural_eob = _ac_tokens(values, table_id)
    eob_bits = EOB_TOKEN_BITS[table_id]
    transmitted = [0] * len(values)

    if presence_prefix:
        trial = copy.deepcopy(guard)
        result = trial.submit(_raw_budget_token(
            layer, 1, 1, mandatory=True, reserve_release=1
        ))
        if result is not Admission.ACCEPTED:
            raise RuntimeError("reserved luma presence marker did not fit")
        accepted_count = 0
        for event in events:
            result = trial.submit(BudgetToken(layer, event.bits, event.bit_length))
            if result is not Admission.ACCEPTED:
                break
            accepted_count += 1
        if accepted_count == 0:
            result = guard.submit(_raw_budget_token(
                layer, 0, 1, mandatory=True, reserve_release=1 + eob_bits
            ))
            if result is not Admission.ACCEPTED:
                raise RuntimeError("reserved empty luma marker did not fit")
            return transmitted, bool(events)
        result = guard.submit(_raw_budget_token(
            layer, 1, 1, mandatory=True, reserve_release=1
        ))
        if result is not Admission.ACCEPTED:
            raise RuntimeError("reserved luma presence marker did not fit")
        for event in events[:accepted_count]:
            if guard.submit(BudgetToken(layer, event.bits, event.bit_length)) \
                    is not Admission.ACCEPTED:
                raise RuntimeError("trial and committed AC admission differ")
    else:
        accepted_count = 0
        for event in events:
            if guard.submit(BudgetToken(layer, event.bits, event.bit_length)) \
                    is not Admission.ACCEPTED:
                break
            accepted_count += 1

    for event in events[:accepted_count]:
        if event.coefficient_index is not None:
            transmitted[event.coefficient_index] = event.coefficient_value

    truncated = accepted_count < len(events)
    if truncated or natural_eob:
        result = guard.submit(_vlc_budget_token(
            layer, VlcClass.AC, table_id, 0x00,
            mandatory=True, reserve_release=eob_bits,
        ))
    else:
        result = guard.submit(_raw_budget_token(
            layer, 0, 0, mandatory=True, reserve_release=eob_bits
        ))
    if result is not Admission.ACCEPTED:
        raise RuntimeError("reserved EOB did not fit")
    return transmitted, truncated


def _stripe_mandatory_reserve(
    ctu_count: int,
    local_prediction: bool,
    adaptive_quant: bool,
) -> tuple[int, int]:
    luma_marker = 1 + EOB_TOKEN_BITS[0]
    chroma_marker = EOB_TOKEN_BITS[1]
    base_per_ctu = (
        (2 if adaptive_quant else 0)
        + (0 if local_prediction else core.INTRA_MODE_BITS)
        + 4 * (DC_MAX_TOKEN_BITS[0] + luma_marker)
        + 2 * (DC_MAX_TOKEN_BITS[1] + chroma_marker)
    )
    enhancement_per_ctu = 4 * luma_marker + 2 * chroma_marker
    return ctu_count * base_per_ctu, ctu_count * enhancement_per_ctu


def _finish_bounded_streams(
    guard: DualBudgetWriter,
) -> tuple[bytes, bytes, int, int]:
    base_bits, enhancement_bits = guard.finish()
    packer = TokenBytePacker()
    for token in guard.accepted:
        packer.submit(token.layer, token.value, token.bit_length)
    packer.finish()
    base_data = bytes(item.value for item in packer.output if item.layer is Layer.BASE)
    enhancement_data = bytes(
        item.value for item in packer.output if item.layer is Layer.ENHANCEMENT
    )
    return base_data, enhancement_data, base_bits, enhancement_bits


def encode_bounded_layered_block(
    guard: DualBudgetWriter,
    residual: np.ndarray,
    quant_table: np.ndarray,
    table_id: int,
    base_count: int,
    stats: core.ArithmeticStats,
    scan: tuple[tuple[int, int], ...] = DIAGONAL_SCAN,
    trace_blocks: list[QuantizedBlockTrace] | None = None,
    trace_residuals: list[ResidualBlockTrace] | None = None,
) -> tuple[np.ndarray, np.ndarray, bool, bool]:
    if trace_residuals is not None:
        trace_residuals.append(ResidualBlockTrace(
            tuple(int(value) for value in residual.reshape(-1)),
            table_id,
            base_count,
        ))
    coefficients = core.forward_residual_dct(residual, stats)
    quantized = core.quantize_block(coefficients, quant_table)
    if trace_blocks is not None:
        if scan != DIAGONAL_SCAN:
            raise ValueError(
                "RTL coefficient traces require the fixed diagonal scan profile"
            )
        trace_blocks.append(QuantizedBlockTrace(
            tuple(int(value) for value in quantized.reshape(-1)),
            table_id,
            base_count,
        ))
    base_positions = set(core.ZIGZAG[:base_count])
    layer_scan = (
        tuple(position for position in scan if position in base_positions)
        + tuple(position for position in scan if position not in base_positions)
    )
    values = [int(quantized[row, column]) for row, column in layer_scan]

    dc = min(2047, max(-2047, values[0]))
    dc_size = core.magnitude_category(dc)
    result = guard.submit(_vlc_budget_token(
        Layer.BASE, VlcClass.DC, table_id, dc_size,
        core.amplitude_bits(dc, dc_size), dc_size,
        mandatory=True, reserve_release=DC_MAX_TOKEN_BITS[table_id],
    ))
    if result is not Admission.ACCEPTED:
        raise RuntimeError("reserved DC token did not fit")

    base_ac, base_truncated = _submit_ac_segment(
        guard, Layer.BASE, values[1:base_count], table_id, table_id == 0
    )
    enhancement_values, enhancement_truncated = _submit_ac_segment(
        guard, Layer.ENHANCEMENT, values[base_count:], table_id, table_id == 0
    )
    base_values = [dc] + base_ac

    base_quantized = np.zeros((8, 8), dtype=np.int64)
    full_quantized = np.zeros((8, 8), dtype=np.int64)
    for index, value in enumerate(base_values):
        row, column = layer_scan[index]
        base_quantized[row, column] = value
        full_quantized[row, column] = value
    for offset, value in enumerate(enhancement_values, start=base_count):
        row, column = layer_scan[offset]
        full_quantized[row, column] = value
    return base_quantized, full_quantized, base_truncated, enhancement_truncated


def encode_layered_block(
    base_writer: core.BitWriter,
    enhancement_writer: core.BitWriter,
    residual: np.ndarray,
    quant_table: np.ndarray,
    table_id: int,
    base_count: int,
    stats: core.ArithmeticStats,
    scan: tuple[tuple[int, int], ...] = DIAGONAL_SCAN,
) -> tuple[np.ndarray, np.ndarray]:
    coefficients = core.forward_residual_dct(residual, stats)
    quantized = core.quantize_block(coefficients, quant_table)
    base_positions = set(core.ZIGZAG[:base_count])
    layer_scan = (
        tuple(position for position in scan if position in base_positions)
        + tuple(position for position in scan if position not in base_positions)
    )
    values = [int(quantized[row, column]) for row, column in layer_scan]

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
        row, column = layer_scan[index]
        base_quantized[row, column] = value
        full_quantized[row, column] = value
    for offset, value in enumerate(enhancement_values, start=base_count):
        row, column = layer_scan[offset]
        full_quantized[row, column] = value
    return base_quantized, full_quantized


def decode_layered_block(
    base_reader: core.BitReader,
    enhancement_reader: core.BitReader | None,
    quant_table: np.ndarray,
    table_id: int,
    base_count: int,
    stats: core.ArithmeticStats,
    scan: tuple[tuple[int, int], ...] = DIAGONAL_SCAN,
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
    base_positions = set(core.ZIGZAG[:base_count])
    layer_scan = (
        tuple(position for position in scan if position in base_positions)
        + tuple(position for position in scan if position not in base_positions)
    )
    for index, value in enumerate(base_values + enhancement_values):
        row, column = layer_scan[index]
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


def scan_for_mode(mode: int) -> tuple[tuple[int, int], ...]:
    if mode == core.INTRA_HORIZONTAL:
        return VERTICAL_SCAN
    if mode == core.INTRA_VERTICAL:
        return HORIZONTAL_SCAN
    return DIAGONAL_SCAN


def deterministic_local_mode(predictors: dict[int, np.ndarray]) -> int:
    has_horizontal = core.INTRA_HORIZONTAL in predictors
    has_vertical = core.INTRA_VERTICAL in predictors
    if has_horizontal and has_vertical:
        return core.INTRA_PLANAR
    if has_horizontal:
        return core.INTRA_HORIZONTAL
    if has_vertical:
        return core.INTRA_VERTICAL
    return core.INTRA_DC


def select_quality_profile(
    used_bits: int,
    processed_ctus: int,
    target_bpp: float,
    activity: float,
) -> int:
    if target_bpp <= 0.0:
        return 2
    activity_profile = 1 if activity < 3.0 else 3 if activity > 14.0 else 2
    if processed_ctus == 0:
        return activity_profile
    bits_per_ctu = target_bpp * 256.0
    error = used_bits - processed_ctus * bits_per_ctu
    if error > bits_per_ctu:
        return 0
    if error > bits_per_ctu * 0.25:
        return min(activity_profile, 1)
    if error < -bits_per_ctu * 0.75:
        return 3
    return activity_profile


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


def encode_coarse_stripe(
    y_source: np.ndarray,
    cb_source: np.ndarray,
    cr_source: np.ndarray,
) -> bytes:
    """Return the ESP32-friendly 2-byte LF summary for every CTU16."""
    if y_source.shape[0] != 16 or y_source.shape[1] % 16:
        raise ValueError("coarse stripe must contain complete CTU16 blocks")
    output = bytearray()
    for x in range(0, y_source.shape[1], 16):
        chroma_x = x // 2
        y_left = (int(y_source[:, x:x + 8].astype(np.uint32).sum()) + 1024) // 2048
        y_right = (int(y_source[:, x + 8:x + 16].astype(np.uint32).sum()) + 1024) // 2048
        cb = (int(cb_source[:, chroma_x:chroma_x + 8].astype(np.uint32).sum()) + 512) // 1024
        cr = (int(cr_source[:, chroma_x:chroma_x + 8].astype(np.uint32).sum()) + 512) // 1024
        output.extend(((min(15, y_left) << 4) | min(15, y_right),
                       (min(15, cb) << 4) | min(15, cr)))
    return bytes(output)


def decode_coarse_stripe(data: bytes, width: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if width % 16 or len(data) != width // 8:
        raise ValueError("invalid coarse stripe summary")
    y = np.empty((16, width), dtype=np.int16)
    cb = np.empty((8, width // 2), dtype=np.int16)
    cr = np.empty((8, width // 2), dtype=np.int16)
    for ctu, x in enumerate(range(0, width, 16)):
        y_pair, chroma_pair = data[2 * ctu:2 * ctu + 2]
        y[:, x:x + 8] = (y_pair >> 4) * 17
        y[:, x + 8:x + 16] = (y_pair & 15) * 17
        chroma_x = x // 2
        cb[:, chroma_x:chroma_x + 8] = (chroma_pair >> 4) * 17
        cr[:, chroma_x:chroma_x + 8] = (chroma_pair & 15) * 17
    return y, cb, cr


def encode_stripe(
    y_source: np.ndarray,
    cb_source: np.ndarray,
    cr_source: np.ndarray,
    quality: int,
    stripe_y: int,
    stats: core.ArithmeticStats,
    local_prediction: bool = False,
    mode_dependent_scan: bool = False,
    target_bpp: float = 0.0,
    base_max_bytes: int = BASE_MAX_BYTES,
    enhancement_max_bytes: int = ENHANCEMENT_MAX_BYTES,
    trace_blocks: list[QuantizedBlockTrace] | None = None,
    trace_modes: list[int] | None = None,
    trace_residuals: list[ResidualBlockTrace] | None = None,
) -> LayeredStripeRecord:
    width = y_source.shape[1]
    if y_source.shape != (16, width) or width % 16:
        raise ValueError("luma stripe must be width x 16 and CTU aligned")
    if cb_source.shape != (8, width // 2) or cr_source.shape != cb_source.shape:
        raise ValueError("stripe chroma must be 4:2:0 and CTU aligned")
    base_y = np.zeros_like(y_source, dtype=np.int16)
    base_cb = np.zeros_like(cb_source, dtype=np.int16)
    base_cr = np.zeros_like(cr_source, dtype=np.int16)

    adaptive_quant = target_bpp > 0.0
    base_reserve, enhancement_reserve = _stripe_mandatory_reserve(
        width // 16, local_prediction, adaptive_quant
    )
    guard = DualBudgetWriter(
        base_max_bytes * 8,
        enhancement_max_bytes * 8,
        base_reserve,
        enhancement_reserve,
    )
    base_truncated_blocks = 0
    enhancement_truncated_blocks = 0
    quant_cache: dict[int, tuple[np.ndarray, np.ndarray]] = {}
    for macroblock_column, lx in enumerate(range(0, width, 16)):
        cx = lx // 2
        activity_block = y_source[:, lx:lx + 16].astype(np.int64)
        activity = float(np.mean(np.abs(activity_block - int(activity_block.mean()))))
        quality_profile = select_quality_profile(
            guard.used[0] + guard.used[1],
            macroblock_column,
            target_bpp,
            activity,
        )
        if adaptive_quant:
            if guard.submit(_raw_budget_token(
                Layer.BASE, quality_profile, 2,
                mandatory=True, reserve_release=2,
            )) is not Admission.ACCEPTED:
                raise RuntimeError("reserved quality profile did not fit")
        ctu_quality = min(100, max(1, quality + QUALITY_OFFSETS[quality_profile]))
        if ctu_quality not in quant_cache:
            quant_cache[ctu_quality] = layered_quant_tables(ctu_quality)
        qy, qc = quant_cache[ctu_quality]

        shared_y_predictors = _predictors(base_y, 0, lx, 16)
        cb_predictors = _predictors(base_cb, 0, cx, 8)
        cr_predictors = _predictors(base_cr, 0, cx, 8)
        if not local_prediction:
            shared_mode = min(
                shared_y_predictors,
                key=lambda candidate: (
                    core.residual_satd(
                        y_source[:, lx:lx + 16] - shared_y_predictors[candidate]
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
            if guard.submit(_raw_budget_token(
                Layer.BASE, shared_mode, core.INTRA_MODE_BITS,
                mandatory=True, reserve_release=core.INTRA_MODE_BITS,
            )) is not Admission.ACCEPTED:
                raise RuntimeError("reserved intra mode did not fit")
            if trace_modes is not None:
                trace_modes.append(shared_mode)
        elif trace_modes is not None:
            raise ValueError("RTL mode traces require signaled CTU prediction")

        for sub_row in range(2):
            for sub_column in range(2):
                by, bx = sub_row * 8, lx + sub_column * 8
                if local_prediction:
                    predictors = _predictors(base_y, by, bx, 8)
                    mode = deterministic_local_mode(predictors)
                    predictor = predictors[mode]
                else:
                    mode = shared_mode
                    predictor = shared_y_predictors[mode][
                        by:by + 8, sub_column * 8:(sub_column + 1) * 8
                    ]
                scan = scan_for_mode(mode) if mode_dependent_scan else DIAGONAL_SCAN
                base_q, _, base_cut, enhancement_cut = encode_bounded_layered_block(
                    guard,
                    y_source[by:by + 8, bx:bx + 8].astype(np.int16) - predictor,
                    qy, 0, LUMA_BASE_COEFFICIENTS, stats, scan, trace_blocks,
                    trace_residuals,
                )
                base_truncated_blocks += base_cut
                enhancement_truncated_blocks += enhancement_cut
                base_residual = core.inverse_residual_dct(base_q * qy, stats)
                base_y[by:by + 8, bx:bx + 8] = np.clip(
                    predictor.astype(np.int64) + base_residual, 0, 255
                )
        if local_prediction:
            chroma_mode = deterministic_local_mode(cb_predictors)
        else:
            chroma_mode = shared_mode
        chroma_scan = (
            scan_for_mode(chroma_mode) if mode_dependent_scan else DIAGONAL_SCAN
        )
        for plane_source, base_plane, predictors in (
            (cb_source, base_cb, cb_predictors),
            (cr_source, base_cr, cr_predictors),
        ):
            predictor = predictors[chroma_mode]
            base_q, _, base_cut, enhancement_cut = encode_bounded_layered_block(
                guard,
                plane_source[:, cx:cx + 8].astype(np.int16) - predictor,
                qc, 1, CHROMA_BASE_COEFFICIENTS, stats, chroma_scan,
                trace_blocks, trace_residuals,
            )
            base_truncated_blocks += base_cut
            enhancement_truncated_blocks += enhancement_cut
            base_residual = core.inverse_residual_dct(base_q * qc, stats)
            base_plane[:, cx:cx + 8] = np.clip(
                predictor.astype(np.int64) + base_residual, 0, 255
            )

    base_data, enhancement_data, base_bits, enhancement_bits = \
        _finish_bounded_streams(guard)
    if len(base_data) > base_max_bytes or len(enhancement_data) > enhancement_max_bytes:
        raise AssertionError("bounded stripe exceeded configured byte limit")
    reference_crc = 0
    for plane in (base_y, base_cb, base_cr):
        reference_crc = zlib.crc32(plane.astype(np.uint8).tobytes(), reference_crc)
    return LayeredStripeRecord(
        stripe_y, width,
        base_data, base_bits,
        enhancement_data, enhancement_bits,
        encode_coarse_stripe(y_source, cb_source, cr_source),
        local_prediction, mode_dependent_scan, adaptive_quant,
        base_truncated_blocks, enhancement_truncated_blocks, reference_crc,
    )


def decode_stripe(
    record: LayeredStripeRecord,
    quality: int,
    stats: core.ArithmeticStats,
    enhancement: bool = True,
) -> tuple[tuple[np.ndarray, np.ndarray, np.ndarray], tuple[np.ndarray, np.ndarray, np.ndarray]]:
    base_reader = core.BitReader(record.base_data, record.base_bits)
    enhancement_reader = (
        core.BitReader(record.enhancement_data, record.enhancement_bits)
        if enhancement else None
    )
    width = record.width
    base_planes = [np.zeros((16, width), dtype=np.int16),
                   np.zeros((8, width // 2), dtype=np.int16),
                   np.zeros((8, width // 2), dtype=np.int16)]
    full_planes = [np.zeros_like(plane) for plane in base_planes]
    quant_cache: dict[int, tuple[np.ndarray, np.ndarray]] = {}

    for lx in range(0, width, 16):
        cx = lx // 2
        quality_profile = base_reader.read(2) if record.adaptive_quant else 2
        ctu_quality = min(100, max(1, quality + QUALITY_OFFSETS[quality_profile]))
        if ctu_quality not in quant_cache:
            quant_cache[ctu_quality] = layered_quant_tables(ctu_quality)
        qy, qc = quant_cache[ctu_quality]
        shared_y_predictors = _predictors(base_planes[0], 0, lx, 16)
        shared_mode = (
            base_reader.read(core.INTRA_MODE_BITS)
            if not record.local_prediction else None
        )
        chroma_predictors = [
            _predictors(base_planes[index], 0, cx, 8)
            for index in (1, 2)
        ]
        for sub_row in range(2):
            for sub_column in range(2):
                by, bx = sub_row * 8, lx + sub_column * 8
                if record.local_prediction:
                    predictors = _predictors(base_planes[0], by, bx, 8)
                    mode = deterministic_local_mode(predictors)
                    predictor = predictors[mode]
                else:
                    mode = int(shared_mode)
                    predictor = shared_y_predictors[mode][
                        by:by + 8, sub_column * 8:(sub_column + 1) * 8
                    ]
                scan = (
                    scan_for_mode(mode)
                    if record.mode_dependent_scan else DIAGONAL_SCAN
                )
                base_residual, full_residual = decode_layered_block(
                    base_reader, enhancement_reader, qy, 0,
                    LUMA_BASE_COEFFICIENTS, stats, scan,
                )
                base_planes[0][by:by + 8, bx:bx + 8] = np.clip(
                    predictor.astype(np.int64) + base_residual, 0, 255
                )
                full_planes[0][by:by + 8, bx:bx + 8] = np.clip(
                    predictor.astype(np.int64) + full_residual, 0, 255
                )
        if record.local_prediction:
            chroma_mode = deterministic_local_mode(chroma_predictors[0])
        else:
            chroma_mode = int(shared_mode)
        chroma_scan = (
            scan_for_mode(chroma_mode)
            if record.mode_dependent_scan else DIAGONAL_SCAN
        )
        for plane_index, predictors in zip((1, 2), chroma_predictors):
            predictor = predictors[chroma_mode]
            base_residual, full_residual = decode_layered_block(
                base_reader, enhancement_reader, qc, 1,
                CHROMA_BASE_COEFFICIENTS, stats, chroma_scan,
            )
            base_planes[plane_index][:, cx:cx + 8] = np.clip(
                predictor.astype(np.int64) + base_residual, 0, 255
            )
            full_planes[plane_index][:, cx:cx + 8] = np.clip(
                predictor.astype(np.int64) + full_residual, 0, 255
            )
    if base_reader.position != record.base_bits:
        raise ValueError("unused stripe base-layer bits")
    if enhancement_reader is not None and enhancement_reader.position != record.enhancement_bits:
        raise ValueError("unused stripe enhancement-layer bits")
    if record.base_reference_crc32:
        reference_crc = 0
        for plane in base_planes:
            reference_crc = zlib.crc32(
                plane.astype(np.uint8).tobytes(), reference_crc
            )
        if reference_crc != record.base_reference_crc32:
            raise ValueError("encoder/decoder base-reference drift")
    return tuple(base_planes), tuple(full_planes)


def pad_stripe_planes(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    pad_y = (-y.shape[0]) % 16
    pad_x = (-y.shape[1]) % 16
    y = np.pad(y, ((0, pad_y), (0, pad_x)), mode="edge")
    cb = np.pad(cb, ((0, pad_y // 2), (0, pad_x // 2)), mode="edge")
    cr = np.pad(cr, ((0, pad_y // 2), (0, pad_x // 2)), mode="edge")
    return y, cb, cr


def decode_frame_records(
    records: list[LayeredStripeRecord],
    quality: int,
    padded_height: int,
    lost_stripe: int | None = None,
    recover_coarse: bool = False,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    width = records[0].width
    planes = [np.full((padded_height, width), 128, dtype=np.int16),
              np.full((padded_height // 2, width // 2), 128, dtype=np.int16),
              np.full((padded_height // 2, width // 2), 128, dtype=np.int16)]
    stats = core.ArithmeticStats()
    for index, record in enumerate(records):
        if index == lost_stripe:
            if not recover_coarse:
                continue
            decoded = decode_coarse_stripe(record.coarse_data, width)
        else:
            _, decoded = decode_stripe(record, quality, stats, True)
        y0 = record.stripe_y * 16
        planes[0][y0:y0 + 16] = decoded[0]
        planes[1][y0 // 2:y0 // 2 + 8] = decoded[1]
        planes[2][y0 // 2:y0 // 2 + 8] = decoded[2]
    return tuple(planes)


def build_esp_packets(records: list[LayeredStripeRecord]) -> list[EspStripePacket]:
    """Make packet N carry primary N and the coarse copy for primary N+1."""
    return [
        EspStripePacket(
            index,
            record,
            records[index + 1].stripe_y if index + 1 < len(records) else None,
            records[index + 1].coarse_data if index + 1 < len(records) else b"",
        )
        for index, record in enumerate(records)
    ]


def decode_esp_packets(
    packets: list[EspStripePacket],
    quality: int,
    padded_height: int,
    lost_packet: int,
    recover_coarse: bool,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    records = [packet.primary for packet in packets]
    width = records[0].width
    planes = [np.full((padded_height, width), 128, dtype=np.int16),
              np.full((padded_height // 2, width // 2), 128, dtype=np.int16),
              np.full((padded_height // 2, width // 2), 128, dtype=np.int16)]
    stats = core.ArithmeticStats()
    for index, packet in enumerate(packets):
        record = packet.primary
        if index == lost_packet:
            previous = packets[index - 1] if index else None
            if (
                not recover_coarse
                or previous is None
                or previous.backup_stripe_y != record.stripe_y
            ):
                continue
            decoded = decode_coarse_stripe(previous.backup_coarse_data, width)
        else:
            _, decoded = decode_stripe(record, quality, stats, True)
        y0 = record.stripe_y * 16
        planes[0][y0:y0 + 16] = decoded[0]
        planes[1][y0 // 2:y0 // 2 + 8] = decoded[1]
        planes[2][y0 // 2:y0 // 2 + 8] = decoded[2]
    return tuple(planes)


def make_comparison(images: list[tuple[str, np.ndarray]], columns: int = 2) -> Image.Image:
    width = images[0][1].shape[1]
    height = images[0][1].shape[0]
    label_height = 34
    rows = (len(images) + columns - 1) // columns
    canvas = Image.new("RGB", (columns * width, rows * (height + label_height)), "white")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=18)
    for index, (label, array) in enumerate(images):
        x = (index % columns) * width
        y = (index // columns) * (height + label_height)
        draw.text((x + 8, y + 7), label, fill="black", font=font)
        canvas.paste(Image.fromarray(array), (x, y + label_height))
    return canvas


def simulate(
    rgb: np.ndarray,
    quality: int = 24,
    target_bpp: float = 0.0,
    local_prediction: bool = False,
    mode_dependent_scan: bool = False,
    base_max_bytes: int = BASE_MAX_BYTES,
    enhancement_max_bytes: int = ENHANCEMENT_MAX_BYTES,
) -> CodecResult:
    height, width = rgb.shape[:2]
    y, cb, cr = core.rgb_to_ycbcr420(rgb)
    y, cb, cr = pad_stripe_planes(y, cb, cr)
    encode_stats = core.ArithmeticStats()
    records = [
        encode_stripe(
            y[y0:y0 + 16], cb[y0 // 2:y0 // 2 + 8], cr[y0 // 2:y0 // 2 + 8],
            quality, y0 // 16, encode_stats,
            local_prediction, mode_dependent_scan, target_bpp,
            base_max_bytes, enhancement_max_bytes,
        )
        for y0 in range(0, y.shape[0], 16)
    ]

    decoded_base = [np.zeros_like(y), np.zeros_like(cb), np.zeros_like(cr)]
    decoded_full = [np.zeros_like(y), np.zeros_like(cb), np.zeros_like(cr)]
    decode_stats = core.ArithmeticStats()
    for record in records:
        base_planes, full_planes = decode_stripe(record, quality, decode_stats, True)
        y0 = record.stripe_y * 16
        decoded_base[0][y0:y0 + 16] = base_planes[0]
        decoded_full[0][y0:y0 + 16] = full_planes[0]
        for plane_index in (1, 2):
            decoded_base[plane_index][y0 // 2:y0 // 2 + 8] = base_planes[plane_index]
            decoded_full[plane_index][y0 // 2:y0 // 2 + 8] = full_planes[plane_index]
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
    parser.add_argument(
        "--target-bpp", type=float, default=0.0,
        help="one-pass CTU fullness target; 0 disables adaptive quantization",
    )
    parser.add_argument("--local-prediction", action="store_true")
    parser.add_argument("--mode-scan", action="store_true")
    parser.add_argument("--base-max-bytes", type=int, default=BASE_MAX_BYTES)
    parser.add_argument(
        "--enhancement-max-bytes", type=int, default=ENHANCEMENT_MAX_BYTES
    )
    parser.add_argument(
        "--loss-stripe", type=int, default=-1,
        help="stripe to remove in previews; -1 selects the middle stripe",
    )
    parser.add_argument("--output-dir", type=Path, default=Path("custom_codec_results"))
    args = parser.parse_args()
    if not 1 <= args.quality <= 100:
        raise SystemExit("--quality must be in [1, 100]")
    if not 0 <= args.base_quality_offset <= 20:
        raise SystemExit("--base-quality-offset must be in [0, 20]")
    if not 0.0 <= args.target_bpp <= 4.0:
        raise SystemExit("--target-bpp must be in [0, 4]")
    if args.base_max_bytes <= 0 or args.enhancement_max_bytes <= 0:
        raise SystemExit("stripe byte limits must be positive")
    BASE_QUALITY_OFFSET = args.base_quality_offset
    rgb = np.asarray(Image.open(args.image).convert("RGB"), dtype=np.uint8)
    result = simulate(
        rgb,
        args.quality,
        args.target_bpp,
        args.local_prediction,
        args.mode_scan,
        args.base_max_bytes,
        args.enhancement_max_bytes,
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    Image.fromarray(result.full_rgb).save(args.output_dir / f"decoded_full_q{args.quality}.png")
    Image.fromarray(result.base_rgb).save(args.output_dir / f"decoded_base_q{args.quality}.png")
    pixels = rgb.shape[0] * rgb.shape[1]
    stripe_index = len(result.records) // 2 if args.loss_stripe < 0 else args.loss_stripe
    if not 1 <= stripe_index < len(result.records):
        raise SystemExit(f"--loss-stripe must be in [1, {len(result.records) - 1}]")
    padded_height = len(result.records) * 16
    esp_packets = build_esp_packets(result.records)
    gray_planes = decode_esp_packets(
        esp_packets, args.quality, padded_height, stripe_index, False
    )
    coarse_planes = decode_esp_packets(
        esp_packets, args.quality, padded_height, stripe_index, True
    )
    gray_rgb = core.ycbcr420_to_rgb(*gray_planes)[:rgb.shape[0], :rgb.shape[1]]
    coarse_rgb = core.ycbcr420_to_rgb(*coarse_planes)[:rgb.shape[0], :rgb.shape[1]]
    Image.fromarray(gray_rgb).save(args.output_dir / f"loss_gray_q{args.quality}.png")
    Image.fromarray(coarse_rgb).save(args.output_dir / f"loss_lf_recovered_q{args.quality}.png")
    comparison = make_comparison([
        ("Original", rgb),
        (f"Loss-free stripe codec, {result.full_psnr:.2f} dB", result.full_rgb),
        (f"Packet {stripe_index} lost: gray stripe", gray_rgb),
        (f"Packet {stripe_index} lost: neighboring LF copy", coarse_rgb),
    ])
    comparison.save(args.output_dir / f"comparison_loss_stripe_q{args.quality}.png")
    loss_y = stripe_index * 16
    crop_top = max(0, loss_y - 56)
    crop_bottom = min(rgb.shape[0], loss_y + 72)
    zoom = make_comparison([
        ("Loss-free crop", result.full_rgb[crop_top:crop_bottom]),
        ("Complete packet loss", gray_rgb[crop_top:crop_bottom]),
        ("Recovered from LF copy", coarse_rgb[crop_top:crop_bottom]),
    ], columns=3)
    zoom = zoom.resize((zoom.width * 2, zoom.height * 2), Image.Resampling.NEAREST)
    zoom.save(args.output_dir / f"comparison_loss_stripe_zoom_q{args.quality}.png")

    packet_payload_bytes = [packet.payload_bytes for packet in esp_packets]
    redundant_bits = sum(
        len(record.coarse_data) * 8 for record in result.records[1:]
    )
    y_slice = slice(loss_y, min(loss_y + 16, rgb.shape[0]))
    print(f"frame: {rgb.shape[1]}x{rgb.shape[0]}, stripes: {len(result.records)}")
    print(f"quality: {args.quality}, full PSNR: {result.full_psnr:.3f} dB, base PSNR: {result.base_psnr:.3f} dB")
    print(f"base: {result.base_bits/pixels:.4f} bpp, enhancement: {result.enhancement_bits/pixels:.4f} bpp, total: {result.total_bits/pixels:.4f} bpp")
    print(
        "stripe limits base/enhancement: "
        f"{args.base_max_bytes}/{args.enhancement_max_bytes} bytes, "
        "observed maxima: "
        f"{max((record.base_bits + 7) // 8 for record in result.records)}/"
        f"{max((record.enhancement_bits + 7) // 8 for record in result.records)} bytes, "
        "truncated blocks: "
        f"{sum(record.base_truncated_blocks for record in result.records)}/"
        f"{sum(record.enhancement_truncated_blocks for record in result.records)}"
    )
    print(
        f"neighbor LF redundancy: {redundant_bits/pixels:.4f} bpp, "
        f"codec+LF: {(result.total_bits+redundant_bits)/pixels:.4f} bpp"
    )
    print(
        "ESP payload bytes/stripe including next-stripe LF: "
        f"min/avg/max={min(packet_payload_bytes)}/"
        f"{float(np.mean(packet_payload_bytes)):.1f}/{max(packet_payload_bytes)}"
    )
    print(
        f"lost stripe {stripe_index} at y={loss_y}: "
        f"gray frame/stripe PSNR={core.calculate_psnr(rgb, gray_rgb):.3f}/"
        f"{core.calculate_psnr(rgb[y_slice], gray_rgb[y_slice]):.3f} dB, "
        f"LF frame/stripe PSNR={core.calculate_psnr(rgb, coarse_rgb):.3f}/"
        f"{core.calculate_psnr(rgb[y_slice], coarse_rgb[y_slice]):.3f} dB"
    )
    print(f"arithmetic saturations: {result.saturations}")
    print("transport headers/FEC: not included; ESP32 owns packing and LF duplication")


if __name__ == "__main__":
    main()

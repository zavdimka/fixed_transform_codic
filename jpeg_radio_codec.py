#!/usr/bin/env python3
"""Standalone FPGA-oriented JPEG-like codec and radio packet simulator.

This is intentionally not a standard .jpg writer.  It keeps the useful JPEG
building blocks (8x8 DCT, quantization, zigzag, DC coding, AC RLE and fixed
Huffman tables) but removes repeated file headers and packs compact 64x64 tile
records into maximum-bounded variable-length radio packets. A deterministic one-pass
fullness controller processes 8/16-line input windows without tile re-encoding.

Only Pillow image I/O and NumPy arrays are used.  No JPEG encoder/decoder
library participates in the codec path.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
from pathlib import Path
import struct
import zlib

import numpy as np
from PIL import Image


# Orthonormal 8x8 DCT matrix in signed Q14.  These constants are hard-coded so
# the pixel/coeff datapath contains no floating-point operations.
DCT_Q14 = np.array([
    [5793, 5793, 5793, 5793, 5793, 5793, 5793, 5793],
    [8035, 6811, 4551, 1598, -1598, -4551, -6811, -8035],
    [7568, 3135, -3135, -7568, -7568, -3135, 3135, 7568],
    [6811, -1598, -8035, -4551, 4551, 8035, 1598, -6811],
    [5793, -5793, -5793, 5793, 5793, -5793, -5793, 5793],
    [4551, -8035, 1598, 6811, -6811, -1598, 8035, -4551],
    [3135, -7568, 7568, -3135, -3135, 7568, -7568, 3135],
    [1598, -4551, 6811, -8035, 8035, -6811, 4551, -1598],
], dtype=np.int64)

LUMA_QUANT_BASE = np.array([
    [16, 11, 10, 16, 24, 40, 51, 61],
    [12, 12, 14, 19, 26, 58, 60, 55],
    [14, 13, 16, 24, 40, 57, 69, 56],
    [14, 17, 22, 29, 51, 87, 80, 62],
    [18, 22, 37, 56, 68, 109, 103, 77],
    [24, 35, 55, 64, 81, 104, 113, 92],
    [49, 64, 78, 87, 103, 121, 120, 101],
    [72, 92, 95, 98, 112, 100, 103, 99],
], dtype=np.int64)

CHROMA_QUANT_BASE = np.array([
    [17, 18, 24, 47, 99, 99, 99, 99],
    [18, 21, 26, 66, 99, 99, 99, 99],
    [24, 26, 56, 99, 99, 99, 99, 99],
    [47, 66, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
], dtype=np.int64)

ZIGZAG = [
    (0, 0),
    (0, 1), (1, 0),
    (2, 0), (1, 1), (0, 2),
    (0, 3), (1, 2), (2, 1), (3, 0),
    (4, 0), (3, 1), (2, 2), (1, 3), (0, 4),
    (0, 5), (1, 4), (2, 3), (3, 2), (4, 1), (5, 0),
    (6, 0), (5, 1), (4, 2), (3, 3), (2, 4), (1, 5), (0, 6),
    (0, 7), (1, 6), (2, 5), (3, 4), (4, 3), (5, 2), (6, 1), (7, 0),
    (7, 1), (6, 2), (5, 3), (4, 4), (3, 5), (2, 6), (1, 7),
    (2, 7), (3, 6), (4, 5), (5, 4), (6, 3), (7, 2),
    (7, 3), (6, 4), (5, 5), (4, 6), (3, 7),
    (4, 7), (5, 6), (6, 5), (7, 4),
    (7, 5), (6, 6), (5, 7),
    (6, 7), (7, 6),
    (7, 7),
]

# Standard baseline JPEG Huffman table definitions (DHT payloads), embedded as
# one compact hexadecimal constant.  Runtime builds canonical lookup tables;
# no .jpg parser or external codec is required.
STANDARD_DHT_HEX = (
    "0000010501010101010100000000000000000102030405060708090a0b"
    "100002010303020403050504040000017d01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa"
    "0100030101010101010101010000000000000102030405060708090a0b"
    "1100020102040403040705040400010277000102031104052131061241510761711322328108144291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa"
)

TILE_SIZE = 64
LF_BYTES_PER_TILE = 12
TILE_HEADER = struct.Struct(">BHB")  # quality, exact entropy bit length, flags
STREAMING_TILE_FLAG = 3  # reconstructed-reference intra prediction enabled
INTRA_DC = 0
INTRA_VERTICAL = 1
INTRA_HORIZONTAL = 2
INTRA_PLANAR = 3
INTRA_MODE_BITS = 2
MAX_BLOCK_MIN_BITS = 24  # worst-case baseline DC code/amplitude plus EOB
INTRA_MACROBLOCKS_PER_TILE = 16
RATE_CONTROL_BITS_PER_QUALITY = 6
MAX_RATE_QUALITY_REDUCTION = 16
PACKET_MAGIC = b"JQ"
PACKET_VERSION = 5
# magic, version, flags, frame_id, sequence, first scan-order tile, primary
# count, LF backup count, tile slot bytes, meaningful payload bytes, width,
# height, CRC32. Packets contain no artificial radio-minimum padding.
PACKET_HEADER_NO_CRC = struct.Struct(">2sBBHHIBBHHHH")
PACKET_HEADER = struct.Struct(">2sBBHHIBBHHHHI")
LOSS_REFERENCE_PACKET_BYTES = 890
QUALITY_PRESETS = {
    # base quality, maximum tile record, maximum packet
    "low": (24, 325, 700),
    "medium": (32, 420, 890),
    "high": (38, 475, 1000),
}


@dataclass
class ArithmeticStats:
    saturations: int = 0
    max_forward_stage: int = 0
    max_coefficient: int = 0
    max_inverse_stage: int = 0

    def saturate(self, values: np.ndarray, bits: int) -> np.ndarray:
        array = np.asarray(values, dtype=np.int64)
        low = -(1 << (bits - 1))
        high = (1 << (bits - 1)) - 1
        self.saturations += int(np.count_nonzero((array < low) | (array > high)))
        return np.clip(array, low, high).astype(np.int64)


@dataclass(frozen=True)
class CodecConfig:
    quality: int = 32
    tile_bytes: int = 420
    packet_bytes: int = 890
    frame_id: int = 0
    lf_backup: bool = True


@dataclass
class SimulationResult:
    rgb: np.ndarray
    psnr: float
    entropy_bytes: int
    tile_capacity_bytes: int
    wire_bytes: int
    packet_count: int
    minimum_packet_bytes: int
    maximum_packet_bytes: int
    average_packet_bytes: float
    dropped_packets: int
    primary_tiles_lost: int
    lf_recovered_tiles: int
    unrecovered_tiles: int
    min_quality: int
    average_quality: float
    truncated_blocks: int
    truncated_coefficients: int
    effective_drop_rate: float
    saturations: int


class BitWriter:
    def __init__(self) -> None:
        self.buffer = bytearray()
        self.current = 0
        self.used = 0
        self.bit_length = 0

    def write(self, value: int, bits: int) -> None:
        if bits < 0:
            raise ValueError("negative bit count")
        value &= (1 << bits) - 1 if bits else 0
        for shift in range(bits - 1, -1, -1):
            self.current = (self.current << 1) | ((value >> shift) & 1)
            self.used += 1
            self.bit_length += 1
            if self.used == 8:
                self.buffer.append(self.current)
                self.current = 0
                self.used = 0

    def finish(self) -> bytes:
        if self.used:
            self.buffer.append(self.current << (8 - self.used))
        return bytes(self.buffer)


class BitReader:
    def __init__(self, data: bytes, bit_length: int | None = None) -> None:
        self.data = data
        self.limit = len(data) * 8 if bit_length is None else bit_length
        self.position = 0

    def read(self, bits: int) -> int:
        if self.position + bits > self.limit:
            raise EOFError("entropy payload ended unexpectedly")
        value = 0
        for _ in range(bits):
            byte_index = self.position >> 3
            bit_index = 7 - (self.position & 7)
            value = (value << 1) | ((self.data[byte_index] >> bit_index) & 1)
            self.position += 1
        return value


def build_huffman_tables() -> tuple[dict, dict]:
    raw = bytes.fromhex(STANDARD_DHT_HEX)
    position = 0
    encoding: dict[tuple[int, int], dict[int, tuple[int, int]]] = {}
    decoding: dict[tuple[int, int], dict[tuple[int, int], int]] = {}
    while position < len(raw):
        table_info = raw[position]
        position += 1
        counts = list(raw[position:position + 16])
        position += 16
        symbols = list(raw[position:position + sum(counts)])
        position += sum(counts)
        key = (table_info >> 4, table_info & 0x0F)
        enc: dict[int, tuple[int, int]] = {}
        dec: dict[tuple[int, int], int] = {}
        code = 0
        symbol_index = 0
        for length, count in enumerate(counts, start=1):
            for _ in range(count):
                symbol = symbols[symbol_index]
                symbol_index += 1
                enc[symbol] = (code, length)
                dec[(length, code)] = symbol
                code += 1
            code <<= 1
        encoding[key] = enc
        decoding[key] = dec
    return encoding, decoding


HUFFMAN_ENCODE, HUFFMAN_DECODE = build_huffman_tables()


def huffman_write(writer: BitWriter, table_class: int, table_id: int, symbol: int) -> None:
    try:
        code, length = HUFFMAN_ENCODE[(table_class, table_id)][symbol]
    except KeyError as error:
        raise OverflowError(f"Huffman symbol 0x{symbol:02x} is not representable") from error
    writer.write(code, length)


def huffman_read(reader: BitReader, table_class: int, table_id: int) -> int:
    table = HUFFMAN_DECODE[(table_class, table_id)]
    code = 0
    for length in range(1, 17):
        code = (code << 1) | reader.read(1)
        symbol = table.get((length, code))
        if symbol is not None:
            return symbol
    raise ValueError("invalid Huffman code")


def round_shift(values: np.ndarray, shift: int) -> np.ndarray:
    array = np.asarray(values, dtype=np.int64)
    magnitude = (np.abs(array) + (1 << (shift - 1))) >> shift
    return np.where(array < 0, -magnitude, magnitude).astype(np.int64)


def round_div(value: int, divisor: int) -> int:
    magnitude = (abs(int(value)) + divisor // 2) // divisor
    return magnitude if value >= 0 else -magnitude


def forward_dct(block: np.ndarray, stats: ArithmeticStats) -> np.ndarray:
    centered = block.astype(np.int64) - 128
    first = round_shift(DCT_Q14 @ centered, 14)
    stats.max_forward_stage = max(stats.max_forward_stage, int(np.max(np.abs(first))))
    first = stats.saturate(first, 12)
    coefficients = round_shift(first @ DCT_Q14.T, 14)
    stats.max_coefficient = max(stats.max_coefficient, int(np.max(np.abs(coefficients))))
    return stats.saturate(coefficients, 16)


def inverse_dct(coefficients: np.ndarray, stats: ArithmeticStats) -> np.ndarray:
    coefficients = stats.saturate(coefficients, 16)
    first = round_shift(DCT_Q14.T @ coefficients, 14)
    stats.max_inverse_stage = max(stats.max_inverse_stage, int(np.max(np.abs(first))))
    first = stats.saturate(first, 18)
    centered = round_shift(first @ DCT_Q14, 14)
    return np.clip(centered + 128, 0, 255).astype(np.int16)


def forward_residual_dct(residual: np.ndarray, stats: ArithmeticStats) -> np.ndarray:
    """Integer DCT for a signed 9-bit intra residual (no 128 level shift)."""
    first = round_shift(DCT_Q14 @ residual.astype(np.int64), 14)
    stats.max_forward_stage = max(stats.max_forward_stage, int(np.max(np.abs(first))))
    first = stats.saturate(first, 13)
    coefficients = round_shift(first @ DCT_Q14.T, 14)
    stats.max_coefficient = max(stats.max_coefficient, int(np.max(np.abs(coefficients))))
    return stats.saturate(coefficients, 16)


def inverse_residual_dct(coefficients: np.ndarray, stats: ArithmeticStats) -> np.ndarray:
    """Bit-exact inverse path used to build encoder and decoder references."""
    coefficients = stats.saturate(coefficients, 16)
    first = round_shift(DCT_Q14.T @ coefficients, 14)
    stats.max_inverse_stage = max(stats.max_inverse_stage, int(np.max(np.abs(first))))
    first = stats.saturate(first, 18)
    return round_shift(first @ DCT_Q14, 14).astype(np.int16)


def intra_predictors(
    top: np.ndarray | None,
    left: np.ndarray | None,
    size: int = 8,
) -> dict[int, np.ndarray]:
    """Return FPGA-friendly 8x8 predictors available at this tile-local edge."""
    predictors: dict[int, np.ndarray] = {}
    size = len(top) if top is not None else len(left) if left is not None else size
    if top is not None and len(top) != size:
        raise ValueError("intra top/left reference length mismatch")
    if left is not None and len(left) != size:
        raise ValueError("intra top/left reference length mismatch")
    if top is not None and left is not None:
        dc = (
            int(top.astype(np.int64).sum())
            + int(left.astype(np.int64).sum())
            + size
        ) // (2 * size)
    elif top is not None:
        dc = (int(top.astype(np.int64).sum()) + size // 2) // size
    elif left is not None:
        dc = (int(left.astype(np.int64).sum()) + size // 2) // size
    else:
        dc = 128
    predictors[INTRA_DC] = np.full((size, size), dc, dtype=np.int16)

    if top is not None:
        predictors[INTRA_VERTICAL] = np.tile(top.astype(np.int16), (size, 1))
    if left is not None:
        predictors[INTRA_HORIZONTAL] = np.repeat(
            left.astype(np.int16)[:, None], size, axis=1
        )
    if top is not None and left is not None:
        planar = np.empty((size, size), dtype=np.int16)
        top_right = int(top[-1])
        left_bottom = int(left[-1])
        denominator = 2 * size
        for row in range(size):
            for column in range(size):
                value = (
                    (size - 1 - column) * int(left[row])
                    + (column + 1) * top_right
                    + (size - 1 - row) * int(top[column])
                    + (row + 1) * left_bottom
                    + denominator // 2
                ) // denominator
                planar[row, column] = value
        predictors[INTRA_PLANAR] = planar
    return predictors


def residual_satd(residual: np.ndarray) -> int:
    """4x4 Hadamard SATD: add/subtract-only proxy for transform bit cost."""
    total = 0
    source = residual.astype(np.int64)
    for y0 in range(0, source.shape[0], 4):
        for x0 in range(0, source.shape[1], 4):
            block = source[y0:y0 + 4, x0:x0 + 4]
            horizontal = np.empty((4, 4), dtype=np.int64)
            for row in range(4):
                a0 = int(block[row, 0]) + int(block[row, 3])
                a1 = int(block[row, 1]) + int(block[row, 2])
                a2 = int(block[row, 1]) - int(block[row, 2])
                a3 = int(block[row, 0]) - int(block[row, 3])
                horizontal[row] = (a0 + a1, a3 + a2, a0 - a1, a3 - a2)
            for column in range(4):
                a0 = int(horizontal[0, column]) + int(horizontal[3, column])
                a1 = int(horizontal[1, column]) + int(horizontal[2, column])
                a2 = int(horizontal[1, column]) - int(horizontal[2, column])
                a3 = int(horizontal[0, column]) - int(horizontal[3, column])
                total += (
                    abs(a0 + a1) + abs(a3 + a2)
                    + abs(a0 - a1) + abs(a3 - a2)
                )
    return total


def choose_intra_mode(
    block: np.ndarray,
    predictors: dict[int, np.ndarray],
) -> tuple[int, np.ndarray]:
    """Select a mode with an FPGA-friendly Hadamard transform-cost proxy."""
    source = block.astype(np.int64)
    mode = min(
        predictors,
        key=lambda candidate: (
            residual_satd(source - predictors[candidate].astype(np.int64)),
            candidate,
        ),
    )
    return mode, predictors[mode]


def quant_tables(quality: int) -> tuple[np.ndarray, np.ndarray]:
    quality = min(max(int(quality), 1), 100)
    scale = 5000 // quality if quality < 50 else 200 - quality * 2
    def scaled(base: np.ndarray) -> np.ndarray:
        return np.clip((base * scale + 50) // 100, 1, 255).astype(np.int64)
    return scaled(LUMA_QUANT_BASE), scaled(CHROMA_QUANT_BASE)


def magnitude_category(value: int) -> int:
    return abs(int(value)).bit_length()


def amplitude_bits(value: int, category: int) -> int:
    if category == 0:
        return 0
    return value if value >= 0 else value + (1 << category) - 1


def amplitude_value(raw: int, category: int) -> int:
    if category == 0:
        return 0
    if raw < (1 << (category - 1)):
        return raw - ((1 << category) - 1)
    return raw


def decode_quantized_block(
    reader: BitReader,
    previous_dc: int,
    table_id: int,
) -> tuple[np.ndarray, int]:
    category = huffman_read(reader, 0, table_id)
    delta = amplitude_value(reader.read(category), category)
    dc = previous_dc + delta
    values = [0] * 64
    values[0] = dc
    index = 1
    while index < 64:
        symbol = huffman_read(reader, 1, table_id)
        if symbol == 0x00:
            break
        if symbol == 0xF0:
            index += 16
            if index > 64:
                raise ValueError("invalid ZRL in AC stream")
            continue
        run = symbol >> 4
        size = symbol & 0x0F
        index += run
        if index >= 64 or size == 0:
            raise ValueError("invalid AC run/size")
        values[index] = amplitude_value(reader.read(size), size)
        index += 1
    output = np.zeros((8, 8), dtype=np.int64)
    for value, (r, c) in zip(values, ZIGZAG):
        output[r, c] = value
    return output, dc


def rgb_to_ycbcr420(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    x = rgb.astype(np.int64)
    r, g, b = x[..., 0], x[..., 1], x[..., 2]
    y = (77 * r + 150 * g + 29 * b + 128) >> 8
    cb = (-43 * r - 85 * g + 128 * b + 32768 + 128) >> 8
    cr = (128 * r - 107 * g - 21 * b + 32768 + 128) >> 8
    h, w = y.shape
    cb420 = (cb.reshape(h // 2, 2, w // 2, 2).sum(axis=(1, 3)) + 2) >> 2
    cr420 = (cr.reshape(h // 2, 2, w // 2, 2).sum(axis=(1, 3)) + 2) >> 2
    return (
        np.clip(y, 0, 255).astype(np.int16),
        np.clip(cb420, 0, 255).astype(np.int16),
        np.clip(cr420, 0, 255).astype(np.int16),
    )


def ycbcr420_to_rgb(y: np.ndarray, cb: np.ndarray, cr: np.ndarray) -> np.ndarray:
    cb_up = np.repeat(np.repeat(cb.astype(np.int64), 2, axis=0), 2, axis=1) - 128
    cr_up = np.repeat(np.repeat(cr.astype(np.int64), 2, axis=0), 2, axis=1) - 128
    yy = y.astype(np.int64)
    r = yy + ((359 * cr_up + 128) >> 8)
    g = yy - ((88 * cb_up + 183 * cr_up + 128) >> 8)
    b = yy + ((454 * cb_up + 128) >> 8)
    return np.clip(np.stack([r, g, b], axis=-1), 0, 255).astype(np.uint8)


def pad_planes(
    y: np.ndarray, cb: np.ndarray, cr: np.ndarray
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    h, w = y.shape
    ph = math.ceil(h / TILE_SIZE) * TILE_SIZE
    pw = math.ceil(w / TILE_SIZE) * TILE_SIZE
    return (
        np.pad(y, ((0, ph - h), (0, pw - w)), mode="edge"),
        np.pad(cb, ((0, ph // 2 - cb.shape[0]), (0, pw // 2 - cb.shape[1])), mode="edge"),
        np.pad(cr, ((0, ph // 2 - cr.shape[0]), (0, pw // 2 - cr.shape[1])), mode="edge"),
    )


def quantize_block(coefficients: np.ndarray, table: np.ndarray) -> np.ndarray:
    quantized = np.empty((8, 8), dtype=np.int64)
    for r in range(8):
        for c in range(8):
            quantized[r, c] = round_div(
                int(coefficients[r, c]), int(table[r, c])
            )
    return quantized


def huffman_symbol_bits(table_class: int, table_id: int, symbol: int) -> int:
    try:
        return HUFFMAN_ENCODE[(table_class, table_id)][symbol][1]
    except KeyError as error:
        raise OverflowError(
            f"Huffman symbol 0x{symbol:02x} is not representable"
        ) from error


def streaming_block_quality(
    base_quality: int,
    bit_position: int,
    processed_blocks: int,
    capacity_bits: int,
) -> int:
    """One-pass deterministic fullness controller, reproduced by decoder."""
    target = (capacity_bits * processed_blocks + 48) // 96
    bits_ahead = max(0, bit_position - target)
    reduction = min(
        MAX_RATE_QUALITY_REDUCTION,
        (bits_ahead + RATE_CONTROL_BITS_PER_QUALITY - 1)
        // RATE_CONTROL_BITS_PER_QUALITY,
    )
    return max(1, base_quality - reduction)


def encode_block_stream(
    writer: BitWriter,
    block: np.ndarray,
    table: np.ndarray,
    previous_dc: int,
    table_id: int,
    end_bit_limit: int,
    stats: ArithmeticStats,
) -> tuple[int, int, np.ndarray]:
    """Append one residual block and return exactly the coefficients sent."""
    coefficients = forward_residual_dct(block, stats)
    quantized = quantize_block(coefficients, table)
    values = [int(quantized[r, c]) for r, c in ZIGZAG]
    reconstructed_quantized = np.zeros((8, 8), dtype=np.int64)
    reconstructed_quantized[0, 0] = values[0]

    delta = values[0] - previous_dc
    category = magnitude_category(delta)
    if category > 11:
        raise OverflowError("DC category exceeds baseline JPEG table")
    dc_bits = huffman_symbol_bits(0, table_id, category) + category
    eob_bits = huffman_symbol_bits(1, table_id, 0x00)
    if writer.bit_length + dc_bits + eob_bits > end_bit_limit:
        raise OverflowError("reserved block budget cannot hold DC and EOB")
    huffman_write(writer, 0, table_id, category)
    writer.write(amplitude_bits(delta, category), category)

    last_nonzero = max(
        (index for index, value in enumerate(values[1:], start=1) if value),
        default=0,
    )
    run = 0
    truncated_coefficients = 0
    truncated = False
    for scan_index, value in enumerate(values[1:], start=1):
        if value == 0:
            run += 1
            continue
        tokens: list[tuple[int, int]] = []
        pending_run = run
        while pending_run >= 16:
            tokens.append((0xF0, 0))
            pending_run -= 16
        size = magnitude_category(value)
        if size > 10:
            truncated_coefficients = 64 - scan_index
            truncated = True
            break
        symbol = (pending_run << 4) | size
        token_bits = sum(
            huffman_symbol_bits(1, table_id, token) + amplitude_size
            for token, amplitude_size in tokens
        )
        token_bits += huffman_symbol_bits(1, table_id, symbol) + size
        needs_eob = scan_index < last_nonzero or last_nonzero < 63
        reserve_eob = eob_bits if needs_eob else 0
        if writer.bit_length + token_bits + reserve_eob > end_bit_limit:
            truncated_coefficients = 64 - scan_index
            truncated = True
            break
        for token, amplitude_size in tokens:
            huffman_write(writer, 1, table_id, token)
            writer.write(0, amplitude_size)
        huffman_write(writer, 1, table_id, symbol)
        writer.write(amplitude_bits(value, size), size)
        coefficient_row, coefficient_column = ZIGZAG[scan_index]
        reconstructed_quantized[coefficient_row, coefficient_column] = value
        run = 0

    # EOB is required for trailing zeros or a deliberately discarded tail.
    # If coefficient 63 was non-zero and encoded, the decoder reaches index 64
    # and no marker may remain for the next block.
    if truncated or last_nonzero < 63:
        huffman_write(writer, 1, table_id, 0x00)
    if writer.bit_length > end_bit_limit:
        raise AssertionError("block exceeded its reserved streaming budget")
    return values[0], truncated_coefficients, reconstructed_quantized


class StreamingTileContext:
    """Entropy/DC/LF state kept while 8/16 input lines cross one tile row."""

    TOTAL_BLOCKS = 96

    def __init__(self, config: CodecConfig) -> None:
        self.config = config
        self.writer = BitWriter()
        self.processed_blocks = 0
        self.truncated_blocks = 0
        self.truncated_coefficients = 0
        self.minimum_quality = config.quality
        self.quality_sum = 0
        self.lf_y = np.zeros((4, 4), dtype=np.int64)
        self.lf_cb = np.zeros((2, 2), dtype=np.int64)
        self.lf_cr = np.zeros((2, 2), dtype=np.int64)
        # Only the reconstructed top edge and current left edge are retained.
        # References reset at every 64x64 tile, making tile records independent.
        self.top_refs = [
            np.zeros(64, dtype=np.int16),
            np.zeros(32, dtype=np.int16),
            np.zeros(32, dtype=np.int16),
        ]
        self.left_refs: list[np.ndarray | None] = [None, None, None]
        self.mode_counts = [0, 0, 0, 0]
        self.modes_written = 0

    def capacity_bits(self) -> int:
        return (self.config.tile_bytes - TILE_HEADER.size) * 8

    def end_bit_limit(self) -> int:
        remaining_after = self.TOTAL_BLOCKS - self.processed_blocks - 1
        future_modes = INTRA_MACROBLOCKS_PER_TILE - self.modes_written
        return (
            self.capacity_bits()
            - remaining_after * MAX_BLOCK_MIN_BITS
            - future_modes * INTRA_MODE_BITS
        )

    def block_quality(self) -> int:
        return streaming_block_quality(
            self.config.quality,
            self.writer.bit_length,
            self.processed_blocks,
            self.capacity_bits(),
        )

    def prediction_references(
        self,
        plane_id: int,
        macroblock_index: int,
    ) -> tuple[np.ndarray | None, np.ndarray | None, int]:
        macroblock_row, macroblock_column = divmod(macroblock_index, 4)
        span = 16 if plane_id == 0 else 8
        start = macroblock_column * span
        top = (
            self.top_refs[plane_id][start:start + span]
            if macroblock_row
            else None
        )
        left = self.left_refs[plane_id] if macroblock_column else None
        return top, left, start

    def update_references(
        self,
        plane_id: int,
        start: int,
        reconstructed: np.ndarray,
    ) -> None:
        self.top_refs[plane_id][start:start + reconstructed.shape[1]] = reconstructed[-1, :]
        self.left_refs[plane_id] = reconstructed[:, -1].copy()

    def add_lf_block(self, plane_id: int, block_index: int, block: np.ndarray) -> None:
        block_columns = 8 if plane_id == 0 else 4
        block_row, block_column = divmod(block_index, block_columns)
        target = (self.lf_y, self.lf_cb, self.lf_cr)[plane_id]
        target[block_row // 2, block_column // 2] += int(
            block.astype(np.int64).sum()
        )

    def summary(self) -> bytes:
        nibbles: list[int] = []
        for sums in (self.lf_y, self.lf_cb, self.lf_cr):
            for value in sums.flat:
                average = (int(value) + 128) // 256
                nibbles.append(min(max(average >> 4, 0), 15))
        if len(nibbles) != 24:
            raise AssertionError("LF tile summary must contain 24 nibbles")
        return bytes(
            (nibbles[index] << 4) | nibbles[index + 1]
            for index in range(0, 24, 2)
        )

    def finish_slot(self) -> tuple[bytes, int]:
        if self.processed_blocks != self.TOTAL_BLOCKS:
            raise AssertionError("streaming tile did not receive all 96 blocks")
        bit_length = self.writer.bit_length
        if bit_length > 0xFFFF:
            raise OverflowError("tile entropy bit length exceeds its header")
        entropy = self.writer.finish()
        capacity = self.config.tile_bytes - TILE_HEADER.size
        if len(entropy) > capacity:
            raise AssertionError("tile entropy exceeded fixed slot capacity")
        header = TILE_HEADER.pack(
            self.config.quality, bit_length, STREAMING_TILE_FLAG
        )
        return header + entropy, len(entropy)


def encode_residual_block(
    context: StreamingTileContext,
    plane_id: int,
    block_index: int,
    block: np.ndarray,
    predictor: np.ndarray,
    table_id: int,
    stats: ArithmeticStats,
) -> np.ndarray:
    quality = context.block_quality()
    qy, qc = quant_tables(quality)
    table = qy if plane_id == 0 else qc
    residual = block.astype(np.int16) - predictor.astype(np.int16)
    _, truncated, transmitted_quantized = encode_block_stream(
        context.writer,
        residual,
        table,
        0,
        table_id,
        context.end_bit_limit(),
        stats,
    )
    reconstructed_residual = inverse_residual_dct(
        transmitted_quantized * table, stats
    )
    reconstructed = np.clip(
        predictor.astype(np.int64) + reconstructed_residual.astype(np.int64),
        0,
        255,
    ).astype(np.int16)
    context.minimum_quality = min(context.minimum_quality, quality)
    context.quality_sum += quality
    context.processed_blocks += 1
    if truncated:
        context.truncated_blocks += 1
        context.truncated_coefficients += truncated
    context.add_lf_block(plane_id, block_index, block)
    return reconstructed


def encode_context_macroblock(
    context: StreamingTileContext,
    macroblock_index: int,
    luma: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    stats: ArithmeticStats,
) -> None:
    """Encode one 16x16 luma + 8x8 4:2:0 region with one shared mode."""
    top, left, luma_start = context.prediction_references(0, macroblock_index)
    luma_predictors = intra_predictors(top, left, 16)
    chroma_prediction: dict[int, tuple[int, dict[int, np.ndarray]]] = {}
    for plane_id in (1, 2):
        chroma_top, chroma_left, chroma_start = context.prediction_references(
            plane_id, macroblock_index
        )
        chroma_prediction[plane_id] = (
            chroma_start,
            intra_predictors(chroma_top, chroma_left),
        )
    mode = min(
        luma_predictors,
        key=lambda candidate: (
            residual_satd(
                luma.astype(np.int64)
                - luma_predictors[candidate].astype(np.int64)
            )
            + residual_satd(
                cb.astype(np.int64)
                - chroma_prediction[1][1][candidate].astype(np.int64)
            )
            + residual_satd(
                cr.astype(np.int64)
                - chroma_prediction[2][1][candidate].astype(np.int64)
            ),
            candidate,
        ),
    )
    luma_predictor = luma_predictors[mode]
    context.writer.write(mode, INTRA_MODE_BITS)
    context.modes_written += 1
    context.mode_counts[mode] += 1

    macroblock_row, macroblock_column = divmod(macroblock_index, 4)
    reconstructed_luma = np.empty((16, 16), dtype=np.int16)
    for sub_row in range(2):
        for sub_column in range(2):
            y0, x0 = sub_row * 8, sub_column * 8
            block_index = (
                (macroblock_row * 2 + sub_row) * 8
                + macroblock_column * 2
                + sub_column
            )
            reconstructed_luma[y0:y0 + 8, x0:x0 + 8] = encode_residual_block(
                context,
                0,
                block_index,
                luma[y0:y0 + 8, x0:x0 + 8],
                luma_predictor[y0:y0 + 8, x0:x0 + 8],
                0,
                stats,
            )
    context.update_references(0, luma_start, reconstructed_luma)

    chroma_block_index = macroblock_row * 4 + macroblock_column
    for plane_id, block in ((1, cb), (2, cr)):
        chroma_start, predictors = chroma_prediction[plane_id]
        reconstructed = encode_residual_block(
            context,
            plane_id,
            chroma_block_index,
            block,
            predictors[mode],
            1,
            stats,
        )
        context.update_references(plane_id, chroma_start, reconstructed)

def decode_tile_slot(
    slot: bytes,
    stats: ArithmeticStats,
    tile_capacity_bytes: int | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, int]:
    if len(slot) < TILE_HEADER.size:
        raise ValueError("truncated tile slot")
    quality, bit_length, flags = TILE_HEADER.unpack(slot[:TILE_HEADER.size])
    if flags != STREAMING_TILE_FLAG or not 1 <= quality <= 100:
        raise ValueError("unsupported streaming intra tile header")
    entropy_bytes = (bit_length + 7) // 8
    if TILE_HEADER.size + entropy_bytes > len(slot):
        raise ValueError("tile entropy length exceeds its record")
    reader = BitReader(
        slot[TILE_HEADER.size:TILE_HEADER.size + entropy_bytes], bit_length
    )
    capacity_bytes = len(slot) if tile_capacity_bytes is None else tile_capacity_bytes
    if capacity_bytes < len(slot):
        raise ValueError("tile record exceeds signalled maximum capacity")
    capacity_bits = (capacity_bytes - TILE_HEADER.size) * 8
    processed_blocks = 0
    y = np.empty((64, 64), dtype=np.int16)
    cb = np.empty((32, 32), dtype=np.int16)
    cr = np.empty((32, 32), dtype=np.int16)
    def decode_residual(
        plane_id: int,
        predictor: np.ndarray,
        table_id: int,
    ) -> np.ndarray:
        nonlocal processed_blocks
        block_quality = streaming_block_quality(
            quality, reader.position, processed_blocks, capacity_bits
        )
        qy, qc = quant_tables(block_quality)
        table = qy if plane_id == 0 else qc
        quantized, _ = decode_quantized_block(reader, 0, table_id)
        reconstructed_residual = inverse_residual_dct(quantized * table, stats)
        processed_blocks += 1
        return np.clip(
            predictor.astype(np.int64) + reconstructed_residual.astype(np.int64),
            0,
            255,
        ).astype(np.int16)

    for macroblock_row in range(4):
        for macroblock_column in range(4):
            mode = reader.read(INTRA_MODE_BITS)
            luma_y, luma_x = macroblock_row * 16, macroblock_column * 16
            luma_top = (
                y[luma_y - 1, luma_x:luma_x + 16]
                if macroblock_row
                else None
            )
            luma_left = (
                y[luma_y:luma_y + 16, luma_x - 1]
                if macroblock_column
                else None
            )
            luma_predictors = intra_predictors(luma_top, luma_left, 16)
            if mode not in luma_predictors:
                raise ValueError("intra mode uses an unavailable tile-edge reference")
            for sub_row in range(2):
                for sub_column in range(2):
                    y0, x0 = sub_row * 8, sub_column * 8
                    y[
                        luma_y + y0:luma_y + y0 + 8,
                        luma_x + x0:luma_x + x0 + 8,
                    ] = decode_residual(
                        0,
                        luma_predictors[mode][y0:y0 + 8, x0:x0 + 8],
                        0,
                    )

            chroma_y, chroma_x = macroblock_row * 8, macroblock_column * 8
            for plane_id, plane in ((1, cb), (2, cr)):
                chroma_top = (
                    plane[chroma_y - 1, chroma_x:chroma_x + 8]
                    if macroblock_row
                    else None
                )
                chroma_left = (
                    plane[chroma_y:chroma_y + 8, chroma_x - 1]
                    if macroblock_column
                    else None
                )
                predictors = intra_predictors(chroma_top, chroma_left)
                if mode not in predictors:
                    raise ValueError("shared chroma intra mode is unavailable")
                plane[
                    chroma_y:chroma_y + 8,
                    chroma_x:chroma_x + 8,
                ] = decode_residual(plane_id, predictors[mode], 1)

    if processed_blocks != 96 or reader.position != bit_length:
        raise ValueError("tile entropy has unused coded bits")
    return y, cb, cr, quality

def tile_scan_coordinates(tile_rows: int, tile_columns: int) -> list[tuple[int, int]]:
    """Raster order keeps tiles in each packet horizontally adjacent."""
    return [
        (tile_row, tile_column)
        for tile_row in range(tile_rows)
        for tile_column in range(tile_columns)
    ]


def decode_lf_summary(summary: bytes) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if len(summary) != LF_BYTES_PER_TILE:
        raise ValueError("invalid LF summary length")
    values: list[int] = []
    for byte in summary:
        values.extend((byte >> 4, byte & 0x0F))
    values = [value * 17 for value in values]
    y = np.empty((64, 64), dtype=np.int16)
    cb = np.empty((32, 32), dtype=np.int16)
    cr = np.empty((32, 32), dtype=np.int16)
    cursor = 0
    for plane, step in ((y, 16), (cb, 16), (cr, 16)):
        for by in range(0, plane.shape[0], step):
            for bx in range(0, plane.shape[1], step):
                plane[by:by + step, bx:bx + step] = values[cursor]
                cursor += 1
    return y, cb, cr


def build_packet(
    config: CodecConfig,
    sequence: int,
    first_tile: int,
    primary_records: list[bytes],
    backup_summaries: list[bytes],
    width: int,
    height: int,
) -> bytes:
    payload = b"".join(primary_records) + b"".join(backup_summaries)
    required_packet_bytes = PACKET_HEADER.size + len(payload)
    if required_packet_bytes > config.packet_bytes:
        raise ValueError(
            f"packet payload needs {required_packet_bytes} bytes, above configured "
            f"maximum {config.packet_bytes}"
        )
    body = payload
    flags = 1 if config.lf_backup else 0
    header_no_crc = PACKET_HEADER_NO_CRC.pack(
        PACKET_MAGIC, PACKET_VERSION, flags, config.frame_id, sequence,
        first_tile, len(primary_records), len(backup_summaries), config.tile_bytes,
        len(payload), width, height,
    )
    checksum = zlib.crc32(header_no_crc + body) & 0xFFFFFFFF
    return header_no_crc + struct.pack(">I", checksum) + body


def parse_packet(
    raw: bytes,
    maximum_packet_bytes: int,
) -> tuple[tuple, bytes]:
    if not PACKET_HEADER.size <= len(raw) <= maximum_packet_bytes:
        raise ValueError("invalid variable packet length")
    fields = PACKET_HEADER.unpack(raw[:PACKET_HEADER.size])
    (
        magic, version, flags, frame_id, sequence, first_tile, primary_count,
        backup_count, tile_bytes, payload_bytes, width, height, expected_crc,
    ) = fields
    if magic != PACKET_MAGIC or version != PACKET_VERSION:
        raise ValueError("invalid packet magic/version")
    body = raw[PACKET_HEADER.size:]
    actual_crc = zlib.crc32(raw[:PACKET_HEADER_NO_CRC.size] + body) & 0xFFFFFFFF
    if actual_crc != expected_crc:
        raise ValueError("packet CRC mismatch")
    if payload_bytes != len(body):
        raise ValueError("packet length does not match its payload length")
    return fields[:-1], body


def calculate_psnr(reference: np.ndarray, test: np.ndarray) -> float:
    error = reference.astype(np.int64) - test.astype(np.int64)
    mse = float(np.mean(error * error))
    return float("inf") if mse == 0 else 10.0 * math.log10(255.0 * 255.0 / mse)


def nearest_conceal(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    available: np.ndarray,
) -> None:
    rows, columns = available.shape
    sources = np.argwhere(available)
    if not len(sources):
        return
    for ty in range(rows):
        for tx in range(columns):
            if available[ty, tx]:
                continue
            distances = np.abs(sources[:, 0] - ty) + np.abs(sources[:, 1] - tx)
            sy, sx = sources[int(np.argmin(distances))]
            y[ty * 64:(ty + 1) * 64, tx * 64:(tx + 1) * 64] = y[
                sy * 64:(sy + 1) * 64, sx * 64:(sx + 1) * 64
            ]
            cb[ty * 32:(ty + 1) * 32, tx * 32:(tx + 1) * 32] = cb[
                sy * 32:(sy + 1) * 32, sx * 32:(sx + 1) * 32
            ]
            cr[ty * 32:(ty + 1) * 32, tx * 32:(tx + 1) * 32] = cr[
                sy * 32:(sy + 1) * 32, sx * 32:(sx + 1) * 32
            ]
            available[ty, tx] = True


def encode_frame_streaming(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    config: CodecConfig,
    original_width: int,
    original_height: int,
    stats: ArithmeticStats,
) -> tuple[list[bytes], int, int, int, int, int, float]:
    """Encode in 16-line RGB windows with one active tile-row state."""
    tile_rows, tile_columns = y.shape[0] // 64, y.shape[1] // 64
    per_tile_with_backup = config.tile_bytes + (
        LF_BYTES_PER_TILE if config.lf_backup else 0
    )
    tiles_per_packet = min(
        4,
        (config.packet_bytes - PACKET_HEADER.size) // per_tile_with_backup,
    )
    if tiles_per_packet < 1:
        raise ValueError("packet cannot hold one tile slot and LF backup")

    packets: list[bytes] = []
    pending: tuple[int, list[bytes]] | None = None
    sequence = 0
    entropy_bytes = 0
    truncated_blocks = 0
    truncated_coefficients = 0
    minimum_quality = config.quality
    quality_sum = 0

    for tile_row in range(tile_rows):
        contexts = [StreamingTileContext(config) for _ in range(tile_columns)]
        y_origin = tile_row * 64
        chroma_origin = tile_row * 32

        # A 16-line RGB window exposes one row of 16x16 luma macroblocks
        # and the matching 8x8 Cb/Cr blocks. No complete 64-line tile buffer
        # participates in prediction or mode selection.
        for macroblock_row in range(4):
            source_y = y_origin + macroblock_row * 16
            source_chroma_y = chroma_origin + macroblock_row * 8
            for tile_column, context in enumerate(contexts):
                luma_x_origin = tile_column * 64
                chroma_x_origin = tile_column * 32
                for macroblock_column in range(4):
                    macroblock_index = macroblock_row * 4 + macroblock_column
                    source_x = luma_x_origin + macroblock_column * 16
                    source_chroma_x = chroma_x_origin + macroblock_column * 8
                    encode_context_macroblock(
                        context,
                        macroblock_index,
                        y[source_y:source_y + 16, source_x:source_x + 16],
                        cb[
                            source_chroma_y:source_chroma_y + 8,
                            source_chroma_x:source_chroma_x + 8,
                        ],
                        cr[
                            source_chroma_y:source_chroma_y + 8,
                            source_chroma_x:source_chroma_x + 8,
                        ],
                        stats,
                    )

        for first_column in range(0, tile_columns, tiles_per_packet):
            group_contexts = contexts[
                first_column:first_column + tiles_per_packet
            ]
            first_tile = tile_row * tile_columns + first_column
            current_slots: list[bytes] = []
            current_summaries = [context.summary() for context in group_contexts]
            for context in group_contexts:
                slot, used_entropy_bytes = context.finish_slot()
                current_slots.append(slot)
                entropy_bytes += used_entropy_bytes
                truncated_blocks += context.truncated_blocks
                truncated_coefficients += context.truncated_coefficients
                minimum_quality = min(minimum_quality, context.minimum_quality)
                quality_sum += context.quality_sum

            if pending is not None:
                pending_first, pending_slots = pending
                backups = current_summaries if config.lf_backup else []
                packets.append(build_packet(
                    config,
                    sequence,
                    pending_first,
                    pending_slots,
                    backups,
                    original_width,
                    original_height,
                ))
                sequence += 1
            pending = (first_tile, current_slots)

    if pending is not None:
        pending_first, pending_slots = pending
        packets.append(build_packet(
            config,
            sequence,
            pending_first,
            pending_slots,
            [],
            original_width,
            original_height,
        ))

    return (
        packets,
        tile_rows * tile_columns,
        entropy_bytes,
        truncated_blocks,
        truncated_coefficients,
        minimum_quality,
        quality_sum / (tile_rows * tile_columns * 96),
    )


def simulate(
    rgb: np.ndarray,
    config: CodecConfig,
    packet_drop_rate: float,
    packet_drop_seed: int,
    concealment: str,
    save_packets_dir: Path | None,
    packet_loss_model: str = "length-scaled",
) -> SimulationResult:
    original_h, original_w = rgb.shape[:2]
    y, cb, cr = rgb_to_ycbcr420(rgb)
    y, cb, cr = pad_planes(y, cb, cr)
    tile_rows, tile_columns = y.shape[0] // 64, y.shape[1] // 64
    coordinates = tile_scan_coordinates(tile_rows, tile_columns)
    stats = ArithmeticStats()
    (
        packets,
        tile_count,
        entropy_bytes,
        truncated_blocks,
        truncated_coefficients,
        minimum_quality,
        average_quality,
    ) = encode_frame_streaming(
        y, cb, cr, config, original_w, original_h, stats
    )

    if save_packets_dir is not None:
        save_packets_dir.mkdir(parents=True, exist_ok=True)
        for index, packet in enumerate(packets):
            (save_packets_dir / f"frame{config.frame_id:04d}_packet{index:04d}.bin").write_bytes(packet)

    if packet_loss_model == "fixed":
        packet_drop_probabilities = np.full(len(packets), packet_drop_rate)
    elif packet_loss_model == "length-scaled":
        packet_drop_probabilities = np.array([
            1.0 - (1.0 - packet_drop_rate) ** (
                len(packet) / LOSS_REFERENCE_PACKET_BYTES
            )
            for packet in packets
        ])
    else:
        raise ValueError("packet loss model must be fixed or length-scaled")
    effective_drop_rate = float(np.mean(packet_drop_probabilities))
    rng = np.random.default_rng(packet_drop_seed)
    drop_mask = rng.random(len(packets)) < packet_drop_probabilities
    primary: dict[int, bytes] = {}
    backup: dict[int, bytes] = {}
    dropped_packets = 0
    for packet_index, raw in enumerate(packets):
        if bool(drop_mask[packet_index]):
            dropped_packets += 1
            continue
        fields, payload = parse_packet(raw, config.packet_bytes)
        (
            magic, version, flags, frame_id, sequence, first_tile, primary_count,
            backup_count, tile_bytes, payload_bytes, width, height,
        ) = fields
        if frame_id != config.frame_id or tile_bytes != config.tile_bytes or sequence != packet_index:
            raise ValueError("packet configuration mismatch")
        cursor = 0
        for local in range(primary_count):
            if cursor + TILE_HEADER.size > len(payload):
                raise ValueError("truncated variable tile record header")
            quality, bit_length, tile_flags = TILE_HEADER.unpack(
                payload[cursor:cursor + TILE_HEADER.size]
            )
            record_bytes = TILE_HEADER.size + (bit_length + 7) // 8
            if (
                tile_flags != STREAMING_TILE_FLAG
                or not 1 <= quality <= 100
                or record_bytes > config.tile_bytes
                or cursor + record_bytes > len(payload)
            ):
                raise ValueError("invalid variable tile record")
            primary[first_tile + local] = payload[cursor:cursor + record_bytes]
            cursor += record_bytes
        next_first = first_tile + primary_count
        lf_payload = payload[cursor:]
        if len(lf_payload) != backup_count * LF_BYTES_PER_TILE:
            raise ValueError("packet primary/LF length mismatch")
        for local in range(backup_count):
            start = local * LF_BYTES_PER_TILE
            backup[next_first + local] = lf_payload[start:start + LF_BYTES_PER_TILE]

    decoded_y = np.full_like(y, 128)
    decoded_cb = np.full_like(cb, 128)
    decoded_cr = np.full_like(cr, 128)
    available = np.zeros((tile_rows, tile_columns), dtype=bool)
    recovered = 0
    decode_stats = ArithmeticStats()
    for scan_index, (ty, tx) in enumerate(coordinates):
        if scan_index in primary:
            tile_y, tile_cb, tile_cr, _ = decode_tile_slot(
                primary[scan_index], decode_stats, config.tile_bytes
            )
            available[ty, tx] = True
        elif scan_index in backup:
            tile_y, tile_cb, tile_cr = decode_lf_summary(backup[scan_index])
            available[ty, tx] = True
            recovered += 1
        else:
            continue
        decoded_y[ty * 64:(ty + 1) * 64, tx * 64:(tx + 1) * 64] = tile_y
        decoded_cb[ty * 32:(ty + 1) * 32, tx * 32:(tx + 1) * 32] = tile_cb
        decoded_cr[ty * 32:(ty + 1) * 32, tx * 32:(tx + 1) * 32] = tile_cr

    unrecovered = int((~available).sum())
    if concealment == "nearest":
        nearest_conceal(decoded_y, decoded_cb, decoded_cr, available)
    elif concealment != "gray":
        raise ValueError("concealment must be gray or nearest")

    output = ycbcr420_to_rgb(
        decoded_y[:original_h, :original_w],
        decoded_cb[:original_h // 2, :original_w // 2],
        decoded_cr[:original_h // 2, :original_w // 2],
    )
    primary_lost = tile_count - len(primary)
    return SimulationResult(
        rgb=output,
        psnr=calculate_psnr(rgb, output),
        entropy_bytes=entropy_bytes,
        tile_capacity_bytes=tile_count * config.tile_bytes,
        wire_bytes=sum(len(packet) for packet in packets),
        packet_count=len(packets),
        minimum_packet_bytes=min(map(len, packets)),
        maximum_packet_bytes=max(map(len, packets)),
        average_packet_bytes=float(np.mean([len(packet) for packet in packets])),
        dropped_packets=dropped_packets,
        primary_tiles_lost=primary_lost,
        lf_recovered_tiles=recovered,
        unrecovered_tiles=unrecovered,
        min_quality=minimum_quality,
        average_quality=average_quality,
        truncated_blocks=truncated_blocks,
        truncated_coefficients=truncated_coefficients,
        effective_drop_rate=effective_drop_rate,
        saturations=stats.saturations + decode_stats.saturations,
    )


def comparison_image(original: np.ndarray, decoded: np.ndarray) -> Image.Image:
    h, w, _ = original.shape
    canvas = Image.new("RGB", (w * 2, h))
    canvas.paste(Image.fromarray(original), (0, 0))
    canvas.paste(Image.fromarray(decoded), (w, 0))
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description="Standalone JPEG-like variable radio codec")
    parser.add_argument("input", type=Path)
    parser.add_argument(
        "--quality-preset", choices=tuple(QUALITY_PRESETS), default="medium",
        help="discrete quality/radio profile (default: medium)",
    )
    parser.add_argument("--quality", type=int, default=None, help="override preset base quality")
    parser.add_argument("--tile-bytes", type=int, default=None, help="override preset maximum tile record")
    parser.add_argument("--packet-bytes", type=int, default=None, help="override preset maximum packet length")
    parser.add_argument("--packet-drop-rate", type=float, default=0.0)
    parser.add_argument(
        "--packet-loss-model", choices=("length-scaled", "fixed"),
        default="length-scaled",
        help="scale loss probability with packet airtime or keep it fixed",
    )
    parser.add_argument("--packet-drop-seed", type=int, default=1234)
    parser.add_argument("--loss-concealment", choices=["gray", "nearest"], default="gray")
    parser.add_argument("--no-lf-backup", action="store_true")
    parser.add_argument("--frame-id", type=int, default=0)
    parser.add_argument("--save-packets", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=Path("jpeg_radio_results"))
    args = parser.parse_args()
    (
        preset_quality,
        preset_tile_bytes,
        preset_packet_bytes,
    ) = QUALITY_PRESETS[args.quality_preset]
    manual_overrides = any(
        value is not None
        for value in (
            args.quality, args.tile_bytes, args.packet_bytes
        )
    )
    args.quality = preset_quality if args.quality is None else args.quality
    args.tile_bytes = preset_tile_bytes if args.tile_bytes is None else args.tile_bytes
    args.packet_bytes = preset_packet_bytes if args.packet_bytes is None else args.packet_bytes

    if not args.input.exists():
        raise SystemExit(f"input image not found: {args.input}")
    if not 1 <= args.quality <= 100:
        raise SystemExit("--quality must be in [1, 100]")
    minimum_tile_bytes = TILE_HEADER.size + (
        96 * MAX_BLOCK_MIN_BITS
        + INTRA_MACROBLOCKS_PER_TILE * INTRA_MODE_BITS
        + 7
    ) // 8
    if not minimum_tile_bytes <= args.tile_bytes <= TILE_HEADER.size + 8192:
        raise SystemExit(
            f"--tile-bytes must be in [{minimum_tile_bytes}, 8196] "
            "to reserve worst-case DC and EOB for all 96 blocks"
        )
    minimum_packet_bytes = (
        PACKET_HEADER.size + args.tile_bytes
        + (0 if args.no_lf_backup else LF_BYTES_PER_TILE)
    )
    if args.packet_bytes < minimum_packet_bytes:
        raise SystemExit(
            f"--packet-bytes must be at least {minimum_packet_bytes} "
            "for one tile and the selected redundancy"
        )
    if not 0.0 <= args.packet_drop_rate <= 1.0:
        raise SystemExit("--packet-drop-rate must be in [0.0, 1.0]")

    image = Image.open(args.input).convert("RGB")
    rgb = np.asarray(image, dtype=np.uint8)
    h, w = rgb.shape[:2]
    rgb = rgb[:h - (h % 2), :w - (w % 2)]
    config = CodecConfig(
        quality=args.quality,
        tile_bytes=args.tile_bytes,
        packet_bytes=args.packet_bytes,
        frame_id=args.frame_id,
        lf_backup=not args.no_lf_backup,
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    packet_dir = args.output_dir / "packets" if args.save_packets else None
    result = simulate(
        rgb, config, args.packet_drop_rate, args.packet_drop_seed,
        args.loss_concealment, packet_dir, args.packet_loss_model,
    )
    packet_label = f"max{args.packet_bytes}"
    suffix = (
        f"q{args.quality}_tile{args.tile_bytes}_pkt{packet_label}"
        f"_lf{int(config.lf_backup)}_drop{int(round(args.packet_drop_rate * 100)):02d}"
    )
    decoded_path = args.output_dir / f"decoded_{suffix}.png"
    comparison_path = args.output_dir / f"comparison_{suffix}.png"
    Image.fromarray(result.rgb).save(decoded_path)
    comparison_image(rgb, result.rgb).save(comparison_path)

    pixels = rgb.shape[0] * rgb.shape[1]
    print("standalone JPEG-like radio simulation")
    print(f"  frame: {rgb.shape[1]}x{rgb.shape[0]}, tiles: {math.ceil(rgb.shape[1]/64)}x{math.ceil(rgb.shape[0]/64)}")
    override_note = " + manual overrides" if manual_overrides else ""
    print(f"  quality preset: {args.quality_preset}{override_note}")
    active_context_bytes = math.ceil(rgb.shape[1] / 64) * args.tile_bytes
    print(f"  base quality: {args.quality}, tile slot: {args.tile_bytes} bytes")
    print(
        "  streaming order: 16 RGB lines per intra macroblock row, "
        "quality retries=0"
    )
    print(
        f"  active tile entropy contexts: {active_context_bytes} bytes "
        "for one 64-line tile band"
    )
    print(
        f"  one-pass effective quality: min={result.min_quality}, "
        f"avg={result.average_quality:.2f}"
    )
    print(
        f"  truncated AC tails: blocks={result.truncated_blocks}, "
        f"coefficient positions={result.truncated_coefficients}"
    )
    print(
        f"  bits/pixel: entropy={result.entropy_bytes*8/pixels:.4f}, "
        f"max_tile_capacity={result.tile_capacity_bytes*8/pixels:.4f}, "
        f"wire={result.wire_bytes*8/pixels:.4f}"
    )
    print(
        f"  packet loss: model={args.packet_loss_model}, "
        f"reference={args.packet_drop_rate:.4f}@{LOSS_REFERENCE_PACKET_BYTES}B, "
        f"effective={result.effective_drop_rate:.4f}"
    )
    print(
        f"  packets: count={result.packet_count}, "
        f"min/avg/max={result.minimum_packet_bytes}/"
        f"{result.average_packet_bytes:.1f}/{result.maximum_packet_bytes} bytes, "
        f"dropped={result.dropped_packets}"
    )
    print(
        f"  primary tiles lost={result.primary_tiles_lost}, "
        f"LF recovered={result.lf_recovered_tiles}, "
        f"unrecovered={result.unrecovered_tiles}"
    )
    print(
        f"  PSNR={result.psnr:.3f} dB, arithmetic saturations={result.saturations}"
    )
    print(f"  decoded: {decoded_path.resolve()}")
    print(f"  comparison: {comparison_path.resolve()}")


if __name__ == "__main__":
    main()

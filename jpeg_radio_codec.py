#!/usr/bin/env python3
"""Standalone FPGA-oriented JPEG-like codec and fixed radio packet simulator.

This is intentionally not a standard .jpg writer.  It keeps the useful JPEG
building blocks (8x8 DCT, quantization, zigzag, DC prediction, AC RLE and fixed
Huffman tables) but removes repeated file headers and wraps fixed-size 64x64
tile slots in fixed-size radio packets.

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
PACKET_MAGIC = b"JQ"
PACKET_VERSION = 1
# magic, version, flags, frame_id, sequence, first scan-order tile, primary
# count, LF backup count, tile slot bytes, meaningful payload bytes, width,
# height, CRC32.  Every raw packet is padded to exactly packet_bytes.
PACKET_HEADER_NO_CRC = struct.Struct(">2sBBHHIBBHHHH")
PACKET_HEADER = struct.Struct(">2sBBHHIBBHHHHI")


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
    tile_slot_bytes: int
    wire_bytes: int
    packet_count: int
    dropped_packets: int
    primary_tiles_lost: int
    lf_recovered_tiles: int
    unrecovered_tiles: int
    min_quality: int
    average_quality: float
    adapted_tiles: int
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


def encode_quantized_block(
    writer: BitWriter,
    quantized: np.ndarray,
    previous_dc: int,
    table_id: int,
) -> int:
    values = [int(quantized[r, c]) for r, c in ZIGZAG]
    delta = values[0] - previous_dc
    category = magnitude_category(delta)
    if category > 11:
        raise OverflowError("DC category exceeds baseline JPEG table")
    huffman_write(writer, 0, table_id, category)
    writer.write(amplitude_bits(delta, category), category)

    run = 0
    for value in values[1:]:
        if value == 0:
            run += 1
            continue
        while run >= 16:
            huffman_write(writer, 1, table_id, 0xF0)
            run -= 16
        size = magnitude_category(value)
        if size > 10:
            raise OverflowError("AC category exceeds baseline JPEG table")
        huffman_write(writer, 1, table_id, (run << 4) | size)
        writer.write(amplitude_bits(value, size), size)
        run = 0
    if run:
        huffman_write(writer, 1, table_id, 0x00)
    return values[0]


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


def encode_tile_entropy(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    quality: int,
    stats: ArithmeticStats,
) -> tuple[bytes, int]:
    qy, qc = quant_tables(quality)
    writer = BitWriter()
    for plane, table, table_id in ((y, qy, 0), (cb, qc, 1), (cr, qc, 1)):
        previous_dc = 0
        for by in range(0, plane.shape[0], 8):
            for bx in range(0, plane.shape[1], 8):
                coefficients = forward_dct(plane[by:by + 8, bx:bx + 8], stats)
                quantized = np.empty((8, 8), dtype=np.int64)
                for r in range(8):
                    for c in range(8):
                        quantized[r, c] = round_div(int(coefficients[r, c]), int(table[r, c]))
                previous_dc = encode_quantized_block(
                    writer, quantized, previous_dc, table_id
                )
    bit_length = writer.bit_length
    return writer.finish(), bit_length


def encode_tile_slot(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    config: CodecConfig,
    stats: ArithmeticStats,
) -> tuple[bytes, int, int]:
    capacity = config.tile_bytes - TILE_HEADER.size
    if capacity <= 0:
        raise ValueError("tile slot is smaller than its header")
    for quality in range(config.quality, 0, -1):
        try:
            entropy, bit_length = encode_tile_entropy(y, cb, cr, quality, stats)
        except OverflowError:
            continue
        if len(entropy) <= capacity and bit_length <= 0xFFFF:
            header = TILE_HEADER.pack(quality, bit_length, 0)
            slot = header + entropy + bytes(capacity - len(entropy))
            return slot, quality, len(entropy)
    raise ValueError("tile cannot fit even at JPEG quality 1")


def decode_tile_slot(
    slot: bytes,
    stats: ArithmeticStats,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, int]:
    if len(slot) < TILE_HEADER.size:
        raise ValueError("truncated tile slot")
    quality, bit_length, flags = TILE_HEADER.unpack(slot[:TILE_HEADER.size])
    if flags != 0 or not 1 <= quality <= 100:
        raise ValueError("unsupported tile header")
    entropy_bytes = (bit_length + 7) // 8
    if TILE_HEADER.size + entropy_bytes > len(slot):
        raise ValueError("tile entropy length exceeds its slot")
    reader = BitReader(
        slot[TILE_HEADER.size:TILE_HEADER.size + entropy_bytes], bit_length
    )
    qy, qc = quant_tables(quality)
    planes: list[np.ndarray] = []
    for shape, table, table_id in (((64, 64), qy, 0), ((32, 32), qc, 1), ((32, 32), qc, 1)):
        plane = np.empty(shape, dtype=np.int16)
        previous_dc = 0
        for by in range(0, shape[0], 8):
            for bx in range(0, shape[1], 8):
                quantized, previous_dc = decode_quantized_block(
                    reader, previous_dc, table_id
                )
                coefficients = quantized * table
                plane[by:by + 8, bx:bx + 8] = inverse_dct(coefficients, stats)
        planes.append(plane)
    if reader.position != bit_length:
        raise ValueError("tile entropy has unused coded bits")
    return planes[0], planes[1], planes[2], quality


def tile_scan_coordinates(tile_rows: int, tile_columns: int) -> list[tuple[int, int]]:
    """2x2 group-major order; two-tile packets use a diagonal pair."""
    coordinates: list[tuple[int, int]] = []
    for group_y in range(0, tile_rows, 2):
        for group_x in range(0, tile_columns, 2):
            for dy, dx in ((0, 0), (1, 1), (0, 1), (1, 0)):
                y, x = group_y + dy, group_x + dx
                if y < tile_rows and x < tile_columns:
                    coordinates.append((y, x))
    return coordinates


def make_lf_summary(y: np.ndarray, cb: np.ndarray, cr: np.ndarray) -> bytes:
    nibbles: list[int] = []
    for plane, step in ((y, 16), (cb, 16), (cr, 16)):
        for by in range(0, plane.shape[0], step):
            for bx in range(0, plane.shape[1], step):
                block = plane[by:by + step, bx:bx + step].astype(np.int64)
                average = (int(block.sum()) + block.size // 2) // block.size
                nibbles.append(min(max(average >> 4, 0), 15))
    if len(nibbles) != 24:
        raise AssertionError("LF tile summary must contain 24 nibbles")
    return bytes((nibbles[i] << 4) | nibbles[i + 1] for i in range(0, 24, 2))


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
    primary_slots: list[bytes],
    backup_summaries: list[bytes],
    width: int,
    height: int,
) -> bytes:
    payload = b"".join(primary_slots) + b"".join(backup_summaries)
    body_capacity = config.packet_bytes - PACKET_HEADER.size
    if len(payload) > body_capacity:
        raise ValueError("packet payload exceeds fixed packet size")
    body = payload + bytes(body_capacity - len(payload))
    flags = 1 if config.lf_backup else 0
    header_no_crc = PACKET_HEADER_NO_CRC.pack(
        PACKET_MAGIC, PACKET_VERSION, flags, config.frame_id, sequence,
        first_tile, len(primary_slots), len(backup_summaries), config.tile_bytes,
        len(payload), width, height,
    )
    checksum = zlib.crc32(header_no_crc + body) & 0xFFFFFFFF
    return header_no_crc + struct.pack(">I", checksum) + body


def parse_packet(raw: bytes, expected_packet_bytes: int) -> tuple[tuple, bytes]:
    if len(raw) != expected_packet_bytes or len(raw) < PACKET_HEADER.size:
        raise ValueError("invalid fixed packet length")
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
    if payload_bytes > len(body) or any(body[payload_bytes:]):
        raise ValueError("invalid packet payload/padding")
    return fields[:-1], body[:payload_bytes]


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


def simulate(
    rgb: np.ndarray,
    config: CodecConfig,
    packet_drop_rate: float,
    packet_drop_seed: int,
    concealment: str,
    save_packets_dir: Path | None,
) -> SimulationResult:
    original_h, original_w = rgb.shape[:2]
    y, cb, cr = rgb_to_ycbcr420(rgb)
    y, cb, cr = pad_planes(y, cb, cr)
    tile_rows, tile_columns = y.shape[0] // 64, y.shape[1] // 64
    coordinates = tile_scan_coordinates(tile_rows, tile_columns)
    stats = ArithmeticStats()
    slots: list[bytes] = []
    summaries: list[bytes] = []
    qualities: list[int] = []
    entropy_lengths: list[int] = []

    for ty, tx in coordinates:
        tile_y = y[ty * 64:(ty + 1) * 64, tx * 64:(tx + 1) * 64]
        tile_cb = cb[ty * 32:(ty + 1) * 32, tx * 32:(tx + 1) * 32]
        tile_cr = cr[ty * 32:(ty + 1) * 32, tx * 32:(tx + 1) * 32]
        slot, used_quality, entropy_bytes = encode_tile_slot(
            tile_y, tile_cb, tile_cr, config, stats
        )
        slots.append(slot)
        summaries.append(make_lf_summary(tile_y, tile_cb, tile_cr))
        qualities.append(used_quality)
        entropy_lengths.append(entropy_bytes)

    per_tile_with_backup = config.tile_bytes + (LF_BYTES_PER_TILE if config.lf_backup else 0)
    tiles_per_packet = min(4, (config.packet_bytes - PACKET_HEADER.size) // per_tile_with_backup)
    if tiles_per_packet < 1:
        raise ValueError("packet cannot hold one tile slot and LF backup")
    groups = [
        list(range(first, min(first + tiles_per_packet, len(slots))))
        for first in range(0, len(slots), tiles_per_packet)
    ]
    packets: list[bytes] = []
    for sequence, group in enumerate(groups):
        next_group = groups[sequence + 1] if sequence + 1 < len(groups) else []
        backups = [summaries[index] for index in next_group] if config.lf_backup else []
        packets.append(build_packet(
            config, sequence, group[0], [slots[index] for index in group],
            backups, original_w, original_h,
        ))

    if save_packets_dir is not None:
        save_packets_dir.mkdir(parents=True, exist_ok=True)
        for index, packet in enumerate(packets):
            (save_packets_dir / f"frame{config.frame_id:04d}_packet{index:04d}.bin").write_bytes(packet)

    rng = np.random.default_rng(packet_drop_seed)
    drop_mask = rng.random(len(packets)) < packet_drop_rate
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
        primary_bytes = primary_count * config.tile_bytes
        if len(payload) != primary_bytes + backup_count * LF_BYTES_PER_TILE:
            raise ValueError("packet primary/LF length mismatch")
        for local in range(primary_count):
            start = local * config.tile_bytes
            primary[first_tile + local] = payload[start:start + config.tile_bytes]
        next_first = first_tile + primary_count
        lf_payload = payload[primary_bytes:]
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
            tile_y, tile_cb, tile_cr, _ = decode_tile_slot(primary[scan_index], decode_stats)
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
    primary_lost = len(slots) - len(primary)
    return SimulationResult(
        rgb=output,
        psnr=calculate_psnr(rgb, output),
        entropy_bytes=sum(entropy_lengths),
        tile_slot_bytes=len(slots) * config.tile_bytes,
        wire_bytes=len(packets) * config.packet_bytes,
        packet_count=len(packets),
        dropped_packets=dropped_packets,
        primary_tiles_lost=primary_lost,
        lf_recovered_tiles=recovered,
        unrecovered_tiles=unrecovered,
        min_quality=min(qualities),
        average_quality=float(np.mean(qualities)),
        adapted_tiles=sum(quality < config.quality for quality in qualities),
        saturations=stats.saturations + decode_stats.saturations,
    )


def comparison_image(original: np.ndarray, decoded: np.ndarray) -> Image.Image:
    h, w, _ = original.shape
    canvas = Image.new("RGB", (w * 2, h))
    canvas.paste(Image.fromarray(original), (0, 0))
    canvas.paste(Image.fromarray(decoded), (w, 0))
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description="Standalone JPEG-like fixed radio codec")
    parser.add_argument("input", type=Path)
    parser.add_argument("--quality", type=int, default=32)
    parser.add_argument("--tile-bytes", type=int, default=420)
    parser.add_argument("--packet-bytes", type=int, default=890)
    parser.add_argument("--packet-drop-rate", type=float, default=0.0)
    parser.add_argument("--packet-drop-seed", type=int, default=1234)
    parser.add_argument("--loss-concealment", choices=["gray", "nearest"], default="gray")
    parser.add_argument("--no-lf-backup", action="store_true")
    parser.add_argument("--frame-id", type=int, default=0)
    parser.add_argument("--save-packets", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=Path("jpeg_radio_results"))
    args = parser.parse_args()

    if not args.input.exists():
        raise SystemExit(f"input image not found: {args.input}")
    if not 1 <= args.quality <= 100:
        raise SystemExit("--quality must be in [1, 100]")
    if not TILE_HEADER.size < args.tile_bytes <= TILE_HEADER.size + 8192:
        raise SystemExit("--tile-bytes must be in [5, 8196]")
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
        args.loss_concealment, packet_dir,
    )
    suffix = (
        f"q{args.quality}_tile{args.tile_bytes}_pkt{args.packet_bytes}"
        f"_lf{int(config.lf_backup)}_drop{int(round(args.packet_drop_rate * 100)):02d}"
    )
    decoded_path = args.output_dir / f"decoded_{suffix}.png"
    comparison_path = args.output_dir / f"comparison_{suffix}.png"
    Image.fromarray(result.rgb).save(decoded_path)
    comparison_image(rgb, result.rgb).save(comparison_path)

    pixels = rgb.shape[0] * rgb.shape[1]
    print("standalone JPEG-like radio simulation")
    print(f"  frame: {rgb.shape[1]}x{rgb.shape[0]}, tiles: {math.ceil(rgb.shape[1]/64)}x{math.ceil(rgb.shape[0]/64)}")
    print(f"  base quality: {args.quality}, tile slot: {args.tile_bytes} bytes")
    print(
        f"  tile quality: min={result.min_quality}, avg={result.average_quality:.2f}, "
        f"adapted={result.adapted_tiles}"
    )
    print(
        f"  bits/pixel: entropy={result.entropy_bytes*8/pixels:.4f}, "
        f"fixed_slots={result.tile_slot_bytes*8/pixels:.4f}, "
        f"wire={result.wire_bytes*8/pixels:.4f}"
    )
    print(
        f"  packets: {result.packet_count} x {args.packet_bytes} bytes, "
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

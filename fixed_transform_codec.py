#!/usr/bin/env python3
"""
Compare fixed-rate block codecs:
  1) H.264-like 4x4 integer transform
  2) 4x4 Walsh-Hadamard transform

The codec uses:
  - YCbCr 4:2:0
  - independent 16x16 macroblocks
  - fixed payload size per macroblock
  - fixed-width signed coefficients
  - no RLE, Huffman, arithmetic coding, or prediction

Usage:
    python fixed_transform_codec.py input.jpg --bytes-per-mb 24
    python fixed_transform_codec.py input.jpg --bytes-per-mb 32 --output-dir results
    python fixed_transform_codec.py input.jpg --sweep 16,20,24,28,32,40,48

Dependencies:
    pip install numpy pillow
Optional for SSIM:
    pip install scikit-image
"""

from __future__ import annotations

import argparse
from collections import deque
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image


# H.264-like integer transform matrix. This is intentionally simple and
# multiplier-light; normalization is handled numerically in the prototype.
INT4 = np.array(
    [
        [1, 1, 1, 1],
        [2, 1, -1, -2],
        [1, -1, -1, 1],
        [1, -2, 2, -1],
    ],
    dtype=np.float64,
)

# Orthogonal Walsh-Hadamard matrix, normalized for convenient inversion.
# Rows are arranged by sequency (number of sign changes), so ORDER_4X4 really
# visits low spatial frequencies first for both transforms.  The old row order
# spent scarce bits on high Hadamard frequencies before lower ones.
HAD4 = np.array(
    [
        [1, 1, 1, 1],
        [1, 1, -1, -1],
        [1, -1, -1, 1],
        [1, -1, 1, -1],
    ],
    dtype=np.float64,
) / 2.0


def orthonormalize_transform(matrix: np.ndarray) -> np.ndarray:
    """Project a transform matrix onto an orthonormal basis for stable inversion."""
    m = matrix.astype(np.float64)
    q, _ = np.linalg.qr(m.T)
    return q.T


INT4_N = orthonormalize_transform(INT4)
HAD4_N = orthonormalize_transform(HAD4)


# Zig-zag-like low-frequency ordering for a 4x4 transform.
ORDER_4X4 = [
    (0, 0),
    (0, 1), (1, 0),
    (2, 0), (1, 1), (0, 2),
    (0, 3), (1, 2), (2, 1), (3, 0),
    (3, 1), (2, 2), (1, 3),
    (2, 3), (3, 2),
    (3, 3),
]


@dataclass
class PlaneBudget:
    bits_per_block: int
    coefficient_bits: list[int]


@dataclass
class CodecResult:
    rgb: np.ndarray
    psnr: float
    ssim: float | None
    actual_bits_per_pixel: float
    encoded_bytes: int
    dropped_macroblocks: int
    arithmetic_saturations: int = 0


class BitWriter:
    """Simple bit writer for fixed-width signed coefficients."""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self._current_byte = 0
        self._bits_in_current = 0

    def write_bits(self, value: int, bits: int) -> None:
        if bits <= 0:
            return
        if bits >= 32:
            raise ValueError("Bit width too large for this simple writer")
        value &= (1 << bits) - 1
        for shift in range(bits - 1, -1, -1):
            bit = (value >> shift) & 1
            self._current_byte = (self._current_byte << 1) | bit
            self._bits_in_current += 1
            if self._bits_in_current == 8:
                self._buffer.append(self._current_byte)
                self._current_byte = 0
                self._bits_in_current = 0

    def flush(self) -> bytes:
        if self._bits_in_current:
            self._buffer.append(self._current_byte << (8 - self._bits_in_current))
        return bytes(self._buffer)



class BitReader:
    """MSB-first reader matching BitWriter exactly."""

    def __init__(self, data: bytes) -> None:
        self._data = data
        self._bit_position = 0

    @property
    def bits_remaining(self) -> int:
        return len(self._data) * 8 - self._bit_position

    def read_bits(self, bits: int) -> int:
        if bits < 0 or bits >= 32:
            raise ValueError("invalid bit width")
        if self.bits_remaining < bits:
            raise EOFError("coefficient payload ended unexpectedly")
        value = 0
        for _ in range(bits):
            byte_index = self._bit_position >> 3
            bit_index = 7 - (self._bit_position & 7)
            value = (value << 1) | ((self._data[byte_index] >> bit_index) & 1)
            self._bit_position += 1
        return value

    def read_signed(self, bits: int) -> int:
        raw = self.read_bits(bits)
        sign_bit = 1 << (bits - 1)
        return raw - (1 << bits) if raw & sign_bit else raw

    def assert_zero_padding(self) -> None:
        if self.bits_remaining >= 8:
            raise ValueError("unexpected unread bytes in coefficient payload")
        if self.bits_remaining and self.read_bits(self.bits_remaining) != 0:
            raise ValueError("non-zero coefficient payload padding")

def rgb_to_ycbcr420(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """BT.601-like full-range RGB -> YCbCr and 2x2 chroma averaging."""
    x = rgb.astype(np.float64)
    r, g, b = x[..., 0], x[..., 1], x[..., 2]

    y = 0.299 * r + 0.587 * g + 0.114 * b
    cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0
    cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128.0

    h, w = y.shape
    h2, w2 = (h // 2) * 2, (w // 2) * 2
    y = y[:h2, :w2]
    cb = cb[:h2, :w2]
    cr = cr[:h2, :w2]

    cb420 = cb.reshape(h2 // 2, 2, w2 // 2, 2).mean(axis=(1, 3))
    cr420 = cr.reshape(h2 // 2, 2, w2 // 2, 2).mean(axis=(1, 3))
    return y, cb420, cr420


def ycbcr420_to_rgb(y: np.ndarray, cb: np.ndarray, cr: np.ndarray) -> np.ndarray:
    cb_up = np.repeat(np.repeat(cb, 2, axis=0), 2, axis=1)
    cr_up = np.repeat(np.repeat(cr, 2, axis=0), 2, axis=1)

    yy = y
    cbb = cb_up - 128.0
    crr = cr_up - 128.0

    r = yy + 1.402 * crr
    g = yy - 0.344136 * cbb - 0.714136 * crr
    b = yy + 1.772 * cbb

    return np.clip(np.stack([r, g, b], axis=-1), 0, 255).astype(np.uint8)


def pad_to_macroblocks(
    y: np.ndarray, cb: np.ndarray, cr: np.ndarray
) -> tuple[np.ndarray, np.ndarray, np.ndarray, tuple[int, int]]:
    original_shape = y.shape
    h, w = y.shape
    ph = math.ceil(h / 16) * 16
    pw = math.ceil(w / 16) * 16

    y2 = np.pad(y, ((0, ph - h), (0, pw - w)), mode="edge")
    cb2 = np.pad(cb, ((0, ph // 2 - cb.shape[0]), (0, pw // 2 - cb.shape[1])), mode="edge")
    cr2 = np.pad(cr, ((0, ph // 2 - cr.shape[0]), (0, pw // 2 - cr.shape[1])), mode="edge")
    return y2, cb2, cr2, original_shape


def allocate_bits(total_bits: int, block_count: int, importance: np.ndarray) -> list[int]:
    """
    Allocate an exact fixed bit budget over transform coefficients.

    Every selected coefficient gets at least 2 bits (sign + magnitude).
    More important low-frequency coefficients receive more bits.
    """
    if total_bits <= 0:
        return [0] * 16

    # Spend the budget across all blocks of this plane. make_budgets() chooses
    # exact per-block budgets, but keeping the division here makes this helper
    # usable on its own.
    per_block = total_bits // block_count
    per_block = max(per_block, 1)

    bits = np.zeros(16, dtype=np.int32)
    remaining = per_block
    order = np.argsort(-importance)

    def add_bits(idx: int, count: int) -> None:
        nonlocal remaining
        if remaining <= 0:
            return
        take = min(count, remaining)
        # A newly opened signed AC coefficient needs zero and both signs. One
        # bit cannot represent that and is better spent on an active term.
        if idx != order[0] and bits[idx] == 0 and take < 2:
            return
        bits[idx] += take
        remaining -= take

    # Range first, then detail. The previous bootstrap gave luma DC only two
    # bits at 24 B/MB, although centered 4x4 DC spans about -512..+508.
    add_bits(order[0], 4)
    add_bits(order[1], 2)
    add_bits(order[2], 2)

    # Refine the low-frequency core before opening more coefficients.
    add_bits(order[0], 1)
    add_bits(order[1], 1)
    add_bits(order[2], 1)
    for idx in order[3:6]:
        add_bits(idx, 2)

    add_bits(order[0], 1)
    for idx in order[1:6]:
        add_bits(idx, 1)

    # Only then open the remaining coefficients in useful two-bit chunks.
    for idx in order[6:]:
        add_bits(idx, 2)

    # Spend leftover single bits as extra precision on the most important
    # already-active coefficients.
    while remaining > 0:
        changed = False
        for idx in order:
            max_bits = 9 if idx == 0 else 7
            if bits[idx] > 0 and bits[idx] < max_bits:
                bits[idx] += 1
                remaining -= 1
                changed = True
                if remaining == 0:
                    break
        if not changed:
            break

    return bits.tolist()


def make_budgets(bytes_per_mb: int, luma_share: float) -> tuple[PlaneBudget, PlaneBudget]:
    """
    One 16x16 YUV420 macroblock contains:
      16 luma 4x4 blocks
       4 Cb   4x4 blocks
       4 Cr   4x4 blocks

    The budget is divided between luma and chroma by luma_share.
    """
    if not 0.1 <= luma_share <= 0.9:
        raise ValueError("luma_share must be in [0.1, 0.9]")

    if bytes_per_mb < 3:
        raise ValueError("bytes_per_mb must be at least 3")

    # Let a be bits per Y block and b be bits per Cb/Cr block. A YUV420
    # macroblock has 16 Y and 8 chroma blocks, therefore
    #
    #   16*a + 8*b = 8*bytes_per_mb  ->  2*a + b = bytes_per_mb.
    #
    # Choosing integer a first and deriving b spends the complete byte budget.
    # The previous code silently left one byte unused at 24 B/MB and two bytes
    # unused at 64 B/MB.
    y_bits_per_block = int(round(bytes_per_mb * luma_share / 2.0))
    y_bits_per_block = min(max(y_bits_per_block, 1), (bytes_per_mb - 1) // 2)
    c_bits_per_block = bytes_per_mb - 2 * y_bits_per_block

    importance = np.array(
        [16, 12, 12, 9, 8, 8, 6, 6, 5, 5, 4, 4, 3, 3, 2, 1],
        dtype=np.float64,
    )

    y_coeff_bits = allocate_bits(y_bits_per_block * 16, 16, importance)
    c_coeff_bits = allocate_bits(c_bits_per_block * 4, 4, importance)

    return (
        PlaneBudget(bits_per_block=sum(y_coeff_bits), coefficient_bits=y_coeff_bits),
        PlaneBudget(bits_per_block=sum(c_coeff_bits), coefficient_bits=c_coeff_bits),
    )


def quantize_fixed_width(value: float, bits: int, scale: float) -> float:
    return quantize_fixed_width_code(value, bits, scale) * scale


def quantize_fixed_width_code(value: float, bits: int, scale: float) -> int:
    if bits <= 0:
        return 0

    # Symmetric signed range avoids a bias at the common two-bit AC setting.
    if bits == 1:
        return 0
    qmax = (1 << (bits - 1)) - 1
    qmin = -qmax

    q = int(np.rint(value / scale))
    q = min(max(q, qmin), qmax)
    return q


def process_block(
    block: np.ndarray,
    transform: np.ndarray,
    coefficient_bits: list[int],
    quality_scale: float,
) -> tuple[np.ndarray, list[int]]:
    """
    Center samples, transform, keep a fixed set of coefficients with fixed
    widths, then invert the transform.
    """
    centered = block.astype(np.float64) - 128.0
    coeff = transform @ centered @ transform.T
    out_coeff = np.zeros((4, 4), dtype=np.float64)
    codes = [0] * 16

    for rank, (r, c) in enumerate(ORDER_4X4):
        bits = coefficient_bits[rank]
        if bits == 0:
            continue

        # Higher frequencies get coarser quantization.
        frequency_weight = 1.0 + 0.55 * (r + c)

        # Extra bits must improve precision, not merely widen an already large
        # range. Four DC bits and two AC bits define the reference range; every
        # additional bit halves the quantization step.
        reference_bits = 4 if rank == 0 else 2
        precision_gain = 2.0 ** max(0, bits - reference_bits)
        scale = quality_scale * frequency_weight / precision_gain
        code = quantize_fixed_width_code(coeff[r, c], bits, scale)
        codes[rank] = code
        out_coeff[r, c] = code * scale

    reconstructed = transform.T @ out_coeff @ transform + 128.0
    return np.clip(reconstructed, 0, 255), codes


def process_plane(
    plane: np.ndarray,
    transform: np.ndarray,
    coefficient_bits: list[int],
    quality_scale: float,
) -> tuple[np.ndarray, bytes]:
    h, w = plane.shape
    out = np.empty_like(plane, dtype=np.float64)
    writer = BitWriter()

    for y in range(0, h, 4):
        for x in range(0, w, 4):
            block_out, codes = process_block(
                plane[y:y + 4, x:x + 4],
                transform,
                coefficient_bits,
                quality_scale,
            )
            out[y:y + 4, x:x + 4] = block_out
            for rank, code in enumerate(codes):
                bits = coefficient_bits[rank]
                if bits <= 0:
                    continue
                if code < 0:
                    code &= (1 << bits) - 1
                writer.write_bits(code, bits)

    return out, writer.flush()



HAD2_N = np.array([[1, 1], [1, -1]], dtype=np.float64) / math.sqrt(2.0)
ORDER_2X2 = [(0, 0), (0, 1), (1, 0), (1, 1)]
COEFFICIENT_IMPORTANCE = np.array(
    [16, 12, 12, 9, 8, 8, 6, 6, 5, 5, 4, 4, 3, 3, 2, 1],
    dtype=np.float64,
)


def hierarchical_dc_scale(
    rank: int,
    bits: int,
    macroblock_size: int,
    quality_scale: float,
) -> float:
    """Quantizer step for the second-stage transform of the 4x4-block DCs."""
    qmax = max((1 << (bits - 1)) - 1, 1)

    if macroblock_size == 16:
        # Approximate useful (not absolute theoretical) coefficient ranges for
        # a 4x4 Hadamard over sixteen luma DC values.  This intentionally allows
        # rare clipping in exchange for much better precision on normal FPV
        # imagery. quality_scale=64 is the calibrated reference point.
        ranges = [
            1664, 512, 768, 384, 384, 448, 320, 288,
            288, 384, 224, 192, 192, 176, 160, 144,
        ]
        reference_quality = 64.0
    elif macroblock_size == 8:
        # 2x2 Hadamard over the four chroma-block DC values.
        ranges = [640, 144, 144, 96]
        reference_quality = 38.4
    else:
        raise ValueError("hierarchical DC expects a 16x16 or 8x8 macroblock")

    return ranges[rank] * (quality_scale / reference_quality) / qmax


def process_plane_hierarchical(
    plane: np.ndarray,
    transform: np.ndarray,
    budget: PlaneBudget,
    quality_scale: float,
    macroblock_size: int,
) -> tuple[np.ndarray, bytes]:
    """
    Encode one plane with a separate transform of all block DC coefficients.

    Each 4x4 block is intra-predicted by its decoded flat DC level.  Its AC
    coefficients therefore describe only detail around that level.  The 16
    luma DC values in a 16x16 macroblock are coded by a 4x4 Hadamard; the four
    chroma DC values in an 8x8 macroblock use a 2x2 Hadamard.  Everything resets
    at the macroblock boundary, retaining packet independence.
    """
    h, w = plane.shape
    if h % macroblock_size or w % macroblock_size:
        raise ValueError("plane dimensions must be aligned to macroblocks")

    blocks_per_side = macroblock_size // 4
    block_count = blocks_per_side ** 2
    dc_order = ORDER_4X4 if block_count == 16 else ORDER_2X2
    dc_transform = HAD4_N if block_count == 16 else HAD2_N

    # Keep exactly the same total DC/AC split as the legacy per-block mode, but
    # decorrelate all DC values jointly before quantization.
    dc_total_bits = budget.coefficient_bits[0] * block_count
    dc_bits = allocate_bits(
        dc_total_bits,
        1,
        COEFFICIENT_IMPORTANCE[:block_count],
    )
    ac_bits = budget.coefficient_bits.copy()
    ac_bits[0] = 0

    if sum(dc_bits) + block_count * sum(ac_bits) != block_count * budget.bits_per_block:
        raise AssertionError("hierarchical DC budget does not match plane budget")

    out = np.empty_like(plane, dtype=np.float64)
    writer = BitWriter()

    def write_signed(code: int, bits: int) -> None:
        if code < 0:
            code &= (1 << bits) - 1
        writer.write_bits(code, bits)

    for my in range(0, h, macroblock_size):
        for mx in range(0, w, macroblock_size):
            dc_grid = np.zeros((blocks_per_side, blocks_per_side), dtype=np.float64)
            reconstructed_coefficients: list[list[np.ndarray]] = [
                [np.zeros((4, 4), dtype=np.float64) for _ in range(blocks_per_side)]
                for _ in range(blocks_per_side)
            ]
            ac_codes: list[list[list[int]]] = [
                [[0] * 16 for _ in range(blocks_per_side)]
                for _ in range(blocks_per_side)
            ]

            # Forward 4x4 transforms.  DC is held aside; AC is the residual
            # around a flat intra predictor equal to the decoded block mean.
            for by in range(blocks_per_side):
                for bx in range(blocks_per_side):
                    y0 = my + by * 4
                    x0 = mx + bx * 4
                    centered = plane[y0:y0 + 4, x0:x0 + 4].astype(np.float64) - 128.0
                    coefficients = transform @ centered @ transform.T
                    dc_grid[by, bx] = coefficients[0, 0]
                    out_coeff = reconstructed_coefficients[by][bx]

                    for rank, (r, c) in enumerate(ORDER_4X4[1:], start=1):
                        bits = ac_bits[rank]
                        if bits <= 0:
                            continue
                        frequency_weight = 1.0 + 0.55 * (r + c)
                        precision_gain = 2.0 ** max(0, bits - 2)
                        scale = quality_scale * frequency_weight / precision_gain
                        code = quantize_fixed_width_code(coefficients[r, c], bits, scale)
                        ac_codes[by][bx][rank] = code
                        out_coeff[r, c] = code * scale

            transformed_dc = dc_transform @ dc_grid @ dc_transform.T
            reconstructed_dc_transform = np.zeros_like(transformed_dc)
            dc_codes = [0] * block_count
            for rank, (r, c) in enumerate(dc_order):
                bits = dc_bits[rank]
                if bits <= 0:
                    continue
                scale = hierarchical_dc_scale(
                    rank, bits, macroblock_size, quality_scale
                )
                code = quantize_fixed_width_code(transformed_dc[r, c], bits, scale)
                dc_codes[rank] = code
                reconstructed_dc_transform[r, c] = code * scale

            reconstructed_dc = (
                dc_transform.T @ reconstructed_dc_transform @ dc_transform
            )

            # Packet layout is deterministic: hierarchical DC first, then AC
            # for the 4x4 blocks in raster order.
            for rank, code in enumerate(dc_codes):
                bits = dc_bits[rank]
                if bits > 0:
                    write_signed(code, bits)

            for by in range(blocks_per_side):
                for bx in range(blocks_per_side):
                    out_coeff = reconstructed_coefficients[by][bx]
                    out_coeff[0, 0] = reconstructed_dc[by, bx]
                    reconstructed = transform.T @ out_coeff @ transform + 128.0
                    y0 = my + by * 4
                    x0 = mx + bx * 4
                    out[y0:y0 + 4, x0:x0 + 4] = np.clip(reconstructed, 0, 255)

                    for rank, code in enumerate(ac_codes[by][bx]):
                        bits = ac_bits[rank]
                        if bits > 0:
                            write_signed(code, bits)

    return out, writer.flush()


# Bit-accurate arithmetic model used by the FPGA-oriented path.  The color
# conversion remains an external wrapper; samples entering these functions are
# already rounded to unsigned 8-bit integers.
INT4_I = np.array(
    [[1, 1, 1, 1], [2, 1, -1, -2], [1, -1, -1, 1], [1, -2, 2, -1]],
    dtype=np.int64,
)
INT4_INV_NUMERATOR = np.array(
    [[5, 4, 5, 2], [5, 2, -5, -4], [5, -2, -5, 4], [5, -4, 5, -2]],
    dtype=np.int64,
)
HAD4_I = np.array(
    [[1, 1, 1, 1], [1, 1, -1, -1], [1, -1, -1, 1], [1, -1, 1, -1]],
    dtype=np.int64,
)
HAD2_I = np.array([[1, 1], [1, -1]], dtype=np.int64)

# Base AC quantizer steps at quality_scale=64.  Transform normalization has
# already been absorbed into these integer constants.  Additional coefficient
# bits divide the step by powers of two with round-half-away-from-zero.
INT4_AC_STEP_Q64 = [
    256, 627, 627, 538, 1344, 538, 1073, 1073,
    1073, 1073, 2048, 819, 2048, 1518, 1518, 2752,
]
HAD4_AC_STEP_Q64 = [
    256, 397, 397, 538, 538, 538, 678, 678,
    678, 678, 819, 819, 819, 960, 960, 1101,
]

# Useful hierarchical-DC ranges in the unnormalised integer domain.  These are
# the former calibrated ranges multiplied by the exact transform scale: x16
# for the 4x4 luma DC Hadamard and x8 for the 2x2 chroma DC Hadamard.
LUMA_HDC_RANGES = [
    26624, 8192, 12288, 6144, 6144, 7168, 5120, 4608,
    4608, 6144, 3584, 3072, 3072, 2816, 2560, 2304,
]
CHROMA_HDC_RANGES = [5120, 1152, 1152, 768]
QUALITY_REFERENCE_Q8 = 64 * 256
CHROMA_QUALITY_REFERENCE_Q8 = 9830  # round(64 * 0.6 * 256)


@dataclass
class FixedArithmeticStats:
    saturation_count: int = 0

    def saturate(self, values: np.ndarray, bits: int) -> np.ndarray:
        low = -(1 << (bits - 1))
        high = (1 << (bits - 1)) - 1
        array = np.asarray(values, dtype=np.int64)
        self.saturation_count += int(np.count_nonzero((array < low) | (array > high)))
        return np.clip(array, low, high).astype(np.int64)


def round_div_signed(value: int, divisor: int) -> int:
    """Integer round-to-nearest, with exact halves rounded away from zero."""
    if divisor <= 0:
        raise ValueError("divisor must be positive")
    magnitude = (abs(int(value)) + divisor // 2) // divisor
    return magnitude if value >= 0 else -magnitude


def round_div_signed_array(values: np.ndarray, divisor: int) -> np.ndarray:
    array = np.asarray(values, dtype=np.int64)
    magnitude = (np.abs(array) + divisor // 2) // divisor
    return np.where(array < 0, -magnitude, magnitude).astype(np.int64)


def quantize_fixed_int(value: int, bits: int, step: int) -> int:
    if bits <= 1:
        return 0
    qmax = (1 << (bits - 1)) - 1
    code = round_div_signed(value, max(step, 1))
    return min(max(code, -qmax), qmax)


def transform_kind(transform: np.ndarray) -> str:
    if transform is INT4_N or np.array_equal(transform, INT4_N):
        return "integer"
    if transform is HAD4_N or np.array_equal(transform, HAD4_N):
        return "hadamard"
    raise ValueError("fixed arithmetic supports only INT4_N and HAD4_N")


def fixed_ac_step(kind: str, rank: int, bits: int, quality_q8: int) -> int:
    table = INT4_AC_STEP_Q64 if kind == "integer" else HAD4_AC_STEP_Q64
    reference_bits = 4 if rank == 0 else 2
    precision_shift = max(0, bits - reference_bits)
    denominator = QUALITY_REFERENCE_Q8 << precision_shift
    return max(1, (table[rank] * quality_q8 + denominator // 2) // denominator)


def fixed_hierarchical_dc_step(
    rank: int,
    bits: int,
    macroblock_size: int,
    quality_q8: int,
) -> int:
    qmax = max((1 << (bits - 1)) - 1, 1)
    if macroblock_size == 16:
        useful_range = LUMA_HDC_RANGES[rank]
        reference_q8 = QUALITY_REFERENCE_Q8
    elif macroblock_size == 8:
        useful_range = CHROMA_HDC_RANGES[rank]
        reference_q8 = CHROMA_QUALITY_REFERENCE_Q8
    else:
        raise ValueError("fixed hierarchical DC expects 16x16 or 8x8")
    denominator = reference_q8 * qmax
    return max(1, (useful_range * quality_q8 + denominator // 2) // denominator)


def fixed_forward_4x4(
    centered: np.ndarray,
    kind: str,
    stats: FixedArithmeticStats,
) -> np.ndarray:
    matrix = INT4_I if kind == "integer" else HAD4_I
    first_stage_bits = 11 if kind == "integer" else 10
    coefficient_bits = 14 if kind == "integer" else 12
    first = stats.saturate(matrix @ centered.astype(np.int64), first_stage_bits)
    return stats.saturate(first @ matrix.T, coefficient_bits)


def fixed_inverse_4x4(
    coefficients: np.ndarray,
    kind: str,
    stats: FixedArithmeticStats,
) -> np.ndarray:
    coefficients = stats.saturate(coefficients, 16)
    if kind == "integer":
        # Exact inverse of INT4_I is INT4_INV_NUMERATOR / 20.  The separable
        # 2D inverse therefore uses one signed division by 400 after both axes.
        first = stats.saturate(INT4_INV_NUMERATOR @ coefficients, 24)
        numerator = stats.saturate(first @ INT4_INV_NUMERATOR.T, 26)
        return round_div_signed_array(numerator, 400)

    first = stats.saturate(HAD4_I.T @ coefficients, 19)
    numerator = stats.saturate(first @ HAD4_I, 22)
    return round_div_signed_array(numerator, 16)


def fixed_hadamard_forward(
    values: np.ndarray,
    size: int,
    stats: FixedArithmeticStats,
) -> np.ndarray:
    matrix = HAD4_I if size == 4 else HAD2_I
    first = stats.saturate(matrix @ values.astype(np.int64), 24)
    return stats.saturate(first @ matrix.T, 24)


def fixed_hadamard_inverse(
    values: np.ndarray,
    size: int,
    stats: FixedArithmeticStats,
) -> np.ndarray:
    matrix = HAD4_I if size == 4 else HAD2_I
    first = stats.saturate(matrix.T @ values.astype(np.int64), 24)
    numerator = stats.saturate(first @ matrix, 24)
    return round_div_signed_array(numerator, size * size)


def process_plane_fixed_block(
    plane: np.ndarray,
    kind: str,
    coefficient_bits: list[int],
    quality_q8: int,
    stats: FixedArithmeticStats,
) -> tuple[np.ndarray, bytes]:
    h, w = plane.shape
    out = np.empty((h, w), dtype=np.int16)
    writer = BitWriter()

    for y in range(0, h, 4):
        for x in range(0, w, 4):
            centered = plane[y:y + 4, x:x + 4].astype(np.int64) - 128
            coefficients = fixed_forward_4x4(centered, kind, stats)
            reconstructed_coefficients = np.zeros((4, 4), dtype=np.int64)

            for rank, (r, c) in enumerate(ORDER_4X4):
                bits = coefficient_bits[rank]
                if bits <= 0:
                    continue
                step = fixed_ac_step(kind, rank, bits, quality_q8)
                code = quantize_fixed_int(int(coefficients[r, c]), bits, step)
                reconstructed_coefficients[r, c] = code * step
                if code < 0:
                    code &= (1 << bits) - 1
                writer.write_bits(code, bits)

            reconstructed = fixed_inverse_4x4(
                reconstructed_coefficients, kind, stats
            ) + 128
            out[y:y + 4, x:x + 4] = np.clip(reconstructed, 0, 255).astype(np.int16)

    return out, writer.flush()


def process_plane_fixed_hierarchical(
    plane: np.ndarray,
    kind: str,
    budget: PlaneBudget,
    quality_q8: int,
    macroblock_size: int,
    stats: FixedArithmeticStats,
) -> tuple[np.ndarray, bytes]:
    h, w = plane.shape
    blocks_per_side = macroblock_size // 4
    block_count = blocks_per_side ** 2
    dc_order = ORDER_4X4 if block_count == 16 else ORDER_2X2
    dc_total_bits = budget.coefficient_bits[0] * block_count
    dc_bits = allocate_bits(dc_total_bits, 1, COEFFICIENT_IMPORTANCE[:block_count])
    ac_bits = budget.coefficient_bits.copy()
    ac_bits[0] = 0

    if sum(dc_bits) + block_count * sum(ac_bits) != block_count * budget.bits_per_block:
        raise AssertionError("fixed hierarchical DC budget mismatch")

    out = np.empty((h, w), dtype=np.int16)
    writer = BitWriter()

    def write_signed(code: int, bits: int) -> None:
        if code < 0:
            code &= (1 << bits) - 1
        writer.write_bits(code, bits)

    for my in range(0, h, macroblock_size):
        for mx in range(0, w, macroblock_size):
            dc_grid = np.zeros((blocks_per_side, blocks_per_side), dtype=np.int64)
            reconstructed_coefficients = [
                [np.zeros((4, 4), dtype=np.int64) for _ in range(blocks_per_side)]
                for _ in range(blocks_per_side)
            ]
            ac_codes = [
                [[0] * 16 for _ in range(blocks_per_side)]
                for _ in range(blocks_per_side)
            ]

            for by in range(blocks_per_side):
                for bx in range(blocks_per_side):
                    y0 = my + by * 4
                    x0 = mx + bx * 4
                    centered = plane[y0:y0 + 4, x0:x0 + 4].astype(np.int64) - 128
                    coefficients = fixed_forward_4x4(centered, kind, stats)
                    dc_grid[by, bx] = coefficients[0, 0]
                    out_coeff = reconstructed_coefficients[by][bx]

                    for rank, (r, c) in enumerate(ORDER_4X4[1:], start=1):
                        bits = ac_bits[rank]
                        if bits <= 0:
                            continue
                        step = fixed_ac_step(kind, rank, bits, quality_q8)
                        code = quantize_fixed_int(int(coefficients[r, c]), bits, step)
                        ac_codes[by][bx][rank] = code
                        out_coeff[r, c] = code * step

            transformed_dc = fixed_hadamard_forward(
                dc_grid, blocks_per_side, stats
            )
            reconstructed_dc_transform = np.zeros_like(transformed_dc)
            dc_codes = [0] * block_count
            for rank, (r, c) in enumerate(dc_order):
                bits = dc_bits[rank]
                if bits <= 0:
                    continue
                step = fixed_hierarchical_dc_step(
                    rank, bits, macroblock_size, quality_q8
                )
                code = quantize_fixed_int(int(transformed_dc[r, c]), bits, step)
                dc_codes[rank] = code
                reconstructed_dc_transform[r, c] = code * step

            reconstructed_dc = fixed_hadamard_inverse(
                reconstructed_dc_transform, blocks_per_side, stats
            )

            for rank, code in enumerate(dc_codes):
                bits = dc_bits[rank]
                if bits > 0:
                    write_signed(code, bits)

            for by in range(blocks_per_side):
                for bx in range(blocks_per_side):
                    out_coeff = reconstructed_coefficients[by][bx]
                    out_coeff[0, 0] = reconstructed_dc[by, bx]
                    reconstructed = fixed_inverse_4x4(out_coeff, kind, stats) + 128
                    y0 = my + by * 4
                    x0 = mx + bx * 4
                    out[y0:y0 + 4, x0:x0 + 4] = np.clip(
                        reconstructed, 0, 255
                    ).astype(np.int16)

                    for rank, code in enumerate(ac_codes[by][bx]):
                        bits = ac_bits[rank]
                        if bits > 0:
                            write_signed(code, bits)

    return out, writer.flush()


def decode_plane_fixed_block(
    payload: bytes,
    shape: tuple[int, int],
    kind: str,
    coefficient_bits: list[int],
    quality_q8: int,
    stats: FixedArithmeticStats,
) -> np.ndarray:
    """Decode a legacy block-DC plane exclusively from its packed bytes."""
    h, w = shape
    out = np.empty((h, w), dtype=np.int16)
    reader = BitReader(payload)

    for y in range(0, h, 4):
        for x in range(0, w, 4):
            coefficients = np.zeros((4, 4), dtype=np.int64)
            for rank, (r, c) in enumerate(ORDER_4X4):
                bits = coefficient_bits[rank]
                if bits <= 0:
                    continue
                code = reader.read_signed(bits)
                step = fixed_ac_step(kind, rank, bits, quality_q8)
                coefficients[r, c] = code * step

            reconstructed = fixed_inverse_4x4(coefficients, kind, stats) + 128
            out[y:y + 4, x:x + 4] = np.clip(reconstructed, 0, 255).astype(np.int16)

    reader.assert_zero_padding()
    return out


def decode_plane_fixed_hierarchical(
    payload: bytes,
    shape: tuple[int, int],
    kind: str,
    budget: PlaneBudget,
    quality_q8: int,
    macroblock_size: int,
    stats: FixedArithmeticStats,
) -> np.ndarray:
    """Decode hierarchical DC/AC coefficients exclusively from packed bytes."""
    h, w = shape
    blocks_per_side = macroblock_size // 4
    block_count = blocks_per_side ** 2
    dc_order = ORDER_4X4 if block_count == 16 else ORDER_2X2
    dc_total_bits = budget.coefficient_bits[0] * block_count
    dc_bits = allocate_bits(dc_total_bits, 1, COEFFICIENT_IMPORTANCE[:block_count])
    ac_bits = budget.coefficient_bits.copy()
    ac_bits[0] = 0
    reader = BitReader(payload)
    out = np.empty((h, w), dtype=np.int16)

    for my in range(0, h, macroblock_size):
        for mx in range(0, w, macroblock_size):
            reconstructed_dc_transform = np.zeros(
                (blocks_per_side, blocks_per_side), dtype=np.int64
            )
            for rank, (r, c) in enumerate(dc_order):
                bits = dc_bits[rank]
                if bits <= 0:
                    continue
                code = reader.read_signed(bits)
                step = fixed_hierarchical_dc_step(
                    rank, bits, macroblock_size, quality_q8
                )
                reconstructed_dc_transform[r, c] = code * step

            reconstructed_dc = fixed_hadamard_inverse(
                reconstructed_dc_transform, blocks_per_side, stats
            )

            for by in range(blocks_per_side):
                for bx in range(blocks_per_side):
                    coefficients = np.zeros((4, 4), dtype=np.int64)
                    coefficients[0, 0] = reconstructed_dc[by, bx]
                    for rank, (r, c) in enumerate(ORDER_4X4[1:], start=1):
                        bits = ac_bits[rank]
                        if bits <= 0:
                            continue
                        code = reader.read_signed(bits)
                        step = fixed_ac_step(kind, rank, bits, quality_q8)
                        coefficients[r, c] = code * step

                    reconstructed = fixed_inverse_4x4(
                        coefficients, kind, stats
                    ) + 128
                    y0 = my + by * 4
                    x0 = mx + bx * 4
                    out[y0:y0 + 4, x0:x0 + 4] = np.clip(
                        reconstructed, 0, 255
                    ).astype(np.int16)

    reader.assert_zero_padding()
    return out

def make_packet_drop_mask(
    padded_shape: tuple[int, int],
    drop_rate: float,
    rng: np.random.Generator,
) -> np.ndarray:
    if not 0.0 <= drop_rate <= 1.0:
        raise ValueError("Packet drop rate must be between 0.0 and 1.0.")

    mb_h = padded_shape[0] // 16
    mb_w = padded_shape[1] // 16
    return rng.random((mb_h, mb_w)) < drop_rate


def apply_packet_drop(
    y: np.ndarray,
    cb: np.ndarray,
    cr: np.ndarray,
    drop_mask: np.ndarray | None,
    concealment: str,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, int]:
    if drop_mask is None:
        return y, cb, cr, 0

    dropped = int(drop_mask.sum())
    if dropped == 0:
        return y, cb, cr, 0

    if concealment not in {"gray", "nearest"}:
        raise ValueError("concealment must be 'gray' or 'nearest'")

    out_y = y.copy()
    out_cb = cb.copy()
    out_cr = cr.copy()

    mb_h, mb_w = drop_mask.shape
    if concealment == "gray":
        for my in range(mb_h):
            for mx in range(mb_w):
                if not drop_mask[my, mx]:
                    continue
                out_y[my * 16:(my + 1) * 16, mx * 16:(mx + 1) * 16] = 128.0
                out_cb[my * 8:(my + 1) * 8, mx * 8:(mx + 1) * 8] = 128.0
                out_cr[my * 8:(my + 1) * 8, mx * 8:(mx + 1) * 8] = 128.0
        return out_y, out_cb, out_cr, dropped

    # Spatial concealment: copy from the nearest received macroblock.
    source_y = -np.ones((mb_h, mb_w), dtype=np.int32)
    source_x = -np.ones((mb_h, mb_w), dtype=np.int32)
    queue: deque[tuple[int, int]] = deque()

    for my in range(mb_h):
        for mx in range(mb_w):
            if not drop_mask[my, mx]:
                source_y[my, mx] = my
                source_x[my, mx] = mx
                queue.append((my, mx))

    # If everything is dropped, fall back to gray.
    if not queue:
        out_y[:, :] = 128.0
        out_cb[:, :] = 128.0
        out_cr[:, :] = 128.0
        return out_y, out_cb, out_cr, dropped

    while queue:
        my, mx = queue.popleft()
        sy = source_y[my, mx]
        sx = source_x[my, mx]
        for ny, nx in ((my - 1, mx), (my + 1, mx), (my, mx - 1), (my, mx + 1)):
            if ny < 0 or ny >= mb_h or nx < 0 or nx >= mb_w:
                continue
            if source_y[ny, nx] != -1:
                continue
            source_y[ny, nx] = sy
            source_x[ny, nx] = sx
            queue.append((ny, nx))

    for my in range(mb_h):
        for mx in range(mb_w):
            if not drop_mask[my, mx]:
                continue

            sy = source_y[my, mx]
            sx = source_x[my, mx]

            out_y[my * 16:(my + 1) * 16, mx * 16:(mx + 1) * 16] = y[
                sy * 16:(sy + 1) * 16,
                sx * 16:(sx + 1) * 16,
            ]
            out_cb[my * 8:(my + 1) * 8, mx * 8:(mx + 1) * 8] = cb[
                sy * 8:(sy + 1) * 8,
                sx * 8:(sx + 1) * 8,
            ]
            out_cr[my * 8:(my + 1) * 8, mx * 8:(mx + 1) * 8] = cr[
                sy * 8:(sy + 1) * 8,
                sx * 8:(sx + 1) * 8,
            ]

    return out_y, out_cb, out_cr, dropped


def calculate_psnr(reference: np.ndarray, test: np.ndarray) -> float:
    mse = np.mean((reference.astype(np.float64) - test.astype(np.float64)) ** 2)
    if mse == 0:
        return float("inf")
    return 10.0 * math.log10((255.0 ** 2) / mse)


def calculate_ssim(reference: np.ndarray, test: np.ndarray) -> float | None:
    try:
        from skimage.metrics import structural_similarity
    except ImportError:
        return None

    return float(
        structural_similarity(
            reference,
            test,
            channel_axis=2,
            data_range=255,
        )
    )


def encode_decode(
    rgb: np.ndarray,
    transform: np.ndarray,
    bytes_per_mb: int,
    quality_scale: float,
    luma_share: float,
    chroma_quality_factor: float,
    drop_mask: np.ndarray | None = None,
    loss_concealment: str = "gray",
    dc_mode: str = "hadamard",
    arithmetic: str = "fixed",
) -> CodecResult:
    y, cb, cr = rgb_to_ycbcr420(rgb)
    y, cb, cr, original_shape = pad_to_macroblocks(y, cb, cr)
    y_budget, c_budget = make_budgets(bytes_per_mb, luma_share)

    fixed_stats = FixedArithmeticStats()
    if arithmetic == "fixed":
        # Float is allowed only in the color wrapper.  The codec itself receives
        # discrete 8-bit samples and integer Q8 configuration constants.
        y = np.clip(np.rint(y), 0, 255).astype(np.int16)
        cb = np.clip(np.rint(cb), 0, 255).astype(np.int16)
        cr = np.clip(np.rint(cr), 0, 255).astype(np.int16)
        kind = transform_kind(transform)
        quality_q8 = int(round(quality_scale * 256.0))
        chroma_quality_q8 = int(round(quality_scale * chroma_quality_factor * 256.0))

        if dc_mode == "hadamard":
            ry, y_bytes = process_plane_fixed_hierarchical(
                y, kind, y_budget, quality_q8, 16, fixed_stats
            )
            rcb, cb_bytes = process_plane_fixed_hierarchical(
                cb, kind, c_budget, chroma_quality_q8, 8, fixed_stats
            )
            rcr, cr_bytes = process_plane_fixed_hierarchical(
                cr, kind, c_budget, chroma_quality_q8, 8, fixed_stats
            )
        elif dc_mode == "block":
            ry, y_bytes = process_plane_fixed_block(
                y, kind, y_budget.coefficient_bits, quality_q8, fixed_stats
            )
            rcb, cb_bytes = process_plane_fixed_block(
                cb, kind, c_budget.coefficient_bits, chroma_quality_q8, fixed_stats
            )
            rcr, cr_bytes = process_plane_fixed_block(
                cr, kind, c_budget.coefficient_bits, chroma_quality_q8, fixed_stats
            )
        else:
            raise ValueError("dc_mode must be 'hadamard' or 'block'")
    elif arithmetic == "float":
        if dc_mode == "hadamard":
            ry, y_bytes = process_plane_hierarchical(
                y, transform, y_budget, quality_scale, 16
            )
            rcb, cb_bytes = process_plane_hierarchical(
                cb, transform, c_budget, quality_scale * chroma_quality_factor, 8
            )
            rcr, cr_bytes = process_plane_hierarchical(
                cr, transform, c_budget, quality_scale * chroma_quality_factor, 8
            )
        elif dc_mode == "block":
            ry, y_bytes = process_plane(y, transform, y_budget.coefficient_bits, quality_scale)
            rcb, cb_bytes = process_plane(
                cb, transform, c_budget.coefficient_bits, quality_scale * chroma_quality_factor
            )
            rcr, cr_bytes = process_plane(
                cr, transform, c_budget.coefficient_bits, quality_scale * chroma_quality_factor
            )
        else:
            raise ValueError("dc_mode must be 'hadamard' or 'block'")
    else:
        raise ValueError("arithmetic must be 'fixed' or 'float'")
    ry, rcb, rcr, dropped_macroblocks = apply_packet_drop(
        ry, rcb, rcr, drop_mask, loss_concealment
    )

    h, w = original_shape
    reconstructed = ycbcr420_to_rgb(ry[:h, :w], rcb[:h // 2, :w // 2], rcr[:h // 2, :w // 2])

    # A macroblock grid covers padded dimensions.
    mb_count = (y.shape[0] // 16) * (y.shape[1] // 16)
    actual_bpp = (mb_count * bytes_per_mb * 8) / (h * w)

    encoded_bytes = len(y_bytes) + len(cb_bytes) + len(cr_bytes)
    return CodecResult(
        rgb=reconstructed,
        psnr=calculate_psnr(rgb[:h, :w], reconstructed),
        ssim=calculate_ssim(rgb[:h, :w], reconstructed),
        actual_bits_per_pixel=actual_bpp,
        encoded_bytes=encoded_bytes,
        dropped_macroblocks=dropped_macroblocks,
        arithmetic_saturations=fixed_stats.saturation_count,
    )


def make_comparison(
    original: np.ndarray,
    integer_result: CodecResult,
    hadamard_result: CodecResult,
) -> Image.Image:
    h, w, _ = original.shape
    canvas = Image.new("RGB", (w * 3, h))
    canvas.paste(Image.fromarray(original), (0, 0))
    canvas.paste(Image.fromarray(integer_result.rgb), (w, 0))
    canvas.paste(Image.fromarray(hadamard_result.rgb), (w * 2, 0))
    return canvas


def parse_sweep(text: str | None, single: int) -> list[int]:
    if not text:
        return [single]
    values = sorted({int(x.strip()) for x in text.split(",") if x.strip()})
    if any(x <= 0 for x in values):
        raise ValueError("All sweep values must be positive.")
    return values


def make_output_suffix(bytes_per_mb: int, packet_drop_rate: float) -> str:
    suffix = f"{bytes_per_mb:02d}B"
    if packet_drop_rate > 0.0:
        suffix += f"_drop{int(round(packet_drop_rate * 100)):02d}"
    return suffix


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--bytes-per-mb", type=int, default=24)
    parser.add_argument("--sweep", type=str, default=None)
    parser.add_argument("--quality-scale", type=float, default=64.0)
    parser.add_argument("--luma-share", type=float, default=0.75)
    parser.add_argument("--chroma-quality-factor", type=float, default=0.6)
    parser.add_argument("--packet-drop-rate", type=float, default=0.0)
    parser.add_argument("--packet-drop-seed", type=int, default=1234)
    parser.add_argument("--loss-concealment", choices=["gray", "nearest"], default="gray")
    parser.add_argument(
        "--dc-mode",
        choices=["hadamard", "block"],
        default="hadamard",
        help="Hadamard codes DC jointly inside each macroblock; block is the legacy mode",
    )
    parser.add_argument(
        "--arithmetic",
        choices=["fixed", "float"],
        default="fixed",
        help="fixed is the FPGA bit-accurate datapath; float keeps the old reference path",
    )
    parser.add_argument("--save-individual", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=Path("codec_results"))
    args = parser.parse_args()

    if not args.input.exists():
        raise SystemExit(f"Input image not found: {args.input}")

    image = Image.open(args.input).convert("RGB")
    rgb = np.asarray(image, dtype=np.uint8)

    # YUV420 conversion crops odd dimensions; make dimensions even here.
    h, w = rgb.shape[:2]
    rgb = rgb[: h - (h % 2), : w - (w % 2)]

    args.output_dir.mkdir(parents=True, exist_ok=True)
    rates = parse_sweep(args.sweep, args.bytes_per_mb)
    rng = np.random.default_rng(args.packet_drop_seed)

    print("bytes/MB,codec,bpp,PSNR,SSIM,encoded_bytes,dropped_macroblocks,saturations")
    for bytes_per_mb in rates:
        padded_h = math.ceil(rgb.shape[0] / 16) * 16
        padded_w = math.ceil(rgb.shape[1] / 16) * 16
        drop_mask = make_packet_drop_mask((padded_h, padded_w), args.packet_drop_rate, rng)
        integer_result = encode_decode(
            rgb,
            INT4_N,
            bytes_per_mb,
            args.quality_scale,
            args.luma_share,
            args.chroma_quality_factor,
            drop_mask,
            args.loss_concealment,
            args.dc_mode,
            args.arithmetic,
        )
        hadamard_result = encode_decode(
            rgb,
            HAD4_N,
            bytes_per_mb,
            args.quality_scale,
            args.luma_share,
            args.chroma_quality_factor,
            drop_mask,
            args.loss_concealment,
            args.dc_mode,
            args.arithmetic,
        )

        suffix = make_output_suffix(bytes_per_mb, args.packet_drop_rate)
        if args.save_individual:
            Image.fromarray(integer_result.rgb).save(
                args.output_dir / f"integer_{suffix}.png"
            )
            Image.fromarray(hadamard_result.rgb).save(
                args.output_dir / f"hadamard_{suffix}.png"
            )
        make_comparison(rgb, integer_result, hadamard_result).save(
            args.output_dir / f"comparison_{suffix}.png"
        )

        for name, result in (
            ("integer", integer_result),
            ("hadamard", hadamard_result),
        ):
            ssim_text = "n/a" if result.ssim is None else f"{result.ssim:.5f}"
            print(
                f"{bytes_per_mb},{name},{result.actual_bits_per_pixel:.4f},"
                f"{result.psnr:.3f},{ssim_text},{result.encoded_bytes},"
                f"{result.dropped_macroblocks},{result.arithmetic_saturations}"
            )

    print(f"\nImages saved to: {args.output_dir.resolve()}")
    print("Comparison layout: original | integer transform | Hadamard")


if __name__ == "__main__":
    main()

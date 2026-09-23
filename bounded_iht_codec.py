"""Golden encoder model for the bounded sparse 8x8 FPGA transform.

The forward transform is the H.264 8x8 integer transform.  Its per-frequency
normalisation is folded into the coefficients so that the matching FPGA
inverse transform can stay multiplier-free.  Quantisation uses only shifts,
exactly like ``receiver_bounded_sparse_iht8``.
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from functools import lru_cache
from math import sqrt
from typing import Iterable, Sequence


Block = list[list[int]]

# Diagonal normalisation D for which I * D * F is the identity in one
# dimension.  The odd-frequency value is exact for the 3/2 and 1/4 lifting
# constants used by the integer transform.
_NORMALISATION = (
    Fraction(1, 8), Fraction(32, 289), Fraction(1, 5), Fraction(32, 289),
    Fraction(1, 8), Fraction(32, 289), Fraction(1, 5), Fraction(32, 289),
)
_FORWARD_SCALE = tuple(tuple(
    64 * _NORMALISATION[row] * _NORMALISATION[column]
    for column in range(8)
) for row in range(8))


@dataclass(frozen=True)
class SparseBlock:
    quant_shift: int
    events: tuple[tuple[int, int], ...]

    def coefficients(self) -> dict[int, int]:
        return dict(self.events)


def _check_block(block: Sequence[Sequence[int]]) -> None:
    if len(block) != 8 or any(len(row) != 8 for row in block):
        raise ValueError("an 8x8 block is required")


def _round_ratio(numerator: int, denominator: int) -> int:
    if numerator >= 0:
        return (numerator + denominator // 2) // denominator
    return -((-numerator + denominator // 2) // denominator)


def _round_div_pow2(value: int, shift: int) -> int:
    if shift == 0:
        return value
    half = 1 << (shift - 1)
    if value >= 0:
        return (value + half) >> shift
    return -((-value + half) >> shift)


def forward_iht8_1d(values: Sequence[int]) -> list[int]:
    if len(values) != 8:
        raise ValueError("eight input values are required")
    s07 = values[0] + values[7]
    s16 = values[1] + values[6]
    s25 = values[2] + values[5]
    s34 = values[3] + values[4]
    a0, a1 = s07 + s34, s16 + s25
    a2, a3 = s07 - s34, s16 - s25
    d07 = values[0] - values[7]
    d16 = values[1] - values[6]
    d25 = values[2] - values[5]
    d34 = values[3] - values[4]
    a4 = d16 + d25 + d07 + (d07 >> 1)
    a5 = d07 - d34 - d25 - (d25 >> 1)
    a6 = d07 + d34 - d16 - (d16 >> 1)
    a7 = d16 - d25 + d34 + (d34 >> 1)
    return [
        a0 + a1, a4 + (a7 >> 2), a2 + (a3 >> 1),
        a5 + (a6 >> 2), a0 - a1, a6 - (a5 >> 2),
        (a2 >> 1) - a3, (a4 >> 2) - a7,
    ]


def inverse_iht8_1d(values: Sequence[int]) -> list[int]:
    if len(values) != 8:
        raise ValueError("eight input values are required")
    c0, c1, c2, c3, c4, c5, c6, c7 = values
    a0, a2 = c0 + c4, c0 - c4
    a4, a6 = (c2 >> 1) - c6, c2 + (c6 >> 1)
    a1 = -c3 + c5 - c7 - (c7 >> 1)
    a3 = c1 + c7 - c3 - (c3 >> 1)
    a5 = -c1 + c7 + c5 + (c5 >> 1)
    a7 = c3 + c5 + c1 + (c1 >> 1)
    b0, b2, b4, b6 = a0 + a6, a2 + a4, a2 - a4, a0 - a6
    b1, b3 = a1 + (a7 >> 2), a3 + (a5 >> 2)
    b5, b7 = (a3 >> 2) - a5, a7 - (a1 >> 2)
    return [
        b0 + b7, b2 + b5, b4 + b3, b6 + b1,
        b6 - b1, b4 - b3, b2 - b5, b0 - b7,
    ]


def _transform_2d(block: Sequence[Sequence[int]], transform) -> Block:
    rows = [transform(row) for row in block]
    columns = [transform([rows[row][column] for row in range(8)])
               for column in range(8)]
    return [[columns[column][row] for column in range(8)]
            for row in range(8)]


def forward_block(block: Sequence[Sequence[int]]) -> Block:
    """Return coefficients normalised for the multiplier-free FPGA inverse."""
    _check_block(block)
    raw = _transform_2d(block, forward_iht8_1d)
    return [[
        _round_ratio(
            raw[row][column] * _FORWARD_SCALE[row][column].numerator,
            _FORWARD_SCALE[row][column].denominator,
        )
        for column in range(8)] for row in range(8)]


def weight_shift(address: int) -> int:
    if not 0 <= address < 64:
        raise ValueError("coefficient address must be in [0, 63]")
    diagonal = (address >> 3) + (address & 7)
    return 0 if diagonal <= 1 else 1 if diagonal <= 3 else 2 if diagonal <= 5 else 3


def dequant_shift(address: int, quant_shift: int) -> int:
    if not 0 <= quant_shift <= 7:
        raise ValueError("quant_shift must be in [0, 7]")
    return min(quant_shift + weight_shift(address), 6)


def inverse_dequantized_block(matrix: Sequence[Sequence[int]]) -> Block:
    """Apply the exact FPGA transform to an already dequantized matrix."""
    _check_block(matrix)
    transformed = _transform_2d(matrix, inverse_iht8_1d)
    return [[max(-32768, min(32767, (value + 32) >> 6)) for value in row]
            for row in transformed]


def inverse_block(coefficients: dict[int, int] | Iterable[tuple[int, int]],
                  quant_shift: int) -> Block:
    """Bit-exact model of FPGA dequantisation, inverse transform and rounding."""
    coefficient_map = dict(coefficients)
    matrix = [[0] * 8 for _ in range(8)]
    for address, value in coefficient_map.items():
        if not 0 <= address < 64:
            raise ValueError("coefficient address must be in [0, 63]")
        matrix[address >> 3][address & 7] = value << dequant_shift(
            address, quant_shift)
    return inverse_dequantized_block(matrix)


@lru_cache(maxsize=None)
def _basis_norm(address: int, quant_shift: int) -> float:
    decoded = inverse_block({address: 256}, quant_shift)
    return sqrt(sum(value * value for row in decoded for value in row)) / 256.0


def coefficient_priority(address: int, value: int, quant_shift: int) -> float:
    """Rank one quantized coefficient by reconstructed residual energy."""
    return (abs(value) * (1 << dequant_shift(address, quant_shift))
            * _basis_norm(address, quant_shift))


def quantize_sparse_block(block: Sequence[Sequence[int]], quant_shift: int,
                          max_ac: int) -> SparseBlock:
    """Quantise an 8x8 residual and retain the most useful bounded AC terms."""
    if not 0 <= max_ac <= 63:
        raise ValueError("max_ac must be in [0, 63]")
    coefficients = forward_block(block)
    quantized: list[tuple[int, int]] = []
    for address in range(64):
        value = coefficients[address >> 3][address & 7]
        code = max(-2048, min(2047, _round_div_pow2(
            value, dequant_shift(address, quant_shift))))
        if code:
            quantized.append((address, code))

    dc = next(((address, value) for address, value in quantized
               if address == 0), None)
    ac = [(address, value) for address, value in quantized if address != 0]
    ac.sort(key=lambda event: (
        coefficient_priority(event[0], event[1], quant_shift),
        -event[0],
    ), reverse=True)
    selected = ([dc] if dc is not None else []) + ac[:max_ac]
    selected.sort(key=lambda event: event[0])
    return SparseBlock(quant_shift, tuple(selected))


def reconstruct_sparse_block(block: SparseBlock) -> Block:
    return inverse_block(block.events, block.quant_shift)

"""Bit-exact 8-bit HEVC 4:2:0 chroma TU8 primitives."""

from __future__ import annotations

from collections.abc import Sequence

from .quant import INVERSE_QUANT_SCALES, QUANT_SCALES, split_qp

DCT8 = (
    (64, 64, 64, 64, 64, 64, 64, 64),
    (89, 75, 50, 18, -18, -50, -75, -89),
    (83, 36, -36, -83, -83, -36, 36, 83),
    (75, -18, -89, -50, 50, 89, 18, -75),
    (64, -64, -64, 64, 64, -64, -64, 64),
    (50, -89, 18, 75, -75, -18, 89, -50),
    (36, -83, 83, -36, -36, 83, -83, 36),
    (18, -50, 75, -89, 89, -75, 50, -18),
)
CHROMA_QP_30_TO_43 = (29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37)


def _round_shift(value: int, shift: int) -> int:
    return (value + (1 << (shift - 1))) >> shift


def _clip16(value: int) -> int:
    return min(32767, max(-32768, value))


def chroma_qp(luma_qp: int, offset: int = 0) -> int:
    if not 0 <= luma_qp <= 51:
        raise ValueError("HEVC luma QP must be in [0, 51]")
    qpi = min(51, max(0, luma_qp + offset))
    if qpi < 30:
        return qpi
    if qpi <= 43:
        return CHROMA_QP_30_TO_43[qpi - 30]
    return qpi - 6


def forward_transform_8(residual: Sequence[Sequence[int]]) -> tuple[list[list[int]], list[list[int]]]:
    if len(residual) != 8 or any(len(row) != 8 for row in residual):
        raise ValueError("transform8 residual must be 8x8")
    if any(not -255 <= int(v) <= 255 for row in residual for v in row):
        raise ValueError("9-bit prediction residual outside [-255, 255]")
    intermediate = [[_round_shift(sum(DCT8[u][x] * int(row[x]) for x in range(8)), 2)
                     for u in range(8)] for row in residual]
    coefficients = [[_round_shift(sum(DCT8[v][y] * intermediate[y][u] for y in range(8)), 9)
                     for u in range(8)] for v in range(8)]
    return intermediate, coefficients


def inverse_transform_8(coefficients: Sequence[Sequence[int]]) -> tuple[list[list[int]], list[list[int]]]:
    if len(coefficients) != 8 or any(len(row) != 8 for row in coefficients):
        raise ValueError("inverse transform8 coefficients must be 8x8")
    if any(not -32768 <= int(v) <= 32767 for row in coefficients for v in row):
        raise ValueError("inverse transform8 coefficient outside signed 16-bit")
    intermediate = [[_clip16(_round_shift(sum(DCT8[v][y] * int(coefficients[v][u])
                                                for v in range(8)), 7))
                     for u in range(8)] for y in range(8)]
    residual = [[_clip16(_round_shift(sum(DCT8[u][x] * intermediate[y][u]
                                           for u in range(8)), 12))
                 for x in range(8)] for y in range(8)]
    return intermediate, residual


def quantize_dequantize_8(coefficient: int, qp: int, intra: bool = True) -> tuple[int, int]:
    if not -32768 <= coefficient <= 32767:
        raise ValueError("transform coefficient outside signed 16-bit")
    qp_per, qp_rem = split_qp(qp)
    q_bits = 18 + qp_per
    offset = (171 if intra else 85) << (q_bits - 9)
    magnitude = (abs(coefficient) * QUANT_SCALES[qp_rem] + offset) >> q_bits
    quantized = _clip16(-magnitude if coefficient < 0 else magnitude)
    dequantized = _clip16((quantized * (INVERSE_QUANT_SCALES[qp_rem] << qp_per) + 2) >> 2)
    return quantized, dequantized

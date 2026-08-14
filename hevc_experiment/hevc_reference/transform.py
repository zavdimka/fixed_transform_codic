"""Bit-exact integer HEVC forward transform primitives."""

from __future__ import annotations

from collections.abc import Sequence


DCT16: tuple[tuple[int, ...], ...] = (
    (64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64),
    (90, 87, 80, 70, 57, 43, 25, 9, -9, -25, -43, -57, -70, -80, -87, -90),
    (89, 75, 50, 18, -18, -50, -75, -89, -89, -75, -50, -18, 18, 50, 75, 89),
    (87, 57, 9, -43, -80, -90, -70, -25, 25, 70, 90, 80, 43, -9, -57, -87),
    (83, 36, -36, -83, -83, -36, 36, 83, 83, 36, -36, -83, -83, -36, 36, 83),
    (80, 9, -70, -87, -25, 57, 90, 43, -43, -90, -57, 25, 87, 70, -9, -80),
    (75, -18, -89, -50, 50, 89, 18, -75, -75, 18, 89, 50, -50, -89, -18, 75),
    (70, -43, -87, 9, 90, 25, -80, -57, 57, 80, -25, -90, -9, 87, 43, -70),
    (64, -64, -64, 64, 64, -64, -64, 64, 64, -64, -64, 64, 64, -64, -64, 64),
    (57, -80, -25, 90, -9, -87, 43, 70, -70, -43, 87, 9, -90, 25, 80, -57),
    (50, -89, 18, 75, -75, -18, 89, -50, -50, 89, -18, -75, 75, 18, -89, 50),
    (43, -90, 57, 25, -87, 70, 9, -80, 80, -9, -70, 87, -25, -57, 90, -43),
    (36, -83, 83, -36, -36, 83, -83, 36, 36, -83, 83, -36, -36, 83, -83, 36),
    (25, -70, 90, -80, 43, 9, -57, 87, -87, 57, -9, -43, 80, -90, 70, -25),
    (18, -50, 75, -89, 89, -75, 50, -18, -18, 50, -75, 89, -89, 75, -50, 18),
    (9, -25, 43, -57, 70, -80, 87, -90, 90, -87, 80, -70, 57, -43, 25, -9),
)


def _round_shift(value: int, shift: int) -> int:
    return (value + (1 << (shift - 1))) >> shift


def forward_transform_16(
    residual: Sequence[Sequence[int]],
) -> tuple[list[list[int]], list[list[int]]]:
    """Return (horizontal intermediate, final coefficients) for 8-bit HEVC."""

    if len(residual) != 16 or any(len(row) != 16 for row in residual):
        raise ValueError("transform16 residual must be 16x16")
    if any(not -255 <= int(value) <= 255 for row in residual for value in row):
        raise ValueError("9-bit prediction residual outside [-255, 255]")

    intermediate = [
        [_round_shift(sum(DCT16[u][x] * int(row[x]) for x in range(16)), 3)
         for u in range(16)]
        for row in residual
    ]
    coefficients = [
        [_round_shift(sum(DCT16[v][y] * intermediate[y][u] for y in range(16)), 10)
         for u in range(16)]
        for v in range(16)
    ]
    return intermediate, coefficients

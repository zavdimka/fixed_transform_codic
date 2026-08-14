"""Integer HEVC intra primitives shared by Python and RTL tests."""

from __future__ import annotations

from collections.abc import Sequence


def filtered_dc_prediction(top: Sequence[int], left: Sequence[int]) -> list[list[int]]:
    """Return normative filtered luma DC prediction for a square block < 32."""

    size = len(top)
    if size != len(left) or size not in (4, 8, 16):
        raise ValueError("filtered DC references must have equal 4/8/16 length")
    if any(not 0 <= sample <= 255 for sample in (*top, *left)):
        raise ValueError("8-bit reference sample outside [0, 255]")

    log2_size = size.bit_length() - 1
    dc = (sum(top) + sum(left) + size) >> (log2_size + 1)
    block = [[dc for _ in range(size)] for _ in range(size)]
    block[0][0] = (left[0] + 2 * dc + top[0] + 2) >> 2
    for x in range(1, size):
        block[0][x] = (top[x] + 3 * dc + 2) >> 2
    for y in range(1, size):
        block[y][0] = (left[y] + 3 * dc + 2) >> 2
    return block


def prediction_residual(
    source: Sequence[Sequence[int]], prediction: Sequence[Sequence[int]]
) -> list[list[int]]:
    if len(source) != len(prediction) or any(
        len(source_row) != len(prediction_row)
        for source_row, prediction_row in zip(source, prediction)
    ):
        raise ValueError("source and prediction dimensions differ")
    return [
        [int(sample) - int(pred) for sample, pred in zip(source_row, pred_row)]
        for source_row, pred_row in zip(source, prediction)
    ]


def reconstruct_sample(prediction: int, residual: int) -> int:
    return min(255, max(0, prediction + residual))

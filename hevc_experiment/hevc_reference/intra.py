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



def filtered_planar_references_16(
    top: Sequence[int], left: Sequence[int]
) -> tuple[list[int], list[int]]:
    """Filter the 19 raw references needed by normative luma planar16.

    Index 0 is the shared top-left sample, indexes 1..16 border the block,
    index 17 is the far corner and index 18 is needed to filter that corner.
    """

    if len(top) != 19 or len(left) != 19:
        raise ValueError("planar16 requires exactly 19 top and left references")
    if top[0] != left[0]:
        raise ValueError("top[0] and left[0] must be the same top-left sample")
    if any(not 0 <= sample <= 255 for sample in (*top, *left)):
        raise ValueError("8-bit reference sample outside [0, 255]")

    filtered_top = [0] * 18
    filtered_left = [0] * 18
    corner = (left[1] + 2 * top[0] + top[1] + 2) >> 2
    filtered_top[0] = corner
    filtered_left[0] = corner
    for index in range(1, 18):
        filtered_top[index] = (
            top[index - 1] + 2 * top[index] + top[index + 1] + 2
        ) >> 2
        filtered_left[index] = (
            left[index - 1] + 2 * left[index] + left[index + 1] + 2
        ) >> 2
    return filtered_top, filtered_left


def planar_prediction_16(top: Sequence[int], left: Sequence[int]) -> list[list[int]]:
    """Return normative HEVC luma planar prediction for a 16x16 block."""

    filtered_top, filtered_left = filtered_planar_references_16(top, left)
    top_right = filtered_top[17]
    bottom_left = filtered_left[17]
    prediction: list[list[int]] = []
    for y in range(16):
        row = []
        for x in range(16):
            horizontal = (15 - x) * filtered_left[y + 1] + (x + 1) * top_right
            vertical = (15 - y) * filtered_top[x + 1] + (y + 1) * bottom_left
            row.append((horizontal + vertical + 16) >> 5)
        prediction.append(row)
    return prediction


def residual_sad(residual: Sequence[Sequence[int]]) -> int:
    return sum(abs(int(value)) for row in residual for value in row)


def select_planar_by_sad(
    dc_residual: Sequence[Sequence[int]],
    planar_residual: Sequence[Sequence[int]],
) -> tuple[bool, int, int]:
    """Choose planar only when its SAD is strictly smaller; DC wins ties."""

    dc_sad = residual_sad(dc_residual)
    planar_sad = residual_sad(planar_residual)
    return planar_sad < dc_sad, dc_sad, planar_sad

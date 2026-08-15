"""Integer HEVC 8x8 chroma intra-prediction primitives."""

from __future__ import annotations

from collections.abc import Sequence


def _validate_references(top: Sequence[int], left: Sequence[int]) -> None:
    if len(top) != 10 or len(left) != 10:
        raise ValueError("chroma8 requires exactly 10 top and left references")
    if top[0] != left[0]:
        raise ValueError("top[0] and left[0] must be the same top-left sample")
    if any(not 0 <= sample <= 255 for sample in (*top, *left)):
        raise ValueError("8-bit reference sample outside [0, 255]")


def chroma_dc_prediction_8(
    top: Sequence[int], left: Sequence[int]
) -> list[list[int]]:
    """Return the unfiltered HEVC 8x8 chroma DC prediction."""

    _validate_references(top, left)
    dc = (sum(top[1:9]) + sum(left[1:9]) + 8) >> 4
    return [[dc for _ in range(8)] for _ in range(8)]


def chroma_planar_prediction_8(
    top: Sequence[int], left: Sequence[int]
) -> list[list[int]]:
    """Return the unfiltered HEVC 8x8 chroma planar prediction."""

    _validate_references(top, left)
    prediction: list[list[int]] = []
    for y in range(8):
        row = []
        for x in range(8):
            horizontal = (7 - x) * left[y + 1] + (x + 1) * top[9]
            vertical = (7 - y) * top[x + 1] + (y + 1) * left[9]
            row.append((horizontal + vertical + 8) >> 4)
        prediction.append(row)
    return prediction

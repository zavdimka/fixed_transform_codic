"""HEVC chroma TU8 diagonal scan and coefficient-context reference."""

from __future__ import annotations

from dataclasses import dataclass
from collections.abc import Sequence

from .scan import DIAGONAL_SCAN_4

DIAGONAL_SCAN_2 = (0, 2, 1, 3)


def diagonal_scan_addresses_8() -> tuple[int, ...]:
    addresses: list[int] = []
    for group_raster in DIAGONAL_SCAN_2:
        gx, gy = group_raster & 1, group_raster >> 1
        for local_raster in DIAGONAL_SCAN_4:
            lx, ly = local_raster & 3, local_raster >> 2
            addresses.append((((gy << 2) | ly) << 3) | ((gx << 2) | lx))
    return tuple(addresses)


DIAGONAL_SCAN_8 = diagonal_scan_addresses_8()
GROUP_INDEX_8 = (0, 1, 2, 3, 4, 4, 5, 5)
MIN_IN_GROUP = (0, 1, 2, 3, 4, 6)


def coefficient_scan_metadata_8(coefficients: Sequence[Sequence[int]]) -> tuple[tuple[bool, ...], int | None]:
    if len(coefficients) != 8 or any(len(row) != 8 for row in coefficients):
        raise ValueError("TU8 coefficient block must be 8x8")
    flags = [False] * 4
    last = None
    for position, address in enumerate(DIAGONAL_SCAN_8):
        if coefficients[address >> 3][address & 7]:
            flags[DIAGONAL_SCAN_2[position >> 4]] = True
            last = position
    return tuple(flags), last


@dataclass(frozen=True)
class ChromaLastBin:
    value: int
    bypass: bool
    axis_y: bool
    context_index: int


def last_significant_bins_8(raster_address: int) -> tuple[ChromaLastBin, ...]:
    if not 0 <= raster_address < 64:
        raise ValueError("TU8 raster address must be in range 0..63")
    events: list[ChromaLastBin] = []
    for axis_y, coordinate in enumerate((raster_address & 7, raster_address >> 3)):
        group = GROUP_INDEX_8[coordinate]
        events.extend(ChromaLastBin(1, False, bool(axis_y), index)
                      for index in range(group))
        if group < 5:
            events.append(ChromaLastBin(0, False, bool(axis_y), group))
    for axis_y, coordinate in enumerate((raster_address & 7, raster_address >> 3)):
        group = GROUP_INDEX_8[coordinate]
        if group > 3:
            width = (group - 2) // 2
            suffix = coordinate - MIN_IN_GROUP[group]
            events.extend(ChromaLastBin((suffix >> bit) & 1, True, bool(axis_y), 0)
                          for bit in range(width - 1, -1, -1))
    return tuple(events)


@dataclass(frozen=True)
class ChromaSignificanceBin:
    value: int
    coded_sub_block: bool
    context_index: int
    scan_position: int


def _group_context(flags: tuple[bool, ...], group_raster: int) -> int:
    right = not (group_raster & 1) and flags[group_raster + 1]
    lower = not (group_raster & 2) and flags[group_raster + 2]
    return int(right or lower)


def _coefficient_context(flags: tuple[bool, ...], address: int) -> int:
    x, y = address & 7, address >> 3
    if x + y == 0:
        return 0
    group = ((y >> 2) << 1) | (x >> 2)
    right = (x >> 2) == 0 and flags[group + 1]
    lower = (y >> 2) == 0 and flags[group + 2]
    pattern = int(right) | (int(lower) << 1)
    lx, ly = x & 3, y & 3
    if pattern == 0:
        count = 2 if lx + ly == 0 else (1 if lx + ly <= 2 else 0)
    elif pattern == 1:
        count = 2 if ly == 0 else (1 if ly == 1 else 0)
    elif pattern == 2:
        count = 2 if lx == 0 else (1 if lx == 1 else 0)
    else:
        count = 2
    return 12 + count


def significance_bins_8(coefficients: Sequence[Sequence[int]]) -> tuple[ChromaSignificanceBin, ...]:
    flags, last = coefficient_scan_metadata_8(coefficients)
    if last is None:
        return ()
    events: list[ChromaSignificanceBin] = []
    last_group = last >> 4
    position = last - 1
    nonzero = 1
    for group_scan in range(last_group, -1, -1):
        base = group_scan << 4
        group_raster = DIAGONAL_SCAN_2[group_scan]
        if group_scan not in (last_group, 0):
            events.append(ChromaSignificanceBin(
                int(flags[group_raster]), True, _group_context(flags, group_raster), base + 15
            ))
        active = group_scan in (last_group, 0) or flags[group_raster]
        if group_scan != last_group:
            nonzero = 0
        if active:
            while position >= base:
                address = DIAGONAL_SCAN_8[position]
                significant = int(coefficients[address >> 3][address & 7] != 0)
                if position > base or group_scan == 0 or nonzero:
                    events.append(ChromaSignificanceBin(
                        significant, False, _coefficient_context(flags, address), position
                    ))
                nonzero += significant
                position -= 1
        else:
            position = base - 1
    return tuple(events)

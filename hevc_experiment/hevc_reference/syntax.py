from __future__ import annotations

from dataclasses import dataclass

from .scan import (
    DIAGONAL_SCAN_4,
    DIAGONAL_SCAN_16,
    coefficient_scan_metadata_16,
)


GROUP_INDEX = (0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7)
MIN_IN_GROUP = (0, 1, 2, 3, 4, 6, 8, 12)


@dataclass(frozen=True)
class LastSigBin:
    value: int
    bypass: bool
    axis_y: bool
    context_index: int
    syntax_last: bool = False


def last_significant_bins_16(raster_address: int) -> tuple[LastSigBin, ...]:
    """Return TU16 luma last_sig_coeff_x/y bins in coding order."""
    if not 0 <= raster_address <= 255:
        raise ValueError("TU16 raster address must be in range 0..255")

    coordinates = (raster_address & 15, raster_address >> 4)
    bins: list[LastSigBin] = []
    for axis_y, coordinate in enumerate(coordinates):
        group_index = GROUP_INDEX[coordinate]
        for prefix_index in range(group_index):
            bins.append(LastSigBin(1, False, bool(axis_y),
                                   6 + (prefix_index >> 1)))
        if group_index < 7:
            bins.append(LastSigBin(0, False, bool(axis_y),
                                   6 + (group_index >> 1)))

    for axis_y, coordinate in enumerate(coordinates):
        group_index = GROUP_INDEX[coordinate]
        if group_index > 3:
            suffix_width = (group_index - 2) // 2
            suffix = coordinate - MIN_IN_GROUP[group_index]
            for bit_index in range(suffix_width - 1, -1, -1):
                bins.append(LastSigBin((suffix >> bit_index) & 1, True,
                                       bool(axis_y), 0))

    if bins:
        last = bins[-1]
        bins[-1] = LastSigBin(last.value, last.bypass, last.axis_y,
                              last.context_index, True)
    return tuple(bins)


@dataclass(frozen=True)
class SignificanceBin:
    value: int
    coded_sub_block: bool
    context_index: int
    scan_position: int
    syntax_last: bool = False


def _significant_group_context(
    group_flags: tuple[bool, ...], group_raster: int,
) -> int:
    group_x = group_raster & 3
    group_y = group_raster >> 2
    right = group_x < 3 and group_flags[group_raster + 1]
    lower = group_y < 3 and group_flags[group_raster + 4]
    return int(right or lower)


def _significant_coefficient_context(
    group_flags: tuple[bool, ...], raster_address: int,
) -> int:
    x = raster_address & 15
    y = raster_address >> 4
    if x + y == 0:
        return 0

    group_x = x >> 2
    group_y = y >> 2
    group_raster = (group_y << 2) | group_x
    right = group_x < 3 and group_flags[group_raster + 1]
    lower = group_y < 3 and group_flags[group_raster + 4]
    pattern = int(right) | (int(lower) << 1)
    local_x = x & 3
    local_y = y & 3
    if pattern == 0:
        local_sum = local_x + local_y
        count = 2 if local_sum == 0 else (1 if local_sum <= 2 else 0)
    elif pattern == 1:
        count = 2 if local_y == 0 else (1 if local_y == 1 else 0)
    elif pattern == 2:
        count = 2 if local_x == 0 else (1 if local_x == 1 else 0)
    else:
        count = 2
    return 21 + (3 if group_x + group_y > 0 else 0) + count


def significance_bins_16(
    coefficients: tuple[tuple[int, ...], ...] | list[list[int]],
) -> tuple[SignificanceBin, ...]:
    """Return TU16 luma coded-sub-block and significant-coefficient bins."""
    group_flags, last_nonzero = coefficient_scan_metadata_16(coefficients)
    if last_nonzero is None:
        return ()

    events: list[SignificanceBin] = []
    last_group = last_nonzero >> 4
    scan_position = last_nonzero - 1
    nonzero_in_group = 1

    for group_scan in range(last_group, -1, -1):
        sub_position = group_scan << 4
        group_raster = DIAGONAL_SCAN_4[group_scan]
        if group_scan not in (last_group, 0):
            events.append(SignificanceBin(
                int(group_flags[group_raster]), True,
                _significant_group_context(group_flags, group_raster),
                sub_position + 15,
            ))

        group_active = (
            group_scan == last_group
            or group_scan == 0
            or group_flags[group_raster]
        )
        if group_scan != last_group:
            nonzero_in_group = 0

        if group_active:
            while scan_position >= sub_position:
                raster_address = DIAGONAL_SCAN_16[scan_position]
                coefficient = coefficients[raster_address >> 4][raster_address & 15]
                significant = int(coefficient != 0)
                if (
                    scan_position > sub_position
                    or group_scan == 0
                    or nonzero_in_group
                ):
                    events.append(SignificanceBin(
                        significant, False,
                        _significant_coefficient_context(
                            group_flags, raster_address
                        ),
                        scan_position,
                    ))
                if significant:
                    nonzero_in_group += 1
                scan_position -= 1
        else:
            scan_position = sub_position - 1

    if events:
        last = events[-1]
        events[-1] = SignificanceBin(
            last.value, last.coded_sub_block, last.context_index,
            last.scan_position, True,
        )
    return tuple(events)

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


LEVEL_GREATER1 = 0
LEVEL_GREATER2 = 1
LEVEL_SIGN = 2
LEVEL_REMAINING = 3


@dataclass(frozen=True)
class LevelBin:
    value: int
    kind: int
    bypass: bool
    context_index: int
    group_scan_position: int
    coefficient_index: int
    syntax_last: bool = False


def _rice_remaining_bits(symbol: int, rice_parameter: int) -> tuple[int, ...]:
    if symbol < (3 << rice_parameter):
        quotient = symbol >> rice_parameter
        prefix = (1,) * quotient + (0,)
        suffix = tuple(
            (symbol >> bit_index) & 1
            for bit_index in range(rice_parameter - 1, -1, -1)
        )
        return prefix + suffix

    length = rice_parameter
    code_number = symbol - (3 << rice_parameter)
    while code_number >= (1 << length):
        code_number -= 1 << length
        length += 1
    prefix_ones = 3 + length - rice_parameter
    suffix = tuple(
        (code_number >> bit_index) & 1
        for bit_index in range(length - 1, -1, -1)
    )
    return (1,) * prefix_ones + (0,) + suffix


def coefficient_level_bins_16(
    coefficients: tuple[tuple[int, ...], ...] | list[list[int]],
) -> tuple[LevelBin, ...]:
    """Return TU16 luma level/sign bins with sign hiding disabled."""
    _, last_nonzero = coefficient_scan_metadata_16(coefficients)
    if last_nonzero is None:
        return ()

    events: list[LevelBin] = []
    carried_c1 = 1
    last_group = last_nonzero >> 4
    for group_scan in range(last_group, -1, -1):
        high_position = last_nonzero if group_scan == last_group else (
            (group_scan << 4) + 15
        )
        low_position = group_scan << 4
        signed_coefficients = []
        for scan_position in range(high_position, low_position - 1, -1):
            address = DIAGONAL_SCAN_16[scan_position]
            coefficient = coefficients[address >> 4][address & 15]
            if coefficient:
                signed_coefficients.append(coefficient)
        if not signed_coefficients:
            continue

        absolute = [abs(value) for value in signed_coefficients]
        context_set = 2 if group_scan > 0 else 0
        if carried_c1 == 0:
            context_set += 1
        c1 = 1
        first_c2_index: int | None = None
        for index, value in enumerate(absolute[:8]):
            symbol = int(value > 1)
            events.append(LevelBin(
                symbol, LEVEL_GREATER1, False, 4 * context_set + c1,
                group_scan, index,
            ))
            if symbol:
                c1 = 0
                if first_c2_index is None:
                    first_c2_index = index
            elif 0 < c1 < 3:
                c1 += 1
        carried_c1 = c1

        if c1 == 0 and first_c2_index is not None:
            events.append(LevelBin(
                int(absolute[first_c2_index] > 2),
                LEVEL_GREATER2, False, context_set,
                group_scan, first_c2_index,
            ))

        for index, value in enumerate(signed_coefficients):
            events.append(LevelBin(
                int(value < 0), LEVEL_SIGN, True, 0,
                group_scan, index,
            ))

        if c1 == 0 or len(absolute) > 8:
            first_coefficient2 = 1
            rice_parameter = 0
            for index, value in enumerate(absolute):
                base_level = (2 + first_coefficient2) if index < 8 else 1
                if value >= base_level:
                    for bit in _rice_remaining_bits(
                        value - base_level, rice_parameter
                    ):
                        events.append(LevelBin(
                            bit, LEVEL_REMAINING, True, 0,
                            group_scan, index,
                        ))
                    if value > (3 << rice_parameter):
                        rice_parameter = min(rice_parameter + 1, 4)
                if value >= 2:
                    first_coefficient2 = 0

    if events:
        last = events[-1]
        events[-1] = LevelBin(
            last.value, last.kind, last.bypass, last.context_index,
            last.group_scan_position, last.coefficient_index, True,
        )
    return tuple(events)

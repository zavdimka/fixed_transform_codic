from __future__ import annotations

from dataclasses import dataclass


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

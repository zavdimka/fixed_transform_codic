"""HEVC chroma TU8 coefficient-level bin reference."""

from __future__ import annotations

from collections.abc import Sequence

from .chroma_syntax import DIAGONAL_SCAN_8, coefficient_scan_metadata_8
from .syntax import (
    LEVEL_GREATER1, LEVEL_GREATER2, LEVEL_REMAINING, LEVEL_SIGN,
    LevelBin, _rice_remaining_bits,
)


def coefficient_level_bins_8(coefficients: Sequence[Sequence[int]]) -> tuple[LevelBin, ...]:
    _, last = coefficient_scan_metadata_8(coefficients)
    if last is None:
        return ()
    events: list[LevelBin] = []
    carried_c1 = 1
    for group_scan in range(last >> 4, -1, -1):
        high = last if group_scan == (last >> 4) else (group_scan << 4) + 15
        low = group_scan << 4
        values = []
        for position in range(high, low - 1, -1):
            address = DIAGONAL_SCAN_8[position]
            value = coefficients[address >> 3][address & 7]
            if value:
                values.append(value)
        if not values:
            continue
        absolute = [abs(value) for value in values]
        # Chroma has only context sets 0/1; sub-block position does not add 2.
        context_set = int(carried_c1 == 0)
        c1 = 1
        first_c2 = None
        for index, value in enumerate(absolute[:8]):
            symbol = int(value > 1)
            events.append(LevelBin(symbol, LEVEL_GREATER1, False,
                                   4 * context_set + c1, group_scan, index))
            if symbol:
                c1 = 0
                if first_c2 is None:
                    first_c2 = index
            elif 0 < c1 < 3:
                c1 += 1
        carried_c1 = c1
        if c1 == 0 and first_c2 is not None:
            events.append(LevelBin(int(absolute[first_c2] > 2), LEVEL_GREATER2,
                                   False, context_set, group_scan, first_c2))
        events.extend(LevelBin(int(value < 0), LEVEL_SIGN, True, 0, group_scan, index)
                      for index, value in enumerate(values))
        if c1 == 0 or len(absolute) > 8:
            first_coefficient2 = 1
            rice = 0
            for index, value in enumerate(absolute):
                base = (2 + first_coefficient2) if index < 8 else 1
                if value >= base:
                    events.extend(LevelBin(bit, LEVEL_REMAINING, True, 0,
                                           group_scan, index)
                                  for bit in _rice_remaining_bits(value - base, rice))
                    if value > (3 << rice):
                        rice = min(rice + 1, 4)
                if value >= 2:
                    first_coefficient2 = 0
    return tuple(events)

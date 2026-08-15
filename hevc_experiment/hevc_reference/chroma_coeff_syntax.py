"""Ordered HEVC chroma TU8 coefficient syntax before arithmetic CABAC."""

from __future__ import annotations

from collections.abc import Sequence

from .chroma_level import coefficient_level_bins_8
from .chroma_syntax import (
    DIAGONAL_SCAN_8,
    coefficient_scan_metadata_8,
    last_significant_bins_8,
    significance_bins_8,
)
from .syntax import (
    CoefficientSyntaxBin,
    SYNTAX_SOURCE_LAST,
    SYNTAX_SOURCE_LEVEL,
    SYNTAX_SOURCE_SIGNIFICANCE,
)


def coefficient_syntax_bins_8(
    coefficients: Sequence[Sequence[int]],
) -> tuple[CoefficientSyntaxBin, ...]:
    """Return standard-ordered chroma TU8 bins with sign hiding disabled."""
    _, last = coefficient_scan_metadata_8(coefficients)
    if last is None:
        return ()
    last_address = DIAGONAL_SCAN_8[last]
    events = [
        CoefficientSyntaxBin(
            event.value,
            event.bypass,
            SYNTAX_SOURCE_LAST,
            context_index=event.context_index,
            last_axis_y=event.axis_y,
        )
        for event in last_significant_bins_8(last_address)
    ]
    events.extend(
        CoefficientSyntaxBin(
            event.value,
            False,
            SYNTAX_SOURCE_SIGNIFICANCE,
            context_index=event.context_index,
            significance_coded_sub_block=event.coded_sub_block,
            scan_position=event.scan_position,
        )
        for event in significance_bins_8(coefficients)
    )
    events.extend(
        CoefficientSyntaxBin(
            event.value,
            event.bypass,
            SYNTAX_SOURCE_LEVEL,
            level_kind=event.kind,
            context_index=event.context_index,
            group_scan_position=event.group_scan_position,
            coefficient_index=event.coefficient_index,
        )
        for event in coefficient_level_bins_8(coefficients)
    )
    return tuple(events)

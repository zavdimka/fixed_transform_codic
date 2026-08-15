"""Fixed CTU16 Y/Cb/Cr syntax ordering reference."""

from __future__ import annotations

from .cu_syntax import CuSyntaxBin, ctu16_intra_prefix_bins, end_of_ctu_bin


def ctu16_yuv_syntax_bins(
    luma_mode: int,
    luma_bins: tuple[CuSyntaxBin, ...],
    cb_bins: tuple[CuSyntaxBin, ...],
    cr_bins: tuple[CuSyntaxBin, ...],
    last_ctu_in_slice: bool,
) -> tuple[CuSyntaxBin, ...]:
    """Order transform-unit syntax as prefix, Y, Cb, Cr, terminate."""
    return (
        ctu16_intra_prefix_bins(
            luma_mode, bool(luma_bins), bool(cb_bins), bool(cr_bins)
        )
        + luma_bins + cb_bins + cr_bins
        + (end_of_ctu_bin(last_ctu_in_slice),)
    )

"""Fixed CTU64/CU16 intra syntax preceding TU16 coefficients."""

from __future__ import annotations

from dataclasses import dataclass

from .cabac import (
    CONTEXT_CHROMA_PRED_MODE,
    CONTEXT_INTRA_PRED_MODE,
    CONTEXT_PART_SIZE,
    CONTEXT_QT_CBF_CHROMA,
    CONTEXT_QT_CBF_LUMA,
    CONTEXT_SPLIT,
)

CABAC_REGULAR = 0
CABAC_BYPASS = 1
CABAC_TERMINATE = 2

INTRA_PLANAR = 0
INTRA_DC = 1


@dataclass(frozen=True)
class CuSyntaxBin:
    value: int
    kind: int
    context_address: int = 0
    name: str = ""
    syntax_last: bool = False


def _split_context(cu_index: int, ctu_x: int) -> int:
    quadrant = cu_index >> 2
    if quadrant == 0:
        return int(ctu_x != 0)
    if quadrant == 1:
        return 1
    if quadrant == 2:
        return 2 if ctu_x != 0 else 1
    return 2


def intra_cu16_prefix_bins(
    cu_index: int,
    ctu_x: int,
    luma_mode: int,
    luma_cbf: bool,
) -> tuple[CuSyntaxBin, ...]:
    """Emit fixed CTU64-to-CU16 syntax in depth-first CU order.

    Each CTU contains 16 CU16 leaves. Planar and DC are always MPM indexes zero
    and one because every available neighbour also uses planar or DC; unavailable
    neighbours default to DC. Chroma uses derived mode and has no residual.
    """

    if not 0 <= cu_index < 16:
        raise ValueError("cu_index must be in [0, 15]")
    if ctu_x < 0:
        raise ValueError("ctu_x must be non-negative")
    if luma_mode not in (INTRA_PLANAR, INTRA_DC):
        raise ValueError("only planar and DC modes are supported")

    bins: list[CuSyntaxBin] = []
    if cu_index == 0:
        root_context = int(ctu_x != 0)
        bins.append(CuSyntaxBin(
            1, CABAC_REGULAR, CONTEXT_SPLIT + root_context, "split_cu_root"
        ))
    if (cu_index & 3) == 0:
        bins.append(CuSyntaxBin(
            1,
            CABAC_REGULAR,
            CONTEXT_SPLIT + _split_context(cu_index, ctu_x),
            "split_cu_32",
        ))

    bins.append(CuSyntaxBin(
        1, CABAC_REGULAR, CONTEXT_PART_SIZE, "part_mode_2Nx2N"
    ))
    bins.append(CuSyntaxBin(
        1, CABAC_REGULAR, CONTEXT_INTRA_PRED_MODE, "prev_intra_luma_pred_flag"
    ))
    bins.append(CuSyntaxBin(
        int(luma_mode == INTRA_DC), CABAC_BYPASS, name="mpm_idx_first"
    ))
    if luma_mode == INTRA_DC:
        bins.append(CuSyntaxBin(0, CABAC_BYPASS, name="mpm_idx_second"))

    bins.append(CuSyntaxBin(
        0, CABAC_REGULAR, CONTEXT_CHROMA_PRED_MODE, "intra_chroma_pred_mode"
    ))
    bins.append(CuSyntaxBin(
        0, CABAC_REGULAR, CONTEXT_QT_CBF_CHROMA, "cbf_cb"
    ))
    bins.append(CuSyntaxBin(
        0, CABAC_REGULAR, CONTEXT_QT_CBF_CHROMA, "cbf_cr"
    ))
    bins.append(CuSyntaxBin(
        int(luma_cbf),
        CABAC_REGULAR,
        CONTEXT_QT_CBF_LUMA + 1,
        "cbf_luma",
        True,
    ))
    return tuple(bins)


def end_of_ctu_bin(last_ctu_in_slice: bool) -> CuSyntaxBin:
    """Emit end_of_slice_segment_flag after the final CU of one CTU."""

    return CuSyntaxBin(
        int(last_ctu_in_slice),
        CABAC_TERMINATE,
        name="end_of_slice_segment_flag",
        syntax_last=True,
    )


def ctu64_syntax_bins(
    ctu_x: int,
    luma_modes: tuple[int, ...],
    luma_cbfs: tuple[bool, ...],
    coefficient_bins: tuple[tuple[CuSyntaxBin, ...], ...],
    last_ctu_in_slice: bool,
) -> tuple[CuSyntaxBin, ...]:
    """Combine 16 fixed CU prefixes, coefficient bins and CTU termination."""

    if len(luma_modes) != 16 or len(luma_cbfs) != 16:
        raise ValueError("a CTU64 requires exactly 16 CU16 descriptors")
    if len(coefficient_bins) != 16:
        raise ValueError("coefficient_bins must contain one entry per CU16")

    result: list[CuSyntaxBin] = []
    for cu_index, (mode, cbf, bins) in enumerate(
        zip(luma_modes, luma_cbfs, coefficient_bins)
    ):
        if bool(bins) != bool(cbf):
            raise ValueError("coefficient bins must match luma CBF")
        result.extend(intra_cu16_prefix_bins(cu_index, ctu_x, mode, cbf))
        result.extend(bins)
    result.append(end_of_ctu_bin(last_ctu_in_slice))
    return tuple(result)

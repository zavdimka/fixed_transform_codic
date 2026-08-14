"""Minimal byte-aligned IDR I-slice header construction."""

from __future__ import annotations

from hevc_reference.parameter_sets import BitWriter


def idr_slice_header_bytes(
    slice_row: int,
    qp: int,
    ctu_columns: int = 20,
    ctu_rows: int = 12,
    no_output_of_prior_pics: bool = False,
) -> bytes:
    """Build the aligned header preceding CABAC for one full-width CTU row."""

    if ctu_columns <= 0 or ctu_rows <= 0:
        raise ValueError("CTU geometry must be positive")
    if not 0 <= slice_row < ctu_rows:
        raise ValueError("slice_row is outside the coded picture")
    if not 0 <= qp <= 51:
        raise ValueError("QP must be in [0, 51]")

    writer = BitWriter()
    first_slice = slice_row == 0
    writer.write(int(first_slice), 1)
    writer.write(int(no_output_of_prior_pics), 1)
    writer.ue(0)             # slice_pic_parameter_set_id
    if not first_slice:
        pic_size_in_ctbs = ctu_columns * ctu_rows
        address_width = (pic_size_in_ctbs - 1).bit_length()
        writer.write(slice_row * ctu_columns, address_width)
    writer.ue(2)             # slice_type: I
    writer.se(qp - 26)       # slice_qp_delta, PPS init QP is 26
    # tiles_enabled_flag and entropy_coding_sync_enabled_flag are both zero,
    # therefore num_entry_point_offsets is absent.
    writer.trailing_bits()   # byte_alignment(): one followed by zeroes
    return writer.to_bytes()

"""Golden descriptor scanner for one quantized 8x8 transform block."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

from custom_budget_writer import Layer
from custom_fixed_vlc import VlcClass


ZIGZAG_ADDRESSES = (
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
)


class SyntaxOpType(IntEnum):
    RAW = 0
    VLC = 1
    SEGMENT_END = 2


@dataclass(frozen=True)
class SyntaxOp:
    op_type: SyntaxOpType
    layer: Layer
    mandatory: bool
    reserve_release: int = 0
    table_class: VlcClass = VlcClass.AC
    table_id: int = 0
    symbol: int = 0
    amplitude: int = 0
    amplitude_length: int = 0
    raw_value: int = 0
    raw_length: int = 0
    eob_required: bool = False
    last: bool = False


def magnitude_category(value: int) -> int:
    return abs(int(value)).bit_length()


def amplitude_bits(value: int, category: int) -> int:
    if not category:
        return 0
    return int(value) if value >= 0 else ((1 << category) - 1 + int(value))


def _ac_ops(values: list[int], table_id: int, layer: Layer) -> list[SyntaxOp]:
    output: list[SyntaxOp] = []
    run = 0
    for raw_value in values:
        if not raw_value:
            run += 1
            continue
        value = min(1023, max(-1023, int(raw_value)))
        while run >= 16:
            output.append(SyntaxOp(
                SyntaxOpType.VLC, layer, False,
                table_class=VlcClass.AC, table_id=table_id, symbol=0xF0,
            ))
            run -= 16
        size = magnitude_category(value)
        output.append(SyntaxOp(
            SyntaxOpType.VLC, layer, False,
            table_class=VlcClass.AC,
            table_id=table_id,
            symbol=(run << 4) | size,
            amplitude=amplitude_bits(value, size),
            amplitude_length=size,
        ))
        run = 0
    return output


def scan_quantized_block(
    raster_coefficients: list[int] | tuple[int, ...],
    table_id: int,
    base_count: int,
) -> list[SyntaxOp]:
    if len(raster_coefficients) != 64:
        raise ValueError("one complete 8x8 coefficient block is required")
    if table_id not in (0, 1):
        raise ValueError("table_id must select luma or chroma")
    if not 1 < base_count < 64:
        raise ValueError("base_count must split DC/base AC from enhancement")

    values = [int(raster_coefficients[address]) for address in ZIGZAG_ADDRESSES]
    dc = min(2047, max(-2047, values[0]))
    dc_size = magnitude_category(dc)
    dc_reserve = 20 if table_id == 0 else 22
    eob_reserve = 4 if table_id == 0 else 2
    output = [SyntaxOp(
        SyntaxOpType.VLC, Layer.BASE, True,
        reserve_release=dc_reserve,
        table_class=VlcClass.DC,
        table_id=table_id,
        symbol=dc_size,
        amplitude=amplitude_bits(dc, dc_size),
        amplitude_length=dc_size,
    )]

    for layer, start, end in (
        (Layer.BASE, 1, base_count),
        (Layer.ENHANCEMENT, base_count, 64),
    ):
        segment = values[start:end]
        last_nonzero = max(
            (index for index, value in enumerate(segment) if value), default=-1
        )
        if table_id == 0:
            output.append(SyntaxOp(
                SyntaxOpType.RAW, layer, True,
                reserve_release=1,
                raw_value=int(last_nonzero >= 0),
                raw_length=1,
            ))
        if last_nonzero >= 0:
            output.extend(_ac_ops(segment[:last_nonzero + 1], table_id, layer))
        eob_required = (
            (last_nonzero >= 0 and last_nonzero < len(segment) - 1)
            or (table_id == 1 and last_nonzero < 0)
        )
        output.append(SyntaxOp(
            SyntaxOpType.SEGMENT_END,
            layer,
            True,
            reserve_release=eob_reserve,
            table_id=table_id,
            eob_required=eob_required,
            last=layer is Layer.ENHANCEMENT,
        ))
    return output


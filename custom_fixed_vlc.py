"""Golden model for the fixed JPEG-table atomic VLC token encoder."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path

from custom_token_byte_packer import left_align_token


class VlcClass(IntEnum):
    DC = 0
    AC = 1


@dataclass(frozen=True)
class VlcToken:
    bits: int
    bit_length: int


def _load_rom(name: str, depth: int) -> tuple[int, ...]:
    path = Path(__file__).resolve().parent / "fpga" / "rtl" / "custom" / name
    words = tuple(int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip())
    if len(words) != depth:
        raise ValueError(f"{name} contains {len(words)} words, expected {depth}")
    return words


DC_ROM = _load_rom("custom_vlc_dc_table.hex", 32)
AC_ROM = _load_rom("custom_vlc_ac_table.hex", 512)


def _entry(table_class: VlcClass, table_id: int, symbol: int) -> tuple[int, int]:
    if table_id not in (0, 1) or not 0 <= symbol <= 255:
        raise ValueError("invalid VLC table address")
    if table_class is VlcClass.DC:
        if symbol > 15:
            raise ValueError("DC symbol exceeds ROM address range")
        word = DC_ROM[(table_id << 4) | symbol]
    else:
        word = AC_ROM[(table_id << 8) | symbol]
    if not (word >> 21) & 1:
        raise ValueError("symbol is absent from the fixed VLC table")
    return word & 0xFFFF, (word >> 16) & 0x1F


def encode_vlc_token(
    table_class: VlcClass,
    table_id: int,
    symbol: int,
    amplitude: int = 0,
    amplitude_length: int = 0,
) -> VlcToken:
    """Combine a Huffman code and amplitude into one left-aligned token."""
    table_class = VlcClass(table_class)
    amplitude_length = int(amplitude_length)
    if not 0 <= amplitude_length <= 11:
        raise ValueError("invalid amplitude length")
    if table_class is VlcClass.DC:
        if symbol != amplitude_length:
            raise ValueError("DC category and amplitude length differ")
    elif symbol in (0x00, 0xF0):
        if amplitude_length:
            raise ValueError("EOB/ZRL cannot carry amplitude bits")
    elif (symbol & 15) == 0 or (symbol & 15) != amplitude_length:
        raise ValueError("AC size and amplitude length differ")

    code, code_length = _entry(table_class, table_id, symbol)
    amplitude_mask = (1 << amplitude_length) - 1 if amplitude_length else 0
    combined = (code << amplitude_length) | (int(amplitude) & amplitude_mask)
    total_length = code_length + amplitude_length
    if total_length > 32:
        raise ValueError("combined VLC token exceeds the hardware width")
    return VlcToken(left_align_token(combined, total_length), total_length)


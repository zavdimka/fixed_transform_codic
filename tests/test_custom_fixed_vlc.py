from __future__ import annotations

import pytest

import jpeg_radio_codec as core
from custom_fixed_vlc import AC_ROM, DC_ROM, VlcClass, VlcToken, encode_vlc_token


def decode_word(word: int) -> tuple[int, int]:
    assert word & (1 << 21)
    return word & 0xFFFF, (word >> 16) & 0x1F


def test_generated_roms_match_every_canonical_jpeg_entry() -> None:
    for table_id in (0, 1):
        expected_dc = core.HUFFMAN_ENCODE[(0, table_id)]
        expected_ac = core.HUFFMAN_ENCODE[(1, table_id)]
        for symbol in range(16):
            word = DC_ROM[(table_id << 4) | symbol]
            if symbol in expected_dc:
                assert decode_word(word) == expected_dc[symbol]
            else:
                assert word == 0
        for symbol in range(256):
            word = AC_ROM[(table_id << 8) | symbol]
            if symbol in expected_ac:
                assert decode_word(word) == expected_ac[symbol]
            else:
                assert word == 0


def test_known_atomic_tokens() -> None:
    assert encode_vlc_token(VlcClass.DC, 0, 0) == VlcToken(0, 2)
    assert encode_vlc_token(VlcClass.DC, 0, 3, 0b010, 3) == VlcToken(0x88000000, 6)
    assert encode_vlc_token(VlcClass.AC, 0, 0x00) == VlcToken(0xA0000000, 4)
    assert encode_vlc_token(VlcClass.AC, 1, 0x00) == VlcToken(0, 2)


def test_combined_tokens_match_table_code_and_amplitude() -> None:
    for table_class in VlcClass:
        rom = DC_ROM if table_class is VlcClass.DC else AC_ROM
        symbols = range(16) if table_class is VlcClass.DC else range(256)
        address_shift = 4 if table_class is VlcClass.DC else 8
        for table_id in (0, 1):
            for symbol in symbols:
                word = rom[(table_id << address_shift) | symbol]
                if not word:
                    continue
                size = symbol if table_class is VlcClass.DC else symbol & 15
                if table_class is VlcClass.AC and symbol == 0xF0:
                    size = 0
                amplitude = (1 << size) - 1 if size else 0
                token = encode_vlc_token(table_class, table_id, symbol, amplitude, size)
                code, code_length = decode_word(word)
                natural = (code << size) | amplitude
                total = code_length + size
                assert token.bit_length == total
                assert token.bits == natural << (32 - total)


def test_invalid_symbol_semantics_are_rejected() -> None:
    with pytest.raises(ValueError):
        encode_vlc_token(VlcClass.DC, 0, 3, 0, 2)
    with pytest.raises(ValueError):
        encode_vlc_token(VlcClass.AC, 0, 0x00, 1, 1)
    with pytest.raises(ValueError):
        encode_vlc_token(VlcClass.AC, 0, 0x10, 0, 0)
    with pytest.raises(ValueError):
        encode_vlc_token(VlcClass.AC, 0, 0x0B, 0, 11)

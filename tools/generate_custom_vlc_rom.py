#!/usr/bin/env python3
"""Generate compact initialized ROMs from the codec's canonical JPEG tables."""

from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jpeg_radio_codec as core


def encode_word(code: int, length: int) -> int:
    if not 1 <= length <= 16 or code >= (1 << length):
        raise ValueError("invalid canonical Huffman entry")
    return (1 << 21) | (length << 16) | code


def main() -> None:
    output_dir = Path(__file__).resolve().parents[1] / "fpga" / "rtl" / "custom"
    dc = [0] * 32
    ac = [0] * 512
    for table_id in (0, 1):
        for symbol, (code, length) in core.HUFFMAN_ENCODE[(0, table_id)].items():
            dc[(table_id << 4) | symbol] = encode_word(code, length)
        for symbol, (code, length) in core.HUFFMAN_ENCODE[(1, table_id)].items():
            ac[(table_id << 8) | symbol] = encode_word(code, length)
    (output_dir / "custom_vlc_dc_table.hex").write_text(
        "".join(f"{word:06x}\n" for word in dc)
    )
    (output_dir / "custom_vlc_ac_table.hex").write_text(
        "".join(f"{word:06x}\n" for word in ac)
    )


if __name__ == "__main__":
    main()

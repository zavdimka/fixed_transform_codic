#!/usr/bin/env python3
"""Generate an exact one-multiply quantizer ROM for Q20 and Q24."""

from __future__ import annotations

from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jpeg_radio_codec as core

MAX_NUMERATOR = 32768 + 255 // 2
MAX_MULTIPLIER = (1 << 16) - 1


def exact_magic(divisor: int) -> tuple[int, int]:
    """Return shift,multiplier with floor(n*m/2**s)==floor(n/d)."""
    for shift in range(8, 31):
        base = (1 << shift) // divisor
        for multiplier in range(max(1, base - 2), base + 4):
            if multiplier > MAX_MULTIPLIER:
                continue
            if all(
                (numerator * multiplier >> shift) == numerator // divisor
                for numerator in range(MAX_NUMERATOR + 1)
            ):
                return shift, multiplier
    raise ValueError(f"no 16-bit exact multiplier for divisor {divisor}")


def layered_table(quality: int, chroma: bool) -> np.ndarray:
    luma, chroma_table = core.quant_tables(quality)
    fine_luma, fine_chroma = core.quant_tables(min(100, quality + 2))
    table = (chroma_table if chroma else luma).copy()
    fine = fine_chroma if chroma else fine_luma
    base_count = 3 if chroma else 6
    for row, column in core.ZIGZAG[:base_count]:
        table[row, column] = fine[row, column]
    return table.reshape(-1)


def main() -> None:
    cache: dict[int, tuple[int, int]] = {}
    words: list[int] = []
    for quality in (20, 24):
        for chroma in (False, True):
            table = layered_table(quality, chroma)
            for index in range(0, 64, 2):
                divisor0 = int(table[index])
                divisor1 = int(table[index + 1])
                shift0, multiplier0 = cache.setdefault(
                    divisor0, exact_magic(divisor0)
                )
                shift1, multiplier1 = cache.setdefault(
                    divisor1, exact_magic(divisor1)
                )
                word = (
                    divisor0
                    | (divisor1 << 8)
                    | (multiplier0 << 16)
                    | (multiplier1 << 32)
                    | (shift0 << 48)
                    | (shift1 << 53)
                )
                words.append(word)
    if len(words) != 128:
        raise AssertionError(f"expected 128 pair entries, got {len(words)}")
    output = (
        Path(__file__).resolve().parents[1]
        / "fpga" / "rtl" / "custom" / "custom_quant_magic_pairs.hex"
    )
    output.write_text(
        "".join(f"{word:015x}\n" for word in words), encoding="ascii"
    )
    print(f"wrote {len(words)} exact pair entries to {output}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate the canonical AC symbol-order ROM used by the receiver decoder."""

from __future__ import annotations

import argparse
from pathlib import Path


def load_encoder_table(path: Path) -> list[int]:
    words = [int(line, 16) for line in path.read_text().split()]
    if len(words) != 512:
        raise ValueError(f"{path} contains {len(words)} words, expected 512")
    return words


def generate(words: list[int]) -> list[int]:
    output: list[int] = []
    for table_id in range(2):
        entries: list[tuple[int, int, int]] = []
        for symbol, word in enumerate(words[table_id * 256:(table_id + 1) * 256]):
            if (word >> 21) & 1:
                entries.append(((word >> 16) & 0x1F, word & 0xFFFF, symbol))
        entries.sort()
        if len(entries) > 256:
            raise ValueError("AC decode table exceeds one 256-byte bank")
        output.extend(symbol for _, _, symbol in entries)
        output.extend([0] * (256 - len(entries)))
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--encoder-table",
        type=Path,
        default=Path("rtl/custom/custom_vlc_ac_table.hex"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("rtl/receiver/receiver_vlc_ac_decode_symbols.hex"),
    )
    args = parser.parse_args()
    values = generate(load_encoder_table(args.encoder_table))
    args.output.write_text("".join(f"{value:02x}\n" for value in values))


if __name__ == "__main__":
    main()

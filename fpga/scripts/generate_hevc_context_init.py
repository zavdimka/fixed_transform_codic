#!/usr/bin/env python3
"""Generate the compile-time HEVC CABAC initValue ROM image."""

from __future__ import annotations

import argparse
from pathlib import Path

from hevc_reference.cabac import (
    CABAC_INIT_B,
    CABAC_INIT_I,
    CABAC_INIT_P,
    cabac_context_init_values,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    rows = tuple(
        cabac_context_init_values(slice_type)
        for slice_type in (CABAC_INIT_B, CABAC_INIT_P, CABAC_INIT_I)
    )
    if tuple(map(len, rows)) != (192, 192, 192):
        raise RuntimeError("CABAC ROM row must contain 192 contexts")
    image = tuple(value for row in rows for value in row)
    args.output.write_text(" ".join(f"{value:02x}" for value in image) + "\n")
    print(f"rows={len(rows)} contexts_per_row={len(rows[0])} total={len(image)}")


if __name__ == "__main__":
    main()

from __future__ import annotations

from collections.abc import Sequence


DIAGONAL_SCAN_4 = (0, 4, 1, 8, 5, 2, 12, 9, 6, 3, 13, 10, 7, 14, 11, 15)


def diagonal_scan_addresses_16() -> tuple[int, ...]:
    """Return the HEVC TU16 diagonal coefficient scan as raster addresses."""
    addresses: list[int] = []
    for group_raster in DIAGONAL_SCAN_4:
        group_x = group_raster & 3
        group_y = group_raster >> 2
        for local_raster in DIAGONAL_SCAN_4:
            local_x = local_raster & 3
            local_y = local_raster >> 2
            x = (group_x << 2) | local_x
            y = (group_y << 2) | local_y
            addresses.append((y << 4) | x)
    return tuple(addresses)


DIAGONAL_SCAN_16 = diagonal_scan_addresses_16()


def scan_coefficients_16(
    coefficients: Sequence[Sequence[int]],
) -> tuple[int, ...]:
    if len(coefficients) != 16 or any(len(row) != 16 for row in coefficients):
        raise ValueError("TU16 coefficient block must be 16x16")
    return tuple(coefficients[address >> 4][address & 15]
                 for address in DIAGONAL_SCAN_16)


def coefficient_scan_metadata_16(
    coefficients: Sequence[Sequence[int]],
) -> tuple[tuple[bool, ...], int | None]:
    """Return raster-indexed significant-group flags and last scan position."""
    scanned = scan_coefficients_16(coefficients)
    group_nonzero = [False] * 16
    last_nonzero: int | None = None
    for scan_position, coefficient in enumerate(scanned):
        if coefficient:
            group_raster = DIAGONAL_SCAN_4[scan_position >> 4]
            group_nonzero[group_raster] = True
            last_nonzero = scan_position
    return tuple(group_nonzero), last_nonzero

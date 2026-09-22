from __future__ import annotations

import random

from bounded_iht_codec import (
    forward_block,
    inverse_dequantized_block,
    inverse_block,
    quantize_sparse_block,
    reconstruct_sparse_block,
)


def test_unquantized_transform_round_trip_is_nearly_lossless() -> None:
    rng = random.Random(0x8A264)
    for _ in range(100):
        source = [[rng.randrange(-128, 128) for _ in range(8)]
                  for _ in range(8)]
        coefficients = forward_block(source)
        reconstructed = inverse_dequantized_block(coefficients)
        assert max(abs(reconstructed[r][c] - source[r][c])
                   for r in range(8) for c in range(8)) <= 1


def test_sparse_quantizer_obeys_bounds_and_fpga_width() -> None:
    source = [[127 if (row + column) & 1 else -128
               for column in range(8)] for row in range(8)]
    encoded = quantize_sparse_block(source, quant_shift=1, max_ac=12)
    assert sum(address != 0 for address, _ in encoded.events) <= 12
    assert len({address for address, _ in encoded.events}) == len(encoded.events)
    assert all(-2048 <= value <= 2047 for _, value in encoded.events)
    assert reconstruct_sparse_block(encoded) == inverse_block(
        encoded.events, encoded.quant_shift)


def test_sparse_selection_retains_detail_better_than_dc_only() -> None:
    rng = random.Random(77)
    source = [[rng.randrange(-96, 97) for _ in range(8)] for _ in range(8)]
    encoded = quantize_sparse_block(source, quant_shift=0, max_ac=12)
    reconstructed = reconstruct_sparse_block(encoded)
    dc_events = tuple(event for event in encoded.events if event[0] == 0)
    dc_only = inverse_block(dc_events, encoded.quant_shift)

    def squared_error(candidate):
        return sum((candidate[r][c] - source[r][c]) ** 2
                   for r in range(8) for c in range(8))

    assert squared_error(reconstructed) < squared_error(dc_only)

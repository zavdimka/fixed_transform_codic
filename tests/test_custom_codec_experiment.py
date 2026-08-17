from __future__ import annotations

import numpy as np

import custom_codec_experiment as codec
import jpeg_radio_codec as core


def test_layered_tile_roundtrip_and_enhancement_drop() -> None:
    x = np.arange(64, dtype=np.uint16)[None, :]
    y = np.arange(64, dtype=np.uint16)[:, None]
    luma = ((3 * x + 2 * y + ((x // 8) ^ (y // 8)) * 12) & 255).astype(np.uint8)
    cb = np.full((32, 32), 112, dtype=np.uint8)
    cr = np.full((32, 32), 148, dtype=np.uint8)

    record = codec.encode_tile(
        luma, cb, cr, 24, 0, 0, core.ArithmeticStats()
    )
    base, full = codec.decode_tile(
        record, 24, core.ArithmeticStats(), enhancement=True
    )
    base_only, no_enhancement = codec.decode_tile(
        record, 24, core.ArithmeticStats(), enhancement=False
    )

    assert record.base_bits > 0
    assert record.enhancement_bits > 0
    assert all(np.array_equal(a, b) for a, b in zip(base, base_only))
    assert all(np.array_equal(a, b) for a, b in zip(base_only, no_enhancement))
    assert any(not np.array_equal(a, b) for a, b in zip(base, full))


def test_default_frame_model_has_bounded_stream() -> None:
    yy, xx = np.indices((64, 64), dtype=np.uint16)
    rgb = np.stack(
        ((xx * 3 + yy) & 255, (xx + yy * 2) & 255, (xx * 2 + yy * 3) & 255),
        axis=2,
    ).astype(np.uint8)
    result = codec.simulate(rgb)

    assert result.full_rgb.shape == rgb.shape
    assert result.base_rgb.shape == rgb.shape
    assert len(result.records) == 1
    assert result.total_bits > result.base_bits > 0
    assert result.saturations == 0

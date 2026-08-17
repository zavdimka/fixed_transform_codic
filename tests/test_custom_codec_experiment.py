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
    assert len(result.records) == 4
    assert all(record.width == 64 for record in result.records)
    assert all(len(record.coarse_data) == 8 for record in result.records)
    assert result.total_bits > result.base_bits > 0
    assert result.saturations == 0


def test_stripe_coarse_summary_survives_primary_loss() -> None:
    yy, xx = np.indices((16, 128), dtype=np.uint16)
    luma = ((xx * 2 + yy * 5) & 255).astype(np.uint8)
    cb = (((xx[:8, :64] // 2) + 96) & 255).astype(np.uint8)
    cr = np.full((8, 64), 144, dtype=np.uint8)
    record = codec.encode_stripe(
        luma, cb, cr, 24, 0, core.ArithmeticStats(),
        local_prediction=True,
        mode_dependent_scan=True,
        target_bpp=0.49,
    )
    base, full = codec.decode_stripe(
        record, 24, core.ArithmeticStats(), enhancement=True
    )
    coarse = codec.decode_coarse_stripe(record.coarse_data, 128)

    assert len(record.coarse_data) == 16
    assert base[0].shape == full[0].shape == coarse[0].shape == (16, 128)
    assert coarse[1].shape == coarse[2].shape == (8, 64)
    assert np.unique(coarse[0]).size > 2


def test_esp_packet_carries_next_stripe_coarse_copy() -> None:
    yy, xx = np.indices((32, 64), dtype=np.uint16)
    rgb = np.stack(
        ((xx * 3 + yy) & 255, (xx + yy * 4) & 255, (xx * 2 + yy) & 255),
        axis=2,
    ).astype(np.uint8)
    result = codec.simulate(rgb)
    packets = codec.build_esp_packets(result.records)

    assert len(packets) == 2
    assert packets[0].backup_stripe_y == packets[1].primary.stripe_y
    assert packets[0].backup_coarse_data == packets[1].primary.coarse_data
    assert packets[1].backup_stripe_y is None
    assert packets[1].backup_coarse_data == b""

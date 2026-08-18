from __future__ import annotations

from pathlib import Path

import numpy as np

import custom_codec_experiment as codec
import jpeg_radio_codec as core


def test_rtl_q20_q24_quant_roms_match_python_tables() -> None:
    rtl = Path(__file__).parents[1] / "fpga" / "rtl" / "custom"
    divisor_words = [
        int(line, 16) for line in
        (rtl / "custom_quant_divisor_pairs.hex").read_text().splitlines()
    ]
    reciprocal_words = [
        int(line, 16) for line in
        (rtl / "custom_quant_reciprocal_pairs.hex").read_text().splitlines()
    ]
    expected_tables = []
    for quality in (20, 24):
        expected_tables.extend(codec.layered_quant_tables(quality))
    expected_divisors = []
    expected_reciprocals = []
    for table in expected_tables:
        values = [int(value) for value in table.reshape(-1)]
        for index in range(0, 64, 2):
            expected_divisors.append(values[index] | (values[index + 1] << 8))
            reciprocal_0 = (1 << 18) // values[index]
            reciprocal_1 = (1 << 18) // values[index + 1]
            expected_reciprocals.append(reciprocal_0 | (reciprocal_1 << 18))
    assert divisor_words == expected_divisors
    assert reciprocal_words == expected_reciprocals


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


def test_stripe_exports_six_raster_coefficient_blocks_per_ctu() -> None:
    yy, xx = np.indices((16, 32), dtype=np.uint16)
    luma = ((xx * 7 + yy * 3) & 255).astype(np.uint8)
    cb = ((xx[:8, :16] * 5 + yy[:8, :16]) & 255).astype(np.uint8)
    cr = np.full((8, 16), 137, dtype=np.uint8)
    trace: list[codec.QuantizedBlockTrace] = []
    residual_trace: list[codec.ResidualBlockTrace] = []
    modes: list[int] = []

    codec.encode_stripe(
        luma, cb, cr, 20, 0, core.ArithmeticStats(),
        trace_blocks=trace, trace_modes=modes,
        trace_residuals=residual_trace,
    )

    assert len(trace) == 12
    assert len(residual_trace) == 12
    assert len(modes) == 2
    assert all(0 <= mode < (1 << core.INTRA_MODE_BITS) for mode in modes)
    assert [block.table_id for block in trace] == [0, 0, 0, 0, 1, 1] * 2
    assert [block.base_count for block in trace] == [6, 6, 6, 6, 3, 3] * 2
    assert all(len(block.coefficients) == 64 for block in trace)
    assert all(-2048 <= value <= 2047 for block in trace for value in block.coefficients)
    assert [block.table_id for block in residual_trace] == [
        block.table_id for block in trace
    ]
    assert all(len(block.samples) == 64 for block in residual_trace)
    assert all(
        -255 <= value <= 255
        for block in residual_trace for value in block.samples
    )


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


def test_bounded_stripe_truncates_cleanly_and_is_deterministic() -> None:
    rng = np.random.default_rng(0xB0DDED)
    luma = rng.integers(0, 256, (16, 128), dtype=np.uint8)
    cb = rng.integers(0, 256, (8, 64), dtype=np.uint8)
    cr = rng.integers(0, 256, (8, 64), dtype=np.uint8)

    records = [
        codec.encode_stripe(
            luma, cb, cr, 20, 0, core.ArithmeticStats(),
            base_max_bytes=150, enhancement_max_bytes=24,
        )
        for _ in range(2)
    ]
    first, second = records

    assert len(first.base_data) <= 150
    assert len(first.enhancement_data) <= 24
    assert first.base_truncated_blocks + first.enhancement_truncated_blocks > 0
    assert first.base_data == second.base_data
    assert first.enhancement_data == second.enhancement_data
    assert first.base_bits == second.base_bits
    assert first.enhancement_bits == second.enhancement_bits
    codec.decode_stripe(first, 20, core.ArithmeticStats(), enhancement=True)


def test_full_width_noise_never_exceeds_production_limits() -> None:
    rng = np.random.default_rng(0x128016)
    luma = rng.integers(0, 256, (16, 1280), dtype=np.uint8)
    cb = rng.integers(0, 256, (8, 640), dtype=np.uint8)
    cr = rng.integers(0, 256, (8, 640), dtype=np.uint8)

    record = codec.encode_stripe(
        luma, cb, cr, 20, 0, core.ArithmeticStats(),
        base_max_bytes=2048, enhancement_max_bytes=1536,
    )
    assert len(record.base_data) <= 2048
    assert len(record.enhancement_data) <= 1536
    assert record.base_truncated_blocks + record.enhancement_truncated_blocks > 0
    codec.decode_stripe(record, 20, core.ArithmeticStats(), enhancement=True)


def test_impossible_mandatory_budget_is_rejected_before_encoding() -> None:
    luma = np.zeros((16, 128), dtype=np.uint8)
    cb = np.zeros((8, 64), dtype=np.uint8)
    cr = np.zeros((8, 64), dtype=np.uint8)
    try:
        codec.encode_stripe(
            luma, cb, cr, 20, 0, core.ArithmeticStats(),
            base_max_bytes=149, enhancement_max_bytes=24,
        )
    except ValueError as error:
        assert "reservation exceeds" in str(error)
    else:
        raise AssertionError("impossible mandatory budget was accepted")

from __future__ import annotations

import random

from custom_budget_writer import Layer
from custom_coefficient_scanner import SyntaxOpType, scan_quantized_block
from custom_fixed_vlc import VlcClass, encode_vlc_token


def test_all_zero_luma_uses_presence_zero_without_eob() -> None:
    operations = scan_quantized_block([0] * 64, table_id=0, base_count=6)

    assert [operation.op_type for operation in operations] == [
        SyntaxOpType.VLC,
        SyntaxOpType.RAW,
        SyntaxOpType.SEGMENT_END,
        SyntaxOpType.RAW,
        SyntaxOpType.SEGMENT_END,
    ]
    assert operations[1].raw_value == operations[3].raw_value == 0
    assert not operations[2].eob_required
    assert not operations[4].eob_required
    assert operations[-1].last


def test_long_zero_run_generates_zrl_then_atomic_ac() -> None:
    coefficients = [0] * 64
    coefficients[63] = -5
    operations = scan_quantized_block(coefficients, table_id=1, base_count=3)
    enhancement = [op for op in operations if op.layer is Layer.ENHANCEMENT]
    vlc = [op for op in enhancement if op.op_type is SyntaxOpType.VLC]

    assert [op.symbol for op in vlc[:-1]] == [0xF0, 0xF0, 0xF0]
    assert vlc[-1].symbol == 0xC3
    assert vlc[-1].amplitude_length == 3
    assert vlc[-1].amplitude == 2
    assert not enhancement[-1].eob_required


def test_random_descriptors_are_accepted_by_fixed_vlc_model() -> None:
    rng = random.Random(0x5CA88E2)
    for table_id, base_count in ((0, 6), (1, 3)):
        for _ in range(100):
            coefficients = [rng.randrange(-1400, 1401) if rng.random() < 0.2 else 0 for _ in range(64)]
            for operation in scan_quantized_block(coefficients, table_id, base_count):
                if operation.op_type is not SyntaxOpType.VLC:
                    continue
                token = encode_vlc_token(
                    operation.table_class,
                    operation.table_id,
                    operation.symbol,
                    operation.amplitude,
                    operation.amplitude_length,
                )
                assert 1 <= token.bit_length <= 32


def test_dc_and_ac_clamps_match_codec_limits() -> None:
    coefficients = [0] * 64
    coefficients[0] = -2048
    coefficients[1] = 1800
    operations = scan_quantized_block(coefficients, table_id=0, base_count=6)
    dc = operations[0]
    ac = next(
        op for op in operations
        if op.op_type is SyntaxOpType.VLC and op.table_class is VlcClass.AC
    )
    assert dc.symbol == dc.amplitude_length == 11
    assert dc.amplitude == 0
    assert ac.symbol & 15 == ac.amplitude_length == 10


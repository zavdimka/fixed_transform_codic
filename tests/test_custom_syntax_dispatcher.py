from __future__ import annotations

import random

from custom_budget_writer import Layer
from custom_coefficient_scanner import SyntaxOp, SyntaxOpType, scan_quantized_block
from custom_fixed_vlc import VlcClass, encode_vlc_token
from custom_syntax_dispatcher import (
    dispatch_syntax_operation,
    dispatch_syntax_operations,
)


def test_natural_segment_end_releases_reserve_without_bits() -> None:
    operation = SyntaxOp(
        SyntaxOpType.SEGMENT_END,
        Layer.ENHANCEMENT,
        True,
        reserve_release=4,
        table_id=0,
        eob_required=False,
        last=True,
    )
    token = dispatch_syntax_operation(operation)
    assert token.bit_length == 0
    assert token.value == 0
    assert token.reserve_release == 4
    assert token.mandatory


def test_required_eob_uses_selected_ac_table() -> None:
    for table_id, reserve in ((0, 4), (1, 2)):
        operation = SyntaxOp(
            SyntaxOpType.SEGMENT_END,
            Layer.BASE,
            True,
            reserve_release=reserve,
            table_id=table_id,
            eob_required=True,
        )
        token = dispatch_syntax_operation(operation)
        expected = encode_vlc_token(VlcClass.AC, table_id, 0x00)
        assert (token.value, token.bit_length) == (
            expected.bits,
            expected.bit_length,
        )


def test_random_scanned_blocks_dispatch_to_valid_atomic_tokens() -> None:
    rng = random.Random(0xD15A7C4)
    for table_id, base_count in ((0, 6), (1, 3)):
        for _ in range(100):
            coefficients = [
                rng.randrange(-1500, 1501) if rng.random() < 0.2 else 0
                for _ in range(64)
            ]
            operations = scan_quantized_block(coefficients, table_id, base_count)
            tokens = dispatch_syntax_operations(operations)
            assert len(tokens) == len(operations)
            assert all(0 <= token.bit_length <= 32 for token in tokens)
            assert all(
                token.mandatory or token.reserve_release == 0
                for token in tokens
            )

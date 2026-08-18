"""Golden conversion from scanner syntax operations to budget tokens."""

from __future__ import annotations

from custom_budget_writer import BudgetToken
from custom_coefficient_scanner import SyntaxOp, SyntaxOpType
from custom_fixed_vlc import VlcClass, encode_vlc_token
from custom_token_byte_packer import left_align_token


def dispatch_syntax_operation(operation: SyntaxOp) -> BudgetToken:
    """Convert one ordered scanner operation into one atomic budget token."""
    if operation.op_type is SyntaxOpType.VLC:
        encoded = encode_vlc_token(
            operation.table_class,
            operation.table_id,
            operation.symbol,
            operation.amplitude,
            operation.amplitude_length,
        )
        value, bit_length = encoded.bits, encoded.bit_length
    elif operation.op_type is SyntaxOpType.RAW:
        if operation.raw_length != 1 or operation.raw_value not in (0, 1):
            raise ValueError("the hardware dispatcher supports one raw bit")
        value = left_align_token(operation.raw_value, operation.raw_length)
        bit_length = operation.raw_length
    elif operation.op_type is SyntaxOpType.SEGMENT_END:
        if operation.eob_required:
            encoded = encode_vlc_token(
                VlcClass.AC, operation.table_id, 0x00, 0, 0
            )
            value, bit_length = encoded.bits, encoded.bit_length
        else:
            value, bit_length = 0, 0
    else:
        raise ValueError("unknown scanner operation")

    return BudgetToken(
        operation.layer,
        value,
        bit_length,
        operation.mandatory,
        operation.reserve_release,
    )


def dispatch_syntax_operations(operations: list[SyntaxOp]) -> list[BudgetToken]:
    return [dispatch_syntax_operation(operation) for operation in operations]

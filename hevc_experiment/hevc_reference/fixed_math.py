"""Small integer operations with explicit FPGA-compatible width semantics."""

from __future__ import annotations

from collections.abc import Iterable


def signed_limits(bits: int) -> tuple[int, int]:
    if bits < 1:
        raise ValueError("signed width must be positive")
    return -(1 << (bits - 1)), (1 << (bits - 1)) - 1


def saturate_signed(value: int, bits: int) -> int:
    low, high = signed_limits(bits)
    return min(high, max(low, value))


def wrap_signed(value: int, bits: int) -> int:
    """Return the two's-complement result of truncating to ``bits``."""

    if bits < 1:
        raise ValueError("signed width must be positive")
    mask = (1 << bits) - 1
    value &= mask
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def biased_round_shift(value: int, shift: int, bias: int | None = None) -> int:
    """Compute ``(value + bias) >> shift`` using arithmetic right shift.

    HEVC stages use different normative offsets, so callers may pass the exact
    offset. Negative ties follow the directly implementable RTL expression.
    """

    if shift < 0:
        raise ValueError("shift must be non-negative")
    if shift == 0:
        if bias not in (None, 0):
            raise ValueError("a zero shift cannot have a non-zero bias")
        return value
    actual_bias = 1 << (shift - 1) if bias is None else bias
    return (value + actual_bias) >> shift


def dot_product(values: Iterable[int], coefficients: Iterable[int]) -> int:
    """Unbounded reference accumulator; width is applied at the call site."""

    left, right = tuple(values), tuple(coefficients)
    if len(left) != len(right):
        raise ValueError("dot-product operands have different lengths")
    return sum(value * coefficient for value, coefficient in zip(left, right))

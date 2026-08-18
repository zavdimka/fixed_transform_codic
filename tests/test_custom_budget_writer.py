from __future__ import annotations

from custom_budget_writer import Admission, BudgetToken, DualBudgetWriter, Layer


def test_optional_token_is_atomic_and_preserves_mandatory_tail() -> None:
    writer = DualBudgetWriter(24, 24, base_reserved_bits=8)

    assert writer.submit(BudgetToken(Layer.BASE, 0xAAA, 12)) is Admission.ACCEPTED
    assert writer.submit(BudgetToken(Layer.BASE, 0x1F, 5)) is Admission.DROPPED
    assert writer.used == [12, 0]
    assert writer.reserved == [8, 0]
    assert writer.submit(
        BudgetToken(Layer.BASE, 0x5A, 8, mandatory=True, reserve_release=8)
    ) is Admission.ACCEPTED
    assert writer.finish() == (20, 0)


def test_shorter_mandatory_token_reclaims_reserved_slack() -> None:
    writer = DualBudgetWriter(20, 20, base_reserved_bits=10)

    assert writer.submit(
        BudgetToken(Layer.BASE, 0b101, 3, mandatory=True, reserve_release=10)
    ) is Admission.ACCEPTED
    assert writer.submit(BudgetToken(Layer.BASE, 0x1FFFF, 17)) is Admission.ACCEPTED
    assert writer.finish() == (20, 0)


def test_layers_are_accounted_independently() -> None:
    writer = DualBudgetWriter(8, 12)

    assert writer.submit(BudgetToken(Layer.BASE, 0xFF, 8)) is Admission.ACCEPTED
    assert writer.submit(BudgetToken(Layer.BASE, 1, 1)) is Admission.DROPPED
    assert writer.submit(BudgetToken(Layer.ENHANCEMENT, 0xABC, 12)) is Admission.ACCEPTED
    assert writer.used == [8, 12]
    assert writer.dropped == [1, 0]


def test_drop_suppresses_rest_of_layer_segment_until_mandatory_tail() -> None:
    writer = DualBudgetWriter(16, 16, base_reserved_bits=4)

    assert writer.submit(BudgetToken(Layer.BASE, 0xFFF, 12)) is Admission.ACCEPTED
    assert writer.submit(BudgetToken(Layer.BASE, 1, 1)) is Admission.DROPPED
    # This token would fit, but its run is relative to a coefficient that the
    # decoder did not receive.
    assert writer.submit(BudgetToken(Layer.BASE, 0, 0)) is Admission.DROPPED
    assert writer.submit(
        BudgetToken(Layer.BASE, 0, 0, mandatory=True, reserve_release=4)
    ) is Admission.ACCEPTED
    assert not writer.discard_optional[0]


def test_mandatory_overflow_is_fatal_without_changing_counters() -> None:
    writer = DualBudgetWriter(8, 8, base_reserved_bits=4)

    assert writer.submit(BudgetToken(Layer.BASE, 0x7F, 7)) is Admission.DROPPED
    assert writer.submit(
        BudgetToken(Layer.BASE, 0x1F, 5, mandatory=True, reserve_release=4)
    ) is Admission.ACCEPTED
    assert writer.submit(BudgetToken(Layer.BASE, 0xF, 4, mandatory=True)) is Admission.FATAL
    assert writer.used == [5, 0]
    assert writer.fatal


def test_invalid_reservation_operations_are_fatal() -> None:
    writer = DualBudgetWriter(32, 32, base_reserved_bits=4)
    assert writer.submit(
        BudgetToken(Layer.BASE, 1, 1, reserve_release=1)
    ) is Admission.FATAL
    assert writer.used == [0, 0]


def test_zero_length_mandatory_token_only_releases_reserve() -> None:
    writer = DualBudgetWriter(16, 16, base_reserved_bits=4)
    assert writer.submit(
        BudgetToken(Layer.BASE, 0, 0, mandatory=True, reserve_release=4)
    ) is Admission.ACCEPTED
    assert writer.finish() == (0, 0)
    assert writer.accepted == []

    writer = DualBudgetWriter(32, 32, base_reserved_bits=4)
    assert writer.submit(
        BudgetToken(Layer.BASE, 1, 1, mandatory=True, reserve_release=5)
    ) is Admission.FATAL
    assert writer.used == [0, 0]

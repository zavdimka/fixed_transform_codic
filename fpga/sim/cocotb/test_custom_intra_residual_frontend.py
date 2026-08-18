from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

INTRA_DC = 0
INTRA_HORIZONTAL = 2


def intra_predictors(left: np.ndarray | None, size: int):
    if left is None:
        return {INTRA_DC: np.full((size, size), 128, dtype=np.int16)}
    dc = (int(left.astype(np.int64).sum()) + size // 2) // size
    return {
        INTRA_DC: np.full((size, size), dc, dtype=np.int16),
        INTRA_HORIZONTAL: np.repeat(
            left.astype(np.int16)[:, None], size, axis=1
        ),
    }


def residual_satd(residual: np.ndarray) -> int:
    total = 0
    source = residual.astype(np.int64)
    for y0 in range(0, source.shape[0], 4):
        for x0 in range(0, source.shape[1], 4):
            block = source[y0:y0 + 4, x0:x0 + 4]
            horizontal = np.empty((4, 4), dtype=np.int64)
            for row in range(4):
                a0 = int(block[row, 0]) + int(block[row, 3])
                a1 = int(block[row, 1]) + int(block[row, 2])
                a2 = int(block[row, 1]) - int(block[row, 2])
                a3 = int(block[row, 0]) - int(block[row, 3])
                horizontal[row] = (a0 + a1, a3 + a2, a0 - a1, a3 - a2)
            for column in range(4):
                a0 = int(horizontal[0, column]) + int(horizontal[3, column])
                a1 = int(horizontal[1, column]) + int(horizontal[2, column])
                a2 = int(horizontal[1, column]) - int(horizontal[2, column])
                a3 = int(horizontal[0, column]) - int(horizontal[3, column])
                total += (
                    abs(a0 + a1) + abs(a3 + a2)
                    + abs(a0 - a1) + abs(a3 - a2)
                )
    return total


def pack_bytes(values) -> int:
    packed = 0
    for index, value in enumerate(values):
        packed |= int(value) << (8 * index)
    return packed


def unpack_signed16(packed: int, count: int = 8) -> list[int]:
    result = []
    for index in range(count):
        value = (packed >> (16 * index)) & 0xFFFF
        result.append(value - 0x10000 if value & 0x8000 else value)
    return result


def expected_ctu(y, cb, cr, left_y, left_cb, left_cr):
    has_left = left_y is not None
    y_predictors = intra_predictors(left_y, 16)
    cb_predictors = intra_predictors(left_cb, 8)
    cr_predictors = intra_predictors(left_cr, 8)
    candidates = sorted(y_predictors)
    costs = {
        mode: (
            residual_satd(y.astype(np.int16) - y_predictors[mode])
            + residual_satd(cb.astype(np.int16) - cb_predictors[mode])
            + residual_satd(cr.astype(np.int16) - cr_predictors[mode])
        )
        for mode in candidates
    }
    mode = min(candidates, key=lambda candidate: (costs[candidate], candidate))
    y_residual = y.astype(np.int16) - y_predictors[mode]
    cb_residual = cb.astype(np.int16) - cb_predictors[mode]
    cr_residual = cr.astype(np.int16) - cr_predictors[mode]
    pairs = (
        (y_residual[:8, :8], y_residual[:8, 8:]),
        (y_residual[8:, :8], y_residual[8:, 8:]),
        (cb_residual, cr_residual),
    )
    return mode, costs[INTRA_DC], (
        costs[INTRA_HORIZONTAL] if has_left else 0
    ), pairs


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.has_left.value = 0
    dut.left_y.value = 0
    dut.left_cb.value = 0
    dut.left_cr.value = 0
    dut.s_valid.value = 0
    dut.s_row.value = 0
    dut.prefix_ready.value = 0
    dut.command_ready.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_ctu(
    dut, y, cb, cr, left_y, left_cb, left_cr, seed, stalls=True
):
    expected_mode, expected_dc, expected_horizontal, expected_pairs = expected_ctu(
        y, cb, cr, left_y, left_cb, left_cr
    )
    rng = random.Random(seed)
    dut.has_left.value = int(left_y is not None)
    dut.left_y.value = pack_bytes(left_y if left_y is not None else np.zeros(16))
    dut.left_cb.value = pack_bytes(left_cb if left_cb is not None else np.zeros(8))
    dut.left_cr.value = pack_bytes(left_cr if left_cr is not None else np.zeros(8))
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0

    rows = [pack_bytes(row) for row in y]
    rows += [pack_bytes(row) for row in cb]
    rows += [pack_bytes(row) for row in cr]
    input_index = 0
    prefix_seen = False
    commands = []
    output_rows = [[], [], []]
    active_pair = None
    held = None
    done_seen = False

    for _cycle in range(2000):
        offer_input = input_index < len(rows) and (
            not stalls or rng.randrange(4) != 0
        )
        dut.s_valid.value = offer_input
        if offer_input:
            dut.s_row.value = rows[input_index]
        dut.prefix_ready.value = not stalls or rng.randrange(3) != 0
        dut.command_ready.value = not stalls or rng.randrange(3) != 0
        dut.m_ready.value = not stalls or rng.randrange(4) != 0

        await Timer(1, units="ns")
        input_fire = offer_input and bool(int(dut.s_ready.value))
        prefix_fire = int(dut.prefix_valid.value) and int(dut.prefix_ready.value)
        command_fire = int(dut.command_valid.value) and int(dut.command_ready.value)
        current = None
        if int(dut.m_valid.value):
            current = (
                int(dut.m_row_a.value), int(dut.m_row_b.value),
                int(dut.m_last.value),
            )
        if held is not None:
            assert current == held
        output_fire = current is not None and int(dut.m_ready.value)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if input_fire:
            input_index += 1
        if prefix_fire:
            assert not prefix_seen
            assert int(dut.prefix_mode.value) == expected_mode
            prefix_seen = True
        if command_fire:
            active_pair = int(dut.command_pair.value)
            commands.append(active_pair)
        if output_fire:
            assert active_pair is not None
            output_rows[active_pair].append((
                unpack_signed16(current[0]), unpack_signed16(current[1])
            ))
            if current[2]:
                assert len(output_rows[active_pair]) == 8
                active_pair = None
        held = current if current is not None and not output_fire else None
        if int(dut.done.value):
            done_seen = True
            break
    else:
        raise AssertionError("intra residual frontend timed out")

    assert done_seen
    assert input_index == 32
    assert prefix_seen
    assert commands == [0, 1, 2]
    assert int(dut.dc_satd.value) == expected_dc
    assert int(dut.horizontal_satd.value) == expected_horizontal
    assert not int(dut.protocol_error.value)
    for pair_index, (expected_a, expected_b) in enumerate(expected_pairs):
        actual_a = np.asarray([row[0] for row in output_rows[pair_index]])
        actual_b = np.asarray([row[1] for row in output_rows[pair_index]])
        np.testing.assert_array_equal(actual_a, expected_a)
        np.testing.assert_array_equal(actual_b, expected_b)
    return _cycle + 1


@cocotb.test()
async def dc_horizontal_mode_and_residual_rows_match_python(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    sample_rng = np.random.default_rng(0xC7F00D)

    # Stripe-left CTU: no reference, so only the DC=128 candidate is legal.
    y = sample_rng.integers(0, 256, (16, 16), dtype=np.uint8)
    cb = sample_rng.integers(0, 256, (8, 8), dtype=np.uint8)
    cr = sample_rng.integers(0, 256, (8, 8), dtype=np.uint8)
    dc_cycles = await run_ctu(
        dut, y, cb, cr, None, None, None, 0x10, stalls=False
    )

    # A strong row-wise continuation must select horizontal prediction.
    left_y = sample_rng.integers(16, 240, 16, dtype=np.uint8)
    left_cb = sample_rng.integers(16, 240, 8, dtype=np.uint8)
    left_cr = sample_rng.integers(16, 240, 8, dtype=np.uint8)
    y = np.repeat(left_y[:, None], 16, axis=1)
    cb = np.repeat(left_cb[:, None], 8, axis=1)
    cr = np.repeat(left_cr[:, None], 8, axis=1)
    horizontal_cycles = await run_ctu(
        dut, y, cb, cr, left_y, left_cb, left_cr, 0x20, stalls=False
    )
    dut._log.info(
        "frontend cycles without stalls: edge DC=%d, two-mode=%d",
        dc_cycles, horizontal_cycles,
    )

    # Random references/source cover a non-directed cost comparison and ties.
    for index in range(4):
        y = sample_rng.integers(0, 256, (16, 16), dtype=np.uint8)
        cb = sample_rng.integers(0, 256, (8, 8), dtype=np.uint8)
        cr = sample_rng.integers(0, 256, (8, 8), dtype=np.uint8)
        left_y = sample_rng.integers(0, 256, 16, dtype=np.uint8)
        left_cb = sample_rng.integers(0, 256, 8, dtype=np.uint8)
        left_cr = sample_rng.integers(0, 256, 8, dtype=np.uint8)
        await run_ctu(
            dut, y, cb, cr, left_y, left_cb, left_cr, 0x30 + index
        )

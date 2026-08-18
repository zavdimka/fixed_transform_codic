from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from custom_budget_writer import Admission, BudgetToken, DualBudgetWriter, Layer
from custom_coefficient_scanner import scan_quantized_block
from custom_syntax_dispatcher import dispatch_syntax_operations
from custom_token_byte_packer import TokenBytePacker, left_align_token
from test_custom_dct8_pair32 import pack_row


BASE_LIMIT_BITS = 2048 * 8
ENHANCEMENT_LIMIT_BITS = 1536 * 8
BASE_RESERVED_BITS = 12000
ENHANCEMENT_RESERVED_BITS = 1920


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.finish_valid.value = 0
    dut.prefix_valid.value = 0
    dut.prefix_mode.value = 0
    dut.command_valid.value = 0
    dut.command_quality24.value = 0
    dut.s_valid.value = 0
    dut.s_row_a.value = 0
    dut.s_row_b.value = 0
    dut.m_ready.value = 1
    dut.base_limit_bits.value = BASE_LIMIT_BITS
    dut.enhancement_limit_bits.value = ENHANCEMENT_LIMIT_BITS
    dut.base_reserved_bits.value = BASE_RESERVED_BITS
    dut.enhancement_reserved_bits.value = ENHANCEMENT_RESERVED_BITS
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def expected_stripe(coefficients: np.ndarray, modes: np.ndarray):
    guard = DualBudgetWriter(
        BASE_LIMIT_BITS, ENHANCEMENT_LIMIT_BITS,
        BASE_RESERVED_BITS, ENHANCEMENT_RESERVED_BITS,
    )
    drops = 0
    for ctu, mode in zip(coefficients, modes, strict=True):
        assert guard.submit(BudgetToken(
            Layer.BASE, left_align_token(int(mode), 2), 2, True, 2
        )) is Admission.ACCEPTED
        for block_index, block in enumerate(ctu):
            table_id = int(block_index >= 4)
            base_count = 3 if table_id else 6
            operations = scan_quantized_block(
                [int(value) for value in block], table_id, base_count
            )
            for token in dispatch_syntax_operations(operations):
                drops += guard.submit(token) is Admission.DROPPED
    guard.finish()
    packer = TokenBytePacker()
    for token in guard.accepted:
        packer.submit(token.layer, token.value, token.bit_length)
    packer.finish()
    return (
        [(int(item.layer), item.value) for item in packer.output],
        drops,
        guard,
        packer,
    )


async def start_stripe(dut, quality24: int) -> None:
    dut.command_quality24.value = quality24
    dut.start_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = bool(int(dut.start_ready.value))
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if fire:
            dut.start_valid.value = 0
            return


async def replay_stripe(dut, residuals, coefficients, modes):
    expected, expected_drops, guard, packer = expected_stripe(
        coefficients, modes
    )
    ctu_count = residuals.shape[0]
    ctu_index = 0
    prefix_accepted = False
    pair_index = 0
    feeding_pair = None
    row = 0
    row_offered = False
    finish_offered = False
    finish_accepted = False
    observed = []
    drops = 0
    completions = []

    for cycle in range(100000):
        if ctu_index < ctu_count and not prefix_accepted:
            dut.prefix_mode.value = int(modes[ctu_index])
            dut.prefix_valid.value = 1
        else:
            dut.prefix_valid.value = 0

        if (
            ctu_index < ctu_count and prefix_accepted
            and feeding_pair is None and pair_index < 3
        ):
            dut.command_valid.value = 1
        else:
            dut.command_valid.value = 0

        if feeding_pair is not None and not row_offered:
            block_a = residuals[ctu_index, 2 * feeding_pair]
            block_b = residuals[ctu_index, 2 * feeding_pair + 1]
            dut.s_row_a.value = pack_row(block_a[row])
            dut.s_row_b.value = pack_row(block_b[row])
            dut.s_valid.value = 1
            row_offered = True

        if ctu_index == ctu_count and not finish_offered and not finish_accepted:
            dut.finish_valid.value = 1
            finish_offered = True

        await Timer(1, units="ns")
        prefix_fire = (
            ctu_index < ctu_count and not prefix_accepted
            and bool(int(dut.prefix_ready.value))
        )
        command_fire = (
            ctu_index < ctu_count and prefix_accepted
            and feeding_pair is None and pair_index < 3
            and bool(int(dut.command_ready.value))
        )
        row_fire = row_offered and bool(int(dut.s_ready.value))
        finish_fire = finish_offered and bool(int(dut.finish_ready.value))
        if int(dut.m_valid.value):
            observed.append((int(dut.m_layer.value), int(dut.m_byte.value)))

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if prefix_fire:
            prefix_accepted = True
            dut.prefix_valid.value = 0
        if command_fire:
            feeding_pair = pair_index
            pair_index += 1
            row = 0
            dut.command_valid.value = 0
        if row_fire:
            row += 1
            row_offered = False
            dut.s_valid.value = 0
            if row == 8:
                feeding_pair = None
        if int(dut.drop_pulse.value):
            drops += 1
        if int(dut.ctu_done.value):
            completions.append(cycle + 1)
            ctu_index += 1
            prefix_accepted = False
            pair_index = 0
        if finish_fire:
            finish_offered = False
            finish_accepted = True
            dut.finish_valid.value = 0
        if finish_accepted and int(dut.finish_done.value):
            stripe_cycles = cycle + 1
            break
    else:
        raise AssertionError("real residual stripe timed out")

    assert len(completions) == ctu_count
    assert observed == expected
    assert drops == expected_drops == 0
    assert not int(dut.fatal_error.value)
    assert not int(dut.coefficient_saturated.value)
    assert int(dut.base_used_bits.value) == guard.used[0]
    assert int(dut.enhancement_used_bits.value) == guard.used[1]
    assert int(dut.base_byte_count.value) == packer.byte_count[0]
    assert int(dut.enhancement_byte_count.value) == packer.byte_count[1]
    assert not int(dut.busy.value)
    intervals = [completions[0], *(
        current - previous
        for previous, current in zip(completions, completions[1:])
    )]
    return intervals, stripe_cycles, len(observed)


@cocotb.test()
async def q20_q24_real_720p_residual_intervals(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    trace_path = Path(os.environ["CUSTOM_SCHEDULER_TRACE_FILE"])
    qualities = tuple(
        int(value) for value in
        os.environ.get("CUSTOM_TRACE_QUALITIES", "20,24").split(",")
    )

    with np.load(trace_path) as trace:
        assert int(trace["width"]) == 1280
        assert int(trace["height"]) == 720
        for quality in qualities:
            prefix = f"q{quality}"
            residuals = trace[f"{prefix}_residuals"]
            coefficients = trace[f"{prefix}_coefficients"]
            modes = trace[f"{prefix}_modes"]
            assert residuals.shape == (45, 80, 6, 8, 8)
            intervals = []
            stripe_cycles = []
            total_bytes = 0
            for stripe in range(45):
                await start_stripe(dut, int(quality == 24))
                measured, cycles, byte_count = await replay_stripe(
                    dut, residuals[stripe], coefficients[stripe], modes[stripe]
                )
                intervals.extend(measured)
                stripe_cycles.append(cycles)
                total_bytes += byte_count

            average = float(np.mean(intervals))
            p95 = int(np.percentile(intervals, 95, method="higher"))
            worst = max(intervals)
            effective = float(sum(stripe_cycles) / len(intervals))
            worst_stripe = float(max(stripe_cycles) / 80)
            dut._log.info(
                "Q%d real residual CTU cycles: avg=%.2f p95=%d worst=%d "
                "effective=%.2f worst_stripe=%.2f bytes=%d",
                quality, average, p95, worst, effective, worst_stripe,
                total_bytes,
            )
            assert len(intervals) == 3600
            assert p95 <= 648
            assert total_bytes > 0

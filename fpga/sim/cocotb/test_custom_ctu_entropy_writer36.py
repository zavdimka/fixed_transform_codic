from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from custom_budget_writer import Admission, BudgetToken, DualBudgetWriter, Layer
from custom_coefficient_scanner import scan_quantized_block
from custom_syntax_dispatcher import dispatch_syntax_operations
from custom_token_byte_packer import TokenBytePacker, left_align_token
from test_custom_dct8_pair32 import pack_row
from test_custom_dct_quant_bank_bridge36 import quantized


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.finish_valid.value = 0
    dut.prefix_valid.value = 0
    dut.prefix_mode.value = 0
    dut.command_valid.value = 0
    dut.command_quality24.value = 1
    dut.s_valid.value = 0
    dut.s_row_a.value = 0
    dut.s_row_b.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def expected_stream(pairs, mode, limits, reserves, quality24):
    guard = DualBudgetWriter(*limits, *reserves)
    assert guard.submit(BudgetToken(
        Layer.BASE, left_align_token(mode, 2), 2, True, 2
    )) is Admission.ACCEPTED
    drops = 0
    for pair_index, (block_a, block_b) in enumerate(pairs):
        table_id = int(pair_index == 2)
        base_count = 3 if table_id else 6
        for block in (block_a, block_b):
            coefficients = quantized(block, quality24, table_id)
            operations = scan_quantized_block(
                coefficients, table_id, base_count
            )
            for token in dispatch_syntax_operations(operations):
                drops += guard.submit(token) is Admission.DROPPED
    guard.finish()
    assert not guard.fatal

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


@cocotb.test()
async def residual_pairs_match_python_bytes_with_stalls(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    sample_rng = np.random.default_rng(0xC7E36)
    pairs = tuple(
        (
            sample_rng.integers(-255, 256, (8, 8), dtype=np.int16),
            sample_rng.integers(-255, 256, (8, 8), dtype=np.int16),
        )
        for _ in range(3)
    )
    mode = 2
    limits = (520, 400)
    reserves = (150, 24)
    expected, expected_drops, guard, packer = expected_stream(
        pairs, mode, limits, reserves, 1
    )
    assert expected_drops > 0

    dut.base_limit_bits.value, dut.enhancement_limit_bits.value = limits
    dut.base_reserved_bits.value, dut.enhancement_reserved_bits.value = reserves
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0

    dut.prefix_mode.value = mode
    dut.prefix_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = bool(int(dut.prefix_ready.value))
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if fire:
            dut.prefix_valid.value = 0
            break

    rng = random.Random(0xC7E36)
    command_pair = 0
    feeding_pair = None
    row = 0
    row_offered = False
    finish_active = False
    observed = []
    drops = 0
    transform_count = 0
    block_count = 0
    pair_count = 0
    held = None

    for _ in range(10000):
        if feeding_pair is None and command_pair < 3:
            dut.command_valid.value = 1
        else:
            dut.command_valid.value = 0

        if feeding_pair is not None and not row_offered and rng.random() < 0.86:
            block_a, block_b = pairs[feeding_pair]
            dut.s_row_a.value = pack_row(block_a[row])
            dut.s_row_b.value = pack_row(block_b[row])
            dut.s_valid.value = 1
            row_offered = True

        if pair_count == 3 and not finish_active:
            dut.finish_valid.value = 1
            finish_active = True
        dut.m_ready.value = int(rng.random() < 0.63)

        await Timer(1, units="ns")
        command_fire = (
            feeding_pair is None
            and command_pair < 3
            and bool(int(dut.command_ready.value))
        )
        row_fire = row_offered and bool(int(dut.s_ready.value))
        finish_fire = finish_active and bool(int(dut.finish_ready.value))
        current = None
        if int(dut.m_valid.value):
            current = (int(dut.m_layer.value), int(dut.m_byte.value))
        if held is not None:
            assert current == held
        output_fire = current is not None and bool(int(dut.m_ready.value))
        if output_fire:
            observed.append(current)
        held = current if current is not None and not output_fire else None

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if command_fire:
            feeding_pair = command_pair
            command_pair += 1
            row = 0
            dut.command_valid.value = 0
        if row_fire:
            row += 1
            row_offered = False
            dut.s_valid.value = 0
            if row == 8:
                feeding_pair = None
        if finish_fire:
            finish_active = False
            dut.finish_valid.value = 0
        transform_count += int(dut.transform_done.value)
        block_count += int(dut.block_done.value)
        pair_count += int(dut.pair_done.value)
        drops += int(dut.drop_pulse.value)
        if int(dut.finish_done.value):
            break
    else:
        raise AssertionError("residual-to-byte CTU timed out")

    assert transform_count == 3
    assert block_count == 6
    assert pair_count == 3
    assert observed == expected
    assert drops == expected_drops
    assert not int(dut.fatal_error.value)
    assert not int(dut.coefficient_saturated.value)
    assert int(dut.base_used_bits.value) == guard.used[0]
    assert int(dut.enhancement_used_bits.value) == guard.used[1]
    assert int(dut.base_byte_count.value) == packer.byte_count[0]
    assert int(dut.enhancement_byte_count.value) == packer.byte_count[1]
    assert not int(dut.busy.value)

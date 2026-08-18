from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_budget_writer import Admission, DualBudgetWriter
from custom_coefficient_scanner import scan_quantized_block
from custom_syntax_dispatcher import dispatch_syntax_operations
from custom_token_byte_packer import TokenBytePacker


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.finish_valid.value = 0
    dut.block_valid.value = 0
    dut.block_table_id.value = 0
    dut.block_base_count.value = 6
    dut.coefficient_valid.value = 0
    dut.coefficient.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def make_blocks() -> list[tuple[list[int], int, int]]:
    rng = random.Random(0xB10C8)
    blocks: list[tuple[list[int], int, int]] = []
    for index in range(6):
        table_id = int(index >= 4)
        base_count = 3 if table_id else 6
        coefficients = [
            rng.randrange(-900, 901) if rng.random() < 0.24 else 0
            for _ in range(64)
        ]
        coefficients[0] = rng.randrange(-400, 401)
        if index == 0:
            coefficients = [0] * 64
        if index == 5:
            coefficients[63] = -5
        blocks.append((coefficients, table_id, base_count))
    return blocks


@cocotb.test()
async def six_blocks_match_python_with_tight_budgets(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    blocks = make_blocks()
    limits = (520, 400)
    reserves = (148, 24)
    guard = DualBudgetWriter(*limits, *reserves)
    expected_drops = 0
    for coefficients, table_id, base_count in blocks:
        operations = scan_quantized_block(coefficients, table_id, base_count)
        for token in dispatch_syntax_operations(operations):
            expected_drops += guard.submit(token) is Admission.DROPPED
    guard.finish()
    assert not guard.fatal
    assert expected_drops > 0

    packer = TokenBytePacker()
    for token in guard.accepted:
        packer.submit(token.layer, token.value, token.bit_length)
    packer.finish()
    expected_bytes = [(int(item.layer), item.value) for item in packer.output]

    dut.base_limit_bits.value, dut.enhancement_limit_bits.value = limits
    dut.base_reserved_bits.value, dut.enhancement_reserved_bits.value = reserves
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0

    block_index = 0
    coefficient_index = 0
    block_active = False
    block_started = False
    coefficient_active = False
    finish_active = False
    observed_bytes: list[tuple[int, int]] = []
    observed_drops = 0
    maximum_fifo_level = 0
    stalled_output = None
    rng = random.Random(0x51A6B10C)

    for _ in range(100000):
        if block_index < len(blocks) and not block_active and not block_started:
            coefficients, table_id, base_count = blocks[block_index]
            dut.block_table_id.value = table_id
            dut.block_base_count.value = base_count
            dut.block_valid.value = 1
            block_active = True

        if (block_index < len(blocks) and block_started
                and coefficient_index < 64
                and not coefficient_active and rng.random() < 0.8):
            coefficients = blocks[block_index][0]
            dut.coefficient.value = coefficients[coefficient_index] & 0xFFF
            dut.coefficient_valid.value = 1
            coefficient_active = True

        if block_index == len(blocks) and not finish_active:
            dut.finish_valid.value = 1
            finish_active = True

        dut.m_ready.value = int(rng.random() < 0.58)
        await Timer(1, units="ns")
        maximum_fifo_level = max(
            maximum_fifo_level, int(dut.token_fifo_level.value)
        )

        current_output = None
        if int(dut.m_valid.value):
            current_output = (int(dut.m_layer.value), int(dut.m_byte.value))
        if stalled_output is not None:
            assert current_output == stalled_output

        block_fire = block_active and bool(int(dut.block_ready.value))
        coefficient_fire = coefficient_active and bool(
            int(dut.coefficient_ready.value)
        )
        finish_fire = finish_active and bool(int(dut.finish_ready.value))
        output_fire = current_output is not None and bool(int(dut.m_ready.value))
        stalled_output = (
            current_output if current_output is not None and not output_fire else None
        )
        if output_fire:
            observed_bytes.append(current_output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if int(dut.drop_pulse.value):
            observed_drops += 1
        if block_fire:
            block_active = False
            block_started = True
            dut.block_valid.value = 0
        if coefficient_fire:
            coefficient_index += 1
            coefficient_active = False
            dut.coefficient_valid.value = 0
        if int(dut.block_done.value):
            assert coefficient_index == 64
            block_index += 1
            coefficient_index = 0
            block_started = False
        if finish_fire:
            finish_active = False
            dut.finish_valid.value = 0
        if int(dut.finish_done.value):
            break
    else:
        raise AssertionError("block entropy writer timed out")

    assert not int(dut.fatal_error.value)
    assert not int(dut.coefficient_saturated.value)
    assert observed_drops == expected_drops
    assert maximum_fifo_level >= 2
    assert observed_bytes == expected_bytes
    assert int(dut.base_used_bits.value) == guard.used[0]
    assert int(dut.enhancement_used_bits.value) == guard.used[1]
    assert int(dut.base_byte_count.value) == packer.byte_count[0]
    assert int(dut.enhancement_byte_count.value) == packer.byte_count[1]
    assert not int(dut.busy.value)


@cocotb.test()
async def invalid_block_error_remains_sticky_until_next_stripe(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.base_limit_bits.value = 128
    dut.enhancement_limit_bits.value = 128
    dut.base_reserved_bits.value = 0
    dut.enhancement_reserved_bits.value = 0

    dut.start_valid.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0

    dut.block_base_count.value = 1
    dut.block_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.block_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.block_valid.value = 0
    assert int(dut.fatal_error.value)

    for _ in range(4):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert int(dut.fatal_error.value)

    dut.finish_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.finish_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.finish_valid.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.finish_done.value):
            break
    assert int(dut.fatal_error.value)

    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0
    assert not int(dut.fatal_error.value)

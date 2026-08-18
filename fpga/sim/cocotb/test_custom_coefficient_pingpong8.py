from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_coefficient_scanner import scan_quantized_block


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.clear_error.value = 0
    dut.block_valid.value = 0
    dut.block_table_id.value = 0
    dut.block_base_count.value = 6
    dut.s_valid.value = 0
    dut.s_coefficient.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def operation_tuple(operation) -> tuple[int, ...]:
    return (
        int(operation.op_type),
        int(operation.layer),
        int(operation.mandatory),
        operation.reserve_release,
        int(operation.table_class),
        operation.table_id,
        operation.symbol,
        operation.amplitude,
        operation.amplitude_length,
        operation.raw_value,
        operation.raw_length,
        int(operation.eob_required),
        int(operation.last),
    )


def dut_operation(dut) -> tuple[int, ...]:
    return (
        int(dut.m_op_type.value),
        int(dut.m_layer.value),
        int(dut.m_mandatory.value),
        int(dut.m_reserve_release.value),
        int(dut.m_table_class.value),
        int(dut.m_table_id.value),
        int(dut.m_symbol.value),
        int(dut.m_amplitude.value),
        int(dut.m_amplitude_length.value),
        int(dut.m_raw_value.value),
        int(dut.m_raw_length.value),
        int(dut.m_eob_required.value),
        int(dut.m_last.value),
    )


async def run_blocks(
    dut,
    blocks: list[tuple[list[int], int, int]],
    seed: int,
    source_probability: float,
    ready_probability: float,
) -> tuple[list[tuple[int, ...]], int]:
    rng = random.Random(seed)
    next_block = 0
    feeding_block: int | None = None
    coefficient_index = 0
    block_active = False
    coefficient_active = False
    completed = 0
    observed: list[tuple[int, ...]] = []
    stalled_output = None

    for cycle in range(20000):
        if (feeding_block is None and next_block < len(blocks)
                and not block_active):
            _, table_id, base_count = blocks[next_block]
            dut.block_table_id.value = table_id
            dut.block_base_count.value = base_count
            dut.block_valid.value = 1
            block_active = True

        if (feeding_block is not None and not coefficient_active
                and coefficient_index < 64
                and rng.random() < source_probability):
            coefficients = blocks[feeding_block][0]
            dut.s_coefficient.value = coefficients[coefficient_index] & 0xFFF
            dut.s_valid.value = 1
            coefficient_active = True

        dut.m_ready.value = int(rng.random() < ready_probability)
        await Timer(1, units="ns")

        current = dut_operation(dut) if int(dut.m_valid.value) else None
        if stalled_output is not None:
            assert current == stalled_output
        block_fire = block_active and bool(int(dut.block_ready.value))
        coefficient_fire = coefficient_active and bool(int(dut.s_ready.value))
        output_fire = current is not None and bool(int(dut.m_ready.value))
        stalled_output = current if current is not None and not output_fire else None
        if output_fire:
            observed.append(current)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if block_fire:
            feeding_block = next_block
            next_block += 1
            coefficient_index = 0
            block_active = False
            dut.block_valid.value = 0
        if coefficient_fire:
            coefficient_index += 1
            coefficient_active = False
            dut.s_valid.value = 0
            if coefficient_index == 64:
                feeding_block = None
        if int(dut.block_done.value):
            completed += 1
        if completed == len(blocks) and not int(dut.busy.value):
            return observed, cycle + 1
    raise AssertionError("coefficient ping-pong scheduler timed out")


@cocotb.test()
async def ordered_blocks_match_python_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x2BAA8)
    blocks = []
    for index in range(6):
        table_id = index & 1
        base_count = 3 if table_id else 6
        coefficients = [
            rng.randrange(-1300, 1301) if rng.random() < 0.2 else 0
            for _ in range(64)
        ]
        blocks.append((coefficients, table_id, base_count))

    actual, _ = await run_blocks(dut, blocks, 0x0D3E2, 0.78, 0.61)
    expected = [
        operation_tuple(operation)
        for coefficients, table_id, base_count in blocks
        for operation in scan_quantized_block(coefficients, table_id, base_count)
    ]
    assert actual == expected
    assert int(dut.coefficient_saturated.value)
    assert not int(dut.input_error.value)


@cocotb.test()
async def two_dense_luma_blocks_overlap_one_load_phase(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dense = [1 if index & 1 else -1 for index in range(64)]
    blocks = [(dense, 0, 6), (dense, 0, 6)]

    actual, cycles = await run_blocks(dut, blocks, 0xFA57, 1.0, 1.0)
    expected = [
        operation_tuple(operation)
        for coefficients, table_id, base_count in blocks
        for operation in scan_quantized_block(coefficients, table_id, base_count)
    ]
    assert actual == expected
    assert cycles <= 456
    assert cycles < 2 * 258

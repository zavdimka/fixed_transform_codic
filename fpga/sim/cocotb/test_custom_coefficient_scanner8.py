from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_coefficient_scanner import scan_quantized_block


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.clear_error.value = 0
    dut.start_valid.value = 0
    dut.table_id.value = 0
    dut.base_count.value = 6
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


def assert_operations_match(actual, expected) -> None:
    if actual == expected:
        return
    shared_length = min(len(actual), len(expected))
    for index in range(shared_length):
        if actual[index] != expected[index]:
            raise AssertionError(
                f"operation {index} differs: actual={actual[index]}, "
                f"expected={expected[index]}; lengths={len(actual)}/{len(expected)}"
            )
    raise AssertionError(
        f"operation count differs: actual={len(actual)}, expected={len(expected)}; "
        f"tail={actual[shared_length:] or expected[shared_length:]}"
    )


async def scan_block(
    dut,
    coefficients: list[int],
    table_id: int,
    base_count: int,
    seed: int,
    source_probability: float = 0.8,
    ready_probability: float = 0.65,
) -> tuple[list[tuple[int, ...]], bool, int]:
    rng = random.Random(seed)
    dut.table_id.value = table_id
    dut.base_count.value = base_count
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0

    source_index = 0
    source_active = False
    observed: list[tuple[int, ...]] = []
    stalled = None

    for cycle in range(10000):
        if (not source_active and source_index < 64
                and rng.random() < source_probability):
            dut.s_coefficient.value = coefficients[source_index] & 0xFFF
            dut.s_valid.value = 1
            source_active = True
        dut.m_ready.value = int(rng.random() < ready_probability)
        await Timer(1, units="ns")

        current = dut_operation(dut) if int(dut.m_valid.value) else None
        if stalled is not None:
            assert current == stalled
        input_fire = source_active and bool(int(dut.s_ready.value))
        output_fire = current is not None and bool(int(dut.m_ready.value))
        stalled = current if current is not None and not output_fire else None
        if output_fire:
            observed.append(current)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if input_fire:
            source_index += 1
            source_active = False
            dut.s_valid.value = 0
        if int(dut.done.value):
            assert source_index == 64
            assert not int(dut.busy.value)
            return observed, bool(int(dut.coefficient_saturated.value)), cycle + 1
    raise AssertionError("coefficient scanner timed out")


@cocotb.test()
async def directed_zero_and_long_run_blocks_match_python(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    blocks = []
    blocks.append(([0] * 64, 0, 6))
    long_run = [0] * 64
    long_run[63] = -5
    blocks.append((long_run, 1, 3))
    for index, (coefficients, table_id, base_count) in enumerate(blocks):
        actual, saturated, _ = await scan_block(
            dut, coefficients, table_id, base_count, 0xD1EC7 + index
        )
        expected = [
            operation_tuple(operation)
            for operation in scan_quantized_block(coefficients, table_id, base_count)
        ]
        assert_operations_match(actual, expected)
        assert not saturated
        assert not int(dut.input_error.value)


@cocotb.test()
async def randomized_blocks_match_python_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x8C4A)

    for block_index in range(30):
        table_id = block_index & 1
        base_count = 6 if table_id == 0 else 3
        coefficients = [
            rng.randrange(-1500, 1501) if rng.random() < 0.22 else 0
            for _ in range(64)
        ]
        actual, saturated, _ = await scan_block(
            dut, coefficients, table_id, base_count, 0x5000 + block_index
        )
        expected = [
            operation_tuple(operation)
            for operation in scan_quantized_block(coefficients, table_id, base_count)
        ]
        assert_operations_match(actual, expected)
        expected_saturation = coefficients[0] == -2048 or any(
            value > 1023 or value < -1023 for value in coefficients[1:]
        )
        assert saturated == expected_saturation
        assert not int(dut.input_error.value)


@cocotb.test()
async def dense_blocks_meet_single_buffer_cycle_bound(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    # Loading remains one coefficient per cycle.  During emission the block
    # RAM output is explicitly registered, adding one cycle for each of the
    # 63 scanned AC positions and isolating RAM clock-to-output from run logic.
    for table_id, base_count, expected_cycles in ((0, 6, 322), (1, 3, 320)):
        coefficients = [1 if index & 1 else -1 for index in range(64)]
        actual, saturated, cycles = await scan_block(
            dut,
            coefficients,
            table_id,
            base_count,
            0xC1C1E + table_id,
            source_probability=1.0,
            ready_probability=1.0,
        )
        expected = [
            operation_tuple(operation)
            for operation in scan_quantized_block(coefficients, table_id, base_count)
        ]
        assert_operations_match(actual, expected)
        assert cycles == expected_cycles
        assert not saturated


@cocotb.test()
async def invalid_base_split_is_rejected(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.base_count.value = 1
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0
    assert int(dut.input_error.value)
    assert not int(dut.busy.value)
    assert not int(dut.s_ready.value)


@cocotb.test()
async def idle_clear_removes_previous_block_saturation(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    coefficients = [0] * 64
    coefficients[1] = 1500
    _, saturated, _ = await scan_block(
        dut, coefficients, 0, 6, 0x5A7, 1.0, 1.0
    )
    assert saturated
    dut.clear_error.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.clear_error.value = 0
    assert not int(dut.coefficient_saturated.value)

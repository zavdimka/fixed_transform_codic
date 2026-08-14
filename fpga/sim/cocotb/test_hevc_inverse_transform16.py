from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.transform import inverse_transform_16


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(
    dut,
    coefficients: list[list[int]],
    rng: random.Random,
    input_probability: float = 0.85,
    ready_probability: float = 0.7,
) -> tuple[list[tuple[int, int, int, bool]], int]:
    _, residual = inverse_transform_16(coefficients)
    expected = [
        (residual[y][x], x, y, x == 15 and y == 15)
        for y in range(16) for x in range(16)
    ]

    source = [
        coefficients[y][x]
        for x in range(16) for y in range(16)
    ]
    source_index = 0
    received: list[tuple[int, int, int, bool]] = []
    stalled_output: tuple[int, int, int, bool] | None = None
    first_input_cycle: int | None = None
    final_output_cycle: int | None = None

    for cycle in range(20000):
        if not int(dut.s_valid.value) and source_index < 256:
            if rng.random() < input_probability:
                dut.s_coefficient.value = source[source_index]
                dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < ready_probability)
        await RisingEdge(dut.clk)

        output = (
            dut.m_residual.value.signed_integer,
            int(dut.m_x.value),
            int(dut.m_y.value),
            bool(dut.m_block_last.value),
        )
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        if stalled_output is not None:
            assert output_valid == 1
            assert output == stalled_output
        stalled_output = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output)
            if len(received) == 256:
                final_output_cycle = cycle

        if int(dut.s_valid.value) and int(dut.s_ready.value):
            if first_input_cycle is None:
                first_input_cycle = cycle
            source_index += 1
            if source_index < 256 and rng.random() < input_probability:
                dut.s_coefficient.value = source[source_index]
                dut.s_valid.value = 1
            else:
                dut.s_valid.value = 0

        if final_output_cycle is not None:
            break
    else:
        raise AssertionError("inverse transform16 stream timed out")

    assert received == expected
    assert sum(item[3] for item in received) == 1
    assert first_input_cycle is not None
    return received, final_output_cycle - first_input_cycle + 1


@cocotb.test()
async def inverse_transform_matches_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1DC716)
    coefficients = [
        [rng.randrange(-32768, 32768) for _ in range(16)]
        for _ in range(16)
    ]
    await run_block(dut, coefficients, rng)


@cocotb.test()
async def dc_only_coefficient_reconstructs_constant_residual(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    coefficients = [[0] * 16 for _ in range(16)]
    coefficients[0][0] = 128
    received, _ = await run_block(dut, coefficients, random.Random(0x1DC0))
    assert all(item[0] == 1 for item in received)


@cocotb.test()
async def continuous_block_latency_is_561_cycles(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    coefficients = [
        [((x * 193 + y * 317) % 65536) - 32768 for x in range(16)]
        for y in range(16)
    ]
    _, cycles = await run_block(
        dut, coefficients, random.Random(0x1561),
        input_probability=1.0, ready_probability=1.0,
    )
    assert cycles == 561

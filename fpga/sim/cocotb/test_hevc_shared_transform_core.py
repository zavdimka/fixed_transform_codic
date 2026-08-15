from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_tu8 import forward_transform_8, inverse_transform_8
from hevc_reference.transform import forward_transform_16, inverse_transform_16


async def reset(dut):
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_transform(dut, source, expected, size8, inverse, rng):
    size = 8 if size8 else 16
    dut.command_size8.value = size8
    dut.command_inverse.value = inverse
    dut.command_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = int(dut.command_valid.value) and int(dut.command_ready.value)
        await RisingEdge(dut.clk)
        if fire:
            break
    dut.command_valid.value = 0

    flat_source = [value for row in source for value in row]
    source_index = 0
    received = []
    stalled = None
    for _ in range(20000):
        if not int(dut.s_valid.value) and source_index < len(flat_source):
            dut.s_data.value = flat_source[source_index]
            dut.s_valid.value = int(rng.random() < 0.89)
        dut.m_ready.value = int(rng.random() < 0.72)
        await Timer(1, units="ns")
        input_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        output = (dut.m_data.value.signed_integer, int(dut.m_x.value),
                  int(dut.m_y.value), bool(dut.m_block_last.value))
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        if stalled is not None:
            assert output_valid and output == stalled
        stalled = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if input_fire:
            source_index += 1
            dut.s_valid.value = 0
        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            break
    else:
        raise AssertionError(f"shared transform timed out size={size} inverse={inverse}")

    expected_stream = [(expected[y][x], x, y,
                        x == size - 1 and y == size - 1)
                       for y in range(size) for x in range(size)]
    assert source_index == size * size
    assert received == expected_stream
    assert not int(dut.busy.value)


@cocotb.test()
async def all_sizes_and_directions_match_integer_reference(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x816D_C7)

    residual16 = [[rng.randrange(-255, 256) for _ in range(16)]
                  for _ in range(16)]
    coefficient16 = [[rng.randrange(-8192, 8193) for _ in range(16)]
                     for _ in range(16)]
    residual8 = [[rng.randrange(-255, 256) for _ in range(8)]
                 for _ in range(8)]
    coefficient8 = [[rng.randrange(-8192, 8193) for _ in range(8)]
                    for _ in range(8)]

    await run_transform(dut, residual16, forward_transform_16(residual16)[1],
                        False, False, rng)
    await run_transform(dut, coefficient16, inverse_transform_16(coefficient16)[1],
                        False, True, rng)
    await run_transform(dut, residual8, forward_transform_8(residual8)[1],
                        True, False, rng)
    await run_transform(dut, coefficient8, inverse_transform_8(coefficient8)[1],
                        True, True, rng)

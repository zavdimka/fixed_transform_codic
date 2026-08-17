from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_tu8 import forward_transform_8, inverse_transform_8


async def reset(dut):
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def source_order(block, inverse):
    if inverse:
        return [block[y][x] for x in range(8) for y in range(8)]
    return [block[y][x] for y in range(8) for x in range(8)]


async def run_pair(dut, blocks, expected, inverse, stalled):
    dut.command_inverse.value = inverse
    dut.command_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = int(dut.command_ready.value)
        await RisingEdge(dut.clk)
        if fire:
            break
    dut.command_valid.value = 0

    source = source_order(blocks[0], inverse) + source_order(blocks[1], inverse)
    source_index = 0
    received = []
    output_cycles = []
    held = None
    rng = random.Random(0x8C2F + int(inverse) * 17)
    for cycle in range(4000):
        if not int(dut.s_valid.value) and source_index < len(source):
            dut.s_data.value = source[source_index]
            dut.s_valid.value = 1 if not stalled else int(rng.random() < 0.83)
        dut.m_ready.value = 1 if not stalled else int(rng.random() < 0.71)
        await Timer(1, units="ns")
        input_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        output = (dut.m_data.value.signed_integer, int(dut.m_plane.value),
                  int(dut.m_x.value), int(dut.m_y.value),
                  bool(dut.m_block_last.value), bool(dut.m_pair_last.value))
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        if held is not None:
            assert output_valid and output == held
        held = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output)
            output_cycles.append(cycle)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if input_fire:
            source_index += 1
            if source_index == len(source):
                dut.s_valid.value = 0
            elif stalled:
                dut.s_valid.value = 0
            else:
                dut.s_data.value = source[source_index]
        if int(dut.done.value):
            break
    else:
        raise AssertionError("paired TU8 transform timed out")

    expected_stream = []
    for plane in range(2):
        expected_stream.extend(
            (expected[plane][y][x], plane, x, y, x == 7 and y == 7,
             plane == 1 and x == 7 and y == 7)
            for y in range(8) for x in range(8))
    assert source_index == 128
    assert received == expected_stream
    assert not int(dut.busy.value)
    if not stalled:
        assert output_cycles == list(range(output_cycles[0], output_cycles[0] + 128))
        span = output_cycles[-1] - output_cycles[0] + 1
        dut._log.info("paired TU8 inverse=%s latency=%d output_span=%d",
                      inverse, cycle + 1, span)
        return span, cycle + 1
    return None


@cocotb.test()
async def forward_and_inverse_pairs_are_bit_exact(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xCB8C)
    residuals = [[[rng.randrange(-255, 256) for _ in range(8)]
                  for _ in range(8)] for _ in range(2)]
    forward = [forward_transform_8(block)[1] for block in residuals]
    span, latency = await run_pair(dut, residuals, forward, False, False)
    assert span == 128
    assert latency <= 207

    coefficients = [[[rng.randrange(-8192, 8193) for _ in range(8)]
                     for _ in range(8)] for _ in range(2)]
    inverse = [inverse_transform_8(block)[1] for block in coefficients]
    span, latency = await run_pair(dut, coefficients, inverse, True, False)
    assert span == 128
    assert latency <= 207


@cocotb.test()
async def pair_survives_input_and_output_stalls(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    blocks = [[[((plane * 29 + x * 7 + y * 11) & 255) - 128
                for x in range(8)] for y in range(8)] for plane in range(2)]
    expected = [forward_transform_8(block)[1] for block in blocks]
    await run_pair(dut, blocks, expected, False, True)

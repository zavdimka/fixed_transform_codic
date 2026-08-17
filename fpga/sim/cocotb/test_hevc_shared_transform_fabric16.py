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


def source_order(block, inverse):
    size = len(block)
    if inverse:
        return [block[y][x] for x in range(size) for y in range(size)]
    return [block[y][x] for y in range(size) for x in range(size)]


async def run_command(dut, blocks, expected, inverse, stalled):
    pair8 = len(blocks) == 2
    size = 8 if pair8 else 16
    dut.command_pair8.value = pair8
    dut.command_inverse.value = inverse
    dut.command_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = int(dut.command_ready.value)
        await RisingEdge(dut.clk)
        if fire:
            break
    dut.command_valid.value = 0

    source = []
    for block in blocks:
        source.extend(source_order(block, inverse))
    source_index = 0
    received = []
    output_cycles = []
    held = None
    rng = random.Random(0xFAB16 + 31 * int(pair8) + 7 * int(inverse))
    for cycle in range(10000):
        if not int(dut.s_valid.value) and source_index < len(source):
            dut.s_data.value = source[source_index]
            dut.s_valid.value = 1 if not stalled else int(rng.random() < 0.84)
        dut.m_ready.value = 1 if not stalled else int(rng.random() < 0.73)
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
        raise AssertionError("shared transform fabric timed out")

    expected_stream = []
    for plane, block in enumerate(expected):
        expected_stream.extend(
            (block[y][x], plane, x, y, x == size - 1 and y == size - 1,
             (plane == len(expected) - 1 and
              x == size - 1 and y == size - 1))
            for y in range(size) for x in range(size))
    assert source_index == len(source)
    assert received == expected_stream
    assert not int(dut.busy.value)
    if not stalled:
        assert output_cycles == list(range(
            output_cycles[0], output_cycles[0] + len(expected_stream)))
        dut._log.info("fabric pair8=%s inverse=%s latency=%d span=%d",
                      pair8, inverse, cycle + 1, len(output_cycles))
        return cycle + 1


@cocotb.test()
async def all_four_datapath_modes_are_bit_exact(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x16FABC)

    residual16 = [[rng.randrange(-255, 256) for _ in range(16)]
                  for _ in range(16)]
    coefficients16 = [[rng.randrange(-8192, 8193) for _ in range(16)]
                      for _ in range(16)]
    residual8 = [[[rng.randrange(-255, 256) for _ in range(8)]
                  for _ in range(8)] for _ in range(2)]
    coefficients8 = [[[rng.randrange(-8192, 8193) for _ in range(8)]
                      for _ in range(8)] for _ in range(2)]

    assert await run_command(
        dut, [residual16], [forward_transform_16(residual16)[1]],
        False, False) <= 536
    assert await run_command(
        dut, [coefficients16], [inverse_transform_16(coefficients16)[1]],
        True, False) <= 536
    assert await run_command(
        dut, residual8, [forward_transform_8(b)[1] for b in residual8],
        False, False) <= 207
    assert await run_command(
        dut, coefficients8, [inverse_transform_8(b)[1] for b in coefficients8],
        True, False) <= 207


@cocotb.test()
async def luma_and_chroma_survive_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    block16 = [[((x * 23 + y * 17) & 255) - 128
                for x in range(16)] for y in range(16)]
    await run_command(dut, [block16], [forward_transform_16(block16)[1]],
                      False, True)
    blocks8 = [[[((p * 29 + x * 7 + y * 11) & 255) - 128
                 for x in range(8)] for y in range(8)] for p in range(2)]
    await run_command(dut, blocks8,
                      [forward_transform_8(b)[1] for b in blocks8],
                      False, True)

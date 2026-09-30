from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from test_receiver_sparse_base_idct8 import reference


async def reset_dut(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.pixel_ready.value = 1
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def send_commands(dut, vectors) -> None:
    for tag, (coefficients, quality, plane) in enumerate(vectors):
        packed = sum((value & 0xFFF) << (12 * index)
                     for index, value in enumerate(coefficients))
        while not int(dut.command_ready.value):
            await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.command_ctu_index.value = tag
        dut.command_block_index.value = tag % 6
        dut.command_plane.value = plane
        dut.command_mode.value = tag % 4
        dut.command_quality.value = quality
        dut.command_coefficients.value = packed
        dut.command_valid.value = 1
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.command_valid.value = 0


@cocotb.test()
async def dual_sparse_idct_overlaps_blocks_without_reordering(dut) -> None:
    await reset_dut(dut)
    rng = random.Random(0xD0A1)
    vectors = []
    for tag in range(20):
        plane = tag % 3
        count = 3 if plane else 6
        coefficients = [rng.randint(-700, 700) for _ in range(count)]
        coefficients += [0] * (6 - count)
        vectors.append((coefficients, 24 if tag & 1 else 20, plane))

    producer = cocotb.start_soon(send_commands(dut, vectors))
    observed = [[] for _ in vectors]
    cycles = 0
    while sum(len(block) for block in observed) < len(vectors) * 64:
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.pixel_valid.value) and int(dut.pixel_ready.value):
            tag = int(dut.pixel_ctu_index.value)
            assert 0 <= tag < len(vectors)
            expected_index = len(observed[tag])
            assert int(dut.pixel_index.value) == expected_index
            assert int(dut.pixel_block_index.value) == tag % 6
            assert int(dut.pixel_plane.value) == tag % 3
            assert int(dut.pixel_mode.value) == tag % 4
            observed[tag].append(dut.pixel_residual.value.signed_integer)
        assert cycles < 1500

    await producer
    for tag, (coefficients, quality, plane) in enumerate(vectors):
        assert observed[tag] == reference(coefficients, quality, plane)

    # 87 clocks for the first block, then one complete 64-pixel block per
    # 64 clocks. Keep a few clocks for testbench phase alignment.
    assert cycles <= 1330

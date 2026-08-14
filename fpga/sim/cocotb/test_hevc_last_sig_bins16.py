from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.syntax import last_significant_bins_16


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def encode_position(dut, address: int, rng: random.Random):
    dut.s_raster_address.value = address
    dut.s_valid.value = 1
    while True:
        dut.m_ready.value = int(rng.random() < 0.7)
        await RisingEdge(dut.clk)
        if int(dut.s_ready.value):
            dut.s_valid.value = 0
            break

    received = []
    stalled = None
    for _ in range(200):
        dut.m_ready.value = int(rng.random() < 0.7)
        await RisingEdge(dut.clk)
        output = (
            int(dut.m_bin.value), int(dut.m_bypass.value),
            int(dut.m_axis_y.value), int(dut.m_context_index.value),
            int(dut.m_syntax_last.value),
        )
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        if stalled is not None:
            assert valid == 1
            assert output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            received.append(output)
            if output[-1]:
                return received
    raise AssertionError("last-significant bin stream timed out")


@cocotb.test()
async def all_tu16_positions_match_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1A57516)
    for address in range(256):
        received = await encode_position(dut, address, rng)
        expected = [
            (event.value, int(event.bypass), int(event.axis_y),
             event.context_index, int(event.syntax_last))
            for event in last_significant_bins_16(address)
        ]
        assert received == expected, f"last-significant mismatch at {address:#04x}"


@cocotb.test()
async def shortest_and_longest_codes_have_expected_lengths(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(4)
    shortest = await encode_position(dut, 0x00, rng)
    longest = await encode_position(dut, 0xFF, rng)
    assert shortest == [(0, 0, 0, 6, 0), (0, 0, 1, 6, 1)]
    assert len(longest) == 18
    assert sum(event[1] for event in longest) == 4

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.scan import DIAGONAL_SCAN_16
from hevc_reference.syntax import (
    SYNTAX_SOURCE_LAST,
    SYNTAX_SOURCE_LEVEL,
    SYNTAX_SOURCE_SIGNIFICANCE,
    coefficient_level_bins_16,
    coefficient_syntax_bins_16,
    last_significant_bins_16,
    significance_bins_16,
)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_start_valid.value = 0
    dut.s_last_valid.value = 0
    dut.s_significance_valid.value = 0
    dut.s_significance_done.value = 0
    dut.s_level_valid.value = 0
    dut.s_level_done.value = 0
    dut.s_last_bin.value = 0
    dut.s_last_bypass.value = 0
    dut.s_last_axis_y.value = 0
    dut.s_last_context_index.value = 0
    dut.s_last_syntax_last.value = 0
    dut.s_significance_bin.value = 0
    dut.s_significance_coded_sub_block.value = 0
    dut.s_significance_context_index.value = 0
    dut.s_significance_scan_position.value = 0
    dut.s_level_bin.value = 0
    dut.s_level_bypass.value = 0
    dut.s_level_kind.value = 0
    dut.s_level_context_index.value = 0
    dut.s_level_group_scan_position.value = 0
    dut.s_level_coefficient_index.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def event_tuple(event):
    return (
        event.value,
        int(event.bypass),
        event.source,
        event.level_kind,
        event.context_index,
        int(event.last_axis_y),
        int(event.significance_coded_sub_block),
        event.scan_position,
        event.group_scan_position,
        event.coefficient_index,
    )


async def run_block(dut, block, rng):
    combined = coefficient_syntax_bins_16(block)
    assert combined
    last_position = max(
        position
        for position, address in enumerate(DIAGONAL_SCAN_16)
        if block[address >> 4][address & 15]
    )
    last = list(last_significant_bins_16(DIAGONAL_SCAN_16[last_position]))
    significance = list(significance_bins_16(block))
    levels = list(coefficient_level_bins_16(block))
    indexes = [0, 0, 0]
    start_accepted = False
    significance_done_sent = False
    level_done_sent = False
    received = []
    stalled = None

    dut.s_start_valid.value = 1
    for _ in range(100000):
        dut.s_significance_done.value = 0
        dut.s_level_done.value = 0

        if indexes[0] < len(last):
            event = last[indexes[0]]
            dut.s_last_valid.value = 1
            dut.s_last_bin.value = event.value
            dut.s_last_bypass.value = int(event.bypass)
            dut.s_last_axis_y.value = int(event.axis_y)
            dut.s_last_context_index.value = event.context_index
            dut.s_last_syntax_last.value = int(event.syntax_last)
        else:
            dut.s_last_valid.value = 0

        if indexes[1] < len(significance):
            event = significance[indexes[1]]
            dut.s_significance_valid.value = 1
            dut.s_significance_bin.value = event.value
            dut.s_significance_coded_sub_block.value = int(
                event.coded_sub_block
            )
            dut.s_significance_context_index.value = event.context_index
            dut.s_significance_scan_position.value = event.scan_position
        else:
            dut.s_significance_valid.value = 0

        if indexes[2] < len(levels):
            event = levels[indexes[2]]
            dut.s_level_valid.value = 1
            dut.s_level_bin.value = event.value
            dut.s_level_bypass.value = int(event.bypass)
            dut.s_level_kind.value = event.kind
            dut.s_level_context_index.value = event.context_index
            dut.s_level_group_scan_position.value = event.group_scan_position
            dut.s_level_coefficient_index.value = event.coefficient_index
        else:
            dut.s_level_valid.value = 0

        if (
            indexes[0] == len(last)
            and indexes[1] == len(significance)
            and not significance_done_sent
            and int(dut.s_last_ready.value) == 0
        ):
            dut.s_significance_done.value = 1
            significance_done_sent = True
        if (
            indexes[2] == len(levels)
            and significance_done_sent
            and not level_done_sent
            and int(dut.s_significance_ready.value) == 0
        ):
            dut.s_level_done.value = 1
            level_done_sent = True

        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)

        output = (
            int(dut.m_bin.value),
            int(dut.m_bypass.value),
            int(dut.m_source.value),
            int(dut.m_level_kind.value),
            int(dut.m_context_index.value),
            int(dut.m_last_axis_y.value),
            int(dut.m_significance_coded_sub_block.value),
            int(dut.m_scan_position.value),
            int(dut.m_group_scan_position.value),
            int(dut.m_coefficient_index.value),
        )
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        if stalled is not None:
            assert valid == 1
            assert output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            received.append(output)

        if int(dut.s_start_valid.value) and int(dut.s_start_ready.value):
            start_accepted = True
            dut.s_start_valid.value = 0
        if int(dut.s_last_valid.value) and int(dut.s_last_ready.value):
            indexes[0] += 1
        if (
            int(dut.s_significance_valid.value)
            and int(dut.s_significance_ready.value)
        ):
            indexes[1] += 1
        if int(dut.s_level_valid.value) and int(dut.s_level_ready.value):
            indexes[2] += 1

        if int(dut.block_done.value):
            assert start_accepted
            assert indexes == [len(last), len(significance), len(levels)]
            return received
    raise AssertionError("coefficient syntax arbitration timed out")


@cocotb.test()
async def ordered_sources_match_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xA8B17E2)

    blocks = []
    dc_only = [[0] * 16 for _ in range(16)]
    dc_only[0][0] = -1
    blocks.append(dc_only)

    for _ in range(25):
        block = [[0] * 16 for _ in range(16)]
        for _ in range(rng.randrange(1, 60)):
            position = rng.randrange(256)
            address = DIAGONAL_SCAN_16[position]
            value = rng.randrange(-32768, 32768) or 1
            block[address >> 4][address & 15] = value
        blocks.append(block)

    for block in blocks:
        received = await run_block(dut, block, rng)
        assert received == [
            event_tuple(event) for event in coefficient_syntax_bins_16(block)
        ]


@cocotb.test()
async def inactive_sources_are_not_consumed(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    block = [[0] * 16 for _ in range(16)]
    address = DIAGONAL_SCAN_16[71]
    block[address >> 4][address & 15] = 7
    received = await run_block(dut, block, random.Random(9))
    sources = [event[2] for event in received]
    assert sources == sorted(sources)
    assert sources[0] == SYNTAX_SOURCE_LAST
    assert SYNTAX_SOURCE_SIGNIFICANCE in sources
    assert sources[-1] == SYNTAX_SOURCE_LEVEL

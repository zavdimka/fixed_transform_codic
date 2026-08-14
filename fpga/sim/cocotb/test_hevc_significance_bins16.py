from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.scan import (
    DIAGONAL_SCAN_4,
    DIAGONAL_SCAN_16,
    coefficient_scan_metadata_16,
)
from hevc_reference.syntax import significance_bins_16


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def scanner_stream(block):
    group_flags, last_nonzero = coefficient_scan_metadata_16(block)
    assert last_nonzero is not None
    flags_word = sum(int(flag) << index for index, flag in enumerate(group_flags))
    stream = []
    for scan_position in range(last_nonzero, -1, -1):
        address = DIAGONAL_SCAN_16[scan_position]
        group_raster = DIAGONAL_SCAN_4[scan_position >> 4]
        stream.append((
            address, scan_position, block[address >> 4][address & 15],
            int(group_flags[group_raster]), flags_word,
            int(scan_position == 0),
        ))
    return stream


async def run_block(dut, block, rng):
    stream = scanner_stream(block)
    source_index = 0
    received = []
    stalled = None
    for _ in range(20000):
        if not int(dut.s_valid.value) and source_index < len(stream):
            address, scan_position, coefficient, group_nonzero, flags, last = (
                stream[source_index]
            )
            dut.s_raster_address.value = address
            dut.s_scan_position.value = scan_position
            dut.s_coefficient.value = coefficient
            dut.s_group_nonzero.value = group_nonzero
            dut.s_significant_group_flags.value = flags
            dut.s_block_last.value = last
            dut.s_valid.value = 1

        dut.m_ready.value = int(rng.random() < 0.7)
        await RisingEdge(dut.clk)
        output = (
            int(dut.m_bin.value),
            int(dut.m_coded_sub_block.value),
            int(dut.m_context_index.value),
            int(dut.m_scan_position.value),
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

        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0

        if int(dut.stage_done.value):
            assert source_index == len(stream)
            return received, int(dut.input_error.value)
    raise AssertionError("significance stream timed out")


def expected_events(block):
    return [
        (
            event.value, int(event.coded_sub_block), event.context_index,
            event.scan_position, int(event.syntax_last),
        )
        for event in significance_bins_16(block)
    ]


@cocotb.test()
async def sparse_and_random_blocks_match_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x516B1)

    blocks = []
    dc_only = [[0] * 16 for _ in range(16)]
    dc_only[0][0] = 3
    blocks.append(dc_only)

    inferred_group_zero = [[0] * 16 for _ in range(16)]
    for position, value in ((0, -2), (16, 7), (32, -9), (79, 4), (173, 12)):
        address = DIAGONAL_SCAN_16[position]
        inferred_group_zero[address >> 4][address & 15] = value
    blocks.append(inferred_group_zero)

    for _ in range(40):
        block = [[0] * 16 for _ in range(16)]
        for _ in range(rng.randrange(1, 45)):
            position = rng.randrange(256)
            address = DIAGONAL_SCAN_16[position]
            value = rng.randrange(-20, 21)
            block[address >> 4][address & 15] = value or 1
        blocks.append(block)

    for block in blocks:
        received, error = await run_block(dut, block, rng)
        assert error == 0
        assert received == expected_events(block)


@cocotb.test()
async def final_dc_has_no_significance_bins(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    block = [[0] * 16 for _ in range(16)]
    block[0][0] = -1
    received, error = await run_block(dut, block, random.Random(1))
    assert received == []
    assert error == 0

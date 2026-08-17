from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.scan import (
    DIAGONAL_SCAN_16,
    coefficient_scan_metadata_16,
)
from hevc_reference.syntax import coefficient_level_bins_16


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def grouped_scanner_stream(block):
    _, last_nonzero = coefficient_scan_metadata_16(block)
    assert last_nonzero is not None
    last_group = last_nonzero >> 4
    stream = []
    first = True
    for group_scan in range(last_group, -1, -1):
        high = last_nonzero if group_scan == last_group else (group_scan << 4) + 15
        low = group_scan << 4
        for scan_position in range(high, low - 1, -1):
            address = DIAGONAL_SCAN_16[scan_position]
            stream.append((
                block[address >> 4][address & 15],
                group_scan,
                int(first),
                int(scan_position == low),
                int(scan_position == 0),
            ))
            first = False
    return stream


async def run_block(dut, block, rng):
    stream = grouped_scanner_stream(block)
    source_index = 0
    received = []
    stalled = None
    for _ in range(50000):
        if not int(dut.s_valid.value) and source_index < len(stream):
            coefficient, group_scan, block_start, group_end, block_last = (
                stream[source_index]
            )
            dut.s_coefficient.value = coefficient
            dut.s_nonzero.value = int(coefficient != 0)
            dut.s_group_scan_position.value = group_scan
            dut.s_block_start.value = block_start
            dut.s_group_end.value = group_end
            dut.s_block_last.value = block_last
            dut.s_valid.value = 1

        dut.m_ready.value = int(rng.random() < 0.7)
        await RisingEdge(dut.clk)
        output = (
            int(dut.m_bin.value),
            int(dut.m_kind.value),
            int(dut.m_bypass.value),
            int(dut.m_context_index.value),
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

        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0

        if int(dut.block_done.value):
            assert source_index == len(stream)
            return received, int(dut.input_error.value)
    raise AssertionError("coefficient level stream timed out")


def expected_events(block):
    return [
        (
            event.value, event.kind, int(event.bypass), event.context_index,
            event.group_scan_position, event.coefficient_index,
        )
        for event in coefficient_level_bins_16(block)
    ]


@cocotb.test()
async def levels_signs_and_rice_match_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1E7E1)

    blocks = []
    directed = [[0] * 16 for _ in range(16)]
    directed_values = (
        (0, -32768), (1, 1), (2, -2), (3, 3), (4, -4),
        (15, 17), (16, -33), (31, 255), (47, -1024), (80, 32767),
    )
    for position, value in directed_values:
        address = DIAGONAL_SCAN_16[position]
        directed[address >> 4][address & 15] = value
    blocks.append(directed)

    for _ in range(30):
        block = [[0] * 16 for _ in range(16)]
        for _ in range(rng.randrange(1, 70)):
            position = rng.randrange(256)
            address = DIAGONAL_SCAN_16[position]
            value = rng.randrange(-32768, 32768)
            block[address >> 4][address & 15] = value or 1
        blocks.append(block)

    for block in blocks:
        received, error = await run_block(dut, block, rng)
        assert error == 0
        assert received == expected_events(block)


@cocotb.test()
async def dc_unit_level_has_greater1_and_sign_only(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    block = [[0] * 16 for _ in range(16)]
    block[0][0] = -1
    received, error = await run_block(dut, block, random.Random(2))
    assert received == [(0, 0, 0, 1, 0, 0), (1, 2, 1, 0, 0, 0)]
    assert error == 0

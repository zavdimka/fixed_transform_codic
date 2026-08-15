from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.chroma_coeff_syntax import coefficient_syntax_bins_8
from hevc_reference.chroma_syntax import coefficient_scan_metadata_8


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_block_last.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def event_tuple(event):
    return (
        event.value, int(event.bypass), event.source, event.level_kind,
        event.context_index, int(event.last_axis_y),
        int(event.significance_coded_sub_block), event.scan_position,
        event.group_scan_position, event.coefficient_index,
    )


async def run_block(dut, block, rng, final_marker=True):
    sent = 0
    received = []
    stalled = None
    flags, last = coefficient_scan_metadata_8(block)
    flags_word = sum(int(flag) << i for i, flag in enumerate(flags))
    for _ in range(12000):
        if not int(dut.s_valid.value) and sent < 64 and int(dut.s_ready.value):
            dut.s_raster_address.value = sent
            dut.s_coefficient.value = block[sent >> 3][sent & 7]
            dut.s_block_last.value = int(final_marker and sent == 63)
            dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < 0.67)
        await RisingEdge(dut.clk)
        valid, ready = int(dut.m_valid.value), int(dut.m_ready.value)
        output = None
        if valid:
            output = (
                int(dut.m_bin.value), int(dut.m_bypass.value),
                int(dut.m_source.value), int(dut.m_level_kind.value),
                int(dut.m_context_index.value), int(dut.m_last_axis_y.value),
                int(dut.m_significance_coded_sub_block.value),
                int(dut.m_scan_position.value),
                int(dut.m_group_scan_position.value),
                int(dut.m_coefficient_index.value),
            )
        if stalled is not None:
            assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            received.append(output)
            assert int(dut.any_nonzero.value)
            assert int(dut.last_nonzero_scan_position.value) == last
            assert int(dut.significant_group_flags.value) == flags_word
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            sent += 1
            dut.s_valid.value = 0
        if int(dut.block_done.value):
            return received, int(dut.input_error.value)
    raise AssertionError(f"TU8 syntax timeout state={int(dut.state.value)} sent={sent}")


@cocotb.test()
async def integrated_chroma_tu8_matches_reference_under_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC4808)
    blocks = []
    directed = [[0] * 8 for _ in range(8)]
    for address, value in ((0, -32768), (7, 32767), (18, -3), (45, 19), (63, -8)):
        directed[address >> 3][address & 7] = value
    blocks.append(directed)
    dc = [[0] * 8 for _ in range(8)]
    dc[0][0] = -1
    blocks.append(dc)
    blocks.append([[0] * 8 for _ in range(8)])
    for _ in range(12):
        block = [[0] * 8 for _ in range(8)]
        for _ in range(rng.randrange(1, 28)):
            address = rng.randrange(64)
            block[address >> 3][address & 7] = rng.randrange(-1024, 1025) or 1
        blocks.append(block)
    for block in blocks:
        received, error = await run_block(dut, block, rng)
        assert not error
        assert received == [event_tuple(e) for e in coefficient_syntax_bins_8(block)]


@cocotb.test()
async def missing_final_marker_is_reported(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    received, error = await run_block(
        dut, [[0] * 8 for _ in range(8)], random.Random(7), False
    )
    assert received == []
    assert error

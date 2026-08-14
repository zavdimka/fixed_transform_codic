from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.scan import DIAGONAL_SCAN_16, coefficient_scan_metadata_16
from hevc_reference.syntax import coefficient_syntax_bins_16


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_raster_address.value = 0
    dut.s_coefficient.value = 0
    dut.s_block_last.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def expected_tuple(event):
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


async def run_block(dut, block, rng, final_marker=True):
    # Match the reconstruction-loop coefficient tap: x advances outside, y inside.
    write_addresses = [
        ((index & 15) << 4) | (index >> 4) for index in range(256)
    ]
    group_flags, last_nonzero = coefficient_scan_metadata_16(block)
    flags_word = sum(
        int(flag) << index for index, flag in enumerate(group_flags)
    )
    source_index = 0
    received = []
    stalled = None

    for _ in range(20000):
        if (
            not int(dut.s_valid.value)
            and source_index < len(write_addresses)
            and int(dut.s_ready.value)
        ):
            address = write_addresses[source_index]
            dut.s_raster_address.value = address
            dut.s_coefficient.value = block[address >> 4][address & 15]
            dut.s_block_last.value = int(
                final_marker and source_index == 255
            )
            dut.s_valid.value = 1

        dut.m_ready.value = int(rng.random() < 0.68)
        await RisingEdge(dut.clk)

        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        output = None
        if valid:
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
        if stalled is not None:
            assert valid == 1
            assert output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            received.append(output)
            assert int(dut.any_nonzero.value) == 1
            assert int(dut.last_nonzero_scan_position.value) == last_nonzero
            assert int(dut.significant_group_flags.value) == flags_word

        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0

        if int(dut.block_done.value):
            assert source_index == 256
            return received, int(dut.input_error.value)
    raise AssertionError(
        "integrated coefficient syntax pipeline timed out: "
        f"state={int(dut.state.value)} source={source_index} "
        f"scan_valid={int(dut.scan_valid.value)} "
        f"scan_position={int(dut.scan_position.value)} "
        f"sig_done={int(dut.significance_stage_done.value)} "
        f"level_done={int(dut.level_block_done.value)}"
    )


@cocotb.test()
async def two_pass_ram_pipeline_matches_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x2A55CA8)

    blocks = []
    directed = [[0] * 16 for _ in range(16)]
    for position, value in (
        (0, -32768), (1, 1), (17, -2), (74, 255), (173, 32767)
    ):
        address = DIAGONAL_SCAN_16[position]
        directed[address >> 4][address & 15] = value
    blocks.append(directed)

    dc_only = [[0] * 16 for _ in range(16)]
    dc_only[0][0] = -1
    blocks.append(dc_only)

    for _ in range(10):
        block = [[0] * 16 for _ in range(16)]
        for _ in range(rng.randrange(1, 55)):
            position = rng.randrange(256)
            address = DIAGONAL_SCAN_16[position]
            value = rng.randrange(-2048, 2049) or 1
            block[address >> 4][address & 15] = value
        blocks.append(block)

    for block in blocks:
        received, error = await run_block(dut, block, rng)
        assert error == 0
        assert received == [
            expected_tuple(event) for event in coefficient_syntax_bins_16(block)
        ]


@cocotb.test()
async def sparse_multigroup_replay_matches_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    block = [[0] * 16 for _ in range(16)]
    for position, value in ((0, -2), (17, 3), (71, -9)):
        address = DIAGONAL_SCAN_16[position]
        block[address >> 4][address & 15] = value
    received, error = await run_block(dut, block, random.Random(5))
    assert received == [
        expected_tuple(event) for event in coefficient_syntax_bins_16(block)
    ]
    assert error == 0


@cocotb.test()
async def dc_only_replays_into_levels_without_significance_bins(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    block = [[0] * 16 for _ in range(16)]
    block[0][0] = -1
    received, error = await run_block(dut, block, random.Random(2))
    assert received == [
        expected_tuple(event) for event in coefficient_syntax_bins_16(block)
    ]
    assert error == 0


@cocotb.test()
async def all_zero_block_bypasses_coefficient_syntax(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    received, error = await run_block(
        dut, [[0] * 16 for _ in range(16)], random.Random(3)
    )
    assert received == []
    assert error == 0


@cocotb.test()
async def missing_final_marker_is_reported(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    received, error = await run_block(
        dut, [[0] * 16 for _ in range(16)], random.Random(4), False
    )
    assert received == []
    assert error == 1


async def load_queued_block(dut, block) -> None:
    write_addresses = [
        ((index & 15) << 4) | (index >> 4) for index in range(256)
    ]
    for source_index, address in enumerate(write_addresses):
        while not int(dut.s_ready.value):
            await RisingEdge(dut.clk)
        dut.s_raster_address.value = address
        dut.s_coefficient.value = block[address >> 4][address & 15]
        dut.s_block_last.value = int(source_index == 255)
        dut.s_valid.value = 1
        await RisingEdge(dut.clk)
        dut.s_valid.value = 0
    dut.s_block_last.value = 0


@cocotb.test()
async def next_tu_loads_before_current_syntax_finishes(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.m_ready.value = 0

    first = [[0] * 16 for _ in range(16)]
    second = [[0] * 16 for _ in range(16)]
    for position, value in (
        (0, -3), (1, 7), (18, -11), (73, 19), (171, -37)
    ):
        address = DIAGONAL_SCAN_16[position]
        first[address >> 4][address & 15] = value
    for position, value in ((0, 2), (16, -5), (89, 13)):
        address = DIAGONAL_SCAN_16[position]
        second[address >> 4][address & 15] = value

    await load_queued_block(dut, first)
    await load_queued_block(dut, second)
    await Timer(1, units="ns")

    assert int(dut.busy.value)
    assert not int(dut.block_done.value)
    assert not int(dut.s_ready.value)

    expected = [
        [
            expected_tuple(event)
            for event in coefficient_syntax_bins_16(block)
        ]
        for block in (first, second)
    ]
    completed = []
    received = []
    dut.m_ready.value = 1

    for _ in range(30000):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value) and int(dut.m_ready.value):
            received.append(
                (
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
            )
        if int(dut.block_done.value):
            completed.append(received)
            received = []
            if len(completed) == 2:
                break
    else:
        raise AssertionError("queued syntax blocks did not finish")

    assert completed == expected
    assert int(dut.s_ready.value)

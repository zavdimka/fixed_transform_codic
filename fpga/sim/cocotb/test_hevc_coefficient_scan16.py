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


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load_and_scan(dut, block, rng, ready_probability=0.7):
    # Match the integrated transform tap: x advances outside, y inside.
    write_addresses = [((index & 15) << 4) | (index >> 4)
                       for index in range(256)]
    source_index = 0
    received = []
    stalled_output = None
    for _ in range(10000):
        if not int(dut.s_valid.value) and source_index < 256:
            address = write_addresses[source_index]
            dut.s_raster_address.value = address
            dut.s_coefficient.value = block[address >> 4][address & 15]
            dut.s_block_last.value = int(source_index == 255)
            dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < ready_probability)
        await RisingEdge(dut.clk)

        output = (
            dut.m_coefficient.value.signed_integer,
            int(dut.m_raster_address.value),
            int(dut.m_scan_position.value),
            int(dut.m_group_scan_position.value),
            int(dut.m_position_in_group.value),
            int(dut.m_group_first.value),
            int(dut.m_group_last.value),
            int(dut.m_block_last.value),
            int(dut.m_nonzero.value),
            int(dut.m_group_nonzero.value),
            int(dut.any_nonzero.value),
            int(dut.last_nonzero_scan_position.value),
            int(dut.input_error.value),
            int(dut.significant_group_flags.value),
        )
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        if stalled_output is not None:
            assert valid == 1
            assert output == stalled_output
        stalled_output = output if valid and not ready else None
        if valid and ready:
            received.append(output)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0
        if received and received[-1][7]:
            return received
    raise AssertionError("coefficient scan timed out")


@cocotb.test()
async def diagonal_scan_and_metadata_survive_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x5CA16)
    block = [[0] * 16 for _ in range(16)]
    for scan_position in (0, 2, 17, 74, 173):
        address = DIAGONAL_SCAN_16[scan_position]
        block[address >> 4][address & 15] = scan_position - 300

    group_flags, last_nonzero = coefficient_scan_metadata_16(block)
    received = await load_and_scan(dut, block, rng)
    assert int(dut.input_error.value) == 0
    expected_positions = list(range(last_nonzero, -1, -1))
    assert len(received) == len(expected_positions)
    for scan_position, output in zip(expected_positions, received):
        address = DIAGONAL_SCAN_16[scan_position]
        coefficient = block[address >> 4][address & 15]
        group_raster = DIAGONAL_SCAN_4[scan_position >> 4]
        assert output == (
            coefficient, address, scan_position, scan_position >> 4,
            scan_position & 15, int((scan_position & 15) == 0),
            int((scan_position & 15) == 15), int(scan_position == 0),
            int(coefficient != 0), int(group_flags[group_raster]),
            1, last_nonzero, 0,
            sum(int(flag) << index for index, flag in enumerate(group_flags)),
        )
    assert last_nonzero == 173


@cocotb.test()
async def all_zero_block_reports_no_significance(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    received = await load_and_scan(
        dut, [[0] * 16 for _ in range(16)], random.Random(7), 1.0
    )
    assert len(received) == 1
    assert received[0][2] == 0
    assert received[0][8:] == (0, 0, 0, 0, 0, 0)
    assert received[0][7] == 1


@cocotb.test()
async def missing_final_marker_is_flagged(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.m_ready.value = 0
    for address in range(256):
        dut.s_raster_address.value = address
        dut.s_coefficient.value = 0
        dut.s_block_last.value = 0
        dut.s_valid.value = 1
        await RisingEdge(dut.clk)
    dut.s_valid.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.input_error.value) == 1
    assert int(dut.busy.value) == 1

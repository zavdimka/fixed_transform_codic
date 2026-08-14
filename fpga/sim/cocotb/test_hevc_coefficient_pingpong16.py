from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.scan import coefficient_scan_metadata_16


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_raster_address.value = 0
    dut.s_coefficient.value = 0
    dut.s_block_last.value = 0
    dut.block_ready.value = 0
    dut.read_enable.value = 0
    dut.read_address.value = 0
    dut.release_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def metadata(block):
    flags, last = coefficient_scan_metadata_16(block)
    return (
        int(any(value for row in block for value in row)),
        0 if last is None else last,
        sum(int(flag) << index for index, flag in enumerate(flags)),
    )


async def load_block(dut, block, final_marker=True):
    for address in range(256):
        dut.s_valid.value = 1
        dut.s_raster_address.value = address
        dut.s_coefficient.value = block[address >> 4][address & 15]
        dut.s_block_last.value = int(final_marker and address == 255)
        await Timer(1, units="ns")
        assert int(dut.s_ready.value)
        await RisingEdge(dut.clk)
    dut.s_valid.value = 0
    dut.s_block_last.value = 0


async def acquire_block(dut, expected_block, expected_bank, error=0):
    await Timer(1, units="ns")
    assert int(dut.block_valid.value)
    assert int(dut.block_bank.value) == expected_bank
    expected_any, expected_last, expected_flags = metadata(expected_block)
    assert int(dut.block_any_nonzero.value) == expected_any
    assert int(dut.block_last_nonzero_scan_position.value) == expected_last
    assert int(dut.block_significant_group_flags.value) == expected_flags
    assert int(dut.block_input_error.value) == error
    dut.block_ready.value = 1
    await RisingEdge(dut.clk)
    dut.block_ready.value = 0
    await Timer(1, units="ns")
    assert int(dut.read_active.value)


async def release_block(dut):
    dut.release_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.release_ready.value)
    await RisingEdge(dut.clk)
    dut.release_valid.value = 0


async def overlap_read_and_load(dut, read_block, load_block_data):
    for address in range(256):
        dut.read_enable.value = 1
        dut.read_address.value = address
        dut.s_valid.value = 1
        dut.s_raster_address.value = address
        dut.s_coefficient.value = load_block_data[address >> 4][address & 15]
        dut.s_block_last.value = int(address == 255)
        await Timer(1, units="ns")
        assert int(dut.s_ready.value)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert dut.read_data.value.signed_integer == (
            read_block[address >> 4][address & 15]
        )
    dut.read_enable.value = 0
    dut.s_valid.value = 0
    dut.s_block_last.value = 0
    await Timer(1, units="ns")
    assert not int(dut.s_ready.value)


@cocotb.test()
async def alternate_banks_load_while_previous_block_is_read(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xB16B00B5)

    blocks = []
    for block_index in range(3):
        block = [[0] * 16 for _ in range(16)]
        for _ in range(35 + block_index * 7):
            address = rng.randrange(256)
            block[address >> 4][address & 15] = (
                rng.randrange(-32768, 32768) or 1
            )
        blocks.append(block)

    await load_block(dut, blocks[0])
    await acquire_block(dut, blocks[0], 0)
    await overlap_read_and_load(dut, blocks[0], blocks[1])
    await release_block(dut)

    await acquire_block(dut, blocks[1], 1)
    await overlap_read_and_load(dut, blocks[1], blocks[2])
    await release_block(dut)

    await acquire_block(dut, blocks[2], 0)
    dut.read_enable.value = 1
    for address in range(256):
        dut.read_address.value = address
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert dut.read_data.value.signed_integer == (
            blocks[2][address >> 4][address & 15]
        )
    dut.read_enable.value = 0
    await release_block(dut)


@cocotb.test()
async def early_and_missing_markers_are_attached_to_their_bank(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    zero = [[0] * 16 for _ in range(16)]

    for address in range(4):
        dut.s_valid.value = 1
        dut.s_raster_address.value = address
        dut.s_coefficient.value = 0
        dut.s_block_last.value = int(address == 3)
        await RisingEdge(dut.clk)
    dut.s_valid.value = 0
    dut.s_block_last.value = 0
    await acquire_block(dut, zero, 0, error=1)
    await release_block(dut)

    await load_block(dut, zero, final_marker=False)
    await acquire_block(dut, zero, 0, error=1)
    await release_block(dut)

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cabac import CabacByteEncoder
from hevc_reference.scan import DIAGONAL_SCAN_16
from hevc_reference.syntax import (
    coefficient_context_address,
    coefficient_syntax_bins_16,
)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.cfg_valid.value = 0
    dut.slice_start_valid.value = 0
    dut.s_valid.value = 0
    dut.s_raster_address.value = 0
    dut.s_coefficient.value = 0
    dut.s_block_last.value = 0
    dut.slice_finish_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def configure_and_start(dut, contexts) -> None:
    for address, (state, mps) in enumerate(contexts):
        dut.cfg_valid.value = 1
        dut.cfg_context_address.value = address
        dut.cfg_state_index.value = state
        dut.cfg_mps.value = mps
        await Timer(1, units="ns")
        assert int(dut.cfg_ready.value)
        await RisingEdge(dut.clk)
    dut.cfg_valid.value = 0
    dut.slice_start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.slice_start_ready.value)
    await RisingEdge(dut.clk)
    dut.slice_start_valid.value = 0


def expected_bytes(contexts, blocks) -> bytes:
    encoder = CabacByteEncoder(contexts)
    for block in blocks:
        for event in coefficient_syntax_bins_16(block):
            address = coefficient_context_address(event)
            if address is None:
                encoder.encode_bypass(event.value)
            else:
                encoder.encode_regular(event.value, address)
    encoder.encode_terminate(1)
    return encoder.bytes()


@cocotb.test()
async def two_queued_tus_match_cabac_byte_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC0EFCAB)
    contexts = [
        (rng.randrange(64), rng.randrange(2)) for _ in range(256)
    ]
    await configure_and_start(dut, contexts)

    blocks = []
    for entries in (
        ((0, -3), (1, 7), (18, -11), (73, 19), (171, -37)),
        ((0, 2), (16, -5), (89, 13), (205, -29)),
    ):
        block = [[0] * 16 for _ in range(16)]
        for position, value in entries:
            address = DIAGONAL_SCAN_16[position]
            block[address >> 4][address & 15] = value
        blocks.append(block)

    input_beats = []
    for block in blocks:
        for index in range(256):
            address = ((index & 15) << 4) | (index >> 4)
            input_beats.append((
                address,
                block[address >> 4][address & 15],
                int(index == 255),
            ))

    input_index = 0
    presenting = False
    completed_blocks = 0
    first_done_input_count = None
    finish_presenting = False
    output = []
    last_flags = []
    stalled_output = None

    for _ in range(300000):
        if not presenting and input_index < len(input_beats):
            presenting = True
        if presenting:
            address, coefficient, block_last = input_beats[input_index]
            dut.s_valid.value = 1
            dut.s_raster_address.value = address
            dut.s_coefficient.value = coefficient
            dut.s_block_last.value = block_last
        else:
            dut.s_valid.value = 0
            dut.s_block_last.value = 0

        if completed_blocks == len(blocks) and not finish_presenting:
            finish_presenting = True
        dut.slice_finish_valid.value = int(finish_presenting)
        dut.m_ready.value = int(rng.random() < 0.71)
        await Timer(1, units="ns")

        input_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        finish_fire = (
            int(dut.slice_finish_valid.value)
            and int(dut.slice_finish_ready.value)
        )
        byte_value = (int(dut.m_byte.value), int(dut.m_last.value))
        byte_valid = int(dut.m_valid.value)
        byte_ready = int(dut.m_ready.value)
        if stalled_output is not None:
            assert byte_valid
            assert byte_value == stalled_output
        stalled_output = (
            byte_value if byte_valid and not byte_ready else None
        )
        if byte_valid and byte_ready:
            output.append(byte_value[0])
            last_flags.append(byte_value[1])

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if input_fire:
            input_index += 1
            presenting = False
        if finish_fire:
            finish_presenting = False
        if int(dut.block_done.value):
            completed_blocks += 1
            if completed_blocks == 1:
                first_done_input_count = input_index
        assert not int(dut.protocol_error.value)

        if int(dut.slice_done.value):
            break
    else:
        raise AssertionError("coefficient-to-CABAC pipeline timed out")

    assert input_index == len(input_beats)
    assert completed_blocks == len(blocks)
    assert first_done_input_count == len(input_beats)
    assert bytes(output) == expected_bytes(contexts, blocks)
    assert last_flags == [0] * (len(output) - 1) + [1]

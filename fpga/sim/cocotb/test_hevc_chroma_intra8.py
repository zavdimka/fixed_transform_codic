from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.chroma_intra import (
    chroma_dc_prediction_8,
    chroma_planar_prediction_8,
)


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.ref_valid.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(dut, top, left, source, mode_dc, rng):
    while not int(dut.start_ready.value):
        await RisingEdge(dut.clk)
    dut.luma_mode_dc.value = mode_dc
    dut.start_valid.value = 1
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    reference_index = 0
    source_index = 0
    received = []
    stalled = None

    for _ in range(2000):
        if (not int(dut.ref_valid.value) and reference_index < 10 and
                rng.random() < 0.8):
            dut.ref_top.value = top[reference_index]
            dut.ref_left.value = left[reference_index]
            dut.ref_last.value = int(reference_index == 9)
            dut.ref_valid.value = 1

        if (reference_index == 10 and not int(dut.s_valid.value) and
                source_index < 64 and rng.random() < 0.85):
            y, x = divmod(source_index, 8)
            dut.s_pixel.value = source[y][x]
            dut.s_valid.value = 1

        dut.m_ready.value = int(rng.random() < 0.7)
        await RisingEdge(dut.clk)

        output = (
            int(dut.m_prediction.value),
            dut.m_residual.value.signed_integer,
            bool(dut.m_block_last.value),
        )
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        if stalled is not None:
            assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            received.append(output)

        if int(dut.ref_valid.value) and int(dut.ref_ready.value):
            reference_index += 1
            dut.ref_valid.value = 0
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0

        if len(received) == 64:
            break
    else:
        raise AssertionError("chroma intra8 timed out")

    assert reference_index == 10
    assert source_index == 64
    assert not int(dut.protocol_error.value)
    return received


@cocotb.test()
async def derived_dc_and_planar_match_reference_under_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC1A08)

    for block_index, mode_dc in enumerate((1, 0, 1, 0)):
        corner = (73 + block_index * 19) & 255
        top = [corner] + [rng.randrange(256) for _ in range(9)]
        left = [corner] + [rng.randrange(256) for _ in range(9)]
        source = [[(x * 31 + y * 17 + block_index * 43) & 255
                   for x in range(8)] for y in range(8)]
        prediction = (chroma_dc_prediction_8(top, left) if mode_dc else
                      chroma_planar_prediction_8(top, left))
        expected = [
            (prediction[y][x], source[y][x] - prediction[y][x],
             x == 7 and y == 7)
            for y in range(8) for x in range(8)
        ]
        received = await run_block(
            dut, top, left, source, mode_dc, rng
        )
        assert received == expected


@cocotb.test()
async def malformed_reference_last_sets_protocol_error(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.luma_mode_dc.value = 1
    dut.start_valid.value = 1
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0
    dut.ref_top.value = 128
    dut.ref_left.value = 128
    dut.ref_last.value = 1
    dut.ref_valid.value = 1
    while not int(dut.ref_ready.value):
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.ref_valid.value = 0
    assert int(dut.protocol_error.value)

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


FRAME_WIDTH = 32
CHROMA_WIDTH = FRAME_WIDTH // 2


def expected_references(top_line, left_edge, carried_top_left, ctu_x, top_available):
    base = ctu_x * 8
    raw = [128] * 19
    available = [False] * 19
    for scan_index in range(19):
        if scan_index < 9:
            offset = 8 - scan_index
            if ctu_x != 0 and offset < 8:
                raw[scan_index] = left_edge[offset]
                available[scan_index] = True
        elif scan_index == 9:
            if top_available and ctu_x != 0:
                raw[scan_index] = carried_top_left
                available[scan_index] = True
        else:
            offset = scan_index - 10
            if top_available and base + offset < CHROMA_WIDTH:
                raw[scan_index] = top_line[base + offset]
                available[scan_index] = True

    first = next((value for value, valid in zip(raw, available) if valid), 128)
    filled = []
    running = first
    for value, valid in zip(raw, available):
        if valid:
            running = value
        filled.append(running)
    return [
        (filled[9], filled[9]) if index == 0 else
        (filled[9 + index], filled[9 - index])
        for index in range(10)
    ]


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.m_ready.value = 0
    dut.recon_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(dut, ctu_x, top_available, block, rng):
    while not int(dut.start_ready.value):
        await RisingEdge(dut.clk)
    dut.ctu_x.value = ctu_x
    dut.top_available.value = top_available
    dut.start_valid.value = 1
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    references = []
    stalled = None
    for _ in range(500):
        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)
        output = (
            int(dut.m_ref_top.value),
            int(dut.m_ref_left.value),
            bool(dut.m_ref_last.value),
        )
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        if stalled is not None:
            assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            references.append(output)
        if len(references) == 10:
            break
    else:
        raise AssertionError("chroma reference output timed out")

    dut.m_ready.value = 0
    for y in range(8):
        for x in range(8):
            dut.recon_pixel.value = block[y][x]
            dut.recon_x.value = x
            dut.recon_y.value = y
            dut.recon_block_last.value = int(x == 7 and y == 7)
            dut.recon_valid.value = 1
            await RisingEdge(dut.clk)
    dut.recon_valid.value = 0
    dut.recon_block_last.value = 0
    await Timer(1, units="ns")
    assert int(dut.block_committed.value)
    assert not int(dut.protocol_error.value)
    return references


@cocotb.test()
async def raster_chroma_references_match_substitution_under_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC4EF8)
    top_line = [128] * CHROMA_WIDTH
    left_edge = [128] * 8
    carried_top_left = 128

    for block_y in range(2):
        for ctu_x in range(2):
            block = [[(block_y * 97 + ctu_x * 53 + y * 17 + x * 11) & 255
                      for x in range(8)] for y in range(8)]
            expected = expected_references(
                top_line, left_edge, carried_top_left, ctu_x, block_y != 0
            )
            received = await run_block(
                dut, ctu_x, block_y != 0, block, rng
            )
            assert [item[:2] for item in received] == expected
            assert [item[2] for item in received] == [False] * 9 + [True]

            base = ctu_x * 8
            if block_y != 0:
                carried_top_left = top_line[base + 7]
            top_line[base:base + 8] = block[7]
            left_edge = [block[y][7] for y in range(8)]

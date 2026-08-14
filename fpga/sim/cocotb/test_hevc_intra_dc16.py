from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.intra import filtered_dc_prediction, prediction_residual


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.ref_valid.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load_references(dut, top: list[int], left: list[int]) -> None:
    for top_sample, left_sample in zip(top, left):
        dut.ref_top.value = top_sample
        dut.ref_left.value = left_sample
        dut.ref_valid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if int(dut.ref_ready.value):
                break
    dut.ref_valid.value = 0


@cocotb.test()
async def dc16_matches_integer_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    rng = random.Random(0xDC16)
    top = [rng.randrange(256) for _ in range(16)]
    left = [rng.randrange(256) for _ in range(16)]
    source = [[rng.randrange(256) for _ in range(16)] for _ in range(16)]
    prediction = filtered_dc_prediction(top, left)
    residual = prediction_residual(source, prediction)
    expected = [
        (prediction[y][x], residual[y][x], y == 15 and x == 15)
        for y in range(16) for x in range(16)
    ]

    await load_references(dut, top, left)

    source_index = 0
    received: list[tuple[int, int, bool]] = []
    stalled_output: tuple[int, int, bool] | None = None
    for _ in range(10000):
        if not int(dut.s_valid.value) and source_index < 256:
            if rng.random() < 0.8:
                y, x = divmod(source_index, 16)
                dut.s_pixel.value = source[y][x]
                dut.s_valid.value = 1

        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)

        output = (
            int(dut.m_prediction.value),
            dut.m_residual.value.signed_integer,
            bool(dut.m_block_last.value),
        )
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        if stalled_output is not None:
            assert output_valid == 1
            assert output == stalled_output
        stalled_output = output if output_valid and not output_ready else None

        if output_valid and output_ready:
            received.append(output)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0
        if len(received) == 256:
            break
    else:
        raise AssertionError("DC16 stream timed out")

    assert received == expected
    assert sum(item[2] for item in received) == 1


@cocotb.test()
async def flat_references_produce_expected_filtered_edges(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    top = [10] * 16
    left = [20] * 16
    await load_references(dut, top, left)

    expected = filtered_dc_prediction(top, left)
    dut.m_ready.value = 1
    received = []
    source_index = 0
    for _ in range(2000):
        if not int(dut.s_valid.value) and source_index < 256:
            dut.s_pixel.value = expected[source_index // 16][source_index % 16]
            dut.s_valid.value = 1
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value) and int(dut.m_ready.value):
            received.append(dut.m_residual.value.signed_integer)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0
        if len(received) == 256:
            break
    else:
        raise AssertionError("flat DC16 stream timed out")
    assert received == [0] * 256

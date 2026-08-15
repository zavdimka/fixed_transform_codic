from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.intra import (
    filtered_dc_prediction,
    planar_prediction_16,
    prediction_residual,
    residual_sad,
)


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.ref_valid.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def selects_mode_and_replays_source_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    rng = random.Random(0xFEED_16)
    corner = 73
    top = [corner] + [40 + index * 3 for index in range(18)]
    left = [corner] + [190 - index * 4 for index in range(18)]
    source = [
        [min(255, 25 + x * 8 + y * 2 + ((x ^ y) & 3)) for x in range(16)]
        for y in range(16)
    ]

    dc_prediction = filtered_dc_prediction(top[1:17], left[1:17])
    planar_prediction = planar_prediction_16(top, left)
    dc_residual = prediction_residual(source, dc_prediction)
    planar_residual = prediction_residual(source, planar_prediction)
    planar_selected = residual_sad(planar_residual) < residual_sad(dc_residual)
    selected_prediction = planar_prediction if planar_selected else dc_prediction
    selected_residual = planar_residual if planar_selected else dc_residual
    expected = [
        (
            selected_prediction[y][x],
            selected_residual[y][x],
            not planar_selected,
            y == 15 and x == 15,
        )
        for y in range(16)
        for x in range(16)
    ]

    dut.start_valid.value = 1
    while True:
        await Timer(1, units="ns")
        if int(dut.start_ready.value):
            await RisingEdge(dut.clk)
            break
        await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    reference_index = 0
    source_index = 0
    received = []
    stalled_output = None
    for _ in range(20000):
        if reference_index < 19:
            dut.ref_valid.value = int(rng.random() < 0.83)
            dut.ref_top.value = top[reference_index]
            dut.ref_left.value = left[reference_index]
            dut.ref_last.value = int(reference_index == 18)
        else:
            dut.ref_valid.value = 0

        if reference_index == 19 and source_index < 256:
            y, x = divmod(source_index, 16)
            dut.s_valid.value = int(rng.random() < 0.81)
            dut.s_pixel.value = source[y][x]
        else:
            dut.s_valid.value = 0

        dut.m_ready.value = int(rng.random() < 0.69)
        await Timer(1, units="ns")

        ref_fire = int(dut.ref_valid.value) and int(dut.ref_ready.value)
        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        output = (
            int(dut.m_prediction.value),
            dut.m_residual.value.signed_integer,
            bool(dut.m_luma_mode_dc.value),
            bool(dut.m_block_last.value),
        )
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        if stalled_output is not None:
            assert output_valid
            assert output == stalled_output
        stalled_output = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output)

        await RisingEdge(dut.clk)
        if ref_fire:
            reference_index += 1
        if source_fire:
            source_index += 1

        assert not int(dut.protocol_error.value)
        if int(dut.done.value):
            assert reference_index == 19
            assert source_index == 256
            assert received == expected
            assert int(dut.dc_sad.value) == residual_sad(dc_residual)
            assert int(dut.planar_sad.value) == residual_sad(planar_residual)
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"frontend timed out refs={reference_index}/19 "
        f"source={source_index}/256 output={len(received)}/256"
    )

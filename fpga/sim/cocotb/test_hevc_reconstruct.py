from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.intra import reconstruct_sample


@cocotb.test()
async def reconstruction_clips_and_survives_stalls(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    rng = random.Random(0xDEC0DE)
    vectors = [(0, -400), (0, 0), (255, 0), (255, 400), (128, -129), (128, 127)]
    vectors += [(rng.randrange(256), rng.randrange(-1024, 1024)) for _ in range(100)]
    expected = [reconstruct_sample(pred, residual) for pred, residual in vectors]

    source_index = 0
    received: list[int] = []
    stalled_output: int | None = None
    for _ in range(5000):
        if not int(dut.s_valid.value) and source_index < len(vectors):
            if rng.random() < 0.8:
                pred, residual = vectors[source_index]
                dut.s_prediction.value = pred
                dut.s_residual.value = residual
                dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < 0.6)
        await RisingEdge(dut.clk)

        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        output = int(dut.m_reconstructed.value)
        if stalled_output is not None:
            assert output_valid == 1
            assert output == stalled_output
        stalled_output = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0
        if len(received) == len(vectors):
            break
    else:
        raise AssertionError("reconstruction stream timed out")

    assert received == expected

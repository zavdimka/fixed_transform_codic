from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.quant import quantize_dequantize_coefficient, split_qp


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_stream(dut, samples, rng, source_probability=0.8, ready_probability=0.7):
    source_index = 0
    received = []
    stalled_output = None
    for _ in range(10000):
        if not int(dut.s_valid.value) and source_index < len(samples):
            if rng.random() < source_probability:
                coefficient, qp, x, y, block_last = samples[source_index]
                qp_per, qp_rem = split_qp(qp)
                dut.s_coefficient.value = coefficient
                dut.s_qp_per.value = qp_per
                dut.s_qp_rem.value = qp_rem
                dut.s_x.value = x
                dut.s_y.value = y
                dut.s_block_last.value = block_last
                dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < ready_probability)
        await RisingEdge(dut.clk)
        output = (
            dut.m_quantized.value.signed_integer,
            dut.m_dequantized.value.signed_integer,
            int(dut.m_nonzero.value), int(dut.m_qp_error.value),
            int(dut.m_x.value), int(dut.m_y.value),
            int(dut.m_block_last.value),
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
        if len(received) == len(samples):
            return received
    raise AssertionError("quant/dequant stream timed out")


@cocotb.test()
async def quant_dequant_matches_integer_reference_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x0A17)
    coefficients = [-32768, -32767, -4096, -1, 0, 1, 4096, 32766, 32767]
    coefficients += [rng.randrange(-32768, 32768) for _ in range(300)]
    qps = [0, 1, 5, 6, 28, 34, 40, 50, 51]
    samples = [
        (coefficient, qps[index % len(qps)], index & 15, (index >> 4) & 15,
         index == len(coefficients) - 1)
        for index, coefficient in enumerate(coefficients)
    ]
    received = await run_stream(dut, samples, rng)
    expected = []
    for coefficient, qp, x, y, block_last in samples:
        quantized, dequantized = quantize_dequantize_coefficient(coefficient, qp)
        expected.append((
            quantized, dequantized, int(quantized != 0), 0,
            x, y, int(block_last),
        ))
    assert received == expected


@cocotb.test()
async def continuous_pipeline_accepts_one_coefficient_per_clock(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    samples = [(index - 128, 34, index & 15, index >> 4, index == 255)
               for index in range(256)]
    received = await run_stream(
        dut, samples, random.Random(0x116),
        source_probability=1.0, ready_probability=1.0,
    )
    assert len(received) == 256
    assert received[-1][-1] == 1


@cocotb.test()
async def invalid_qp_encoding_is_flagged(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.s_coefficient.value = 100
    dut.s_qp_per.value = 8
    dut.s_qp_rem.value = 4
    dut.s_x.value = 0
    dut.s_y.value = 0
    dut.s_block_last.value = 1
    dut.s_valid.value = 1
    dut.m_ready.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.s_ready.value):
            dut.s_valid.value = 0
            break
    while True:
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            assert int(dut.m_qp_error.value) == 1
            break

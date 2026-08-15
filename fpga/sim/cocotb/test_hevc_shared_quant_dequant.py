from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_tu8 import quantize_dequantize_8
from hevc_reference.quant import quantize_dequantize_coefficient, split_qp


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def tu8_tu16_match_integer_reference_under_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x51A2ED)
    source = []
    expected = []
    for size8 in (False, True):
        for qp in (0, 28, 33, 40, 51):
            qp_per, qp_rem = split_qp(qp)
            for index in range(37):
                coefficient = rng.randrange(-32768, 32768)
                x = index & (7 if size8 else 15)
                y = (index * 3) & (7 if size8 else 15)
                last = index == 36
                source.append((size8, coefficient, qp_per, qp_rem, x, y, last))
                pair = (quantize_dequantize_8(coefficient, qp) if size8 else
                        quantize_dequantize_coefficient(coefficient, qp))
                expected.append((*pair, int(pair[0] != 0), 0, x, y, last))

    source_index = 0
    received = []
    stalled = None
    for _ in range(10000):
        if not int(dut.s_valid.value) and source_index < len(source):
            if rng.random() < 0.86:
                size8, coefficient, qp_per, qp_rem, x, y, last = source[source_index]
                dut.s_size8.value = size8
                dut.s_coefficient.value = coefficient
                dut.s_qp_per.value = qp_per
                dut.s_qp_rem.value = qp_rem
                dut.s_x.value = x
                dut.s_y.value = y
                dut.s_block_last.value = last
                dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < 0.69)
        await Timer(1, units="ns")
        input_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        output = (
            dut.m_quantized.value.signed_integer,
            dut.m_dequantized.value.signed_integer,
            int(dut.m_nonzero.value), int(dut.m_qp_error.value),
            int(dut.m_x.value), int(dut.m_y.value),
            bool(dut.m_block_last.value),
        )
        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        if stalled is not None:
            assert output_valid and output == stalled
        stalled = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if input_fire:
            source_index += 1
            dut.s_valid.value = 0
        if len(received) == len(expected):
            break
    else:
        raise AssertionError("shared quant/dequant timed out")

    assert source_index == len(source)
    assert received == expected


@cocotb.test()
async def invalid_qp_is_flagged(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.s_size8.value = 0
    dut.s_coefficient.value = 123
    dut.s_qp_per.value = 9
    dut.s_qp_rem.value = 0
    dut.s_x.value = 0
    dut.s_y.value = 0
    dut.s_block_last.value = 1
    dut.s_valid.value = 1
    dut.m_ready.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.s_ready.value):
            dut.s_valid.value = 0
        if int(dut.m_valid.value):
            assert int(dut.m_qp_error.value)
            return
    raise AssertionError("invalid QP result timed out")

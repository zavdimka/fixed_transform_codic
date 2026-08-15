from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.chroma_tu8 import (
    chroma_qp, forward_transform_8, inverse_transform_8, quantize_dequantize_8,
)
from hevc_reference.quant import QUALITY_QPS

QUALITY_CODES = {"good": 0, "medium": 1, "poor": 2}


def expected_block(prediction, residual, quality):
    coefficients = forward_transform_8(residual)[1]
    qp = chroma_qp(QUALITY_QPS[quality])
    pairs = [[quantize_dequantize_8(v, qp) for v in row] for row in coefficients]
    quantized = [[pairs[y][x][0] for x in range(8)] for y in range(8)]
    dequantized = [[pairs[y][x][1] for x in range(8)] for y in range(8)]
    restored = inverse_transform_8(dequantized)[1]
    pixels = [(min(255, max(0, prediction[y][x] + restored[y][x])), x, y,
               x == 7 and y == 7) for y in range(8) for x in range(8)]
    coeffs = [(quantized[y][x], y * 8 + x, x == 7 and y == 7)
              for y in range(8) for x in range(8)]
    return coeffs, pixels


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(dut, prediction, residual, quality_code, rng):
    source_index = 0
    coeffs, pixels = [], []
    stalled = None
    for _ in range(5000):
        if not int(dut.s_valid.value) and source_index < 64 and rng.random() < 0.85:
            y, x = divmod(source_index, 8)
            dut.s_prediction.value = prediction[y][x]
            dut.s_residual.value = residual[y][x]
            dut.s_quality.value = quality_code
            dut.s_valid.value = 1
        dut.m_ready.value = int(rng.random() < 0.7)
        await RisingEdge(dut.clk)
        if int(dut.coefficient_write_enable.value):
            coeffs.append((dut.coefficient_write_data.value.signed_integer,
                           int(dut.coefficient_write_address.value),
                           bool(dut.coefficient_block_last.value)))
        output = (int(dut.m_reconstructed.value), int(dut.m_x.value),
                  int(dut.m_y.value), bool(dut.m_block_last.value),
                  bool(dut.m_block_error.value))
        valid, ready = int(dut.m_valid.value), int(dut.m_ready.value)
        if stalled is not None:
            assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            pixels.append(output)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0
        if len(pixels) == 64:
            break
    else:
        raise AssertionError("chroma TU8 loop timed out")
    assert source_index == 64
    assert len(coeffs) == 64
    return coeffs, pixels


@cocotb.test()
async def chroma_tu8_matches_reference_under_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC4208)
    for block_index, quality in enumerate(("good", "medium", "poor")):
        prediction = [[(x * 13 + y * 9 + block_index * 31) & 255
                       for x in range(8)] for y in range(8)]
        source = [[(x * 23 + y * 37 + block_index * 19) & 255
                   for x in range(8)] for y in range(8)]
        residual = [[source[y][x] - prediction[y][x] for x in range(8)] for y in range(8)]
        expected_coeffs, expected_pixels = expected_block(prediction, residual, quality)
        coeffs, pixels = await run_block(dut, prediction, residual, QUALITY_CODES[quality], rng)
        assert coeffs == expected_coeffs
        assert [p[:4] for p in pixels] == expected_pixels
        assert all(not p[4] for p in pixels)


@cocotb.test()
async def invalid_quality_falls_back_to_medium_and_sets_error(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    prediction = [[128] * 8 for _ in range(8)]
    residual = [[3] * 8 for _ in range(8)]
    expected_coeffs, expected_pixels = expected_block(prediction, residual, "medium")
    coeffs, pixels = await run_block(dut, prediction, residual, 3, random.Random(8))
    assert coeffs == expected_coeffs
    assert [p[:4] for p in pixels] == expected_pixels
    assert all(p[4] for p in pixels)

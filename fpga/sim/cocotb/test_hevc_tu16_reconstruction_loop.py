from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.transform import forward_transform_16, inverse_transform_16


QUALITY_CODES = {"good": 0, "medium": 1, "poor": 2}


def expected_block(prediction, residual, quality):
    coefficients = forward_transform_16(residual)[1]
    quantized = [[0] * 16 for _ in range(16)]
    dequantized = [[0] * 16 for _ in range(16)]
    qp = QUALITY_QPS[quality]
    for y in range(16):
        for x in range(16):
            quantized[y][x], dequantized[y][x] = (
                quantize_dequantize_coefficient(coefficients[y][x], qp)
            )
    restored_residual = inverse_transform_16(dequantized)[1]
    reconstructed = [
        [min(255, max(0, prediction[y][x] + restored_residual[y][x]))
         for x in range(16)]
        for y in range(16)
    ]
    coefficient_stream = [
        (quantized[y][x], y * 16 + x, x == 15 and y == 15)
        for x in range(16) for y in range(16)
    ]
    pixel_stream = [
        (reconstructed[y][x], x, y, x == 15 and y == 15)
        for y in range(16) for x in range(16)
    ]
    return coefficient_stream, pixel_stream


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(
    dut,
    prediction,
    residual,
    quality_code,
    rng,
    input_probability=0.85,
    ready_probability=0.7,
):
    source = [
        (prediction[y][x], residual[y][x])
        for y in range(16) for x in range(16)
    ]
    source_index = 0
    coefficients = []
    pixels = []
    stalled_output = None
    first_input_cycle = None
    final_output_cycle = None

    for cycle in range(30000):
        if not int(dut.s_valid.value) and source_index < 256:
            if rng.random() < input_probability:
                pred, resid = source[source_index]
                dut.s_prediction.value = pred
                dut.s_residual.value = resid
                dut.s_quality.value = quality_code
                dut.s_valid.value = 1

        dut.m_ready.value = int(rng.random() < ready_probability)
        await RisingEdge(dut.clk)

        if int(dut.coefficient_write_enable.value):
            coefficients.append((
                dut.coefficient_write_data.value.signed_integer,
                int(dut.coefficient_write_address.value),
                bool(dut.coefficient_block_last.value),
            ))

        output = (
            int(dut.m_reconstructed.value),
            int(dut.m_x.value),
            int(dut.m_y.value),
            bool(dut.m_block_last.value),
            bool(dut.m_block_error.value),
        )
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        if stalled_output is not None:
            assert valid == 1
            assert output == stalled_output
        stalled_output = output if valid and not ready else None
        if valid and ready:
            pixels.append(output)
            if len(pixels) == 256:
                final_output_cycle = cycle

        if int(dut.s_valid.value) and int(dut.s_ready.value):
            if first_input_cycle is None:
                first_input_cycle = cycle
            source_index += 1
            if source_index < 256 and rng.random() < input_probability:
                pred, resid = source[source_index]
                dut.s_prediction.value = pred
                dut.s_residual.value = resid
                dut.s_valid.value = 1
            else:
                dut.s_valid.value = 0

        if final_output_cycle is not None:
            break
    else:
        raise AssertionError("TU16 reconstruction loop timed out")

    dut.s_valid.value = 0
    dut.m_ready.value = 1
    for _ in range(3):
        if not int(dut.block_busy.value):
            break
        await RisingEdge(dut.clk)
    assert int(dut.block_busy.value) == 0
    assert source_index == 256
    assert len(coefficients) == 256
    assert first_input_cycle is not None
    return coefficients, pixels, final_output_cycle - first_input_cycle + 1


@cocotb.test()
async def reconstruction_loop_matches_reference_for_all_profiles(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x7E16)

    for block_index, quality in enumerate(("good", "medium", "poor")):
        prediction = [
            [(x * 11 + y * 7 + block_index * 23) & 255 for x in range(16)]
            for y in range(16)
        ]
        source = [
            [(x * 29 + y * 17 + block_index * 41) & 255 for x in range(16)]
            for y in range(16)
        ]
        residual = [
            [source[y][x] - prediction[y][x] for x in range(16)]
            for y in range(16)
        ]
        expected_coefficients, expected_pixels = expected_block(
            prediction, residual, quality
        )
        coefficients, pixels, _ = await run_block(
            dut, prediction, residual, QUALITY_CODES[quality], rng
        )
        assert coefficients == expected_coefficients
        assert [pixel[:4] for pixel in pixels] == expected_pixels
        assert all(not pixel[4] for pixel in pixels)


@cocotb.test()
async def invalid_quality_uses_medium_and_sets_block_error(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    prediction = [[128] * 16 for _ in range(16)]
    residual = [[1] * 16 for _ in range(16)]
    expected_coefficients, expected_pixels = expected_block(
        prediction, residual, "medium"
    )
    coefficients, pixels, cycles = await run_block(
        dut, prediction, residual, 3, random.Random(0xBAD),
        input_probability=1.0, ready_probability=1.0,
    )
    assert coefficients == expected_coefficients
    assert [pixel[:4] for pixel in pixels] == expected_pixels
    assert all(pixel[4] for pixel in pixels)
    dut._log.info("TU16 no-stall inclusive latency: %d cycles", cycles)
    assert cycles < 1000

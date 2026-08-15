from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_tu8 import (
    chroma_qp,
    forward_transform_8,
    inverse_transform_8,
    quantize_dequantize_8,
)
from hevc_reference.quant import QUALITY_QPS


QUALITY_CODES = {"good": 0, "medium": 1, "poor": 2}


def expected_block(prediction, residual, quality):
    transformed = forward_transform_8(residual)[1]
    qp = chroma_qp(QUALITY_QPS[quality])
    pairs = [
        [quantize_dequantize_8(transformed[y][x], qp) for x in range(8)]
        for y in range(8)
    ]
    quantized = [[pairs[y][x][0] for x in range(8)] for y in range(8)]
    dequantized = [[pairs[y][x][1] for x in range(8)] for y in range(8)]
    restored = inverse_transform_8(dequantized)[1]
    coefficients = [
        (quantized[y][x], y * 8 + x, x == 7 and y == 7)
        for y in range(8) for x in range(8)
    ]
    pixels = [
        (min(255, max(0, prediction[y][x] + restored[y][x])),
         x, y, x == 7 and y == 7)
        for y in range(8) for x in range(8)
    ]
    return coefficients, pixels


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    dut.descriptor_ready.value = 0
    dut.coefficient_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(dut, prediction, residual, quality, seed):
    source = [
        (prediction[y][x], residual[y][x])
        for y in range(8) for x in range(8)
    ]
    expected_coefficients, expected_pixels = expected_block(
        prediction, residual, quality
    )
    expected_cbf = any(value != 0 for value, _, _ in expected_coefficients)
    rng = random.Random(seed)
    source_index = 0
    pixels = []
    coefficients = []
    descriptors = []
    stalled_pixel = None
    stalled_coefficient = None
    stalled_descriptor = None

    for _ in range(15000):
        if not int(dut.s_valid.value) and source_index < 64:
            if rng.random() < 0.83:
                prediction_value, residual_value = source[source_index]
                dut.s_valid.value = 1
                dut.s_prediction.value = prediction_value
                dut.s_residual.value = residual_value
                dut.s_quality.value = QUALITY_CODES[quality]

        dut.m_ready.value = int(rng.random() < 0.71)
        dut.descriptor_ready.value = int(rng.random() < 0.67)
        dut.coefficient_ready.value = int(rng.random() < 0.69)
        await Timer(1, units="ns")

        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        pixel_valid = int(dut.m_valid.value)
        pixel_ready = int(dut.m_ready.value)
        pixel = (
            int(dut.m_reconstructed.value),
            int(dut.m_x.value),
            int(dut.m_y.value),
            bool(dut.m_block_last.value),
        )
        descriptor_valid = int(dut.descriptor_valid.value)
        descriptor_ready = int(dut.descriptor_ready.value)
        descriptor = bool(dut.descriptor_cbf.value)
        coefficient_valid = int(dut.coefficient_valid.value)
        coefficient_ready = int(dut.coefficient_ready.value)
        coefficient = (
            dut.coefficient.value.signed_integer,
            int(dut.coefficient_raster_address.value),
            bool(dut.coefficient_block_last.value),
        )

        if stalled_pixel is not None:
            assert pixel_valid and pixel == stalled_pixel
        if stalled_descriptor is not None:
            assert descriptor_valid and descriptor == stalled_descriptor
        if stalled_coefficient is not None:
            assert coefficient_valid and coefficient == stalled_coefficient
        stalled_pixel = pixel if pixel_valid and not pixel_ready else None
        stalled_descriptor = (
            descriptor if descriptor_valid and not descriptor_ready else None
        )
        stalled_coefficient = (
            coefficient if coefficient_valid and not coefficient_ready else None
        )

        if pixel_valid and pixel_ready:
            pixels.append(pixel)
        if descriptor_valid and descriptor_ready:
            descriptors.append(descriptor)
        if coefficient_valid and coefficient_ready:
            coefficients.append(coefficient)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if source_fire:
            source_index += 1
            dut.s_valid.value = 0

        if int(dut.block_done.value):
            assert source_index == 64
            assert pixels == expected_pixels
            assert descriptors == [expected_cbf]
            assert coefficients == (
                expected_coefficients if expected_cbf else []
            )
            assert not int(dut.block_error.value)
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"chroma TU8 bridge timed out source={source_index} "
        f"pixels={len(pixels)} descriptors={len(descriptors)} "
        f"coefficients={len(coefficients)} busy={int(dut.busy.value)}"
    )


@cocotb.test()
async def nonzero_and_zero_blocks_form_correct_cabac_inputs(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    prediction0 = [
        [(x * 13 + y * 9 + 47) & 255 for x in range(8)]
        for y in range(8)
    ]
    source0 = [
        [(x * 29 + y * 17 + 83) & 255 for x in range(8)]
        for y in range(8)
    ]
    residual0 = [
        [source0[y][x] - prediction0[y][x] for x in range(8)]
        for y in range(8)
    ]
    await run_block(dut, prediction0, residual0, "medium", 0xC8CAB)

    prediction1 = [[112 + ((x + y) & 7) for x in range(8)] for y in range(8)]
    residual1 = [[0] * 8 for _ in range(8)]
    await run_block(dut, prediction1, residual1, "poor", 0xCBF008)

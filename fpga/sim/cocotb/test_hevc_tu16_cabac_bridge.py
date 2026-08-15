from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

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
        [
            min(255, max(0, prediction[y][x] + restored_residual[y][x]))
            for x in range(16)
        ]
        for y in range(16)
    ]
    coefficient_stream = [
        (quantized[y][x], y * 16 + x, x == 15 and y == 15)
        for y in range(16)
        for x in range(16)
    ]
    pixel_stream = [
        (reconstructed[y][x], x, y, x == 15 and y == 15)
        for y in range(16)
        for x in range(16)
    ]
    return coefficient_stream, pixel_stream


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_prediction.value = 0
    dut.s_residual.value = 0
    dut.s_quality.value = QUALITY_CODES["medium"]
    dut.s_luma_mode_dc.value = 0
    dut.m_ready.value = 0
    dut.cu_ready.value = 0
    dut.coefficient_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(dut, prediction, residual, quality, mode_dc, seed):
    source = [
        (prediction[y][x], residual[y][x])
        for y in range(16)
        for x in range(16)
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

    for _ in range(40000):
        if not int(dut.s_valid.value) and source_index < len(source):
            if rng.random() < 0.83:
                prediction_value, residual_value = source[source_index]
                dut.s_valid.value = 1
                dut.s_prediction.value = prediction_value
                dut.s_residual.value = residual_value
                dut.s_quality.value = QUALITY_CODES[quality]
                dut.s_luma_mode_dc.value = int(mode_dc)

        dut.m_ready.value = int(rng.random() < 0.71)
        dut.cu_ready.value = int(rng.random() < 0.67)
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
        descriptor_valid = int(dut.cu_valid.value)
        descriptor_ready = int(dut.cu_ready.value)
        descriptor = (
            bool(dut.cu_luma_mode_dc.value),
            bool(dut.cu_luma_cbf.value),
        )
        coefficient_valid = int(dut.coefficient_valid.value)
        coefficient_ready = int(dut.coefficient_ready.value)
        coefficient = (
            dut.coefficient.value.signed_integer,
            int(dut.coefficient_raster_address.value),
            bool(dut.coefficient_block_last.value),
        )

        if stalled_pixel is not None:
            assert pixel_valid
            assert pixel == stalled_pixel
        if stalled_descriptor is not None:
            assert descriptor_valid
            assert descriptor == stalled_descriptor
        if stalled_coefficient is not None:
            assert coefficient_valid
            assert coefficient == stalled_coefficient
        stalled_pixel = pixel if pixel_valid and not pixel_ready else None
        stalled_descriptor = (
            descriptor if descriptor_valid and not descriptor_ready else None
        )
        stalled_coefficient = (
            coefficient
            if coefficient_valid and not coefficient_ready
            else None
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
            assert source_index == 256
            assert pixels == expected_pixels
            assert descriptors == [(bool(mode_dc), expected_cbf)]
            assert coefficients == (
                expected_coefficients if expected_cbf else []
            )
            assert not int(dut.busy.value)
            return

    raise AssertionError(
        f"TU16 CABAC bridge timed out: source={source_index} "
        f"pixels={len(pixels)} descriptors={len(descriptors)} "
        f"coefficients={len(coefficients)} busy={int(dut.busy.value)}"
    )


@cocotb.test()
async def nonzero_and_zero_blocks_form_correct_cabac_inputs(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    prediction0 = [
        [(x * 7 + y * 11 + 53) & 255 for x in range(16)]
        for y in range(16)
    ]
    source0 = [
        [(x * 29 + y * 17 + 91) & 255 for x in range(16)]
        for y in range(16)
    ]
    residual0 = [
        [source0[y][x] - prediction0[y][x] for x in range(16)]
        for y in range(16)
    ]
    await run_block(
        dut,
        prediction0,
        residual0,
        "medium",
        mode_dc=False,
        seed=0x7E16CAB,
    )

    prediction1 = [[96 + ((x + y) & 7) for x in range(16)] for y in range(16)]
    residual1 = [[0] * 16 for _ in range(16)]
    await run_block(
        dut,
        prediction1,
        residual1,
        "poor",
        mode_dc=True,
        seed=0xCBF000,
    )

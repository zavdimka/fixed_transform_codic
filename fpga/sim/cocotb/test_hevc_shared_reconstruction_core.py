from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.chroma_tu8 import (
    chroma_qp, forward_transform_8, inverse_transform_8,
    quantize_dequantize_8,
)
from hevc_reference.quant import QUALITY_QPS, quantize_dequantize_coefficient
from hevc_reference.transform import forward_transform_16, inverse_transform_16


QUALITY_NAMES = {0: "good", 1: "medium", 2: "poor", 3: "medium"}


def expected_block(prediction, residual, size8, chroma, quality_code):
    size = 8 if size8 else 16
    quality = QUALITY_NAMES[quality_code]
    luma_qp = QUALITY_QPS[quality]
    qp = chroma_qp(luma_qp) if chroma else luma_qp
    if size8:
        transformed = forward_transform_8(residual)[1]
        pairs = [[quantize_dequantize_8(value, qp) for value in row]
                 for row in transformed]
        restored = inverse_transform_8(
            [[pairs[y][x][1] for x in range(size)] for y in range(size)]
        )[1]
    else:
        transformed = forward_transform_16(residual)[1]
        pairs = [[quantize_dequantize_coefficient(value, qp) for value in row]
                 for row in transformed]
        restored = inverse_transform_16(
            [[pairs[y][x][1] for x in range(size)] for y in range(size)]
        )[1]
    coefficients = [
        (pairs[y][x][0], x, y, int(pairs[y][x][0] != 0),
         x == size - 1 and y == size - 1)
        for y in range(size) for x in range(size)
    ]
    pixels = [
        (min(255, max(0, prediction[y][x] + restored[y][x])),
         x, y, x == size - 1 and y == size - 1,
         quality_code == 3)
        for y in range(size) for x in range(size)
    ]
    return coefficients, pixels


async def reset(dut):
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.s_valid.value = 0
    dut.coefficient_ready.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_block(dut, prediction, residual, size8, chroma, quality, rng,
                    no_stall=False):
    size = 8 if size8 else 16
    expected_coefficients, expected_pixels = expected_block(
        prediction, residual, size8, chroma, quality)
    dut.command_size8.value = size8
    dut.command_chroma.value = chroma
    dut.command_quality.value = quality
    dut.command_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = int(dut.command_valid.value) and int(dut.command_ready.value)
        await RisingEdge(dut.clk)
        if fire:
            break
    dut.command_valid.value = 0

    source = [(prediction[y][x], residual[y][x])
              for y in range(size) for x in range(size)]
    source_index = 0
    coefficients = []
    pixels = []
    pixel_cycles = []
    coefficient_stalled = None
    pixel_stalled = None
    for cycle in range(50000):
        if not int(dut.s_valid.value) and source_index < len(source):
            if no_stall or rng.random() < 0.87:
                pred, resid = source[source_index]
                dut.s_prediction.value = pred
                dut.s_residual.value = resid
                dut.s_valid.value = 1
        dut.coefficient_ready.value = 1 if no_stall else int(rng.random() < 0.68)
        dut.m_ready.value = 1 if no_stall else int(rng.random() < 0.71)
        await Timer(1, units="ns")

        source_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        coefficient = (
            dut.coefficient_data.value.signed_integer,
            int(dut.coefficient_x.value), int(dut.coefficient_y.value),
            int(dut.coefficient_nonzero.value),
            bool(dut.coefficient_block_last.value),
        )
        coefficient_valid = int(dut.coefficient_valid.value)
        coefficient_ready = int(dut.coefficient_ready.value)
        if coefficient_stalled is not None:
            assert coefficient_valid and coefficient == coefficient_stalled
        coefficient_stalled = (coefficient if coefficient_valid and
                                 not coefficient_ready else None)
        if coefficient_valid and coefficient_ready:
            coefficients.append(coefficient)

        pixel = (
            int(dut.m_reconstructed.value), int(dut.m_x.value),
            int(dut.m_y.value), bool(dut.m_block_last.value),
            bool(dut.m_block_error.value),
        )
        pixel_valid = int(dut.m_valid.value)
        pixel_ready = int(dut.m_ready.value)
        if pixel_stalled is not None:
            assert pixel_valid and pixel == pixel_stalled
        pixel_stalled = pixel if pixel_valid and not pixel_ready else None
        if pixel_valid and pixel_ready:
            pixels.append(pixel)
            pixel_cycles.append(cycle)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if source_fire:
            source_index += 1
            if no_stall and source_index < len(source):
                pred, resid = source[source_index]
                dut.s_prediction.value = pred
                dut.s_residual.value = resid
                dut.s_valid.value = 1
            else:
                dut.s_valid.value = 0
        if int(dut.done.value):
            break
    else:
        raise AssertionError("shared reconstruction core timed out")

    assert source_index == size * size
    assert coefficients == expected_coefficients
    assert pixels == expected_pixels
    if no_stall:
        assert pixel_cycles == list(range(
            pixel_cycles[0], pixel_cycles[0] + size * size))
    assert not int(dut.busy.value)
    return cycle + 1


@cocotb.test()
async def luma_and_chroma_blocks_match_reference(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x5EC0A57)
    configurations = (
        (False, False, 0),
        (True, True, 1),
        (True, True, 2),
        (False, False, 3),
    )
    for block_index, (size8, chroma, quality) in enumerate(configurations):
        size = 8 if size8 else 16
        prediction = [
            [(x * 11 + y * 17 + block_index * 29) & 255
             for x in range(size)] for y in range(size)
        ]
        source = [
            [(x * 31 + y * 7 + block_index * 43) & 255
             for x in range(size)] for y in range(size)
        ]
        residual = [[source[y][x] - prediction[y][x]
                     for x in range(size)] for y in range(size)]
        await run_block(
            dut, prediction, residual, size8, chroma, quality, rng)


@cocotb.test()
async def no_stall_latency_is_bounded(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1A7E)
    for size8, chroma in ((False, False), (True, True)):
        size = 8 if size8 else 16
        prediction = [[128 for _ in range(size)] for _ in range(size)]
        residual = [[((x * 9 + y * 5) & 31) - 16
                     for x in range(size)] for y in range(size)]
        cycles = await run_block(
            dut, prediction, residual, size8, chroma, 1, rng, no_stall=True)
        dut._log.info("shared reconstruction TU%d no-stall latency: %d cycles",
                      size, cycles)
        assert cycles < (1700 if size == 16 else 450)

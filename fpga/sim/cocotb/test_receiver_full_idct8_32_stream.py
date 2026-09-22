from __future__ import annotations

import random
import sys
import types

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

if "PIL" not in sys.modules:
    pil_stub = types.ModuleType("PIL")
    pil_stub.Image = types.SimpleNamespace(Image=object)
    pil_stub.ImageDraw = types.SimpleNamespace()
    pil_stub.ImageFont = types.SimpleNamespace()
    sys.modules["PIL"] = pil_stub

import custom_codec_experiment as codec
import jpeg_radio_codec as core


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.command_ctu_index.value = 0
    dut.command_block_index.value = 0
    dut.command_plane.value = 0
    dut.command_mode.value = 0
    dut.command_quality.value = 0
    dut.command_coefficients.value = 0
    dut.load_start_valid.value = 0
    dut.load_ctu_index.value = 0
    dut.load_block_index.value = 0
    dut.load_plane.value = 0
    dut.load_mode.value = 0
    dut.load_quality.value = 0
    dut.load_coeff_valid.value = 0
    dut.load_coeff_address.value = 0
    dut.load_coeff_data.value = 0
    dut.load_base_valid.value = 0
    dut.load_base_coefficients.value = 0
    dut.load_base_plane.value = 0
    dut.load_commit_valid.value = 0
    dut.load_abort.value = 0
    dut.pixel_ready.value = 1
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def reference(coefficients, quality, plane):
    table = codec.layered_quant_tables(quality)[int(plane != 0)]
    return core.inverse_residual_dct(
        coefficients.astype(np.int64) * table,
        core.ArithmeticStats(),
    ).reshape(-1).tolist()


async def pulse_when_ready(dut, valid, ready):
    valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(ready.value):
            break
    await FallingEdge(dut.clk)
    valid.value = 0


async def load_sparse_block(dut, coefficients, quality, plane, tag):
    await FallingEdge(dut.clk)
    dut.load_ctu_index.value = tag
    dut.load_block_index.value = tag % 6
    dut.load_plane.value = plane
    dut.load_mode.value = tag % 3
    dut.load_quality.value = quality
    await pulse_when_ready(dut, dut.load_start_valid, dut.load_start_ready)

    for address, coefficient in enumerate(coefficients.reshape(-1)):
        if not coefficient:
            continue
        dut.load_coeff_address.value = address
        dut.load_coeff_data.value = int(coefficient)
        await pulse_when_ready(dut, dut.load_coeff_valid, dut.load_coeff_ready)

    await pulse_when_ready(dut, dut.load_commit_valid, dut.load_commit_ready)


async def receive_block(dut, expected, tag, plane):
    observed = []
    for _ in range(220):
        await RisingEdge(dut.clk)
        if int(dut.pixel_valid.value):
            observed.append(dut.pixel_residual.value.signed_integer)
            assert int(dut.pixel_ctu_index.value) == tag
            assert int(dut.pixel_block_index.value) == tag % 6
            assert int(dut.pixel_plane.value) == plane
            assert int(dut.pixel_mode.value) == tag % 3
            if int(dut.pixel_last.value):
                break
    assert observed == expected


@cocotb.test()
async def narrow_loader_is_bit_exact_and_unwritten_coefficients_are_zero(dut):
    await reset_dut(dut)
    rng = random.Random(0x510A)

    for tag in range(6):
        plane = tag % 3
        quality = 24 if tag & 1 else 20
        coefficients = np.zeros((8, 8), dtype=np.int16)
        for _ in range(5 + tag * 2):
            coefficients[rng.randrange(8), rng.randrange(8)] = rng.randint(
                -120, 120
            )
        await load_sparse_block(dut, coefficients, quality, plane, tag)
        await receive_block(
            dut, reference(coefficients, quality, plane), tag, plane
        )

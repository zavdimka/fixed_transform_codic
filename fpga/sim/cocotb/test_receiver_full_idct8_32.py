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
    dut.command_quality.value = 24
    dut.command_coefficients.value = 0
    dut.pixel_ready.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def reference(coefficients, quality, plane):
    table = codec.layered_quant_tables(quality)[int(plane != 0)]
    return core.inverse_residual_dct(
        coefficients.astype(np.int64) * table,
        core.ArithmeticStats(),
    ).reshape(-1).tolist()


async def run_block(
    dut, coefficients, quality, plane, tag, rng, *, ready_probability=0.83
):
    packed = sum(
        (int(value) & 0xFFF) << (12 * index)
        for index, value in enumerate(coefficients.reshape(-1))
    )
    while not int(dut.command_ready.value):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.command_ctu_index.value = tag
    dut.command_block_index.value = tag % 6
    dut.command_plane.value = plane
    dut.command_mode.value = tag % 3
    dut.command_quality.value = quality
    dut.command_coefficients.value = packed
    dut.command_valid.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.command_valid.value = 0

    observed = []
    held = None
    cycles = 0
    for cycles in range(300):
        dut.pixel_ready.value = int(rng.random() < ready_probability)
        await RisingEdge(dut.clk)
        valid = int(dut.pixel_valid.value)
        current = None
        if valid:
            current = (
                int(dut.pixel_index.value),
                dut.pixel_residual.value.signed_integer,
                int(dut.pixel_last.value),
                int(dut.pixel_ctu_index.value),
                int(dut.pixel_block_index.value),
                int(dut.pixel_plane.value),
                int(dut.pixel_mode.value),
            )
        if held is not None and not int(dut.pixel_ready.value):
            assert current == held
        held = current if valid and not int(dut.pixel_ready.value) else None
        if valid and int(dut.pixel_ready.value):
            observed.append(current)
            if current[2]:
                break
        await FallingEdge(dut.clk)

    assert len(observed) == 64
    assert [sample[0] for sample in observed] == list(range(64))
    assert [sample[1] for sample in observed] == reference(
        coefficients, quality, plane
    )
    assert all(sample[3:] == (tag, tag % 6, plane, tag % 3)
               for sample in observed)
    # With no output stalls the architecture takes at most 92 clocks from command
    # acceptance through the last sample: below the 92.6 clocks/block budget
    # for 720p30 at 60 MHz.
    return cycles + 1


@cocotb.test()
async def full_idct_is_bit_exact_for_both_presets_and_all_planes(dut):
    await reset_dut(dut)
    rng = random.Random(0xF011)
    vectors = []
    vectors.append((np.zeros((8, 8), dtype=np.int16), 24, 0))
    impulse = np.zeros((8, 8), dtype=np.int16)
    impulse[0, 0] = 700
    impulse[7, 7] = -17
    vectors.append((impulse, 20, 1))
    for index in range(12):
        matrix = np.zeros((8, 8), dtype=np.int16)
        for _ in range(15 + index):
            matrix[rng.randrange(8), rng.randrange(8)] = rng.randint(-140, 140)
        vectors.append((matrix, 24 if index & 1 else 20, index % 3))

    for tag, (coefficients, quality, plane) in enumerate(vectors):
        await run_block(dut, coefficients, quality, plane, tag, rng)


@cocotb.test()
async def unstalled_block_meets_720p30_cycle_budget(dut):
    await reset_dut(dut)
    rng = random.Random(0x32D5)
    coefficients = np.array(
        [[rng.randint(-90, 90) for _ in range(8)] for _ in range(8)],
        dtype=np.int16,
    )
    dut.pixel_ready.value = 1
    cycles = await run_block(
        dut, coefficients, 24, 0, 3, random.Random(1),
        ready_probability=1.0,
    )
    assert cycles <= 92

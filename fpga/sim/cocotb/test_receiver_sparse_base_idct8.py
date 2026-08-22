from __future__ import annotations

import random
import sys
import types

import numpy as np
import cocotb
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
    matrix = np.zeros((8, 8), dtype=np.int64)
    count = 3 if plane else 6
    for value, (row, column) in zip(coefficients[:count], core.ZIGZAG[:count]):
        matrix[row, column] = value
    return core.inverse_residual_dct(
        matrix * table, core.ArithmeticStats()
    ).reshape(-1).tolist()


async def run_block(dut, coefficients, quality, plane, tag, rng):
    packed = sum((value & 0xFFF) << (12 * index)
                 for index, value in enumerate(coefficients))
    while not int(dut.command_ready.value):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.command_ctu_index.value = tag
    dut.command_block_index.value = tag % 6
    dut.command_plane.value = plane
    dut.command_mode.value = tag % 4
    dut.command_quality.value = quality
    dut.command_coefficients.value = packed
    dut.command_valid.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.command_valid.value = 0

    observed = []
    held = None
    for _ in range(400):
        dut.pixel_ready.value = int(rng.random() < 0.72)
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
    assert [item[0] for item in observed] == list(range(64))
    assert [item[1] for item in observed] == reference(
        coefficients, quality, plane
    )
    assert all(item[3:] == (tag, tag % 6, plane, tag % 4)
               for item in observed)
    await FallingEdge(dut.clk)
    assert int(dut.done.value) or int(dut.command_ready.value)


@cocotb.test()
async def sparse_idct_matches_two_stage_fixed_point_reference(dut):
    await reset_dut(dut)
    rng = random.Random(0x1DC7)
    vectors = [
        ([0, 0, 0, 0, 0, 0], 24, 0),
        ([600, 0, 0, 0, 0, 0], 20, 0),
        ([-800, 300, -200, 0, 0, 0], 24, 1),
        ([2047, -1023, 1023, -1023, 1023, -1023], 20, 0),
    ]
    for index in range(16):
        plane = index % 3
        count = 3 if plane else 6
        values = [rng.randint(-900, 900) for _ in range(count)]
        values += [0] * (6 - count)
        vectors.append((values, 24 if index & 1 else 20, plane))

    for tag, (coefficients, quality, plane) in enumerate(vectors):
        await run_block(dut, coefficients, quality, plane, tag, rng)

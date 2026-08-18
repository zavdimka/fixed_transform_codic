from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from test_custom_dct8_pair32 import pack_row, reference
from test_custom_quant_pair4 import quant_table, round_div


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.command_quality24.value = 0
    dut.command_table_id.value = 0
    dut.s_valid.value = 0
    dut.s_row_a.value = 0
    dut.s_row_b.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_pair(dut, block_a, block_b, quality24, chroma, stalled):
    coefficient_a, _ = reference(block_a)
    coefficient_b, _ = reference(block_b)
    table = quant_table(24 if quality24 else 20, bool(chroma))
    expected = []
    for index in range(0, 64, 2):
        expected.append((
            index,
            round_div(coefficient_a[index], int(table[index])),
            round_div(coefficient_a[index + 1], int(table[index + 1])),
            round_div(coefficient_b[index], int(table[index])),
            round_div(coefficient_b[index + 1], int(table[index + 1])),
            index == 62,
        ))

    dut.command_quality24.value = quality24
    dut.command_table_id.value = chroma
    dut.command_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = bool(int(dut.command_ready.value))
        await RisingEdge(dut.clk)
        if fire:
            break
    dut.command_valid.value = 0

    row = 0
    offered = False
    received = []
    held = None
    rng = random.Random(0xD036 + quality24 * 7 + chroma * 19)
    for cycle in range(1000):
        if row < 8 and not offered and (not stalled or rng.random() < 0.82):
            dut.s_row_a.value = pack_row(block_a[row])
            dut.s_row_b.value = pack_row(block_b[row])
            dut.s_valid.value = 1
            offered = True
        dut.m_ready.value = int(not stalled or rng.random() < 0.71)

        await Timer(1, units="ns")
        input_fire = offered and bool(int(dut.s_ready.value))
        output = (
            int(dut.m_index.value),
            dut.m_a0.value.signed_integer,
            dut.m_a1.value.signed_integer,
            dut.m_b0.value.signed_integer,
            dut.m_b1.value.signed_integer,
            bool(int(dut.m_last.value)),
        )
        output_valid = bool(int(dut.m_valid.value))
        output_ready = bool(int(dut.m_ready.value))
        if held is not None:
            assert output_valid and output == held
        held = output if output_valid and not output_ready else None
        if output_valid and output_ready:
            received.append(output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if input_fire:
            row += 1
            offered = False
            dut.s_valid.value = 0
        if int(dut.done.value):
            latency = cycle + 1
            break
    else:
        raise AssertionError("DCT/quant pair timed out")

    assert row == 8
    assert received == expected
    assert not int(dut.input_error.value)
    assert not int(dut.saturated.value)
    assert not int(dut.busy.value)
    if not stalled:
        assert latency <= 140
        dut._log.info("DCT plus exact quant pair latency=%d cycles", latency)
    return latency


@cocotb.test()
async def all_profiles_match_python_arithmetic(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = np.random.default_rng(0xD036)
    for quality24 in (0, 1):
        for chroma in (0, 1):
            block_a = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
            block_b = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
            await run_pair(dut, block_a, block_b, quality24, chroma, False)


@cocotb.test()
async def combined_pipeline_survives_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = np.random.default_rng(0xBACC36)
    block_a = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
    block_b = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
    await run_pair(dut, block_a, block_b, 1, 0, True)

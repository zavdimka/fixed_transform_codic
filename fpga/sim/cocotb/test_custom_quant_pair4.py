from __future__ import annotations

from collections import deque
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np


LUMA_BASE = np.array([
    [16, 11, 10, 16, 24, 40, 51, 61],
    [12, 12, 14, 19, 26, 58, 60, 55],
    [14, 13, 16, 24, 40, 57, 69, 56],
    [14, 17, 22, 29, 51, 87, 80, 62],
    [18, 22, 37, 56, 68, 109, 103, 77],
    [24, 35, 55, 64, 81, 104, 113, 92],
    [49, 64, 78, 87, 103, 121, 120, 101],
    [72, 92, 95, 98, 112, 100, 103, 99],
], dtype=np.int64)
CHROMA_BASE = np.array([
    [17, 18, 24, 47, 99, 99, 99, 99],
    [18, 21, 26, 66, 99, 99, 99, 99],
    [24, 26, 56, 99, 99, 99, 99, 99],
    [47, 66, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
], dtype=np.int64)
ZIGZAG = (
    (0, 0), (0, 1), (1, 0), (2, 0), (1, 1), (0, 2),
)


def scaled(base: np.ndarray, quality: int) -> np.ndarray:
    scale = 5000 // quality
    return np.clip((base * scale + 50) // 100, 1, 255)


def quant_table(quality: int, chroma: bool) -> np.ndarray:
    base = CHROMA_BASE if chroma else LUMA_BASE
    table = scaled(base, quality)
    fine = scaled(base, quality + 2)
    count = 3 if chroma else 6
    for row, column in ZIGZAG[:count]:
        table[row, column] = fine[row, column]
    return table.reshape(-1)


def round_div(value: int, divisor: int) -> int:
    magnitude = (abs(value) + divisor // 2) // divisor
    return magnitude if value >= 0 else -magnitude


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.clear.value = 0
    dut.s_valid.value = 0
    dut.s_quality24.value = 0
    dut.s_table_id.value = 0
    dut.s_index.value = 0
    dut.s_a0.value = 0
    dut.s_a1.value = 0
    dut.s_b0.value = 0
    dut.s_b1.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_vectors(dut, vectors, *, stalled: bool) -> list[int]:
    next_input = 0
    offered = False
    expected = deque()
    accepted_cycles: list[int] = []
    held = None
    rng = random.Random(0x4D51 + int(stalled))

    for cycle in range(10000):
        if next_input < len(vectors) and not offered:
            quality24, chroma, index, values = vectors[next_input]
            dut.s_quality24.value = quality24
            dut.s_table_id.value = chroma
            dut.s_index.value = index
            dut.s_a0.value, dut.s_a1.value, dut.s_b0.value, dut.s_b1.value = values
            dut.s_valid.value = 1
            offered = True
        dut.m_ready.value = int(not stalled or rng.random() < 0.67)

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
            assert expected
            assert output == expected.popleft()

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if input_fire:
            quality24, chroma, index, values = vectors[next_input]
            table = quant_table(24 if quality24 else 20, bool(chroma))
            divisors = (int(table[index]), int(table[index + 1]))
            quantized = (
                round_div(values[0], divisors[0]),
                round_div(values[1], divisors[1]),
                round_div(values[2], divisors[0]),
                round_div(values[3], divisors[1]),
            )
            expected.append((index, *quantized, index == 62))
            accepted_cycles.append(cycle)
            next_input += 1
            offered = False
            dut.s_valid.value = 0

        if next_input == len(vectors) and not expected and not int(dut.busy.value):
            break
    else:
        raise AssertionError("quantizer stream timed out")

    assert not int(dut.input_error.value)
    assert not int(dut.saturated.value)
    return accepted_cycles


@cocotb.test()
async def q20_q24_all_entries_are_exact_at_two_cycle_interval(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x2024)
    vectors = []
    for quality24 in (0, 1):
        for chroma in (0, 1):
            for index in range(0, 64, 2):
                values = tuple(rng.randrange(-32768, 32768) for _ in range(4))
                vectors.append((quality24, chroma, index, values))
    accepted = await run_vectors(dut, vectors, stalled=False)
    intervals = [b - a for a, b in zip(accepted[1:], accepted[2:])]
    assert intervals and set(intervals) == {2}


@cocotb.test()
async def random_backpressure_preserves_exact_results(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xB4C2)
    vectors = [
        (
            rng.randrange(2), rng.randrange(2), rng.randrange(32) * 2,
            tuple(rng.randrange(-32768, 32768) for _ in range(4)),
        )
        for _ in range(80)
    ]
    await run_vectors(dut, vectors, stalled=True)


@cocotb.test()
async def odd_index_error_is_sticky_until_clear(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.s_index.value = 1
    dut.s_valid.value = 1
    while True:
        await Timer(1, units="ns")
        fire = bool(int(dut.s_ready.value))
        await RisingEdge(dut.clk)
        if fire:
            break
    dut.s_valid.value = 0
    await Timer(1, units="ns")
    assert int(dut.input_error.value)
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await Timer(1, units="ns")
    assert not int(dut.input_error.value)

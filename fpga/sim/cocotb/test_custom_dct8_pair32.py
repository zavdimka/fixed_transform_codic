from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

DCT_Q14 = np.array([
    [5793, 5793, 5793, 5793, 5793, 5793, 5793, 5793],
    [8035, 6811, 4551, 1598, -1598, -4551, -6811, -8035],
    [7568, 3135, -3135, -7568, -7568, -3135, 3135, 7568],
    [6811, -1598, -8035, -4551, 4551, 8035, 1598, -6811],
    [5793, -5793, -5793, 5793, 5793, -5793, -5793, 5793],
    [4551, -8035, 1598, 6811, -6811, -1598, 8035, -4551],
    [3135, -7568, 7568, -3135, -3135, 7568, -7568, 3135],
    [1598, -4551, 6811, -8035, 8035, -6811, 4551, -1598],
], dtype=np.int64)


def pack_row(row: np.ndarray) -> int:
    value = 0
    for lane, sample in enumerate(row):
        value |= (int(sample) & 0xFFFF) << (lane * 16)
    return value


def round_shift(values: np.ndarray) -> np.ndarray:
    magnitude = (np.abs(values) + 8192) >> 14
    return np.where(values < 0, -magnitude, magnitude)


def reference(block: np.ndarray) -> tuple[list[int], int]:
    saturations = 0
    first_unclipped = round_shift(DCT_Q14 @ block.astype(np.int64))
    saturations += int(np.count_nonzero((first_unclipped < -4096) |
                                       (first_unclipped > 4095)))
    first = np.clip(first_unclipped, -4096, 4095)
    output_unclipped = round_shift(first @ DCT_Q14.T)
    saturations += int(np.count_nonzero((output_unclipped < -32768) |
                                       (output_unclipped > 32767)))
    output = np.clip(output_unclipped, -32768, 32767)
    return [int(value) for value in output.reshape(-1)], saturations


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.command_valid.value = 0
    dut.s_valid.value = 0
    dut.s_row_a.value = 0
    dut.s_row_b.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_pair(
    dut,
    block_a: np.ndarray,
    block_b: np.ndarray,
    *,
    stalled: bool,
) -> tuple[list[int], list[int], int]:
    expected_a, saturation_a = reference(block_a)
    expected_b, saturation_b = reference(block_b)
    rng = random.Random(0xD8C7 + int(stalled))

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
    received_a: list[int] = []
    received_b: list[int] = []
    held = None
    first_output_cycle = None
    for cycle in range(1000):
        if row < 8 and not offered and (not stalled or rng.random() < 0.81):
            dut.s_row_a.value = pack_row(block_a[row])
            dut.s_row_b.value = pack_row(block_b[row])
            dut.s_valid.value = 1
            offered = True
        dut.m_ready.value = int(not stalled or rng.random() < 0.68)

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
            index, a0, a1, b0, b1, last = output
            assert index == len(received_a)
            assert last == (index == 62)
            received_a.extend((a0, a1))
            received_b.extend((b0, b1))
            if first_output_cycle is None:
                first_output_cycle = cycle

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
        raise AssertionError("paired custom DCT timed out")

    assert row == 8
    assert received_a == expected_a
    assert received_b == expected_b
    assert bool(int(dut.saturated.value)) == bool(saturation_a + saturation_b)
    assert not int(dut.busy.value)
    if not stalled:
        assert first_output_cycle is not None
        assert latency <= 110
        dut._log.info(
            "two DCT8 blocks latency=%d cycles, output starts=%d",
            latency,
            first_output_cycle,
        )
    return received_a, received_b, latency


@cocotb.test()
async def directed_and_random_pairs_match_q14_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    directed_a = np.full((8, 8), 255, dtype=np.int16)
    directed_b = np.fromfunction(
        lambda y, x: np.where((x + y) & 1, 255, -255), (8, 8), dtype=int
    ).astype(np.int16)
    await run_pair(dut, directed_a, directed_b, stalled=False)

    # Outside the physical 9-bit residual range, but proves both saturation
    # stages and the sticky status output instead of leaving them unexercised.
    extreme_a = np.full((8, 8), 32767, dtype=np.int16)
    extreme_b = np.fromfunction(
        lambda y, x: np.where((x + y) & 1, 32767, -32768),
        (8, 8), dtype=int,
    ).astype(np.int16)
    await run_pair(dut, extreme_a, extreme_b, stalled=False)

    rng = np.random.default_rng(0x1432)
    for _ in range(12):
        block_a = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
        block_b = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
        await run_pair(dut, block_a, block_b, stalled=False)


@cocotb.test()
async def input_and_output_backpressure_preserve_pair(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = np.random.default_rng(0xBACC)
    block_a = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
    block_b = rng.integers(-255, 256, size=(8, 8), dtype=np.int16)
    await run_pair(dut, block_a, block_b, stalled=True)

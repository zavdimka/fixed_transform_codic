from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np


BLOCKS_PER_CTU = 6


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.clear_error.value = 0
    dut.block_valid.value = 0
    dut.block_table_id.value = 0
    dut.block_base_count.value = 6
    dut.s_valid.value = 0
    dut.s_coefficient.value = 0
    dut.m_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def clear_idle_scheduler(dut) -> None:
    assert not int(dut.busy.value)
    dut.clear_error.value = 1
    await RisingEdge(dut.clk)
    dut.clear_error.value = 0
    await Timer(1, units="ns")


async def replay_stripe(
    dut,
    coefficients: np.ndarray,
    table_ids: np.ndarray,
    base_counts: np.ndarray,
) -> list[int]:
    flat_coefficients = coefficients.reshape(-1, 64)
    flat_tables = table_ids.reshape(-1)
    flat_base_counts = base_counts.reshape(-1)
    block_count = len(flat_coefficients)
    next_block = 0
    loading_block: int | None = None
    coefficient_index = 0
    block_offered = False
    coefficient_offered = False
    completed_blocks = 0
    ctu_completion_cycles: list[int] = []

    for cycle in range(200000):
        if loading_block is None and next_block < block_count and not block_offered:
            dut.block_table_id.value = int(flat_tables[next_block])
            dut.block_base_count.value = int(flat_base_counts[next_block])
            dut.block_valid.value = 1
            block_offered = True

        if loading_block is not None and not coefficient_offered:
            dut.s_coefficient.value = int(
                flat_coefficients[loading_block, coefficient_index]
            ) & 0xFFF
            dut.s_valid.value = 1
            coefficient_offered = True

        await Timer(1, units="ns")
        block_fire = block_offered and bool(int(dut.block_ready.value))
        coefficient_fire = coefficient_offered and bool(int(dut.s_ready.value))

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if block_fire:
            loading_block = next_block
            next_block += 1
            coefficient_index = 0
            block_offered = False
            dut.block_valid.value = 0
        if coefficient_fire:
            coefficient_index += 1
            coefficient_offered = False
            dut.s_valid.value = 0
            if coefficient_index == 64:
                loading_block = None
        if int(dut.block_done.value):
            completed_blocks += 1
            if completed_blocks % BLOCKS_PER_CTU == 0:
                ctu_completion_cycles.append(cycle + 1)
        if completed_blocks == block_count and not int(dut.busy.value):
            assert next_block == block_count
            assert len(ctu_completion_cycles) == coefficients.shape[0]
            return ctu_completion_cycles

    raise AssertionError("representative coefficient trace timed out")


def intervals_from_completions(completions: list[int]) -> list[int]:
    return [completions[0], *(
        current - previous for previous, current in zip(completions, completions[1:])
    )]


@cocotb.test()
async def q20_q24_720p_ctu_intervals(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    trace_path = Path(os.environ["CUSTOM_SCHEDULER_TRACE_FILE"])
    qualities = tuple(
        int(value) for value in
        os.environ.get("CUSTOM_TRACE_QUALITIES", "20,24").split(",")
    )

    with np.load(trace_path) as trace:
        assert int(trace["width"]) == 1280
        assert int(trace["height"]) == 720
        for quality in qualities:
            prefix = f"q{quality}"
            coefficients = trace[f"{prefix}_coefficients"]
            table_ids = trace[f"{prefix}_table_ids"]
            base_counts = trace[f"{prefix}_base_counts"]
            assert coefficients.shape == (45, 80, 6, 64)
            intervals: list[int] = []
            for stripe in range(coefficients.shape[0]):
                await clear_idle_scheduler(dut)
                completions = await replay_stripe(
                    dut,
                    coefficients[stripe],
                    table_ids[stripe],
                    base_counts[stripe],
                )
                intervals.extend(intervals_from_completions(completions))

            average = float(np.mean(intervals))
            p95 = int(np.percentile(intervals, 95, method="higher"))
            worst = max(intervals)
            dut._log.info(
                "Q%d scheduler CTU cycles: avg=%.2f p95=%d worst=%d",
                quality, average, p95, worst,
            )
            assert len(intervals) == 45 * 80
            assert min(intervals) > 0
            assert not int(dut.coefficient_saturated.value)
            assert not int(dut.input_error.value)

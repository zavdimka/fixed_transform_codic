from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np


BLOCKS_PER_CTU = 6
BASE_LIMIT_BITS = 2048 * 8
ENHANCEMENT_LIMIT_BITS = 1536 * 8
# The block-to-byte wrapper does not yet accept the 2-bit CTU intra prefix.
# Six block tails reserve 148 base bits/CTU; the later stream mux must add the
# omitted 160 mode bits/stripe and use the full 12000-bit stripe reservation.
BASE_RESERVED_BITS = 80 * 148
ENHANCEMENT_RESERVED_BITS = 1920


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.finish_valid.value = 0
    dut.block_valid.value = 0
    dut.block_table_id.value = 0
    dut.block_base_count.value = 6
    dut.coefficient_valid.value = 0
    dut.coefficient.value = 0
    dut.m_ready.value = 1
    dut.base_limit_bits.value = BASE_LIMIT_BITS
    dut.enhancement_limit_bits.value = ENHANCEMENT_LIMIT_BITS
    dut.base_reserved_bits.value = BASE_RESERVED_BITS
    dut.enhancement_reserved_bits.value = ENHANCEMENT_RESERVED_BITS
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start_stripe(dut, stripe: int) -> None:
    dut.finish_valid.value = 0
    dut.start_valid.value = 1
    while True:
        await Timer(1, units="ns")
        start_fire = bool(int(dut.start_ready.value))
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if start_fire:
            dut.start_valid.value = 0
            if not int(dut.busy.value) or int(dut.fatal_error.value):
                raise AssertionError(
                    f"stripe {stripe} start was not committed: "
                    f"busy={int(dut.busy.value)} fatal={int(dut.fatal_error.value)} "
                    f"start_ready={int(dut.start_ready.value)} "
                    f"finish_done={int(dut.finish_done.value)}"
                )
            return


async def replay_stripe(
    dut,
    stripe: int,
    coefficients: np.ndarray,
    table_ids: np.ndarray,
    base_counts: np.ndarray,
) -> tuple[list[int], int, int, int]:
    flat_coefficients = coefficients.reshape(-1, 64)
    flat_tables = table_ids.reshape(-1)
    flat_base_counts = base_counts.reshape(-1)
    block_count = len(flat_coefficients)
    next_block = 0
    loading_block: int | None = None
    coefficient_index = 0
    block_offered = False
    coefficient_offered = False
    finish_offered = False
    finish_accepted = False
    completed_blocks = 0
    ctu_completion_cycles: list[int] = []
    output_bytes = 0
    drops = 0

    for cycle in range(200000):
        if int(dut.fatal_error.value) or not int(dut.busy.value):
            raise AssertionError(
                f"stripe {stripe} stopped at cycle {cycle}: "
                f"busy={int(dut.busy.value)} fatal={int(dut.fatal_error.value)} "
                f"writer_error={int(dut.writer_fatal_error.value)} "
                f"guard_error={int(dut.writer.guard_fatal_error.value)} "
                f"packer_error={int(dut.writer.packer_input_error.value)} "
                f"limit={int(dut.base_limit_bits.value)}/"
                f"{int(dut.enhancement_limit_bits.value)} "
                f"reserve={int(dut.base_reserved_bits.value)}/"
                f"{int(dut.enhancement_reserved_bits.value)} "
                f"finish_valid={int(dut.finish_valid.value)}"
            )
        if loading_block is None and next_block < block_count and not block_offered:
            dut.block_table_id.value = int(flat_tables[next_block])
            dut.block_base_count.value = int(flat_base_counts[next_block])
            dut.block_valid.value = 1
            block_offered = True

        if loading_block is not None and not coefficient_offered:
            dut.coefficient.value = int(
                flat_coefficients[loading_block, coefficient_index]
            ) & 0xFFF
            dut.coefficient_valid.value = 1
            coefficient_offered = True

        if (completed_blocks == block_count and not finish_offered
                and not finish_accepted):
            dut.finish_valid.value = 1
            finish_offered = True

        await Timer(1, units="ns")
        block_fire = block_offered and bool(int(dut.block_ready.value))
        coefficient_fire = coefficient_offered and bool(
            int(dut.coefficient_ready.value)
        )
        finish_fire = finish_offered and bool(int(dut.finish_ready.value))
        output_fire = bool(int(dut.m_valid.value))

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
            dut.coefficient_valid.value = 0
            if coefficient_index == 64:
                loading_block = None
        if int(dut.block_done.value):
            completed_blocks += 1
            if completed_blocks % BLOCKS_PER_CTU == 0:
                ctu_completion_cycles.append(cycle + 1)
        if int(dut.drop_pulse.value):
            drops += 1
        if output_fire:
            output_bytes += 1
        if finish_fire:
            finish_offered = False
            finish_accepted = True
            dut.finish_valid.value = 0
        if finish_accepted and int(dut.finish_done.value):
            dut.finish_valid.value = 0
            assert next_block == block_count
            assert len(ctu_completion_cycles) == coefficients.shape[0]
            return ctu_completion_cycles, cycle + 1, output_bytes, drops

    raise AssertionError(
        f"representative block entropy trace {stripe} timed out: "
        f"next={next_block}/{block_count} loading={loading_block} "
        f"completed={completed_blocks} finish_offered={finish_offered} "
        f"finish_accepted={finish_accepted} busy={int(dut.busy.value)} "
        f"finish_ready={int(dut.finish_ready.value)} "
        f"finish_done={int(dut.finish_done.value)} "
        f"fatal={int(dut.fatal_error.value)} "
        f"scanner_error={int(dut.scanner_input_error.value)} "
        f"scanner_latched={int(dut.scanner_error_latched.value)} "
        f"token_error={int(dut.token_input_error.value)} "
        f"writer_error={int(dut.writer_fatal_error.value)} "
        f"base_used={int(dut.base_used_bits.value)} "
        f"enh_used={int(dut.enhancement_used_bits.value)}"
    )


def intervals_from_completions(completions: list[int]) -> list[int]:
    return [completions[0], *(
        current - previous for previous, current in zip(completions, completions[1:])
    )]


@cocotb.test()
async def q20_q24_720p_full_entropy_intervals(dut) -> None:
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
            stripe_cycles: list[int] = []
            total_bytes = 0
            total_drops = 0
            for stripe in range(coefficients.shape[0]):
                await start_stripe(dut, stripe)
                completions, cycles, output_bytes, drops = await replay_stripe(
                    dut,
                    stripe,
                    coefficients[stripe],
                    table_ids[stripe],
                    base_counts[stripe],
                )
                intervals.extend(intervals_from_completions(completions))
                stripe_cycles.append(cycles)
                total_bytes += output_bytes
                total_drops += drops
                assert not int(dut.fatal_error.value)
                assert not int(dut.coefficient_saturated.value)
                assert not int(dut.busy.value)
                assert int(dut.base_used_bits.value) <= BASE_LIMIT_BITS
                assert int(dut.enhancement_used_bits.value) <= ENHANCEMENT_LIMIT_BITS

            average = float(np.mean(intervals))
            p95 = int(np.percentile(intervals, 95, method="higher"))
            worst = max(intervals)
            effective = float(sum(stripe_cycles) / (45 * 80))
            worst_stripe = float(max(stripe_cycles) / 80)
            dut._log.info(
                "Q%d full entropy CTU cycles: avg=%.2f p95=%d worst=%d "
                "effective=%.2f worst_stripe=%.2f bytes=%d drops=%d",
                quality, average, p95, worst, effective, worst_stripe,
                total_bytes, total_drops,
            )
            assert len(intervals) == 45 * 80
            assert min(intervals) > 0
            assert total_bytes > 0
            assert total_drops == 0
            assert p95 <= 500
            assert worst <= 648
            assert effective <= 450.0

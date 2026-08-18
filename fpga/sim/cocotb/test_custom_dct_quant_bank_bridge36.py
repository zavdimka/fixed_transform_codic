from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from custom_coefficient_scanner import scan_quantized_block
from test_custom_coefficient_scanner8 import operation_tuple
from test_custom_dct8_pair32 import pack_row, reference
from test_custom_quant_pair4 import quant_table, round_div


def quantized(block: np.ndarray, quality24: int, table_id: int) -> list[int]:
    coefficients, saturations = reference(block)
    assert not saturations
    table = quant_table(24 if quality24 else 20, bool(table_id))
    return [
        max(-2048, min(2047, round_div(value, int(table[index]))))
        for index, value in enumerate(coefficients)
    ]


def dut_operation(dut) -> tuple[int, ...]:
    return (
        int(dut.m_op_type.value),
        int(dut.m_layer.value),
        int(dut.m_mandatory.value),
        int(dut.m_reserve_release.value),
        int(dut.m_table_class.value),
        int(dut.m_table_id.value),
        int(dut.m_symbol.value),
        int(dut.m_amplitude.value),
        int(dut.m_amplitude_length.value),
        int(dut.m_raw_value.value),
        int(dut.m_raw_length.value),
        int(dut.m_eob_required.value),
        int(dut.m_last.value),
    )


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.clear_error.value = 0
    dut.command_valid.value = 0
    dut.command_quality24.value = 0
    dut.command_table_id.value = 0
    dut.command_base_count.value = 6
    dut.s_valid.value = 0
    dut.s_row_a.value = 0
    dut.s_row_b.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def smooth_block(offset: int, dx: int, dy: int, ripple: int) -> np.ndarray:
    return np.fromfunction(
        lambda y, x: offset + dx * x + dy * y + ripple * ((x + y) & 1),
        (8, 8),
        dtype=int,
    ).astype(np.int16)


async def run_ctu(dut, pairs, *, stalled: bool) -> tuple[int, list[int]]:
    expected = []
    for block_a, block_b, quality24, table_id, base_count in pairs:
        for block in (block_a, block_b):
            expected.extend(
                operation_tuple(operation)
                for operation in scan_quantized_block(
                    quantized(block, quality24, table_id), table_id, base_count
                )
            )

    rng = random.Random(0xB4A36 + int(stalled))
    command_pair = 0
    feeding_pair = None
    row = 0
    row_offered = False
    observed = []
    held = None
    command_cycles = []
    transform_count = 0
    block_count = 0
    pair_count = 0

    for cycle in range(5000):
        if feeding_pair is None and command_pair < len(pairs):
            _, _, quality24, table_id, base_count = pairs[command_pair]
            dut.command_quality24.value = quality24
            dut.command_table_id.value = table_id
            dut.command_base_count.value = base_count
            dut.command_valid.value = 1
        else:
            dut.command_valid.value = 0

        if feeding_pair is not None and not row_offered:
            if not stalled or rng.random() < 0.86:
                block_a, block_b, _, _, _ = pairs[feeding_pair]
                dut.s_row_a.value = pack_row(block_a[row])
                dut.s_row_b.value = pack_row(block_b[row])
                dut.s_valid.value = 1
                row_offered = True
        dut.m_ready.value = int(not stalled or rng.random() < 0.71)

        await Timer(1, units="ns")
        command_fire = (
            feeding_pair is None
            and command_pair < len(pairs)
            and bool(int(dut.command_ready.value))
        )
        input_fire = row_offered and bool(int(dut.s_ready.value))
        output_valid = bool(int(dut.m_valid.value))
        output_ready = bool(int(dut.m_ready.value))
        current = dut_operation(dut) if output_valid else None
        if held is not None:
            assert current == held
        if current is not None and output_ready:
            observed.append(current)
        held = current if current is not None and not output_ready else None

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if command_fire:
            feeding_pair = command_pair
            command_pair += 1
            row = 0
            command_cycles.append(cycle)
            dut.command_valid.value = 0
        if input_fire:
            row += 1
            row_offered = False
            dut.s_valid.value = 0
            if row == 8:
                feeding_pair = None
        transform_count += int(dut.transform_done.value)
        block_count += int(dut.block_done.value)
        pair_count += int(dut.pair_done.value)

        if (
            pair_count == len(pairs)
            and command_pair == len(pairs)
            and not int(dut.busy.value)
        ):
            latency = cycle + 1
            break
    else:
        raise AssertionError("DCT/quant/coefficient-bank CTU timed out")

    assert observed == expected
    assert transform_count == len(pairs)
    assert block_count == 2 * len(pairs)
    assert pair_count == len(pairs)
    assert not int(dut.input_error.value)
    assert not int(dut.saturated.value)
    return latency, command_cycles


@cocotb.test()
async def three_pair_yuv422_ctu_overlaps_transform_and_scan(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    pairs = (
        (
            smooth_block(-16, 3, 2, 1), smooth_block(11, -2, 3, 2),
            1, 0, 6,
        ),
        (
            smooth_block(8, 4, -1, 1), smooth_block(-9, 1, 4, -2),
            1, 0, 6,
        ),
        (
            smooth_block(3, 2, 1, 1), smooth_block(-5, -1, 2, 1),
            1, 1, 3,
        ),
    )
    latency, commands = await run_ctu(dut, pairs, stalled=False)
    assert len(commands) == 3
    assert max(b - a for a, b in zip(commands, commands[1:])) <= 140
    dut._log.info(
        "three-pair CTU latency=%d cycles, command cycles=%s", latency, commands
    )


@cocotb.test()
async def complete_bridge_is_lossless_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    pairs = (
        (
            smooth_block(-7, 5, 2, 3), smooth_block(6, -3, 4, -2),
            0, 0, 6,
        ),
        (
            smooth_block(4, 2, -4, 2), smooth_block(-2, 4, 1, 3),
            0, 1, 3,
        ),
    )
    await run_ctu(dut, pairs, stalled=True)


@cocotb.test()
async def invalid_pair_metadata_does_not_start_or_deadlock_transform(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.command_base_count.value = 1
    dut.command_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.command_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.command_valid.value = 0
    assert int(dut.input_error.value)
    assert not int(dut.busy.value)
    assert not int(dut.transform_done.value)

    dut.clear_error.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.clear_error.value = 0
    assert not int(dut.input_error.value)

    pairs = ((
        smooth_block(1, 2, 3, 1), smooth_block(-1, -2, 1, 2),
        1, 0, 6,
    ),)
    await run_ctu(dut, pairs, stalled=False)

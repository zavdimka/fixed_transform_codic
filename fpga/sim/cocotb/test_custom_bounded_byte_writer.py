from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_budget_writer import Admission, BudgetToken, DualBudgetWriter, Layer
from custom_token_byte_packer import TokenBytePacker, left_align_token


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.finish_valid.value = 0
    dut.s_valid.value = 0
    dut.s_layer.value = 0
    dut.s_bits.value = 0
    dut.s_length.value = 0
    dut.s_mandatory.value = 0
    dut.s_reserve_release.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start(dut, limits: tuple[int, int], reserves: tuple[int, int]) -> None:
    dut.base_limit_bits.value, dut.enhancement_limit_bits.value = limits
    dut.base_reserved_bits.value, dut.enhancement_reserved_bits.value = reserves
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0


@cocotb.test()
async def budget_guard_and_byte_packer_match_composed_python_model(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    limits = (80, 56)
    reserves = (8, 8)
    await start(dut, limits, reserves)

    rng = random.Random(0xB01DED)
    tokens: list[BudgetToken] = []
    for _ in range(32):
        layer = Layer(rng.randrange(2))
        length = rng.randrange(1, 17)
        value = left_align_token(rng.getrandbits(length), length)
        tokens.append(BudgetToken(layer, value, length))
    tokens.extend((
        BudgetToken(Layer.BASE, left_align_token(0xB, 4), 4, True, 8),
        BudgetToken(Layer.ENHANCEMENT, left_align_token(0x5, 3), 3, True, 8),
    ))

    guard = DualBudgetWriter(*limits, *reserves)
    expected_drops = 0
    for token in tokens:
        if guard.submit(token) is Admission.DROPPED:
            expected_drops += 1
    assert not guard.fatal
    guard.finish()

    packer = TokenBytePacker()
    for token in guard.accepted:
        packer.submit(token.layer, token.value, token.bit_length)
    packer.finish()
    expected_output = [(int(item.layer), item.value) for item in packer.output]

    source_index = 0
    source_active = False
    finish_active = False
    observed: list[tuple[int, int]] = []
    observed_drops = 0
    stalled_output: tuple[int, int] | None = None
    drive_rng = random.Random(0x5157E4D)

    for _ in range(30000):
        if not source_active and source_index < len(tokens) and drive_rng.random() < 0.8:
            token = tokens[source_index]
            dut.s_layer.value = int(token.layer)
            dut.s_bits.value = token.value
            dut.s_length.value = token.bit_length
            dut.s_mandatory.value = token.mandatory
            dut.s_reserve_release.value = token.reserve_release
            dut.s_valid.value = 1
            source_active = True

        if source_index == len(tokens) and not source_active and not finish_active:
            dut.finish_valid.value = 1
            finish_active = True

        dut.m_ready.value = int(drive_rng.random() < 0.6)
        await Timer(1, units="ns")

        current_output = None
        if int(dut.m_valid.value):
            current_output = (int(dut.m_layer.value), int(dut.m_byte.value))
        if stalled_output is not None:
            assert current_output == stalled_output

        source_fire = source_active and bool(int(dut.s_ready.value))
        finish_fire = finish_active and bool(int(dut.finish_ready.value))
        output_fire = current_output is not None and bool(int(dut.m_ready.value))
        stalled_output = current_output if current_output is not None and not output_fire else None
        if output_fire:
            observed.append(current_output)

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        if int(dut.drop_pulse.value):
            observed_drops += 1
        if source_fire:
            source_index += 1
            source_active = False
            dut.s_valid.value = 0
        if finish_fire:
            finish_active = False
            dut.finish_valid.value = 0
        if int(dut.finish_done.value):
            break
    else:
        raise AssertionError("bounded byte writer timed out")

    assert not int(dut.fatal_error.value)
    assert observed_drops == expected_drops
    assert observed == expected_output
    assert int(dut.base_used_bits.value) == guard.used[0]
    assert int(dut.enhancement_used_bits.value) == guard.used[1]
    assert int(dut.base_byte_count.value) == packer.byte_count[0]
    assert int(dut.enhancement_byte_count.value) == packer.byte_count[1]
    assert not int(dut.busy.value)


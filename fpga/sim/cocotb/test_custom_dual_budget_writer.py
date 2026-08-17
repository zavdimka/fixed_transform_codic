from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from custom_budget_writer import Admission, BudgetToken, DualBudgetWriter, Layer


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


async def start_writer(dut, limits: tuple[int, int], reserves: tuple[int, int]) -> None:
    dut.base_limit_bits.value, dut.enhancement_limit_bits.value = limits
    dut.base_reserved_bits.value, dut.enhancement_reserved_bits.value = reserves
    dut.start_valid.value = 1
    await Timer(1, units="ns")
    while not int(dut.start_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.start_valid.value = 0


async def submit(dut, token: BudgetToken, ready: int = 1) -> tuple[bool, bool, tuple[int, int, int] | None]:
    dut.s_layer.value = int(token.layer)
    dut.s_bits.value = token.value
    dut.s_length.value = token.bit_length
    dut.s_mandatory.value = token.mandatory
    dut.s_reserve_release.value = token.reserve_release
    dut.s_valid.value = 1
    dut.m_ready.value = ready
    await Timer(1, units="ns")
    while not int(dut.s_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.s_valid.value = 0
    output = None
    if int(dut.m_valid.value):
        output = (int(dut.m_layer.value), int(dut.m_bits.value), int(dut.m_length.value))
    dropped = bool(int(dut.drop_pulse.value))
    fatal = bool(int(dut.fatal_error.value))
    if output is not None:
        dut.m_ready.value = 1
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
    return dropped, fatal, output


@cocotb.test()
async def directed_atomic_truncation_and_independent_layers(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await start_writer(dut, (24, 12), (8, 0))

    tokens = (
        BudgetToken(Layer.BASE, 0xAAA, 12),
        BudgetToken(Layer.BASE, 0x1F, 5),
        BudgetToken(Layer.ENHANCEMENT, 0xABC, 12),
        BudgetToken(Layer.BASE, 0x5A, 8, mandatory=True, reserve_release=8),
    )
    expected = DualBudgetWriter(24, 12, 8, 0)
    outputs = []
    drops = []
    for token in tokens:
        admission = expected.submit(token)
        dropped, fatal, output = await submit(dut, token)
        drops.append(dropped)
        assert fatal == expected.fatal
        assert dropped == (admission is Admission.DROPPED)
        if output is not None:
            outputs.append(output)

    assert outputs == [(int(t.layer), t.value, t.bit_length) for t in expected.accepted]
    assert drops == [False, True, False, False]
    assert int(dut.base_used_bits.value) == 20
    assert int(dut.enhancement_used_bits.value) == 12
    assert int(dut.base_remaining_reserve.value) == 0


@cocotb.test()
async def randomized_backpressure_matches_python_model(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xB0D6E7)
    limits = (160, 128)
    reserves = (32, 24)
    expected = DualBudgetWriter(*limits, *reserves)
    await start_writer(dut, limits, reserves)

    tokens: list[BudgetToken] = []
    for _ in range(30):
        tokens.append(BudgetToken(Layer(rng.randrange(2)), rng.getrandbits(32), rng.randrange(1, 17)))
    tokens.extend((
        BudgetToken(Layer.BASE, 0x15, 5, mandatory=True, reserve_release=32),
        BudgetToken(Layer.ENHANCEMENT, 0x3F, 6, mandatory=True, reserve_release=24),
    ))

    observed = []
    for token in tokens:
        admission = expected.submit(token)
        ready = rng.randrange(2)
        dropped, fatal, output = await submit(dut, token, ready)
        if output is not None:
            observed.append(output)
        assert fatal == expected.fatal
        assert dropped == (admission is Admission.DROPPED)

    assert observed == [(int(t.layer), t.value, t.bit_length) for t in expected.accepted]
    assert int(dut.base_used_bits.value) == expected.used[0]
    assert int(dut.enhancement_used_bits.value) == expected.used[1]
    assert int(dut.base_remaining_reserve.value) == expected.reserved[0]
    assert int(dut.enhancement_remaining_reserve.value) == expected.reserved[1]


@cocotb.test()
async def mandatory_overflow_and_unreleased_reserve_are_fatal(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await start_writer(dut, (8, 8), (4, 0))

    dropped, fatal, output = await submit(
        dut, BudgetToken(Layer.BASE, 0x1F, 5, mandatory=True, reserve_release=4)
    )
    assert not dropped and not fatal and output == (0, 0x1F, 5)

    dropped, fatal, output = await submit(
        dut, BudgetToken(Layer.BASE, 0xF, 4, mandatory=True)
    )
    assert not dropped and fatal and output is None
    assert int(dut.base_used_bits.value) == 5

    dut.finish_valid.value = 1
    await Timer(1, units="ns")
    assert int(dut.finish_ready.value)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.finish_valid.value = 0
    assert not int(dut.busy.value)

    await start_writer(dut, (32, 32), (4, 0))
    dropped, fatal, output = await submit(
        dut, BudgetToken(Layer.BASE, 1, 1, reserve_release=1)
    )
    assert not dropped and fatal and output is None
    assert int(dut.base_used_bits.value) == 0

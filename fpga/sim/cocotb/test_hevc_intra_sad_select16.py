from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_block(
    dut, dc_residuals: list[int], planar_residuals: list[int]
) -> None:
    assert len(dc_residuals) == len(planar_residuals) == 256
    for index, (dc_residual, planar_residual) in enumerate(
        zip(dc_residuals, planar_residuals)
    ):
        dut.s_dc_residual.value = dc_residual
        dut.s_planar_residual.value = planar_residual
        dut.s_block_last.value = int(index == 255)
        dut.s_valid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if int(dut.s_ready.value):
                break
    dut.s_valid.value = 0


async def receive_decision(dut, rng: random.Random) -> tuple[bool, int, int]:
    stalled = None
    for _ in range(1000):
        dut.m_ready.value = int(rng.random() < 0.5)
        await RisingEdge(dut.clk)
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        value = (
            bool(dut.m_planar_selected.value),
            int(dut.m_dc_sad.value),
            int(dut.m_planar_sad.value),
        )
        if stalled is not None:
            assert valid == 1
            assert value == stalled
        stalled = value if valid and not ready else None
        if valid and ready:
            return value
    raise AssertionError("SAD decision timed out")


@cocotb.test()
async def selects_lower_sad_and_dc_on_tie(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x5AD16)

    dc = [rng.randrange(-255, 256) for _ in range(256)]
    planar = [value // 2 for value in dc]
    await send_block(dut, dc, planar)
    decision = await receive_decision(dut, rng)
    assert decision == (True, sum(map(abs, dc)), sum(map(abs, planar)))

    tie = [(-1 if index & 1 else 1) * (index % 256) for index in range(256)]
    await send_block(dut, tie, tie)
    decision = await receive_decision(dut, rng)
    assert decision == (False, sum(map(abs, tie)), sum(map(abs, tie)))

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cu_syntax import ctu16_intra_prefix_bins


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.luma_mode_dc.value = 0
    dut.luma_cbf.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_case(dut, luma_mode: int, luma_cbf: bool, rng) -> None:
    dut.start_valid.value = 1
    dut.luma_mode_dc.value = int(luma_mode == 1)
    dut.luma_cbf.value = int(luma_cbf)
    await Timer(1, units="ns")
    assert int(dut.start_ready.value)
    await RisingEdge(dut.clk)
    dut.start_valid.value = 0

    observed = []
    stalled = None
    for _ in range(100):
        dut.m_ready.value = int(rng.random() < 0.62)
        await Timer(1, units="ns")
        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        output = None
        if valid:
            output = (
                int(dut.m_bin.value),
                int(dut.m_kind.value),
                int(dut.m_context_address.value),
                bool(dut.m_last.value),
            )
        if stalled is not None:
            assert valid
            assert output == stalled
        stalled = output if valid and not ready else None
        if valid and ready:
            observed.append(output)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.done.value):
            break
    else:
        raise AssertionError("CTU16 prefix timed out")

    expected = [
        (event.value, event.kind, event.context_address, event.syntax_last)
        for event in ctu16_intra_prefix_bins(luma_mode, luma_cbf)
    ]
    assert observed == expected
    assert not int(dut.busy.value)


@cocotb.test()
async def unsplit_ctu16_prefix_matches_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC7A16)
    for luma_mode, luma_cbf in ((0, False), (0, True), (1, False), (1, True)):
        await run_case(dut, luma_mode, luma_cbf, rng)

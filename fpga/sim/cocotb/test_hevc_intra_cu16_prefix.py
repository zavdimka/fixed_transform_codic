from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.cu_syntax import intra_cu16_prefix_bins


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.cu_index.value = 0
    dut.ctu_x.value = 0
    dut.luma_mode_dc.value = 0
    dut.luma_cbf.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_case(dut, cu_index, ctu_x, luma_mode, luma_cbf, rng) -> None:
    dut.start_valid.value = 1
    dut.cu_index.value = cu_index
    dut.ctu_x.value = ctu_x
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
        raise AssertionError("CU16 prefix timed out")

    expected = [
        (event.value, event.kind, event.context_address, event.syntax_last)
        for event in intra_cu16_prefix_bins(
            cu_index, ctu_x, luma_mode, luma_cbf
        )
    ]
    assert observed == expected
    assert not int(dut.busy.value)


@cocotb.test()
async def fixed_ctu64_cu16_prefix_matches_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0xC016CAB)

    cases = (
        (0, 0, 0, True),
        (0, 1, 1, False),
        (1, 0, 0, False),
        (4, 3, 1, True),
        (8, 0, 0, True),
        (8, 2, 1, False),
        (12, 0, 1, True),
        (15, 5, 0, False),
    )
    for case in cases:
        await run_case(dut, *case, rng)

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.chroma_syntax import last_significant_bins_8


async def reset(dut):
    dut.rst_n.value = 0; dut.s_valid.value = 0; dut.m_ready.value = 0
    for _ in range(3): await RisingEdge(dut.clk)
    dut.rst_n.value = 1; await RisingEdge(dut.clk)


async def run_address(dut, address, rng):
    expected = last_significant_bins_8(address)
    while not int(dut.s_ready.value): await RisingEdge(dut.clk)
    dut.s_raster_address.value = address; dut.s_valid.value = 1
    await RisingEdge(dut.clk); dut.s_valid.value = 0
    received = []; stalled = None
    for _ in range(300):
        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)
        output = (int(dut.m_bin.value), bool(dut.m_bypass.value),
                  bool(dut.m_axis_y.value), int(dut.m_context_index.value))
        valid, ready = int(dut.m_valid.value), int(dut.m_ready.value)
        if stalled is not None: assert valid and output == stalled
        stalled = output if valid and not ready else None
        if valid and ready: received.append(output)
        if len(received) == len(expected): break
    assert received == [(e.value, e.bypass, e.axis_y, e.context_index) for e in expected]


@cocotb.test()
async def all_tu8_positions_match_chroma_reference(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(0x1A578)
    for address in range(64): await run_address(dut, address, rng)

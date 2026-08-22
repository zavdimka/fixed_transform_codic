from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer


@cocotb.test()
async def timing_matches_vic4_720p60(dut) -> None:
    cocotb.start_soon(Clock(dut.pixel_clk, 10, units="ns").start())
    dut.rst_n.value = 0
    await ClockCycles(dut.pixel_clk, 3)
    dut.rst_n.value = 1

    horizontal_de = 0
    horizontal_sync = 0
    for _ in range(1650):
        await RisingEdge(dut.pixel_clk)
        await ReadOnly()
        horizontal_de += int(dut.data_enable.value)
        horizontal_sync += int(dut.hsync.value)
    assert horizontal_de == 1280
    assert horizontal_sync == 40
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 1

    # Skip through autonomous clock activity with a single scheduler wait.
    # We are at line 1; positive vertical sync starts at line 725.
    await Timer(724 * 1650 * 10, units="ns")
    await ReadOnly()
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 725
    assert int(dut.vsync.value) == 1

    await Timer(5 * 1650 * 10, units="ns")
    await ReadOnly()
    assert int(dut.y.value) == 730
    assert int(dut.vsync.value) == 0

    await Timer(20 * 1650 * 10, units="ns")
    await ReadOnly()
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 0
    assert int(dut.frame_start.value) == 1

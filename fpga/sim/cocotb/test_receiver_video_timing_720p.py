from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer


@cocotb.test()
async def timing_matches_720p50(dut) -> None:
    cocotb.start_soon(Clock(dut.pixel_clk, 10, units="ns").start())
    dut.rst_n.value = 0
    await ClockCycles(dut.pixel_clk, 3)
    dut.rst_n.value = 1

    horizontal_de = 0
    horizontal_sync = 0
    for _ in range(1980):
        await RisingEdge(dut.pixel_clk)
        await ReadOnly()
        horizontal_de += int(dut.data_enable.value)
        horizontal_sync += int(dut.hsync.value)
    assert horizontal_de == 1280
    assert horizontal_sync == 40
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 1

    # We are at line 1. CTA requires the leading VSYNC edge to coincide
    # exactly with the leading HSYNC edge on line 724.
    await Timer(723 * 1980 * 10, units="ns")
    await ReadOnly()
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 724
    assert int(dut.vsync.value) == 0

    await Timer(1720 * 10, units="ns")
    await ReadOnly()
    assert int(dut.x.value) == 1720
    assert int(dut.hsync.value) == 1
    assert int(dut.vsync.value) == 1

    await Timer(((1980 - 1720) + 4 * 1980) * 10, units="ns")
    await ReadOnly()
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 729
    assert int(dut.vsync.value) == 1

    await Timer(1720 * 10, units="ns")
    await ReadOnly()
    assert int(dut.x.value) == 1720
    assert int(dut.hsync.value) == 1
    assert int(dut.vsync.value) == 0

    await Timer(((1980 - 1720) + 20 * 1980) * 10, units="ns")
    await ReadOnly()
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 0
    assert int(dut.frame_start.value) == 1

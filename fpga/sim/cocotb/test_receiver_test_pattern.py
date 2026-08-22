from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge


async def apply_and_read(dut, mode: int, x: int, y: int) -> int:
    # Leave a possible ReadOnly phase from the preceding sample.
    await RisingEdge(dut.pixel_clk)
    dut.mode.value = mode
    dut.x.value = x
    dut.y.value = y
    # The pattern pipeline matches the three-cycle OSD/sync latency.
    await ClockCycles(dut.pixel_clk, 4)
    await ReadOnly()
    return int(dut.rgb.value)


@cocotb.test()
async def all_diagnostic_modes_and_pipeline_work(dut) -> None:
    cocotb.start_soon(Clock(dut.pixel_clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.mode.value = 0
    dut.x.value = 0
    dut.y.value = 0
    await ClockCycles(dut.pixel_clk, 3)
    dut.rst_n.value = 1

    assert await apply_and_read(dut, 0, 700, 300) == 0x808080
    assert await apply_and_read(dut, 1, 159, 20) == 0xFFFFFF
    assert await apply_and_read(dut, 1, 160, 20) == 0xFFFF00
    assert await apply_and_read(dut, 1, 1119, 20) == 0x0000FF
    assert await apply_and_read(dut, 1, 1120, 20) == 0x000000

    assert await apply_and_read(dut, 2, 64, 33) == 0xFFFFFF
    assert await apply_and_read(dut, 2, 65, 33) == 0x606060
    assert await apply_and_read(dut, 2, 1, 1) == 0x303030

    x, y = 0x2AC, 0x155
    expected = ((x >> 2) & 0xFF) << 16
    expected |= ((y >> 2) & 0xFF) << 8
    expected |= (x ^ y) & 0xFF
    assert await apply_and_read(dut, 3, x, y) == expected

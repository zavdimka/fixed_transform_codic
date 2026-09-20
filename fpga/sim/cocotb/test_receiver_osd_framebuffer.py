from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge


@cocotb.test()
async def words_are_cleared_written_and_scaled_two_by_two(dut) -> None:
    cocotb.start_soon(Clock(dut.write_clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.pixel_clk, 14, units="ns").start())
    dut.write_rst_n.value = 0
    dut.pixel_rst_n.value = 0
    dut.clear_request.value = 0
    dut.write_valid.value = 0
    dut.write_address.value = 0
    dut.write_data.value = 0
    dut.x.value = 0
    dut.y.value = 0
    dut.data_enable.value = 0
    dut.hsync.value = 0
    dut.vsync.value = 0
    await ClockCycles(dut.write_clk, 3)
    dut.write_rst_n.value = 1
    dut.pixel_rst_n.value = 1

    for _ in range(5800):
        await RisingEdge(dut.write_clk)
        if not int(dut.clear_busy.value):
            break
    assert int(dut.clear_busy.value) == 0
    assert int(dut.write_ready.value) == 1

    # Logical pixels 0, 1, 8 and 39 are opaque in the first 40-pixel word.
    word = (1 << 0) | (1 << 1) | (1 << 8) | (1 << 39)
    dut.write_address.value = 0
    dut.write_data.value = word
    dut.write_valid.value = 1
    await RisingEdge(dut.write_clk)
    dut.write_valid.value = 0
    await ClockCycles(dut.write_clk, 2)

    observed = []
    for x in range(23):
        await FallingEdge(dut.pixel_clk)
        dut.data_enable.value = 1
        dut.x.value = x
        await RisingEdge(dut.pixel_clk)
        await ReadOnly()
        observed.append((int(dut.data_enable_out.value), int(dut.osd_mask.value)))

    # Bank select, byte select and bit select delay the input by three clocks.
    expected_pixels = []
    for x in range(20):
        expected_pixels.append((word >> (x // 2)) & 1)
    assert [mask for valid, mask in observed[3:] if valid] == expected_pixels

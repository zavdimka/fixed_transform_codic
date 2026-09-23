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
    dut.attribute_write_valid.value = 0
    dut.attribute_write_address.value = 0
    dut.attribute_write_data.value = 0
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
    await FallingEdge(dut.pixel_clk)

    # The same path must address the final logical scanline, which lives in
    # bitmap bank 11. Both physical rows select logical row 359.
    bottom_address = 359 * 16
    dut.data_enable.value = 0
    await RisingEdge(dut.pixel_clk)
    dut.write_address.value = bottom_address
    dut.write_data.value = word
    dut.write_valid.value = 1
    await RisingEdge(dut.write_clk)
    dut.write_valid.value = 0
    await ClockCycles(dut.write_clk, 2)

    for y in (718, 719):
        await FallingEdge(dut.pixel_clk)
        dut.data_enable.value = 0
        await RisingEdge(dut.pixel_clk)
        observed = []
        for x in range(23):
            await FallingEdge(dut.pixel_clk)
            dut.data_enable.value = 1
            dut.x.value = x
            dut.y.value = y
            await RisingEdge(dut.pixel_clk)
            await ReadOnly()
            observed.append(
                (int(dut.data_enable_out.value), int(dut.osd_mask.value))
            )
        assert [mask for valid, mask in observed[3:] if valid] == expected_pixels
    await FallingEdge(dut.pixel_clk)

    # Walk the inexpensive line counter to attribute row 29 and verify that
    # its first cell is backed by the fifth attribute RAM bank.
    dut.data_enable.value = 0
    await RisingEdge(dut.pixel_clk)
    for line in range(29 * 24):
        await FallingEdge(dut.pixel_clk)
        dut.data_enable.value = 1
        dut.x.value = 1279
        dut.y.value = line
        await RisingEdge(dut.pixel_clk)
    dut.data_enable.value = 0
    await RisingEdge(dut.pixel_clk)

    bottom_attribute = 0x1A5
    dut.attribute_write_address.value = 29 * 80
    dut.attribute_write_data.value = bottom_attribute
    dut.attribute_write_valid.value = 1
    await RisingEdge(dut.write_clk)
    dut.attribute_write_valid.value = 0
    await ClockCycles(dut.write_clk, 2)

    attributes = []
    for x in range(6):
        await FallingEdge(dut.pixel_clk)
        dut.data_enable.value = 1
        dut.x.value = x
        dut.y.value = 29 * 24
        await RisingEdge(dut.pixel_clk)
        await ReadOnly()
        attributes.append(
            (int(dut.data_enable_out.value), int(dut.osd_attribute.value))
        )
    assert [value for valid, value in attributes[3:] if valid] == [
        bottom_attribute
    ] * 3

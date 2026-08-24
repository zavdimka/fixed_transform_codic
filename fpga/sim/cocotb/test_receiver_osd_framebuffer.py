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

    # Cells are 16x24 physical pixels.  Attribute 0 has an opaque red-ish
    # background and foreground index 4; attribute 1 uses indices 2/10.
    attribute0 = (1 << 8) | (5 << 4) | 4
    attribute1 = (10 << 4) | 2
    attribute80 = (1 << 8) | (3 << 4) | 12
    for address, attribute in ((0, attribute0), (1, attribute1),
                               (80, attribute80)):
        dut.attribute_write_address.value = address
        dut.attribute_write_data.value = attribute
        dut.attribute_write_valid.value = 1
        await RisingEdge(dut.write_clk)
    dut.attribute_write_valid.value = 0
    await ClockCycles(dut.write_clk, 2)

    observed = []
    for x in range(39):
        await FallingEdge(dut.pixel_clk)
        dut.data_enable.value = 1
        dut.x.value = x
        await RisingEdge(dut.pixel_clk)
        await ReadOnly()
        observed.append((
            int(dut.data_enable_out.value),
            int(dut.osd_mask.value),
            int(dut.osd_attribute.value),
        ))

    # Bank select, byte select and bit select delay the input by three clocks.
    expected_pixels = []
    for x in range(36):
        expected_pixels.append((word >> (x // 2)) & 1)
    assert [mask for valid, mask, _ in observed[3:] if valid] == expected_pixels
    assert [attribute for valid, _, attribute in observed[3:] if valid] == (
        [attribute0] * 16 + [attribute1] * 16 + [0x00F] * 4
    )

    # Advance the raster-side 24-line cell counter and verify that row 1,
    # column 0 reads attribute address 80.
    for line in range(24):
        await FallingEdge(dut.pixel_clk)
        dut.x.value = 1279
        dut.y.value = line
        await RisingEdge(dut.pixel_clk)
    row_attributes = []
    for _ in range(4):
        await FallingEdge(dut.pixel_clk)
        dut.x.value = 0
        dut.y.value = 24
        await RisingEdge(dut.pixel_clk)
        await ReadOnly()
        row_attributes.append(int(dut.osd_attribute.value))
    assert row_attributes[-1] == attribute80

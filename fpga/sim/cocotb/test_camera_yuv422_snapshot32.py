from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer


async def reset(dut) -> None:
    dut.pixel_rst_n.value = 0
    dut.read_rst_n.value = 0
    dut.pixel_vsync.value = 0
    dut.pixel_href.value = 0
    dut.pixel_data.value = 0
    dut.arm.value = 0
    dut.vsync_active_high.value = 1
    dut.href_active_high.value = 1
    dut.read_request.value = 0
    dut.read_word_address.value = 0
    for _ in range(5):
        await RisingEdge(dut.read_clk)
    dut.pixel_rst_n.value = 1
    dut.read_rst_n.value = 1


async def read_word(dut, address: int) -> int:
    await Timer(1, units="ns")
    dut.read_word_address.value = address
    dut.read_request.value = 1
    await RisingEdge(dut.read_clk)
    dut.read_request.value = 0
    await RisingEdge(dut.read_clk)
    await ReadOnly()
    assert int(dut.read_valid.value) == 0
    return int(dut.read_word.value)


@cocotb.test()
async def captures_two_raw_yuv422_stripes_without_padding(dut) -> None:
    cocotb.start_soon(Clock(dut.pixel_clk, 12, units="ns").start())
    cocotb.start_soon(Clock(dut.read_clk, 10, units="ns").start())
    await reset(dut)

    dut.arm.value = 1
    await RisingEdge(dut.read_clk)
    dut.arm.value = 0
    for _ in range(8):
        await RisingEdge(dut.pixel_clk)

    dut.pixel_vsync.value = 1
    await RisingEdge(dut.pixel_clk)
    dut.pixel_vsync.value = 0
    await RisingEdge(dut.pixel_clk)

    byte_index = 0
    for line in range(32):
        dut.pixel_href.value = 1
        for column_byte in range(2560):
            value = (line * 17 + column_byte * 3) & 0xFF
            dut.pixel_data.value = value
            await RisingEdge(dut.pixel_clk)
            byte_index += 1
        dut.pixel_href.value = 0
        await RisingEdge(dut.pixel_clk)

    for _ in range(30):
        await RisingEdge(dut.read_clk)
        if int(dut.capture_done.value):
            break

    assert int(dut.capture_done.value)
    assert not int(dut.capture_busy.value)
    assert not int(dut.capture_error.value)
    assert int(dut.captured_lines.value) == 32
    assert int(dut.last_line_bytes.value) == 2560
    assert int(dut.captured_words.value) == 16384

    for word_address in [0, 1, 511, 8192, 16383]:
        observed = await read_word(dut, word_address)
        expected_bytes = []
        for offset in range(5):
            linear = word_address * 5 + offset
            line = linear // 2560
            column_byte = linear % 2560
            expected_bytes.append((line * 17 + column_byte * 3) & 0xFF)
        expected = sum(value << (8 * index)
                       for index, value in enumerate(expected_bytes))
        assert observed == expected

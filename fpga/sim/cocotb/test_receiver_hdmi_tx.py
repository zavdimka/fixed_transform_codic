from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

CONTROL = {
    0: 0b1101010100,
    1: 0b0010101011,
    2: 0b0101010100,
    3: 0b1010101011,
}


async def send_pixel(dut, x: int, y: int, de: int = 0,
                     hs: int = 0, vs: int = 0) -> tuple[int, int, int]:
    await Timer(1, units="ns")
    dut.x.value = x
    dut.y.value = y
    dut.rgb.value = 0x123456
    dut.data_enable.value = de
    dut.hsync.value = hs
    dut.vsync.value = vs
    await RisingEdge(dut.pixel_clk)
    await ReadOnly()
    return tuple(int(word.value) for word in
                 (dut.tmds_blue, dut.tmds_green, dut.tmds_red))


@cocotb.test()
async def dvi_blanking_contains_only_control_symbols(dut) -> None:
    cocotb.start_soon(Clock(dut.pixel_clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.x.value = dut.y.value = dut.rgb.value = 0
    dut.data_enable.value = dut.hsync.value = dut.vsync.value = 0
    await RisingEdge(dut.pixel_clk)
    dut.rst_n.value = 1

    samples = (0, 7, 8, 9, 10, 31, 41, 42, 43, 1719, 1720,
               1759, 1760, 1799, 1800, 1969, 1970, 1977, 1978, 1979)
    for y in (0, 720, 724, 725, 729, 749):
        for x in samples:
            hs = int(1720 <= x < 1760)
            vs = int((y == 724 and x >= 1720) or 725 <= y < 729
                     or (y == 729 and x < 1720))
            words = await send_pixel(dut, x, y, hs=hs, vs=vs)
            assert words == (CONTROL[(vs << 1) | hs], CONTROL[0], CONTROL[0])

    # Active video must switch away from the control period on all channels.
    words = await send_pixel(dut, 0, 0, de=1)
    assert words != (CONTROL[0], CONTROL[0], CONTROL[0])

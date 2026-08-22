from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly


@cocotb.test()
async def emits_low_five_bits_before_high_five_bits(dut) -> None:
    cocotb.start_soon(Clock(dut.half_pixel_clk, 8, units="ns").start())
    dut.rst_n.value = 0
    dut.tmds_word.value = 0
    for _ in range(2):
        await FallingEdge(dut.half_pixel_clk)
    dut.rst_n.value = 1
    dut.tmds_word.value = 0b10110_01101

    await FallingEdge(dut.half_pixel_clk)
    await ReadOnly()
    assert int(dut.serializer_data.value) == 0b01101

    await FallingEdge(dut.half_pixel_clk)
    await ReadOnly()
    assert int(dut.serializer_data.value) == 0b10110

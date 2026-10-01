from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, Timer


async def sample_half(dut) -> tuple[int, int, int]:
    await FallingEdge(dut.half_pixel_clk)
    await ReadOnly()
    value = (
        int(dut.serializer_data0.value),
        int(dut.serializer_data1.value),
        int(dut.serializer_data2.value),
    )
    await Timer(1, units="ps")
    return value


@cocotb.test()
async def all_lanes_realign_on_each_pixel_word(dut) -> None:
    cocotb.start_soon(Clock(dut.half_pixel_clk, 8, units="ns").start())
    dut.rst_n.value = 0
    dut.pixel_word_toggle.value = 0
    dut.tmds_word0.value = 0
    dut.tmds_word1.value = 0
    dut.tmds_word2.value = 0
    await sample_half(dut)
    await sample_half(dut)

    dut.rst_n.value = 1
    dut.tmds_word0.value = 0b10110_01101
    dut.tmds_word1.value = 0b00111_11000
    dut.tmds_word2.value = 0b11100_00011
    dut.pixel_word_toggle.value = 1
    assert await sample_half(dut) == (0b01101, 0b11000, 0b00011)
    assert await sample_half(dut) == (0b10110, 0b00111, 0b11100)

    # Deliberately wait an extra half slot. The next word boundary must
    # recover low-half-first operation for every lane together.
    await sample_half(dut)
    dut.tmds_word0.value = 0b01001_10010
    dut.tmds_word1.value = 0b11111_00000
    dut.tmds_word2.value = 0b00001_11110
    dut.pixel_word_toggle.value = 0
    assert await sample_half(dut) == (0b10010, 0b00000, 0b11110)
    assert await sample_half(dut) == (0b01001, 0b11111, 0b00001)

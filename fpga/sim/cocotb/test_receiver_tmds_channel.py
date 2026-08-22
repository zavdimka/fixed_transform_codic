from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


CONTROL = {
    0b00: 0b1101010100,
    0b01: 0b0010101011,
    0b10: 0b0101010100,
    0b11: 0b1010101011,
}


def encode(data: int, enable: bool, control: int, disparity: int) -> tuple[int, int]:
    if not enable:
        return CONTROL[control], 0

    ones = data.bit_count()
    use_xnor = ones > 4 or (ones == 4 and not (data & 1))
    q = data & 1
    previous = q
    for bit in range(1, 8):
        value = (data >> bit) & 1
        current = int(not (previous ^ value)) if use_xnor else previous ^ value
        q |= current << bit
        previous = current
    q8 = int(not use_xnor)
    balance = 2 * q.bit_count() - 8

    if disparity == 0 or balance == 0:
        word = ((1 - q8) << 9) | (q8 << 8) | (q if q8 else ((~q) & 0xFF))
        disparity = balance if q8 else -balance
    elif (disparity > 0 and balance > 0) or (disparity < 0 and balance < 0):
        word = (1 << 9) | (q8 << 8) | ((~q) & 0xFF)
        disparity = disparity - balance + (2 if q8 else 0)
    else:
        word = (q8 << 8) | q
        disparity = disparity + balance - (0 if q8 else 2)
    return word, disparity


@cocotb.test()
async def control_and_video_symbols_match_reference(dut) -> None:
    cocotb.start_soon(Clock(dut.pixel_clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.video_data.value = 0
    dut.control_data.value = 0
    dut.data_enable.value = 0
    for _ in range(3):
        await RisingEdge(dut.pixel_clk)
    dut.rst_n.value = 1

    disparity = 0
    sequence = [
        (0x00, False, 0b00),
        (0x00, False, 0b01),
        (0x00, False, 0b10),
        (0x00, False, 0b11),
        (0x00, True, 0),
        (0xFF, True, 0),
        (0x80, True, 0),
        (0x7F, True, 0),
        (0x55, True, 0),
        (0xAA, True, 0),
        (0x12, True, 0),
        (0xE7, True, 0),
    ]
    for data, enable, control in sequence:
        await FallingEdge(dut.pixel_clk)
        dut.video_data.value = data
        dut.data_enable.value = enable
        dut.control_data.value = control
        expected, disparity = encode(data, enable, control, disparity)
        await RisingEdge(dut.pixel_clk)
        await ReadOnly()
        assert int(dut.tmds_word.value) == expected

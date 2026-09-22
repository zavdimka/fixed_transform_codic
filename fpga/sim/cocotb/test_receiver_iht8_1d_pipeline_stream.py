from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


WORD_WIDTH = 24
MASK = (1 << WORD_WIDTH) - 1


def inverse_iht8(v: list[int]) -> list[int]:
    c0, c1, c2, c3, c4, c5, c6, c7 = v
    a0, a2 = c0 + c4, c0 - c4
    a4, a6 = (c2 >> 1) - c6, c2 + (c6 >> 1)
    a1 = -c3 + c5 - c7 - (c7 >> 1)
    a3 = c1 + c7 - c3 - (c3 >> 1)
    a5 = -c1 + c7 + c5 + (c5 >> 1)
    a7 = c3 + c5 + c1 + (c1 >> 1)
    b0, b2, b4, b6 = a0 + a6, a2 + a4, a2 - a4, a0 - a6
    b1, b3 = a1 + (a7 >> 2), a3 + (a5 >> 2)
    b5, b7 = (a3 >> 2) - a5, a7 - (a1 >> 2)
    return [b0 + b7, b2 + b5, b4 + b3, b6 + b1,
            b6 - b1, b4 - b3, b2 - b5, b0 - b7]


def pack(values: list[int]) -> int:
    return sum((value & MASK) << (WORD_WIDTH * index)
               for index, value in enumerate(values))


def unpack(value: int) -> list[int]:
    words = [(value >> (WORD_WIDTH * index)) & MASK for index in range(8)]
    return [word - (1 << WORD_WIDTH) if word & (1 << (WORD_WIDTH - 1)) else word for word in words]


@cocotb.test()
async def back_to_back_vectors_remain_bit_exact(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.input_valid.value = 0
    dut.input_tag.value = 0
    dut.input_values.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1

    rng = random.Random(0x1A78)
    vectors = [[0] * 8, [256, 0, 0, 0, 0, 0, 0, 0],
               [0, -31, 22, -17, 9, -5, 3, -1]]
    vectors += [[rng.randint(-32768, 32767) for _ in range(8)]
                for _ in range(29)]
    observed = []

    for cycle in range(len(vectors) + 8):
        await FallingEdge(dut.clk)
        if cycle < len(vectors):
            dut.input_valid.value = 1
            dut.input_tag.value = cycle & 15
            dut.input_values.value = pack(vectors[cycle])
        else:
            dut.input_valid.value = 0
        await RisingEdge(dut.clk)
        if int(dut.output_valid.value):
            observed.append((int(dut.output_tag.value),
                             unpack(int(dut.output_values.value))))

    assert len(observed) == len(vectors)
    for index, (tag, values) in enumerate(observed):
        assert tag == (index & 15)
        assert values == inverse_iht8(vectors[index])

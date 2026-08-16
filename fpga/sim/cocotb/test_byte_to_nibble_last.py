from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.s_last.value = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def last_marks_only_the_final_low_nibble_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    payload = bytes([0x01, 0x23, 0xAB, 0xF0, 0x5E])
    expected = [nibble for byte in payload for nibble in (byte >> 4, byte & 0xF)]
    rng = random.Random(0x4B17)
    source_index = 0
    received: list[tuple[int, int]] = []
    stalled: tuple[int, int] | None = None

    for _ in range(1000):
        if not int(dut.s_valid.value) and source_index < len(payload):
            dut.s_valid.value = 1
            dut.s_data.value = payload[source_index]
            dut.s_last.value = int(source_index == len(payload) - 1)
        dut.m_ready.value = int(rng.random() < 0.55)

        await RisingEdge(dut.clk)

        output = (int(dut.m_data.value), int(dut.m_last.value))
        if stalled is not None:
            assert int(dut.m_valid.value)
            assert output == stalled
        stalled = output if int(dut.m_valid.value) and not int(dut.m_ready.value) else None

        if int(dut.m_valid.value) and int(dut.m_ready.value):
            received.append(output)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0

        if len(received) == len(expected):
            assert [item[0] for item in received] == expected
            assert [index for index, item in enumerate(received) if item[1]] == [len(expected) - 1]
            return

    raise AssertionError("byte-to-nibble transfer timed out")

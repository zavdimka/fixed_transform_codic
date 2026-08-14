from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hevc_reference.debug_interface import bytes_to_nibbles


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def transfer(dut, payload: bytes, seed: int) -> list[int]:
    rng = random.Random(seed)
    source_index = 0
    received: list[int] = []
    stalled_output: int | None = None

    for _ in range(5000):
        # A source must hold valid/data until the handshake completes.
        if not int(dut.s_valid.value) and source_index < len(payload):
            if rng.random() < 0.8:
                dut.s_valid.value = 1
                dut.s_data.value = payload[source_index]

        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)

        output_valid = int(dut.m_valid.value)
        output_ready = int(dut.m_ready.value)
        output_data = int(dut.m_data.value)

        if stalled_output is not None:
            assert output_valid == 1
            assert output_data == stalled_output
        stalled_output = output_data if output_valid and not output_ready else None

        if output_valid and output_ready:
            received.append(output_data)

        if int(dut.s_valid.value) and int(dut.s_ready.value):
            source_index += 1
            dut.s_valid.value = 0

        if source_index == len(payload) and len(received) == 2 * len(payload):
            return received

    raise AssertionError("stream transfer timed out")


@cocotb.test()
async def random_backpressure_preserves_nibble_order(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    payload = bytes([0x00, 0x12, 0xAB, 0xFF]) + bytes(range(64))
    received = await transfer(dut, payload, seed=0x265)

    assert received == bytes_to_nibbles(payload)


@cocotb.test()
async def reset_discards_a_partial_byte(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    dut.s_data.value = 0xAB
    dut.s_valid.value = 1
    await RisingEdge(dut.clk)
    dut.s_valid.value = 0
    dut.m_ready.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.m_data.value) == 0xB

    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.m_valid.value) == 0
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    received = await transfer(dut, bytes([0x34]), seed=7)
    assert received == [0x3, 0x4]

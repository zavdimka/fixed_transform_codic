from __future__ import annotations

import random
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.annexb import build_annexb_nal
from hevc_reference.parameter_sets import parameter_set_rbsps

CTU_SIZE = int(os.environ.get("PARAMETER_SET_CTU_SIZE", "16"))


async def reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start_valid.value = 0
    dut.m_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def emit_parameter_sets(dut, seed: int) -> tuple[bytes, list[int]]:
    rng = random.Random(seed)
    expected_nals = [
        build_annexb_nal(nal_type, rbsp)
        for nal_type, rbsp in zip((32, 33, 34), parameter_set_rbsps(ctu_size=CTU_SIZE))
    ]
    expected = b"".join(expected_nals)

    dut.start_valid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.start_ready.value):
            break
    dut.start_valid.value = 0

    received = bytearray()
    last_positions: list[int] = []
    stalled: tuple[int, int] | None = None

    for _ in range(10000):
        dut.m_ready.value = int(rng.random() < 0.65)
        await RisingEdge(dut.clk)

        valid = int(dut.m_valid.value)
        ready = int(dut.m_ready.value)
        output = (int(dut.m_data.value), int(dut.m_last.value))
        if stalled is not None:
            assert valid
            assert output == stalled
        stalled = output if valid and not ready else None

        if valid and ready:
            received.append(output[0])
            if output[1]:
                last_positions.append(len(received) - 1)

        if int(dut.done.value):
            assert bytes(received) == expected
            assert last_positions == [
                len(expected_nals[0]) - 1,
                len(expected_nals[0]) + len(expected_nals[1]) - 1,
                len(expected) - 1,
            ]
            assert not int(dut.parameter_error.value)
            return bytes(received), last_positions

    raise AssertionError("parameter-set stream timed out")


@cocotb.test()
async def rom_parameter_sets_match_golden_model_under_backpressure(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    first, _ = await emit_parameter_sets(dut, 0x5053)
    second, _ = await emit_parameter_sets(dut, 0x5054)
    assert second == first
